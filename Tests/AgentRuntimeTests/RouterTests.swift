import AgentRuntime
import ChatCore
import Foundation
import Testing

private let piAccount = ProviderAccount(option: .apiKey, providerID: "fixture-pi")
private let oauthAccount = ProviderAccount(option: .chatGPT, providerID: "openai-codex")
private let piModel = ModelSelection(account: piAccount, modelID: "pi-model")
private let cursorModel = ModelSelection(account: CursorProviderSettingsService.account, modelID: "cursor-model")
private let oauthModel = ModelSelection(account: oauthAccount, modelID: "oauth-model")

private func configured(_ models: [ModelSelection]) -> [ProviderStatus] {
    models.map { model in
        ProviderStatus(configuration: ProviderConfiguration(account: model.account, selectedModelID: model.modelID),
                       authentication: .configured, models: [ChatModel(id: model, displayName: model.modelID)])
    }
}

private actor RoutingFixtureBackend: ChatBackend {
    let prefix: String
    private var state: ChatSnapshot
    private var subscribers: [UUID: AsyncThrowingStream<ChatEvent, any Error>.Continuation] = [:]
    private(set) var snapshotReads = 0
    private(set) var sends: [SendRequest] = []
    private(set) var stops: [ConversationID] = []
    private(set) var preparing = false
    var delaysSend = false
    init(_ prefix: String) {
        self.prefix = prefix
        let summary = ConversationSummary(id: ConversationID("\(prefix):conversation:saved"), title: "Saved \(prefix)")
        state = ChatSnapshot(connection: .connected, conversations: [summary], selectedConversationID: summary.id,
                             loadedConversations: [ConversationSnapshot(summary: summary)])
    }
    func snapshot() async throws -> ChatSnapshot { snapshotReads += 1; return state }
    func events() async -> AsyncThrowingStream<ChatEvent, any Error> {
        let id = UUID()
        let (stream, continuation) = AsyncThrowingStream<ChatEvent, any Error>.makeStream()
        subscribers[id] = continuation
        continuation.yield(.snapshot(state))
        continuation.onTermination = { [weak self] _ in Task { await self?.remove(id) } }
        return stream
    }
    private func remove(_ id: UUID) { subscribers.removeValue(forKey: id) }
    private func publish() { for subscriber in subscribers.values { subscriber.yield(.snapshot(state)) } }
    func createConversation(title: String?) async throws -> ConversationID {
        let summary = ConversationSummary(id: ConversationID("\(prefix):conversation:\(UUID())"), title: title ?? "New")
        state.conversations.append(summary); state.loadedConversations.append(ConversationSnapshot(summary: summary))
        state.selectedConversationID = summary.id; publish(); return summary.id
    }
    func selectConversation(_ id: ConversationID?) async throws { state.selectedConversationID = id; publish() }
    func setDelayedSend() { delaysSend = true }
    func send(_ request: SendRequest) async throws {
        preparing = true
        defer { preparing = false }
        if delaysSend { try await Task.sleep(for: .seconds(30)) }
        try Task.checkCancellation()
        sends.append(request)
    }
    func stop(conversationID: ConversationID) async throws { stops.append(conversationID) }
    func lateUpdate(_ id: ConversationID, failure: Bool = false) {
        guard let i = state.loadedConversations.firstIndex(where: { $0.id == id }) else { return }
        state.selectedConversationID = id
        state.loadedConversations[i].messages.append(ChatMessage(id: MessageID("\(prefix):late"), conversationID: id, role: .assistant, content: "Late \(prefix) output"))
        state.loadedConversations[i].activity = failure ? .failed("Origin failure") : .streaming
        publish()
    }
    func endObservation() { for subscriber in subscribers.values { subscriber.finish() }; subscribers.removeAll() }
}

private func temporaryRoutingURL() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Router-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.appendingPathComponent("routing.json")
}

@MainActor
private func routerEventually(_ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await predicate())
}

@Suite(.serialized) @MainActor
struct RouterTests {
    @Test func atomicMixedHistoryNoImplicitModelAndNoSnapshotSubscriptionGap() async throws {
        let pi = RoutingFixtureBackend("pi"), cursor = RoutingFixtureBackend("cursor")
        let url = try temporaryRoutingURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let router = try await ChatBackendRouter.open(pi: pi, cursor: cursor, preferencesURL: url)
        let stream = await router.events()
        var iterator = stream.makeAsyncIterator()
        guard case .snapshot(let snapshot) = try await iterator.next() else { Issue.record("Missing initial snapshot"); return }
        #expect(snapshot.conversations.map(\.id.rawValue) == ["pi:conversation:saved", "cursor:conversation:saved"])
        #expect(snapshot.selectedConversationID == nil)
        #expect(snapshot.modelContext?.selection == nil)
        #expect(snapshot.connection == .disconnected)
        #expect(await pi.snapshotReads == 0)
        #expect(await cursor.snapshotReads == 0)
        await #expect(throws: ChatBackendError.noModel) { try await router.createConversation(title: nil) }
        try await router.selectConversation(ConversationID("pi:conversation:saved"))
        let history = try await router.snapshot()
        #expect(history.loadedConversations.count == 2)
        #expect(history.connection == .disconnected)
        #expect(history.modelContext?.notice?.contains("no recorded account") == true)
        await #expect(throws: (any Error).self) {
            try await router.send(SendRequest(conversationID: ConversationID("pi:conversation:saved"), text: "Do not forward legacy history", model: piModel))
        }
        #expect(await pi.sends.isEmpty)
        try await router.shutdown()
    }

    @Test func switchingAccountsIsAtomicAndLateSnapshotsCannotStealSelectionOrConnection() async throws {
        let pi = RoutingFixtureBackend("pi"), cursor = RoutingFixtureBackend("cursor")
        let url = try temporaryRoutingURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let router = try await ChatBackendRouter.open(pi: pi, cursor: cursor, preferencesURL: url)
        await router.updateProviderStatuses(configured([piModel, cursorModel, oauthModel]))
        let store = ChatStore(backend: router)
        let observation = Task { await store.start() }; defer { observation.cancel() }
        try await router.useModel(piModel)
        let a = try await router.createConversation(title: "Pi A")
        try await routerEventually { store.selectedConversationID == a && store.modelSelection == piModel }
        try await router.useModel(cursorModel)
        try await routerEventually { store.selectedConversationID == nil && store.modelSelection == cursorModel }
        let b = try await router.createConversation(title: "Cursor B")
        try await routerEventually { store.selectedConversationID == b && store.modelSelection == cursorModel }
        await pi.lateUpdate(a, failure: true)
        try await routerEventually { store.loadedConversations[a]?.messages.count == 1 }
        #expect(store.selectedConversationID == b && store.messages.isEmpty)
        #expect(store.connection == .connected && store.visibleFailure == nil)
        await #expect(throws: (any Error).self) {
            try await router.send(SendRequest(conversationID: a, text: "Wrong backend", model: cursorModel))
        }
        await #expect(throws: (any Error).self) {
            try await router.send(SendRequest(conversationID: a, text: "Wrong Pi account", model: oauthModel))
        }
        #expect(await pi.sends.isEmpty)
        #expect(await cursor.sends.isEmpty)
        try await router.selectConversation(a)
        try await routerEventually { store.selectedConversationID == a && store.modelSelection == piModel }
        var statuses = configured([piModel, cursorModel, oauthModel]); statuses[0].authentication = .signedOut
        await router.updateProviderStatuses(statuses)
        try await routerEventually { store.connection == .disconnected }
        #expect(store.messages.first?.content == "Late pi output")
        try await router.selectConversation(b)
        try await routerEventually { store.modelSelection == cursorModel && store.connection == .connected }
        await pi.endObservation()
        try await Task.sleep(for: .milliseconds(30))
        #expect(store.connection == .connected)
        try await router.selectConversation(a)
        try await routerEventually { if case .failed = store.connection { return true }; return false }
        try await router.shutdown()
    }

    @Test func persistsExplicitAccountModelAndBindingsAcrossReopenWithoutChoosingDefaults() async throws {
        let pi = RoutingFixtureBackend("pi"), cursor = RoutingFixtureBackend("cursor")
        let url = try temporaryRoutingURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try await ChatBackendRouter.open(pi: pi, cursor: cursor, preferencesURL: url)
        await first.updateProviderStatuses(configured([piModel, cursorModel]))
        try await first.useModel(piModel)
        let a = try await first.createConversation(title: "Pi persisted")
        try await first.useModel(cursorModel)
        let b = try await first.createConversation(title: "Cursor persisted")
        try await first.shutdown()
        let second = try await ChatBackendRouter.open(pi: pi, cursor: cursor, preferencesURL: url)
        let restored = try await second.snapshot()
        #expect(restored.selectedConversationID == b && restored.modelContext?.selection == cursorModel)
        await second.updateProviderStatuses(configured([piModel, cursorModel]))
        try await second.selectConversation(a)
        #expect(try await second.snapshot().modelContext?.selection == piModel)
        try await second.useModel(nil)
        #expect(try await second.snapshot().modelContext?.selection == nil)
        try await second.shutdown()
    }

    @Test func stopDuringPreflightTargetsOriginAfterSwitchAndPreventsAcceptance() async throws {
        let pi = RoutingFixtureBackend("pi"), cursor = RoutingFixtureBackend("cursor")
        let url = try temporaryRoutingURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let router = try await ChatBackendRouter.open(pi: pi, cursor: cursor, preferencesURL: url)
        await router.updateProviderStatuses(configured([piModel, cursorModel]))
        try await router.useModel(piModel)
        let a = try await router.createConversation(title: nil)
        await pi.setDelayedSend()
        let send = Task { try await router.send(SendRequest(conversationID: a, text: "Cancel me", model: piModel)) }
        try await routerEventually { await pi.preparing }
        try await router.useModel(cursorModel)
        let b = try await router.createConversation(title: nil)
        try await router.stop(conversationID: a)
        await #expect(throws: CancellationError.self) { try await send.value }
        #expect(await pi.sends.isEmpty)
        #expect(await pi.stops == [a])
        #expect(await cursor.stops.isEmpty)
        #expect(try await router.snapshot().selectedConversationID == b)
        try await router.shutdown()
        #expect(await pi.stops.contains(a))
        #expect(await cursor.stops.contains(b))
    }

    @Test func switchingBetweenPiAPIAndOAuthCreatesDistinctAccountBindings() async throws {
        let pi = RoutingFixtureBackend("pi"), cursor = RoutingFixtureBackend("cursor")
        let url = try temporaryRoutingURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let router = try await ChatBackendRouter.open(pi: pi, cursor: cursor, preferencesURL: url)
        await router.updateProviderStatuses(configured([piModel, oauthModel]))
        try await router.useModel(piModel)
        let a = try await router.createConversation(title: nil)
        try await router.useModel(oauthModel)
        #expect(try await router.snapshot().selectedConversationID == nil)
        let b = try await router.createConversation(title: nil)
        try await router.send(SendRequest(conversationID: b, text: "OAuth origin", model: oauthModel))
        try await router.selectConversation(a)
        #expect(try await router.snapshot().modelContext?.selection == piModel)
        #expect(await pi.sends.map(\.conversationID) == [b])
        try await router.shutdown()
    }
}
