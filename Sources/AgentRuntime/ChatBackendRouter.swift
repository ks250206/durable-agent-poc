import ChatCore
import Foundation

/// Owns both subscriptions. Child selection never controls workspace selection.
/// Conversation/account bindings and explicit model choices contain no credentials.
public actor ChatBackendRouter: ChatBackend {
    public enum Route: String, CaseIterable, Sendable { case pi, cursor }
    private struct Preferences: Codable {
        var version = 1
        var activeModel: ModelSelection?
        var models: [ModelSelection] = []
        var accounts: [String: ProviderAccount] = [:]
        var selected: ConversationID?
    }
    private var backends: [Route: any ChatBackend]
    private let preferencesURL: URL
    private var preferences: Preferences
    private var states: [Route: ChatSnapshot] = [:]
    private var statuses: [ProviderStatus] = []
    private var watchers: [Task<Void, Never>] = []
    private var subscribers: [UUID: AsyncThrowingStream<ChatEvent, any Error>.Continuation] = [:]
    private var initialWaiter: CheckedContinuation<Void, Never>?
    private var eventWaiters: [CheckedContinuation<Void, Never>] = []
    private var sends: [ConversationID: (UUID, Task<Void, any Error>)] = [:]
    private var closed = false
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public static func open(pi: any ChatBackend, cursor: any ChatBackend, preferencesURL: URL) async throws -> ChatBackendRouter {
        let router = try ChatBackendRouter(pi: pi, cursor: cursor, preferencesURL: preferencesURL)
        await router.observe()
        return router
    }

    private init(pi: any ChatBackend, cursor: any ChatBackend, preferencesURL: URL) throws {
        backends = [.pi: pi, .cursor: cursor]
        self.preferencesURL = preferencesURL
        if FileManager.default.fileExists(atPath: preferencesURL.path) {
            do { preferences = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: preferencesURL)) }
            catch { throw ChatBackendError.unavailable("Conversation routing preferences could not be read.") }
            guard preferences.version == 1 else { throw ChatBackendError.unavailable("Unsupported routing preferences.") }
        } else { preferences = Preferences() }
    }

    deinit { for watcher in watchers { watcher.cancel() }; for send in sends.values { send.1.cancel() } }

    public static func route(for account: ProviderAccount) -> Route? {
        switch account.option {
        case .codexCLI: nil // Runtime composition is owned by #21.
        case .cursor: account == CursorProviderSettingsService.account ? .cursor : nil
        case .chatGPT: account.providerID == "openai-codex" ? .pi : nil
        case .apiKey: !account.providerID.isEmpty && account.providerID != "cursor" && account.providerID != "openai-codex" ? .pi : nil
        }
    }
    private static func route(for id: ConversationID) -> Route? {
        if id.rawValue.hasPrefix("pi:conversation:") { return .pi }
        if id.rawValue.hasPrefix("cursor:conversation:") { return .cursor }
        return nil
    }
    private func account(for id: ConversationID) -> ProviderAccount? {
        if Self.route(for: id) == .cursor { return CursorProviderSettingsService.account }
        guard let account = preferences.accounts[id.rawValue], Self.route(for: account) == Self.route(for: id) else { return nil }
        return account
    }
    private func model(for account: ProviderAccount) -> ModelSelection? {
        preferences.models.first { $0.account == account }
    }
    private func observe() async {
        for route in Route.allCases {
            guard let backend = backends[route] else { continue }
            watchers.append(Task { [weak self] in
                do {
                    let stream = await backend.events()
                    for try await event in stream {
                        guard !Task.isCancelled else { return }
                        await self?.receive(event, from: route)
                    }
                    if !Task.isCancelled { await self?.failed(route) }
                } catch { if !Task.isCancelled { await self?.failed(route) } }
            })
        }
        if states.count != Route.allCases.count { await withCheckedContinuation { initialWaiter = $0 } }
        if let id = preferences.selected {
            if !summaries.contains(where: { $0.id == id }) { preferences.selected = nil }
            else { preferences.activeModel = account(for: id).flatMap { model(for: $0) } }
        }
    }
    private func receive(_ event: ChatEvent, from route: Route) {
        guard !closed else { return }
        switch event {
        case .snapshot(let snapshot):
            guard snapshot.conversations.allSatisfy({ Self.route(for: $0.id) == route }),
                  Set(snapshot.conversations.map(\.id)).count == snapshot.conversations.count,
                  snapshot.loadedConversations.allSatisfy({ conversation in
                      snapshot.conversations.contains { $0.id == conversation.id } &&
                      conversation.messages.allSatisfy { $0.conversationID == conversation.id }
                  }) else { failed(route); return }
            states[route] = snapshot
        case .conversationUpdated(let conversation):
            guard Self.route(for: conversation.id) == route,
                  conversation.messages.allSatisfy({ $0.conversationID == conversation.id }) else { failed(route); return }
            var state = states[route] ?? ChatSnapshot()
            if let i = state.conversations.firstIndex(where: { $0.id == conversation.id }) { state.conversations[i] = conversation.summary }
            else { state.conversations.append(conversation.summary) }
            state.loadedConversations.removeAll { $0.id == conversation.id }
            state.loadedConversations.append(conversation)
            states[route] = state
        }
        if states.count == Route.allCases.count { initialWaiter?.resume(); initialWaiter = nil }
        let pending = eventWaiters; eventWaiters.removeAll(); for waiter in pending { waiter.resume() }
        publish()
    }
    private func failed(_ route: Route) {
        var state = states[route] ?? ChatSnapshot()
        state.connection = .failed("This backend's observation stopped. Quit and reopen DurableChat.")
        states[route] = state
        if states.count == Route.allCases.count { initialWaiter?.resume(); initialWaiter = nil }
        let pending = eventWaiters; eventWaiters.removeAll(); for waiter in pending { waiter.resume() }
        publish()
    }
    private var summaries: [ConversationSummary] { Route.allCases.flatMap { states[$0]?.conversations ?? [] } }
    private func current() -> ChatSnapshot {
        let selected = preferences.selected
        let selectedAccount = selected.flatMap { account(for: $0) }
        let active = preferences.activeModel
        let account = selected == nil ? active?.account : selectedAccount
        var connection: ConnectionState = .disconnected
        if !closed, let account, let route = Self.route(for: account) {
            if case .failed(let message) = states[route]?.connection { connection = .failed(message) }
            else if let status = statuses.first(where: { $0.configuration.account == account }),
                    status.authentication == .configured, let active, active.account == account,
                    status.models.contains(where: { $0.id == active }) { connection = .connected }
        }
        let notice: String?
        if selected != nil && selectedAccount == nil {
            notice = "Saved Pi history has no recorded account. Browse it here; use Settings to choose a model, then create a new conversation to send."
        } else if active == nil { notice = "Choose a provider and model in Settings, then use Use selected model. History remains available without signing in." }
        else if selected == nil { notice = "Model selected. Create a new conversation to send with \(active!.account.providerID)." }
        else if !connection.canSend { notice = "This conversation's provider or model is unavailable. History is still available; check Settings to reconnect." }
        else { notice = nil }
        return ChatSnapshot(connection: connection, conversations: summaries, selectedConversationID: selected,
                            loadedConversations: Route.allCases.flatMap { states[$0]?.loadedConversations ?? [] },
                            modelContext: ChatModelContext(selection: active, notice: notice))
    }
    public func snapshot() async throws -> ChatSnapshot { current() }
    public func events() async -> AsyncThrowingStream<ChatEvent, any Error> {
        let id = UUID()
        let (stream, continuation) = AsyncThrowingStream<ChatEvent, any Error>.makeStream()
        continuation.yield(.snapshot(current()))
        if closed { continuation.finish(); return stream }
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.remove(id) } }
        return stream
    }
    private func remove(_ id: UUID) { subscribers.removeValue(forKey: id) }
    private func publish() { let event = ChatEvent.snapshot(current()); for subscriber in subscribers.values { subscriber.yield(event) } }

    /// Snapshot refresh updates availability only; it never chooses or clears a model.
    public func updateProviderStatuses(_ statuses: [ProviderStatus]) { self.statuses = statuses; publish() }

    public func useModel(_ selection: ModelSelection?) async throws {
        await acquire(); defer { release() }
        try checkOpen()
        if let selection {
            guard Self.route(for: selection.account) != nil,
                  let status = statuses.first(where: { $0.configuration.account == selection.account }),
                  status.authentication == .configured, status.models.contains(where: { $0.id == selection }) else { throw ChatBackendError.noModel }
        }
        var next = preferences
        next.activeModel = selection
        if let selection {
            next.models.removeAll { $0.account == selection.account }; next.models.append(selection)
        }
        if let id = next.selected, account(for: id) != selection?.account { next.selected = nil }
        try save(next)
        publish()
    }
    public func createConversation(title: String?) async throws -> ConversationID {
        await acquire(); defer { release() }
        try checkOpen()
        guard let model = preferences.activeModel, let route = Self.route(for: model.account), let backend = backends[route] else { throw ChatBackendError.noModel }
        let id = try await backend.createConversation(title: title)
        // Already observing: wait for the authoritative event rather than taking a racing second snapshot.
        while !summaries.contains(where: { $0.id == id }) {
            try checkOpen()
            if case .failed = states[route]?.connection { throw ChatBackendError.unavailable("The new conversation could not be observed.") }
            await withCheckedContinuation { eventWaiters.append($0) }
        }
        try checkOpen()
        var next = preferences; next.accounts[id.rawValue] = model.account; next.selected = id
        try save(next); publish()
        return id
    }
    public func selectConversation(_ id: ConversationID?) async throws {
        await acquire(); defer { release() }
        try checkOpen()
        var next = preferences
        if let id {
            guard summaries.contains(where: { $0.id == id }), let route = Self.route(for: id), let backend = backends[route] else { throw ChatBackendError.noConversation }
            try await backend.selectConversation(id)
            next.activeModel = account(for: id).flatMap { model(for: $0) }
        }
        try checkOpen()
        next.selected = id
        try save(next); publish()
    }
    public func send(_ request: SendRequest) async throws {
        try checkOpen()
        guard let account = account(for: request.conversationID), account == request.model.account,
              let route = Self.route(for: account), let backend = backends[route],
              summaries.contains(where: { $0.id == request.conversationID }) else {
            throw ChatBackendError.unavailable("The conversation and model use different accounts. Select a compatible conversation in Settings.")
        }
        guard sends[request.conversationID] == nil else { throw ChatBackendError.busy }
        let token = UUID()
        let task = Task { try Task.checkCancellation(); try await backend.send(request) }
        sends[request.conversationID] = (token, task)
        defer { if sends[request.conversationID]?.0 == token { sends.removeValue(forKey: request.conversationID) } }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    public func stop(conversationID: ConversationID) async throws {
        try checkOpen()
        guard let route = Self.route(for: conversationID), let backend = backends[route] else { throw ChatBackendError.noConversation }
        sends[conversationID]?.1.cancel()
        try await backend.stop(conversationID: conversationID)
    }
    /// Explicit shutdown releases the Cursor owner as well as cancelling every origin's work.
    public func shutdown() async throws {
        guard !closed else { return }
        closed = true
        for watcher in watchers { watcher.cancel() }; watchers.removeAll()
        let pending = sends.values.map(\.1); for task in pending { task.cancel() }
        let ids = Set(summaries.map(\.id)).union(sends.keys)
        var failed = false
        for id in ids {
            if let route = Self.route(for: id), let backend = backends[route] {
                do { try await backend.stop(conversationID: id) } catch { failed = true }
            }
        }
        for task in pending { _ = await task.result }
        if let pi = backends[.pi] as? PiChatBackend {
            do { try await pi.close() } catch { failed = true }
        }
        backends.removeAll(); sends.removeAll()
        let waiting = eventWaiters; eventWaiters.removeAll(); for waiter in waiting { waiter.resume() }
        publish(); for subscriber in subscribers.values { subscriber.finish() }; subscribers.removeAll()
        if failed { throw ChatBackendError.unavailable("Some work could not be saved during shutdown.") }
    }
    private func checkOpen() throws { if closed { throw ChatBackendError.disconnected }; try Task.checkCancellation() }
    private func save(_ next: Preferences) throws {
        do {
            try FileManager.default.createDirectory(at: preferencesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: preferencesURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: preferencesURL.path)
        } catch { throw ChatBackendError.unavailable("Conversation routing preferences could not be saved.") }
        preferences = next
    }
    private func acquire() async {
        if !locked { locked = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() { if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() } }
}
