import ChatCore
import Foundation
import Darwin

/// Cursor-only runtime. #9 supplies routing and UI composition.
public actor CursorChatBackend: ChatBackend {
    private struct Acceptance: Codable {
        var conversationID: ConversationID
        var model: ModelSelection
    }
    private struct Archive: Codable {
        var version = 1
        var selected: ConversationID?
        var conversations: [ConversationSnapshot] = []
        var sessions: [String: String] = [:]
        var accepted: [String: Acceptance] = [:]
    }
    private struct Run: Sendable {
        var token: UUID
        var process: CursorProcess
        var assistantID: MessageID
        var resultReceived = false
    }
    private let settings: CursorProviderSettingsService
    private let workspace: URL
    private let archiveURL: URL
    private let storageLock: Int32
    private var archive: Archive
    private var connection: ConnectionState = .disconnected
    private var runs: [ConversationID: Run] = [:]
    private var preparing = Set<ConversationID>()
    private var subscribers: [UUID: AsyncThrowingStream<ChatEvent, any Error>.Continuation] = [:]

    public init(
        storageDirectory: URL = CursorProcess.defaultStorageDirectory,
        settings: CursorProviderSettingsService
    ) throws {
        self.settings = settings
        workspace = storageDirectory.appendingPathComponent("workspace", isDirectory: true)
        archiveURL = storageDirectory.appendingPathComponent("conversations.json")
        try CursorFiles.prepare(storageDirectory)
        try CursorFiles.prepare(workspace)
        let descriptor = open(storageDirectory.appendingPathComponent("runtime.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CursorRuntimeError.storage }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); throw CursorRuntimeError.storage }
        storageLock = descriptor
        do {
            var restored: Archive
            if FileManager.default.fileExists(atPath: archiveURL.path) {
                restored = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: archiveURL))
                guard restored.version == 1,
                      restored.sessions.values.allSatisfy(Self.validSession),
                      Set(restored.conversations.map(\.id)).count == restored.conversations.count,
                      restored.conversations.allSatisfy({ conversation in
                          conversation.id.rawValue.hasPrefix("cursor:conversation:") &&
                          conversation.messages.allSatisfy { $0.conversationID == conversation.id }
                      }),
                      Set(restored.conversations.flatMap(\.messages).map(\.id)).count == restored.conversations.flatMap(\.messages).count,
                      restored.selected == nil || restored.conversations.contains(where: { $0.id == restored.selected }) else {
                    throw CursorRuntimeError.storage
                }
            } else { restored = Archive() }
            for i in restored.conversations.indices {
                if restored.conversations[i].activity.isBusy {
                    restored.conversations[i].activity = .idle
                    restored.sessions.removeValue(forKey: restored.conversations[i].id.rawValue)
                }
                for j in restored.conversations[i].messages.indices where restored.conversations[i].messages[j].status == .streaming {
                    restored.conversations[i].messages[j].status = .stopped
                }
            }
            try CursorFiles.write(restored, to: archiveURL)
            archive = restored
        } catch { close(descriptor); throw CursorRuntimeError.storage }
    }

    deinit {
        for run in runs.values { run.process.cancel() }
        close(storageLock)
    }

    /// Explicit status refresh, for integration after a settings/login change. No model request.
    public func refreshConnection() async throws {
        let statuses = try await settings.snapshot()
        connection = statuses.first?.authentication == .configured ? .connected : .disconnected
        publish(.snapshot(currentSnapshot()))
    }

    public func snapshot() async throws -> ChatSnapshot { currentSnapshot() }

    public func events() async -> AsyncThrowingStream<ChatEvent, any Error> {
        let id = UUID()
        let (stream, continuation) = AsyncThrowingStream<ChatEvent, any Error>.makeStream()
        subscribers[id] = continuation
        continuation.yield(.snapshot(currentSnapshot()))
        continuation.onTermination = { @Sendable [weak self] _ in Task { await self?.removeSubscriber(id) } }
        return stream
    }

    public func createConversation(title: String?) async throws -> ConversationID {
        let id = ConversationID("cursor:conversation:\(UUID().uuidString)")
        let summary = ConversationSummary(id: id, title: title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "New conversation")
        var next = archive
        next.conversations.append(ConversationSnapshot(summary: summary))
        next.selected = id
        try commit(next)
        publish(.snapshot(currentSnapshot()))
        return id
    }

    public func selectConversation(_ id: ConversationID?) async throws {
        if let id { _ = try index(id) }
        var next = archive; next.selected = id
        try commit(next)
        publish(.snapshot(currentSnapshot()))
    }

    public func send(_ request: SendRequest) async throws {
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatBackendError.emptyMessage }
        let i = try index(request.conversationID)
        if let acceptance = archive.accepted[request.messageID.rawValue] {
            guard acceptance.conversationID == request.conversationID, acceptance.model == request.model,
                  archive.conversations[i].messages.contains(where: { $0.id == request.messageID && $0.content == request.text }) else {
                throw ChatBackendError.unavailable("Message ID was already used for a different submission.")
            }
            return
        }
        guard !archive.conversations.flatMap(\.messages).contains(where: { $0.id == request.messageID }) else {
            throw ChatBackendError.unavailable("Message ID is already in use.")
        }
        guard !archive.conversations[i].activity.isBusy, !preparing.contains(request.conversationID) else { throw ChatBackendError.busy }
        guard request.model.account == CursorProviderSettingsService.account,
              CursorProviderSettingsService.validModel(request.model.modelID) else { throw ChatBackendError.noModel }
        preparing.insert(request.conversationID)
        defer { preparing.remove(request.conversationID) }
        let executable = try await settings.prepare(model: request.model)
        try Task.checkCancellation()
        // No suspension between acceptance persistence, publication, and task installation.
        guard !archive.conversations.flatMap(\.messages).contains(where: { $0.id == request.messageID }) else {
            throw ChatBackendError.unavailable("Message ID is already in use.")
        }
        let currentIndex = try index(request.conversationID)
        let assistantID = MessageID("cursor:assistant:\(UUID().uuidString)")
        let token = UUID()
        let process = CursorProcess(executable: executable, workingDirectory: workspace)
        let session = archive.sessions[request.conversationID.rawValue]
        let input = try prompt(request: request, conversation: archive.conversations[currentIndex], resume: session != nil)
        var arguments = ["--print", "--mode", "ask", "--output-format", "stream-json", "--stream-partial-output", "--model", request.model.modelID,
                         "--workspace", workspace.path]
        if let session { arguments += ["--resume", session] }
        var next = archive
        next.conversations[currentIndex].messages.append(ChatMessage(id: request.messageID, conversationID: request.conversationID, role: .user, content: request.text))
        next.conversations[currentIndex].messages.append(ChatMessage(id: assistantID, conversationID: request.conversationID, role: .assistant, content: "", status: .streaming))
        next.conversations[currentIndex].activity = .sending
        next.conversations[currentIndex].summary.updatedAt = .now
        next.accepted[request.messageID.rawValue] = Acceptance(conversationID: request.conversationID, model: request.model)
        try commit(next)
        connection = .connected
        runs[request.conversationID] = Run(token: token, process: process, assistantID: assistantID)
        publish(.conversationUpdated(archive.conversations[currentIndex]))
        Task { [weak self, arguments] in
            do {
                try await process.run(arguments: arguments, input: input) { [weak self] line in
                    try await self?.receive(line, conversationID: request.conversationID, token: token)
                }
                await self?.finish(request.conversationID, token: token, error: nil)
            } catch { await self?.finish(request.conversationID, token: token, error: error) }
        }
    }

    public func stop(conversationID: ConversationID) async throws {
        let i = try index(conversationID)
        guard let run = runs.removeValue(forKey: conversationID) else { return }
        run.process.cancel()
        var next = archive
        next.conversations[i].activity = .idle
        for j in next.conversations[i].messages.indices where next.conversations[i].messages[j].id == run.assistantID {
            next.conversations[i].messages[j].status = .stopped
        }
        next.sessions.removeValue(forKey: conversationID.rawValue)
        do { try commit(next) } catch { storageFailure(); throw CursorRuntimeError.storage }
        publish(.conversationUpdated(archive.conversations[i]))
    }

    private func receive(_ line: Data, conversationID: ConversationID, token: UUID) throws {
        guard var run = runs[conversationID], run.token == token else { return }
        guard let frame = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = frame["type"] as? String,
              !run.resultReceived else { throw CursorRuntimeError.invalidOutput }
        let i = try index(conversationID)
        guard let j = archive.conversations[i].messages.firstIndex(where: { $0.id == run.assistantID }) else { throw CursorRuntimeError.invalidOutput }
        var next = archive
        if let session = frame["session_id"] as? String {
            guard Self.validSession(session) else {
                throw CursorRuntimeError.invalidOutput
            }
            next.sessions[conversationID.rawValue] = session
        }
        switch type {
        case "assistant":
            if frame["timestamp_ms"] != nil, frame["model_call_id"] == nil {
                guard let message = frame["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] else { throw CursorRuntimeError.invalidOutput }
                next.conversations[i].messages[j].content += content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
                next.conversations[i].activity = .streaming
            }
        case "result":
            guard frame["is_error"] as? Bool == false, frame["subtype"] as? String == "success", let text = frame["result"] as? String else {
                throw CursorRuntimeError.invalidOutput
            }
            next.conversations[i].messages[j].content = text
            run.resultReceived = true
        case "system", "user", "tool_call": break
        default: throw CursorRuntimeError.invalidOutput
        }
        guard next.conversations[i].messages[j].content.utf8.count <= 8 * 1024 * 1024 else { throw CursorRuntimeError.invalidOutput }
        try commit(next)
        runs[conversationID] = run
        publish(.conversationUpdated(archive.conversations[i]))
    }

    private func finish(_ id: ConversationID, token: UUID, error: (any Error)?) {
        guard let run = runs[id], run.token == token, let i = try? index(id) else { return }
        runs.removeValue(forKey: id)
        var next = archive
        let failed = error != nil || !run.resultReceived
        next.conversations[i].activity = failed ? .failed("Cursor response failed. Check CLI login, subscription, limits, and compatibility.") : .idle
        next.conversations[i].summary.updatedAt = .now
        for j in next.conversations[i].messages.indices where next.conversations[i].messages[j].id == run.assistantID {
            next.conversations[i].messages[j].status = failed ? .failed : .complete
        }
        if failed { next.sessions.removeValue(forKey: id.rawValue) }
        do {
            try commit(next)
            publish(.conversationUpdated(archive.conversations[i]))
        } catch { storageFailure() }
    }

    private func prompt(request: SendRequest, conversation: ConversationSnapshot, resume: Bool) throws -> String {
        if resume { return request.text }
        if conversation.messages.isEmpty { return request.text }
        struct Turn: Encodable { let role: MessageRole; let content: String }
        let turns = conversation.messages.filter { !$0.content.isEmpty }.map { Turn(role: $0.role, content: $0.content) }
            + [Turn(role: .user, content: request.text)]
        let data = try JSONEncoder().encode(turns)
        return "Continue this conversation. The following JSON is conversation history, ending with the new user message:\n" + String(decoding: data, as: UTF8.self)
    }

    private nonisolated static func validSession(_ session: String) -> Bool {
        guard let first = session.first, first.isLetter || first.isNumber else { return false }
        return session.count <= 256 && session.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    private func index(_ id: ConversationID) throws -> Int {
        guard let i = archive.conversations.firstIndex(where: { $0.id == id }) else { throw ChatBackendError.noConversation }
        return i
    }
    private func commit(_ next: Archive) throws { try CursorFiles.write(next, to: archiveURL); archive = next }
    private func currentSnapshot() -> ChatSnapshot {
        ChatSnapshot(connection: connection, conversations: archive.conversations.map(\.summary), selectedConversationID: archive.selected, loadedConversations: archive.conversations)
    }
    private func publish(_ event: ChatEvent) { for subscriber in subscribers.values { subscriber.yield(event) } }
    private func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }
    var subscriberCount: Int { subscribers.count }
    private func storageFailure() {
        connection = .failed("Cursor conversation storage is unavailable.")
        for i in archive.conversations.indices where archive.conversations[i].activity.isBusy {
            archive.conversations[i].activity = .failed("Cursor conversation storage is unavailable.")
            for j in archive.conversations[i].messages.indices where archive.conversations[i].messages[j].status == .streaming {
                archive.conversations[i].messages[j].status = .failed
            }
        }
        for run in runs.values { run.process.cancel() }
        runs.removeAll()
        publish(.snapshot(currentSnapshot()))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
