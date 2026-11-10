import ChatCore
import Foundation
import Observation
import Testing

private let a = ConversationID("test:a")
private let b = ConversationID("test:b")
private let model = ModelSelection(account: ProviderAccount(option: .apiKey, providerID: "test"), modelID: "faux")

private func conversation(_ id: ConversationID, text: String = "", activity: ConversationActivity = .idle) -> ConversationSnapshot {
    ConversationSnapshot(summary: ConversationSummary(id: id, title: id.rawValue),
                         messages: text.isEmpty ? [] : [ChatMessage(id: MessageID("\(id):message"), conversationID: id,
                                                                  role: .assistant, content: text)],
                         activity: activity)
}

private func connectedState() -> ChatSnapshot {
    ChatSnapshot(connection: .connected, conversations: [conversation(a).summary, conversation(b).summary],
                 selectedConversationID: a, loadedConversations: [conversation(a), conversation(b)])
}

private enum TestFailure: Error, LocalizedError {
    case rejected
    var errorDescription: String? { "Submission rejected" }
}

private actor TestBackend: ChatBackend {
    var state: ChatSnapshot
    var subscribers: [UUID: AsyncThrowingStream<ChatEvent, any Error>.Continuation] = [:]
    var requests: [SendRequest] = []
    var stopped: [ConversationID] = []
    var heldSend: CheckedContinuation<Void, any Error>?
    let holdSend: Bool
    let rejectSend: Bool
    let delayAcceptanceEvent: Bool

    init(state: ChatSnapshot = connectedState(), holdSend: Bool = false, rejectSend: Bool = false, delayAcceptanceEvent: Bool = false) {
        self.state = state
        self.holdSend = holdSend
        self.rejectSend = rejectSend
        self.delayAcceptanceEvent = delayAcceptanceEvent
    }
    func snapshot() async throws -> ChatSnapshot { state }
    func events() async -> AsyncThrowingStream<ChatEvent, any Error> {
        let id = UUID()
        let (stream, continuation) = AsyncThrowingStream<ChatEvent, any Error>.makeStream()
        subscribers[id] = continuation
        continuation.yield(.snapshot(state))
        continuation.onTermination = { @Sendable [weak self] _ in Task { await self?.remove(id) } }
        return stream
    }
    private func remove(_ id: UUID) { subscribers.removeValue(forKey: id) }
    func publish(_ event: ChatEvent) {
        switch event {
        case .snapshot(let value): state = value
        case .conversationUpdated(let value):
            state.loadedConversations.removeAll { $0.id == value.id }
            state.loadedConversations.append(value)
            if let index = state.conversations.firstIndex(where: { $0.id == value.id }) {
                state.conversations[index] = value.summary
            } else {
                state.conversations.append(value.summary)
            }
        }
        for continuation in subscribers.values { continuation.yield(event) }
    }
    func finishWithError() {
        for continuation in subscribers.values { continuation.finish(throwing: TestFailure.rejected) }
        subscribers = [:]
    }
    func finishNormally() {
        for continuation in subscribers.values { continuation.finish() }
        subscribers = [:]
    }
    func createConversation(title: String?) async throws -> ConversationID {
        let id = ConversationID("test:created")
        var value = conversation(id)
        value.summary.title = title ?? "New conversation"
        state.conversations.append(value.summary)
        state.loadedConversations.append(value)
        state.selectedConversationID = id
        publish(.snapshot(state))
        return id
    }
    func selectConversation(_ id: ConversationID?) async throws {
        state.selectedConversationID = id
        publish(.snapshot(state))
    }
    func send(_ request: SendRequest) async throws {
        requests.append(request)
        if holdSend { try await withCheckedThrowingContinuation { heldSend = $0 } }
        if rejectSend { throw TestFailure.rejected }
        if !delayAcceptanceEvent { publishAcceptance(request) }
    }
    func publishAcceptance(_ request: SendRequest) {
        var value = conversation(request.conversationID)
        value.messages = [ChatMessage(id: request.messageID, conversationID: request.conversationID, role: .user, content: request.text)]
        publish(.conversationUpdated(value))
    }
    func releaseSend() { heldSend?.resume(); heldSend = nil }
    func stop(conversationID: ConversationID) async throws {
        stopped.append(conversationID)
        var value = conversation(conversationID, text: "partial", activity: .idle)
        value.messages[0].status = .stopped
        publish(.conversationUpdated(value))
    }
    func subscriberCount() -> Int { subscribers.count }
    func requestCount() -> Int { requests.count }
}

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition(), ContinuousClock.now < deadline { await Task.yield() }
    #expect(condition(), sourceLocation: sourceLocation)
}

@MainActor
private func waitUntilAsync(_ condition: @MainActor () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await condition()), ContinuousClock.now < deadline { await Task.yield() }
    #expect(await condition(), sourceLocation: sourceLocation)
}

@Test @MainActor func normalStoreIsEmptyUntilBackendPublishes() async {
    let backend = TestBackend(state: ChatSnapshot())
    let store = ChatStore(backend: backend)
    #expect(store.connection == .disconnected)
    #expect(store.conversations.isEmpty)
    #expect(store.messages.isEmpty)
    #expect(store.selectedConversationID == nil)
    #expect(!store.canSend)
    let observing = Task { await store.start() }
    await waitUntil { store.isObserving }
    #expect(!(await store.send("hello")))
    #expect(await backend.requestCount() == 0)
    observing.cancel()
    await observing.value
    #expect(!store.isObserving)
}

@Test @MainActor func eventsKeepOtherConversationStreamsOutOfSelection() async {
    let backend = TestBackend()
    let store = ChatStore(backend: backend)
    let observing = Task { await store.start() }
    defer { observing.cancel() }
    await waitUntil { store.selectedConversationID == a }
    await backend.publish(.conversationUpdated(conversation(a, text: "partial", activity: .streaming)))
    await waitUntil { store.messages.first?.content == "partial" }
    let messageID = store.messages.first?.id
    #expect(store.isSending)
    await store.selectConversation(b)
    await waitUntil { store.selectedConversationID == b }
    await backend.publish(.conversationUpdated(conversation(a, text: "completed")))
    await waitUntil { store.loadedConversations[a]?.messages.first?.content == "completed" }
    #expect(store.messages.isEmpty)
    #expect(!store.isSending)
    #expect(store.loadedConversations[a]?.messages.first?.id == messageID)
    await store.selectConversation(a)
    await waitUntil { store.selectedConversationID == a && store.messages.first?.content == "completed" }
}

@Test @MainActor func sendCapturesConversationPreservesDraftEditsAndRejectsReentry() async {
    let backend = TestBackend(holdSend: true)
    let store = ChatStore(backend: backend)
    let observing = Task { await store.start() }
    defer { observing.cancel() }
    await waitUntil { store.selectedConversationID == a }
    store.modelSelection = model
    store.draft = "  original\n"
    let sending = Task { await store.sendDraft() }
    await waitUntil { store.isSending }
    #expect(!(await store.send("duplicate")))
    store.draft = "edited while sending"
    await store.selectConversation(b)
    await waitUntil { store.selectedConversationID == b }
    #expect(!store.isSending)
    store.modelSelection = ModelSelection(account: model.account, modelID: "changed")
    await backend.releaseSend()
    await sending.value
    #expect(store.draft == "edited while sending")
    let requests = await backend.requests
    #expect(requests.count == 1)
    #expect(requests.first?.conversationID == a)
    #expect(requests.first?.model == model)
    #expect(requests.first?.text == "  original\n")
    #expect(requests.first?.messageID.rawValue.isEmpty == false)
}

@Test @MainActor func sendValidationAndFailurePreserveDraft() async {
    let backend = TestBackend(rejectSend: true)
    let store = ChatStore(backend: backend)
    let observing = Task { await store.start() }
    defer { observing.cancel() }
    await waitUntil { store.selectedConversationID == a }
    #expect(!(await store.send("hello"))) // No selected model.
    store.modelSelection = model
    #expect(!(await store.send(" \n\t")))
    #expect(await backend.requestCount() == 0)
    store.draft = "retry me"
    await store.sendDraft()
    #expect(store.draft == "retry me")
    #expect(store.visibleFailure?.message == "Submission rejected")
    await store.selectConversation(b)
    await waitUntil { store.selectedConversationID == b }
    #expect(store.visibleFailure == nil)
    #expect(store.lastFailure?.conversationID == a)
}

@Test @MainActor func successfulDraftCreateSelectAndStopUseBackendEvents() async {
    let backend = TestBackend()
    let store = ChatStore(backend: backend)
    let observing = Task { await store.start() }
    defer { observing.cancel() }
    await waitUntil { store.selectedConversationID == a }
    store.modelSelection = model
    store.draft = "send me"
    await store.sendDraft()
    #expect(store.draft.isEmpty)
    #expect(await backend.requestCount() == 1)
    let created = await store.createConversation(title: "Created title")
    await waitUntil { store.selectedConversationID == created }
    #expect(store.selectedConversation?.summary.title == "Created title")
    await store.stop()
    #expect(await backend.stopped == [created].compactMap { $0 })
    await waitUntil { store.messages.first?.status == .stopped }
    #expect(store.selectedConversation?.activity == .idle)
    await store.selectConversation(nil)
    await waitUntil { store.selectedConversationID == nil }
    #expect(store.messages.isEmpty)
}

@Test @MainActor func observationCanCancelRestartAndReportStreamFailure() async {
    let backend = TestBackend()
    let store = ChatStore(backend: backend)
    let first = Task { await store.start() }
    await waitUntil { store.selectedConversationID == a }
    // Starting a second observer must not create another subscription.
    await store.start()
    #expect(await backend.subscriberCount() == 1)
    first.cancel()
    await first.value
    #expect(!store.isObserving)
    #expect(store.connection == .disconnected)
    #expect(store.lastFailure == nil)
    await waitUntilAsync { await backend.subscriberCount() == 0 }
    let second = Task { await store.start() }
    await waitUntilAsync { await backend.subscriberCount() == 1 }
    await backend.finishWithError()
    await second.value
    #expect(store.connection == .failed("Submission rejected"))
    #expect(store.lastFailure?.operation == "observe")
}

@Test @MainActor func unexpectedEndDisablesSending() async {
    let backend = TestBackend()
    let store = ChatStore(backend: backend)
    let observing = Task { await store.start() }
    await waitUntil { store.connection == .connected }
    await backend.finishNormally()
    await observing.value
    #expect(!store.connection.canSend)
    #expect(store.lastFailure?.operation == "observe")
}

@Test @MainActor func fullSnapshotReplacesRemovedConversationCache() async {
    let backend = TestBackend()
    let store = ChatStore(backend: backend)
    let observing = Task { await store.start() }
    defer { observing.cancel() }
    await waitUntil { store.selectedConversationID == a }
    await backend.publish(.snapshot(ChatSnapshot(connection: .connected, conversations: [conversation(b).summary],
                                                selectedConversationID: b, loadedConversations: [conversation(b)])))
    await waitUntil { store.selectedConversationID == b }
    #expect(store.loadedConversations[a] == nil)
    #expect(store.conversations.map(\.id) == [b])
}

@Test @MainActor func switchingConversationClearsAcceptedUnchangedSharedDraft() async {
    let backend = TestBackend(holdSend: true)
    let store = ChatStore(backend: backend)
    let observing = Task { await store.start() }
    defer { observing.cancel() }
    await waitUntil { store.selectedConversationID == a }
    store.modelSelection = model
    store.draft = "same text"
    let sending = Task { await store.sendDraft() }
    await waitUntil { store.isSending }
    await store.selectConversation(b)
    await waitUntil { store.selectedConversationID == b }
    await backend.releaseSend()
    await sending.value
    #expect(store.draft.isEmpty)
}

@Test @MainActor func acceptedSendRemainsBusyUntilItsEventIsDelivered() async {
    let backend = TestBackend(delayAcceptanceEvent: true)
    let store = ChatStore(backend: backend)
    let observing = Task { await store.start() }
    defer { observing.cancel() }
    await waitUntil { store.selectedConversationID == a }
    store.modelSelection = model
    #expect(await store.send("first"))
    #expect(store.isSending)
    #expect(!store.canSend)
    #expect(!(await store.send("duplicate")))
    let requests = await backend.requests
    #expect(requests.count == 1)
    await backend.publishAcceptance(requests[0])
    await waitUntil { !store.isSending }
    #expect(store.canSend)
}

@Test @MainActor func createDoesNotEraseAnotherConversationFailure() async {
    let backend = TestBackend(rejectSend: true)
    let store = ChatStore(backend: backend)
    let observing = Task { await store.start() }
    defer { observing.cancel() }
    await waitUntil { store.selectedConversationID == a }
    store.modelSelection = model
    #expect(!(await store.send("fails")))
    _ = await store.createConversation()
    #expect(store.lastFailure?.conversationID == a)
}
