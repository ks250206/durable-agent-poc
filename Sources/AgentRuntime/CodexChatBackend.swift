import ChatCore
import Foundation

/// Standalone Codex CLI route. Router/application composition is deliberately owned by #21.
public actor CodexChatBackend: ChatBackend {
    private struct Acceptance: Codable {
        var conversationID: ConversationID
        var model: ModelSelection
        var text: String
    }
    private struct Archive: Codable {
        var version = 1
        var selected: ConversationID?
        var conversations: [ConversationSnapshot] = []
        var threads: [String: String] = [:]
        var accepted: [String: Acceptance] = [:]
    }
    private struct Run {
        let token: UUID
        let process: CodexProcess
        var task: Task<Void, Never>?
        var threadID: String?
        var turnID: String?
        var itemIDs: [String: MessageID] = [:]
        var completedItems: Set<String> = []
    }
    private let settings: CodexProviderSettingsService
    private let workspace: URL
    private let archiveURL: URL
    private let storageLock: CodexStorageLock
    private let requestTimeout: TimeInterval
    private let turnTimeout: TimeInterval
    private var archive: Archive
    private var connection: ConnectionState = .disconnected
    private var runs: [ConversationID: Run] = [:]
    private var preparing: [ConversationID: (token: UUID, task: Task<URL, any Error>)] = [:]
    private var subscribers: [UUID: AsyncThrowingStream<ChatEvent, any Error>.Continuation] = [:]
    private var closed = false
    private var shutdownFinished = false
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopping: [ConversationID: Task<Void, Never>] = [:]
    private var workers: [UUID: (CodexProcess, Task<Void, Never>)] = [:]

    public init(
        storageDirectory: URL = CodexProcess.defaultStorageDirectory,
        settings: CodexProviderSettingsService,
        requestTimeout: TimeInterval = 20, turnTimeout: TimeInterval = 600
    ) throws {
        self.settings = settings; self.requestTimeout = requestTimeout; self.turnTimeout = turnTimeout
        try CodexFiles.prepare(storageDirectory)
        workspace = storageDirectory.resolvingSymlinksInPath().appendingPathComponent("workspace", isDirectory: true)
        try CodexFiles.prepare(workspace)
        archiveURL = storageDirectory.appendingPathComponent("conversations.json")
        storageLock = try CodexStorageLock(directory: storageDirectory)
        do {
            var restored = try CodexFiles.read(Archive.self, from: archiveURL) ?? Archive()
            let conversations = restored.conversations, ids = Set(conversations.map(\.id))
            let messages = conversations.flatMap(\.messages)
            guard restored.version == 1, ids.count == conversations.count,
                  Set(messages.map(\.id)).count == messages.count,
                  conversations.allSatisfy({ c in c.id.rawValue.hasPrefix("codex:conversation:") && c.messages.allSatisfy { $0.conversationID == c.id } }),
                  restored.selected.map({ ids.contains($0) }) ?? true,
                  restored.threads.allSatisfy({ ids.contains(ConversationID($0.key)) && CodexProviderSettingsService.validIdentifier($0.value) }),
                  restored.accepted.allSatisfy({ key, acceptance in
                      acceptance.model.account == CodexProviderSettingsService.account &&
                      CodexProviderSettingsService.validIdentifier(acceptance.model.modelID) &&
                      conversations.contains { c in c.id == acceptance.conversationID && c.messages.contains { $0.id.rawValue == key && $0.role == .user && $0.content == acceptance.text } }
                  }) else { throw CodexRuntimeError.storage }
            for i in restored.conversations.indices {
                if restored.conversations[i].activity.isBusy { restored.conversations[i].activity = .idle }
                for j in restored.conversations[i].messages.indices where restored.conversations[i].messages[j].status == .streaming {
                    restored.conversations[i].messages[j].status = .stopped
                }
            }
            // Keep thread IDs even for interrupted turns: never replay an accepted user submission.
            try CodexFiles.write(restored, to: archiveURL)
            archive = restored
        } catch { storageLock.release(); throw CodexRuntimeError.storage }
    }
    deinit { for run in runs.values { run.task?.cancel(); let p = run.process; Task { await p.shutdown() } }; for p in preparing.values { p.task.cancel() }; storageLock.release() }

    public func refreshConnection() async throws {
        try ensureOpen()
        let statuses = try await settings.snapshot()
        try ensureOpen()
        connection = statuses.first?.authentication == .configured ? .connected : .disconnected
        publish(.snapshot(currentSnapshot()))
    }
    public func snapshot() async throws -> ChatSnapshot { currentSnapshot() }
    public func events() async -> AsyncThrowingStream<ChatEvent, any Error> {
        let id = UUID()
        let (stream, continuation) = AsyncThrowingStream<ChatEvent, any Error>.makeStream()
        guard !closed else { continuation.yield(.snapshot(currentSnapshot())); continuation.finish(); return stream }
        subscribers[id] = continuation
        continuation.yield(.snapshot(currentSnapshot()))
        continuation.onTermination = { @Sendable [weak self] _ in Task { await self?.removeSubscriber(id) } }
        return stream
    }
    public func createConversation(title: String?) async throws -> ConversationID {
        try ensureOpen()
        let id = ConversationID("codex:conversation:\(UUID())")
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = archive
        next.conversations.append(ConversationSnapshot(summary: ConversationSummary(id: id, title: name?.isEmpty == false ? name! : "New conversation")))
        next.selected = id
        try commit(next); publish(.snapshot(currentSnapshot()))
        return id
    }
    public func selectConversation(_ id: ConversationID?) async throws {
        try ensureOpen()
        if let id { _ = try index(id) }
        var next = archive; next.selected = id
        try commit(next); publish(.snapshot(currentSnapshot()))
    }
    private func isAccepted(_ request: SendRequest) throws -> Bool {
        if let previous = archive.accepted[request.messageID.rawValue] {
            guard previous.conversationID == request.conversationID, previous.model == request.model, previous.text == request.text else {
                throw ChatBackendError.unavailable("Message ID was already used for a different submission.")
            }
            return true
        }
        guard !archive.conversations.flatMap(\.messages).contains(where: { $0.id == request.messageID }) else {
            throw ChatBackendError.unavailable("Message ID is already in use.")
        }
        return false
    }
    public func send(_ request: SendRequest) async throws {
        try ensureOpen(); try Task.checkCancellation()
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatBackendError.emptyMessage }
        guard request.text.utf8.count <= 1024 * 1024, CodexProviderSettingsService.validIdentifier(request.messageID.rawValue) else {
            throw ChatBackendError.unavailable("Codex submission is too large or has an invalid message ID.")
        }
        let i = try index(request.conversationID)
        if try isAccepted(request) { return }
        guard request.model.account == CodexProviderSettingsService.account else { throw ChatBackendError.noModel }
        guard !archive.conversations[i].activity.isBusy, preparing[request.conversationID] == nil, stopping[request.conversationID] == nil else { throw ChatBackendError.busy }
        let token = UUID(), preparation = Task { [settings] in try await settings.prepare(model: request.model) }
        preparing[request.conversationID] = (token, preparation)
        defer { if preparing[request.conversationID]?.token == token { preparing.removeValue(forKey: request.conversationID) } }
        let executable = try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
        try Task.checkCancellation(); try ensureOpen()
        guard preparing[request.conversationID]?.token == token else { throw CancellationError() }
        if try isAccepted(request) { return }
        let current = try index(request.conversationID)
        let process = CodexProcess(executable: executable, workingDirectory: workspace, requestTimeout: requestTimeout)
        var next = archive
        next.conversations[current].messages.append(ChatMessage(id: request.messageID, conversationID: request.conversationID, role: .user, content: request.text))
        next.conversations[current].activity = .sending
        next.conversations[current].summary.updatedAt = .now
        next.accepted[request.messageID.rawValue] = Acceptance(conversationID: request.conversationID, model: request.model, text: request.text)
        try commit(next)
        connection = .connected
        runs[request.conversationID] = Run(token: token, process: process)
        publish(.conversationUpdated(archive.conversations[current]))
        // Admission, durable user+busy event, and owned task installation are atomic on this actor.
        let task = Task { [weak self] in
            guard let self else { await process.shutdown(); return }
            let deadline = Task { [turnTimeout] in
                do { try await Task.sleep(for: .seconds(max(0.01, turnTimeout))) } catch { return }
                await process.shutdown()
            }
            do {
                try await self.generate(request, token: token, process: process)
                deadline.cancel(); await process.shutdown()
            } catch {
                deadline.cancel(); await process.shutdown()
                await self.finishFailure(request.conversationID, token: token)
            }
            await self.workerFinished(token)
        }
        runs[request.conversationID]?.task = task
        workers[token] = (process, task)
    }

    private func generate(_ request: SendRequest, token: UUID, process: CodexProcess) async throws {
        let id = request.conversationID
        let cwd = try CodexFiles.canonicalPath(workspace)
        try requireRun(id, token)
        try await process.start()
        let account = try await process.request("account/read", .object(["refreshToken": .bool(false)]))
        guard try CodexProviderSettingsService.authentication(account) == .configured else { throw ChatBackendError.disconnected }
        try requireRun(id, token)
        var params: [String: CodexJSON] = ["model": .string(request.model.modelID), "modelProvider": .string("openai"),
            "cwd": .string(cwd), "approvalPolicy": .string("never"), "approvalsReviewer": .string("user"), "sandbox": .string("read-only")]
        let previous = archive.threads[id.rawValue]
        if let previous { params["threadId"] = .string(previous) }
        let result = try await process.request(previous == nil ? "thread/start" : "thread/resume", .object(params))
        try requireRun(id, token)
        guard let thread = result["thread"]["id"].string, CodexProviderSettingsService.validIdentifier(thread),
              previous == nil || previous == thread,
              result["approvalPolicy"] == .string("never"), result["approvalsReviewer"] == .string("user"),
              result["sandbox"]["type"] == .string("readOnly"), result["sandbox"]["networkAccess"] != .bool(true),
              result["cwd"].string == cwd, result["modelProvider"] == .string("openai") else {
            throw CodexRuntimeError.invalidOutput
        }
        var next = archive; next.threads[id.rawValue] = thread
        try commit(next)
        runs[id]?.threadID = thread
        try Task.checkCancellation(); try requireRun(id, token)
        let response = try await process.request("turn/start", .object([
            "threadId": .string(thread), "clientUserMessageId": .string(request.messageID.rawValue),
            "input": .array([.object(["type": .string("text"), "text": .string(request.text), "text_elements": .array([])])]),
            "model": .string(request.model.modelID), "cwd": .string(cwd),
            "approvalPolicy": .string("never"), "approvalsReviewer": .string("user"),
            "sandboxPolicy": .object(["type": .string("readOnly"), "networkAccess": .bool(false)])
        ]))
        try requireRun(id, token)
        guard let turn = response["turn"]["id"].string, CodexProviderSettingsService.validIdentifier(turn) else { throw CodexRuntimeError.invalidOutput }
        runs[id]?.turnID = turn
        // Notifications can precede the turn/start response; the bounded queue preserves their wire order.
        for try await frame in await process.notifications() {
            try Task.checkCancellation(); try requireRun(id, token)
            if try receive(frame, conversationID: id, token: token) { return }
        }
        throw CodexRuntimeError.exited
    }

    /// Idempotent item completion replaces deltas; repeated equal deltas are legitimate without a wire sequence ID.
    private func receive(_ frame: CodexJSON, conversationID id: ConversationID, token: UUID) throws -> Bool {
        guard var run = runs[id], run.token == token else { return true }
        let params = frame["params"], method = frame["method"].string
        // Other thread/turn events are unrelated, including late notifications after an interrupt.
        guard params["threadId"].string == run.threadID else { return false }
        let eventTurn = params["turnId"].string ?? params["turn"]["id"].string
        guard eventTurn == run.turnID else { return false }
        let i = try index(id)
        var next = archive
        switch method {
        case "item/agentMessage/delta":
            guard let item = params["itemId"].string, let text = params["delta"].string else { throw CodexRuntimeError.invalidOutput }
            if !run.completedItems.contains(item) { try upsert(item, text: text, append: true, run: &run, conversation: &next.conversations[i]) }
            next.conversations[i].activity = .streaming
        case "item/completed":
            let item = params["item"]
            if item["type"] == .string("agentMessage") {
                guard let itemID = item["id"].string, let text = item["text"].string else { throw CodexRuntimeError.invalidOutput }
                try upsert(itemID, text: text, append: false, run: &run, conversation: &next.conversations[i])
                run.completedItems.insert(itemID)
            }
        case "turn/completed":
            let turn = params["turn"]
            guard let items = turn["items"].array, let status = turn["status"].string,
                  ["completed", "interrupted", "failed"].contains(status) else { throw CodexRuntimeError.invalidOutput }
            var order: [MessageID] = [], seen = Set<String>()
            for item in items where item["type"] == .string("agentMessage") {
                guard let itemID = item["id"].string, let text = item["text"].string, seen.insert(itemID).inserted else { throw CodexRuntimeError.invalidOutput }
                try upsert(itemID, text: text, append: false, run: &run, conversation: &next.conversations[i])
                order.append(run.itemIDs[itemID]!)
            }
            // The final payload is authoritative for item order; retain stream-only partial items too.
            let itemIDs = Set(run.itemIDs.values)
            let active = next.conversations[i].messages.filter { itemIDs.contains($0.id) }
            next.conversations[i].messages.removeAll { itemIDs.contains($0.id) }
            next.conversations[i].messages += order.compactMap { wanted in active.first { $0.id == wanted } }
            next.conversations[i].messages += active.filter { !order.contains($0.id) }
            let messageStatus: MessageStatus = status == "completed" ? .complete : status == "interrupted" ? .stopped : .failed
            for j in next.conversations[i].messages.indices where itemIDs.contains(next.conversations[i].messages[j].id) {
                next.conversations[i].messages[j].status = messageStatus
            }
            next.conversations[i].activity = status == "failed" ? .failed(Self.failureMessage) : .idle
            next.conversations[i].summary.updatedAt = .now
            try commit(next); runs.removeValue(forKey: id)
            publish(.conversationUpdated(archive.conversations[i])); return true
        case "error":
            // Error notifications may describe retries; fatal completion is turn/completed.failed.
            return false
        default: return false
        }
        try commit(next); runs[id] = run
        publish(.conversationUpdated(archive.conversations[i]))
        return false
    }
    private func upsert(_ item: String, text: String, append: Bool, run: inout Run, conversation: inout ConversationSnapshot) throws {
        guard CodexProviderSettingsService.validIdentifier(item), text.utf8.count <= 8 * 1024 * 1024 else { throw CodexRuntimeError.invalidOutput }
        let messageID: MessageID
        if let mapped = run.itemIDs[item] { messageID = mapped }
        else {
            guard run.itemIDs.count < 10_000 else { throw CodexRuntimeError.invalidOutput }
            messageID = MessageID("codex:assistant:\(run.token.uuidString):\(item)")
            guard !archive.conversations.flatMap(\.messages).contains(where: { $0.id == messageID }) else { throw CodexRuntimeError.invalidOutput }
            run.itemIDs[item] = messageID
            conversation.messages.append(ChatMessage(id: messageID, conversationID: conversation.id, role: .assistant, content: "", status: .streaming))
        }
        guard let j = conversation.messages.firstIndex(where: { $0.id == messageID }) else { throw CodexRuntimeError.invalidOutput }
        let content = append ? conversation.messages[j].content + text : text
        guard content.utf8.count <= 8 * 1024 * 1024 else { throw CodexRuntimeError.invalidOutput }
        conversation.messages[j].content = content
    }

    public func stop(conversationID: ConversationID) async throws {
        try ensureOpen(); _ = try index(conversationID)
        if let stopping = stopping[conversationID] { await stopping.value; return }
        let preparation = preparing.removeValue(forKey: conversationID)?.task
        preparation?.cancel()
        let run = runs.removeValue(forKey: conversationID)
        let cleanupTask = run.map { run in Task { await self.cleanup(run) } }
        if let cleanupTask { stopping[conversationID] = cleanupTask }
        defer { stopping.removeValue(forKey: conversationID) }
        // Publish idle/stopped before any interrupt suspension; late events cannot revive this run.
        if run != nil {
            do { try markStopped(conversationID) }
            catch {
                await cleanupTask?.value
                if let preparation { _ = await preparation.result }
                throw CodexRuntimeError.storage
            }
        }
        if let preparation { _ = await preparation.result }
        await cleanupTask?.value
    }
    private func cleanup(_ run: Run) async {
        if let thread = run.threadID, let turn = run.turnID {
            _ = try? await run.process.request("turn/interrupt", .object(["threadId": .string(thread), "turnId": .string(turn)]), timeout: min(requestTimeout, 2))
        }
        run.task?.cancel()
        await run.process.shutdown()
        await run.task?.value
    }
    private func markStopped(_ id: ConversationID) throws {
        let i = try index(id)
        var next = archive
        next.conversations[i].activity = .idle
        for j in next.conversations[i].messages.indices where next.conversations[i].messages[j].status == .streaming {
            next.conversations[i].messages[j].status = .stopped
        }
        next.conversations[i].summary.updatedAt = .now
        try commit(next); publish(.conversationUpdated(archive.conversations[i]))
    }
    private static let failureMessage = "Codex response failed. Check CLI compatibility, ChatGPT login, access, and limits."
    private func finishFailure(_ id: ConversationID, token: UUID) {
        guard runs[id]?.token == token, let i = try? index(id) else { return }
        runs.removeValue(forKey: id)
        var next = archive
        next.conversations[i].activity = .failed(Self.failureMessage)
        for j in next.conversations[i].messages.indices where next.conversations[i].messages[j].status == .streaming {
            next.conversations[i].messages[j].status = .failed
        }
        do { try commit(next); publish(.conversationUpdated(archive.conversations[i])) }
        catch { connection = .failed(CodexRuntimeError.storage.localizedDescription); publish(.snapshot(currentSnapshot())) }
    }
    public func shutdown() async {
        if closed {
            if !shutdownFinished { await withCheckedContinuation { shutdownWaiters.append($0) } }
            return
        }
        closed = true; connection = .disconnected
        let preparations = Array(preparing.values), active = runs
        preparing.removeAll(); runs.removeAll()
        for p in preparations { p.task.cancel() }
        for id in active.keys { try? markStopped(id) }
        for p in preparations { _ = await p.task.result }
        for run in active.values { await cleanup(run) }
        let remaining = Array(workers.values)
        for (process, task) in remaining { task.cancel(); await process.shutdown(); await task.value }
        workers.removeAll()
        for task in Array(stopping.values) { await task.value }; stopping.removeAll()
        publish(.snapshot(currentSnapshot()))
        for continuation in subscribers.values { continuation.finish() }; subscribers.removeAll()
        storageLock.release()
        shutdownFinished = true
        for waiter in shutdownWaiters { waiter.resume() }; shutdownWaiters.removeAll()
    }
    private func workerFinished(_ token: UUID) { workers.removeValue(forKey: token) }
    private func requireRun(_ id: ConversationID, _ token: UUID) throws {
        try Task.checkCancellation(); try ensureOpen()
        guard runs[id]?.token == token else { throw CancellationError() }
    }
    private func ensureOpen() throws { guard !closed else { throw CodexRuntimeError.closed } }
    private func index(_ id: ConversationID) throws -> Int {
        guard let i = archive.conversations.firstIndex(where: { $0.id == id }) else { throw ChatBackendError.noConversation }
        return i
    }
    private func commit(_ next: Archive) throws { try CodexFiles.write(next, to: archiveURL); archive = next }
    private func currentSnapshot() -> ChatSnapshot {
        ChatSnapshot(connection: connection, conversations: archive.conversations.map(\.summary), selectedConversationID: archive.selected, loadedConversations: archive.conversations)
    }
    private func publish(_ event: ChatEvent) { for c in subscribers.values { c.yield(event) } }
    private func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }
    var subscriberCount: Int { subscribers.count }
}
