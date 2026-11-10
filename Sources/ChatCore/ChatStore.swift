import Foundation
import Observation

/// One store per backend/session. Own in SwiftUI @State and observe using .task { await store.start() }.
/// start() lives for the subscription; cancel that task when the owner disappears. It is safe to restart.
@MainActor @Observable
public final class ChatStore {
    public private(set) var connection: ConnectionState = .disconnected
    public private(set) var conversations: [ConversationSummary] = []
    public private(set) var selectedConversationID: ConversationID?
    public private(set) var loadedConversations: [ConversationID: ConversationSnapshot] = [:]
    public private(set) var lastFailure: ChatFailure?
    public private(set) var isObserving = false
    public var draft = ""
    public var modelSelection: ModelSelection?

    @ObservationIgnored private let backend: any ChatBackend
    private var pendingSends: Set<ConversationID> = []
    private var awaitingAcceptance: [ConversationID: MessageID] = [:]

    public init(backend: any ChatBackend) { self.backend = backend }

    public var selectedConversation: ConversationSnapshot? {
        selectedConversationID.flatMap { loadedConversations[$0] }
    }
    public var messages: [ChatMessage] { selectedConversation?.messages ?? [] }
    public var isSending: Bool {
        guard let id = selectedConversationID else { return false }
        return pendingSends.contains(id) || awaitingAcceptance[id] != nil || (loadedConversations[id]?.activity.isBusy ?? false)
    }
    public var canSend: Bool {
        connection.canSend && selectedConversation != nil && modelSelection != nil && !isSending
    }
    /// Conversation-scoped failures do not appear in another conversation after a selection change.
    public var visibleFailure: ChatFailure? {
        guard let failure = lastFailure else { return nil }
        return failure.conversationID == nil || failure.conversationID == selectedConversationID ? failure : nil
    }

    public func clearFailure() { lastFailure = nil }

    public func start() async {
        guard !isObserving else { return }
        isObserving = true
        defer {
            isObserving = false
            if Task.isCancelled { connection = .disconnected }
        }
        do {
            let stream = await backend.events()
            for try await event in stream {
                try Task.checkCancellation()
                apply(event)
            }
            if !Task.isCancelled && connection != .disconnected {
                throw ChatBackendError.unavailable("The backend event stream ended. Reconnect to continue.")
            }
        } catch {
            guard !Task.isCancelled else { return }
            connection = .failed(error.localizedDescription)
            record(error, operation: "observe")
        }
    }

    @discardableResult
    public func createConversation(title: String? = nil) async -> ConversationID? {
        do {
            let id = try await backend.createConversation(title: title)
            if lastFailure?.operation == "create", lastFailure?.conversationID == nil { lastFailure = nil }
            return id
        } catch {
            record(error, operation: "create")
            return nil
        }
    }

    public func selectConversation(_ id: ConversationID?) async {
        do {
            try await backend.selectConversation(id)
        } catch {
            record(error, operation: "select", conversationID: id)
        }
    }

    /// Captures the conversation and model BEFORE suspension. Whitespace is preserved in accepted messages.
    @discardableResult
    public func send(_ text: String) async -> Bool {
        let id = selectedConversationID
        do {
            guard connection.canSend else {
                throw connection == .demo ? ChatBackendError.demoReadOnly : ChatBackendError.disconnected
            }
            guard let id, selectedConversation != nil else { throw ChatBackendError.noConversation }
            guard let model = modelSelection else { throw ChatBackendError.noModel }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ChatBackendError.emptyMessage
            }
            guard !isSending else { throw ChatBackendError.busy }
            pendingSends.insert(id)
            defer { pendingSends.remove(id) }
            let request = SendRequest(conversationID: id, text: text, model: model)
            awaitingAcceptance[id] = request.messageID
            do {
                try await backend.send(request)
            } catch {
                awaitingAcceptance.removeValue(forKey: id)
                throw error
            }
            // An older command completing must not erase a newer failure from another conversation.
            if lastFailure?.conversationID == id { lastFailure = nil }
            return true
        } catch {
            record(error, operation: "send", conversationID: id)
            return false
        }
    }

    public func sendDraft() async {
        let submitted = draft
        if await send(submitted), draft == submitted { draft = "" }
    }

    public func stop() async {
        guard let id = selectedConversationID else { return }
        do {
            try await backend.stop(conversationID: id)
        } catch {
            record(error, operation: "stop", conversationID: id)
        }
    }

    private func apply(_ event: ChatEvent) {
        switch event {
        case .snapshot(let snapshot):
            connection = snapshot.connection
            conversations = snapshot.conversations
            selectedConversationID = snapshot.selectedConversationID
            loadedConversations = [:]
            for conversation in snapshot.loadedConversations {
                loadedConversations[conversation.id] = conversation
                acknowledgeAcceptance(conversation)
            }
            if !snapshot.connection.canSend { awaitingAcceptance.removeAll() }
        case .conversationUpdated(let conversation):
            loadedConversations[conversation.id] = conversation
            acknowledgeAcceptance(conversation)
            if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
                conversations[index] = conversation.summary
            } else {
                conversations.append(conversation.summary)
            }
        }
    }

    private func acknowledgeAcceptance(_ conversation: ConversationSnapshot) {
        guard let messageID = awaitingAcceptance[conversation.id] else { return }
        if conversation.activity.isBusy || conversation.messages.contains(where: { $0.id == messageID }) {
            awaitingAcceptance.removeValue(forKey: conversation.id)
        }
    }

    private func record(_ error: any Error, operation: String, conversationID: ConversationID? = nil) {
        guard !(error is CancellationError), !Task.isCancelled else { return }
        lastFailure = ChatFailure(operation: operation, message: error.localizedDescription, conversationID: conversationID)
    }
}
