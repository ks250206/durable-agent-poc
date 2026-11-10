import ChatCore
import Foundation
import PiDurableKit

/// One owner per SQLite file. Call close() before reopening; see docs/PiRuntime.md.
/// Installs no extensions, tools, execution environment, telemetry, or logging callbacks.
public actor PiChatBackend: ChatBackend {
    private struct AcceptedInput: Codable, Sendable {
        var id: ChatCore.MessageID
        var text: String
        var createdAt: Date
    }
    private struct Metadata: Codable, Sendable {
        var summary: ConversationSummary?
        var accepted: [AcceptedInput] = []
    }
    private struct Selection: Codable, Sendable { var id: ChatCore.ConversationID? }
    private static let metadata = Document("durable-chat.conversation", initial: Metadata())
    private static let selection = Document("durable-chat.selection", scope: .session, initial: Selection())
    private let harness: Harness
    private let settings: PiProviderSettingsService
    private var state = ChatSnapshot()
    private var handles: [ChatCore.ConversationID: Conversation] = [:]
    private var history: [ChatCore.ConversationID: [Entry]] = [:]
    private var watchers: [ChatCore.ConversationID: Task<Void, Never>] = [:]
    private var settingsWatcher: Task<Void, Never>?
    private var subscribers: [UUID: AsyncThrowingStream<ChatEvent, any Error>.Continuation] = [:]
    private var closed = false
    private var observationHasFailed = false
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public static func applicationSupportDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            .appendingPathComponent("DurableChat", isDirectory: true)
    }

    /// Opening restores every conversation and stops interrupted work without resuming provider requests.
    /// A new explicit, configured send starts generation. Test callers supply a temporary databaseURL.
    public static func open(
        settings: PiProviderSettingsService, databaseURL: URL? = nil
    ) async throws -> PiChatBackend {
        let url = try databaseURL ?? applicationSupportDirectory().appendingPathComponent("conversations.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let harness: Harness
        do {
            harness = try await Harness.open(
                .sqlite(at: url), models: settings.models, extensions: [],
                settings: Settings(extensions: [], retry: .init(enabled: false), compaction: .init(enabled: false),
                                   progress: .init(partialInterval: .milliseconds(30))), resume: false)
        } catch { throw ChatBackendError.unavailable("The conversation database could not be opened.") }
        let backend = PiChatBackend(harness: harness, settings: settings)
        do { try await backend.restore() }
        catch {
            try? await harness.close()
            throw ChatBackendError.unavailable("Saved conversations could not be restored.")
        }
        return backend
    }

    private init(harness: Harness, settings: PiProviderSettingsService) {
        self.harness = harness
        self.settings = settings
    }

    private func restore() async throws {
        var cursor: Cursor?
        repeat {
            let page = try await harness.conversations(limit: 100, after: cursor)
            for record in page.items {
                guard let conversation = try await harness.conversation(record.id) else { continue }
                let id = Self.id(record.id)
                handles[id] = conversation
                var entries: [Entry] = []
                var entryCursor: Cursor?
                repeat {
                    let page = try await conversation.entries(order: .ascending, limit: 100, after: entryCursor)
                    entries += page.items
                    entryCursor = page.next
                } while entryCursor != nil
                history[id] = entries
                // abort does not submit new input; it retains committed partials as aborted assistant entries.
                let view = try await conversation.view()
                if view.isBusy || !view.inbox.isEmpty { try await conversation.abort() }
                try await refresh(id)
            }
            cursor = page.next
        } while cursor != nil
        let selection = try await harness.document(Self.selection)
        state.selectedConversationID = selection.id.flatMap { handles[$0] == nil ? nil : $0 }
        try await refreshConnection()
        for id in state.conversations.map(\.id) { observe(id) }
        let stream = await settings.changes()
        settingsWatcher = Task { [weak self] in
            for await _ in stream {
                guard !Task.isCancelled else { break }
                await self?.settingsChanged()
            }
        }
    }

    public func snapshot() async throws -> ChatSnapshot { state }

    /// Registration and initial yield occur in one actor turn, with no await or subscription gap.
    public func events() async -> AsyncThrowingStream<ChatEvent, any Error> {
        let id = UUID()
        let (stream, continuation) = AsyncThrowingStream<ChatEvent, any Error>.makeStream()
        continuation.yield(.snapshot(state))
        if closed { continuation.finish(); return stream }
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        return stream
    }

    public func createConversation(title: String? = nil) async throws -> ChatCore.ConversationID {
        await acquire()
        defer { release() }
        try checkOpen()
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title.flatMap { $0.isEmpty ? nil : $0 } ?? "New conversation"
        do {
            let conversation = try await harness.createConversation(
                agent: AgentChange(extensions: .only([]), tools: .only([])),
                initialize: { tx, id in
                    let summary = ConversationSummary(id: Self.id(id), title: name)
                    try await tx.setDocument(Self.metadata, Metadata(summary: summary), of: .conversation(id))
                    try await tx.setDocument(Self.selection, Selection(id: Self.id(id)), of: .session)
                })
            let id = Self.id(conversation.id)
            handles[id] = conversation
            history[id] = []
            try await refresh(id)
            state.selectedConversationID = id
            observe(id)
            publish(.snapshot(state))
            return id
        } catch { throw safe(error, fallback: "The conversation could not be created.") }
    }

    public func selectConversation(_ id: ChatCore.ConversationID?) async throws {
        await acquire()
        defer { release() }
        try checkOpen()
        if let id, handles[id] == nil { throw ChatBackendError.noConversation }
        do {
            try await harness.update(Self.selection) { $0.id = id }
            state.selectedConversationID = id
            publish(.snapshot(state))
        } catch { throw safe(error, fallback: "The conversation selection could not be saved.") }
    }

    public func send(_ request: SendRequest) async throws {
        await acquire()
        defer { release() }
        try checkOpen()
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatBackendError.emptyMessage }
        guard let conversation = handles[request.conversationID] else { throw ChatBackendError.noConversation }
        do {
            let existing = try await harness.commit { tx in
                try await tx.submission(in: conversation.id, requestId: request.messageID.rawValue)
            }
            // Retries acknowledge the original durable submission even if busy or credentials were removed.
            if existing != nil {
                let metadata = try await conversation.document(Self.metadata)
                guard metadata.accepted.first(where: { $0.id == request.messageID })?.text == request.text else {
                    throw ChatBackendError.unavailable("This message ID already identifies a different submission.")
                }
                try await refresh(request.conversationID)
                if let snapshot = state.loadedConversations.first(where: { $0.id == request.conversationID }) {
                    publish(.conversationUpdated(snapshot))
                }
                return
            }
            let statuses = try await settings.snapshot()
            guard let status = statuses.first(where: { $0.configuration.account == request.model.account }),
                  status.authentication == .configured else { throw ChatBackendError.disconnected }
            guard status.models.contains(where: { $0.id == request.model }) else { throw ChatBackendError.noModel }
            try Task.checkCancellation()
            let view = try await conversation.view()
            guard !view.isBusy, view.inbox.isEmpty else { throw ChatBackendError.busy }
            try await conversation.configure(AgentChange(
                model: ModelRef(provider: ProviderID(request.model.account.providerID), modelId: request.model.modelID),
                extensions: .only([]), tools: .only([])))
            let metadata = try await conversation.document(Self.metadata)
            let accepted = metadata.accepted.first { $0.id == request.messageID }
                ?? AcceptedInput(id: request.messageID, text: request.text, createdAt: Date())
            guard accepted.text == request.text else {
                throw ChatBackendError.unavailable("This message ID already identifies a different submission.")
            }
            // Write the candidate before admission. Recovery shows it only if Pi has the matching
            // durable submission. This covers crashes on either side of submit, including an
            // accepted input aborted while it was still in the inbox.
            try await conversation.update(Self.metadata) { metadata in
                if !metadata.accepted.contains(where: { $0.id == accepted.id }) { metadata.accepted.append(accepted) }
            }
            let entry = InputEntry(kind: "durable-chat.user", data: [
                "clientMessageID": .string(accepted.id.rawValue),
                "createdAt": .number(accepted.createdAt.timeIntervalSince1970),
            ])
            try Task.checkCancellation()
            _ = try await conversation.submit(request.text, whenBusy: .reject,
                                              requestId: request.messageID.rawValue, entry: entry)
            // Publish acceptance synchronously from the durable submission; observation can lag.
            if let index = state.loadedConversations.firstIndex(where: { $0.id == request.conversationID }) {
                var snapshot = state.loadedConversations[index]
                snapshot.messages.append(ChatMessage(id: accepted.id, conversationID: request.conversationID,
                                                     role: .user, content: accepted.text, createdAt: accepted.createdAt))
                snapshot.summary.updatedAt = max(snapshot.summary.updatedAt, accepted.createdAt)
                snapshot.activity = .sending
                state.loadedConversations[index] = snapshot
                if let summaryIndex = state.conversations.firstIndex(where: { $0.id == request.conversationID }) {
                    state.conversations[summaryIndex] = snapshot.summary
                }
                publish(.conversationUpdated(snapshot))
            }
        } catch { throw safe(error, fallback: "The message could not be submitted.") }
    }

    public func stop(conversationID id: ChatCore.ConversationID) async throws {
        await acquire()
        defer { release() }
        try checkOpen()
        guard let conversation = handles[id] else { throw ChatBackendError.noConversation }
        do {
            if let index = state.loadedConversations.firstIndex(where: { $0.id == id }),
               state.loadedConversations[index].activity.isBusy {
                state.loadedConversations[index].activity = .stopping
                publish(.conversationUpdated(state.loadedConversations[index]))
            }
            try await conversation.abort()
            try await refresh(id)
        } catch { throw safe(error, fallback: "The conversation could not be stopped.") }
    }

    /// Idempotent, explicit shutdown. Aborts work, preserves partial output, finishes subscribers, closes SQLite.
    /// The owner must await this before constructing another backend over the same file.
    public func close() async throws {
        await acquire()
        defer { release() }
        if closed { return }
        closed = true
        settingsWatcher?.cancel()
        settingsWatcher = nil
        for watcher in watchers.values { watcher.cancel() }
        watchers.removeAll()
        var failed = false
        for id in state.conversations.map(\.id) {
            do {
                try await handles[id]?.abort()
                try await refresh(id)
            } catch { failed = true }
        }
        // Even if abort/read fails, always release the harness and its SQLite connection.
        do { try await harness.close() } catch { failed = true }
        if failed {
            state.connection = .failed("The conversation database could not be closed cleanly.")
            publish(.snapshot(state))
            finishSubscribers()
            throw ChatBackendError.unavailable("The conversation database could not be closed cleanly.")
        }
        state.connection = .disconnected
        publish(.snapshot(state))
        finishSubscribers()
    }

    private func observe(_ id: ChatCore.ConversationID) {
        guard let conversation = handles[id] else { return }
        let stream = conversation.changes()
        watchers[id] = Task { [weak self] in
            do {
                for try await _ in stream {
                    guard !Task.isCancelled else { break }
                    await self?.conversationChanged(id)
                }
                if !Task.isCancelled { await self?.observationFailed() }
            } catch {
                if !Task.isCancelled { await self?.observationFailed() }
            }
        }
    }

    private func conversationChanged(_ id: ChatCore.ConversationID) async {
        await acquire()
        defer { release() }
        guard !closed else { return }
        do { try await refresh(id) }
        catch { failObservation() }
    }

    private func settingsChanged() async {
        await acquire()
        defer { release() }
        guard !closed, !observationHasFailed else { return }
        do {
            let connection = state.connection
            try await refreshConnection()
            if state.connection != connection { publish(.snapshot(state)) }
        }
        catch { failObservation() }
    }

    private func observationFailed() async {
        await acquire()
        defer { release() }
        if !closed { failObservation() }
    }
    private func failObservation() {
        observationHasFailed = true
        state.connection = .failed("The runtime could not refresh its saved state. Close and reopen it.")
        publish(.snapshot(state))
    }

    private func refreshConnection() async throws {
        let statuses = try await settings.snapshot()
        state.connection = statuses.contains { $0.authentication == .configured && !$0.models.isEmpty } ? .connected : .disconnected
    }

    private func refresh(_ id: ChatCore.ConversationID) async throws {
        guard let conversation = handles[id] else { throw ChatBackendError.noConversation }
        let view = try await conversation.view()
        // Keep older contexts as well as all submessages. No page/depth/transcript truncation.
        var entries = Dictionary(uniqueKeysWithValues: (history[id] ?? []).map { ($0.id, $0) })
        for entry in view.entries { entries[entry.id] = entry }
        let ordered = entries.values.sorted { $0.id < $1.id }
        history[id] = ordered
        let metadata = try await conversation.document(Self.metadata)
        var summary = metadata.summary ?? ConversationSummary(id: id, title: "Saved conversation",
                                                               createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        var messages: [ChatMessage] = []
        var userID: ChatCore.MessageID?
        var replyOrdinal = 0
        for entry in ordered {
            for (ordinal, message) in (entry.model ?? []).enumerated() {
                let fallback = ChatCore.MessageID("pi:entry:\(entry.id):\(ordinal)")
                switch message {
                case .user(let user):
                    let client = ordinal == 0 ? entry.data?["clientMessageID"]?.stringValue : nil
                    let messageID = client.map { ChatCore.MessageID($0) } ?? fallback
                    userID = messageID
                    replyOrdinal = 0
                    let date = entry.data?["createdAt"]?.doubleValue.map(Date.init(timeIntervalSince1970:)) ?? user.timestamp
                    messages.append(ChatMessage(id: messageID, conversationID: id, role: .user, content: user.text, createdAt: date))
                case .assistant(let assistant):
                    let messageID = userID.map { Self.replyID(user: $0, ordinal: replyOrdinal) } ?? fallback
                    replyOrdinal += 1
                    messages.append(Self.assistant(assistant, id: messageID, conversation: id))
                case .toolResult(let tool):
                    messages.append(ChatMessage(id: fallback, conversationID: id, role: .tool, content: tool.text,
                                                createdAt: tool.timestamp, status: tool.isError ? .failed : .complete))
                case .system(let system):
                    messages.append(ChatMessage(id: fallback, conversationID: id, role: .system, content: system.text,
                                                createdAt: system.timestamp))
                case .other: continue
                }
            }
        }
        for item in view.inbox where item.mode != .write {
            guard let data = item.inputEntry?.data,
                  let client = data["clientMessageID"]?.stringValue else { continue }
            let messageID = ChatCore.MessageID(client)
            if !messages.contains(where: { $0.id == messageID }) {
                let date = Date(timeIntervalSince1970: data["createdAt"]?.doubleValue ?? 0)
                messages.append(ChatMessage(id: messageID, conversationID: id, role: .user,
                                            content: item.text, createdAt: date))
            }
        }
        for accepted in metadata.accepted where !messages.contains(where: { $0.id == accepted.id }) {
            let submission = try await harness.commit { tx in
                try await tx.submission(in: conversation.id, requestId: accepted.id.rawValue)
            }
            guard submission != nil else { continue }
            let message = ChatMessage(id: accepted.id, conversationID: id, role: .user,
                                      content: accepted.text, createdAt: accepted.createdAt)
            let position = messages.firstIndex { $0.createdAt > accepted.createdAt } ?? messages.endIndex
            messages.insert(message, at: position)
        }
        if let partial = view.streamingMessage {
            let partialID = userID.map { Self.replyID(user: $0, ordinal: replyOrdinal) }
                ?? ChatCore.MessageID("pi:stream:\(conversation.id)")
            var message = Self.assistant(partial, id: partialID, conversation: id)
            message.status = .streaming
            messages.append(message)
        }
        if let latest = messages.map(\.createdAt).max() { summary.updatedAt = max(summary.updatedAt, latest) }
        let activity: ConversationActivity
        if view.isBusy || !view.inbox.isEmpty { activity = view.streamingMessage == nil ? .sending : .streaming }
        else if messages.last?.status == .failed { activity = .failed("The provider request failed.") }
        else { activity = .idle }
        let snapshot = ConversationSnapshot(summary: summary, messages: messages, activity: activity)
        if let index = state.conversations.firstIndex(where: { $0.id == id }) { state.conversations[index] = summary }
        else { state.conversations.append(summary) }
        let previous = state.loadedConversations.first { $0.id == id }
        if let index = state.loadedConversations.firstIndex(where: { $0.id == id }) { state.loadedConversations[index] = snapshot }
        else { state.loadedConversations.append(snapshot) }
        if previous != snapshot { publish(.conversationUpdated(snapshot)) }
    }

    private static func assistant(_ message: AssistantMessage, id: ChatCore.MessageID,
                                  conversation: ChatCore.ConversationID) -> ChatMessage {
        let status: MessageStatus = message.stopReason == .aborted ? .stopped : (message.stopReason == .error ? .failed : .complete)
        // Provider errorMessage/retry details can contain headers or tokens. Never expose them.
        let content = status == .failed && message.text.isEmpty ? "The provider request failed." : message.text
        return ChatMessage(id: id, conversationID: conversation, role: .assistant, content: content,
                           createdAt: message.timestamp, status: status)
    }
    private static func replyID(user: ChatCore.MessageID, ordinal: Int) -> ChatCore.MessageID {
        ChatCore.MessageID("pi:reply:\(user.rawValue):\(ordinal)")
    }
    private static func id(_ id: PiDurableKit.ConversationID) -> ChatCore.ConversationID {
        ChatCore.ConversationID("pi:conversation:\(id)")
    }
    private func checkOpen() throws { if closed { throw ChatBackendError.disconnected } }
    private func safe(_ error: any Error, fallback: String) -> ChatBackendError {
        if let error = error as? ChatBackendError { return error }
        if case PiDurableError.conversationBusy = error { return .busy }
        return .unavailable(fallback)
    }
    private func publish(_ event: ChatEvent) { for subscriber in subscribers.values { subscriber.yield(event) } }
    private func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }
    private func finishSubscribers() {
        for subscriber in subscribers.values { subscriber.finish() }
        subscribers.removeAll()
    }
    private func acquire() async {
        if locked { await withCheckedContinuation { waiters.append($0) } }
        else { locked = true }
    }
    private func release() {
        if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
    }
}
