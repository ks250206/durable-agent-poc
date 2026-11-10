import Foundation

public struct SendRequest: Equatable, Sendable {
    public let conversationID: ConversationID
    /// Client-generated idempotency ID. Reuse as the user message ID and when retrying the same submission.
    public let messageID: MessageID
    public let text: String
    public let model: ModelSelection

    public init(
        conversationID: ConversationID, messageID: MessageID = MessageID(UUID().uuidString),
        text: String, model: ModelSelection
    ) {
        self.conversationID = conversationID
        self.messageID = messageID
        self.text = text
        self.model = model
    }
}

public enum ChatEvent: Equatable, Sendable {
    case snapshot(ChatSnapshot)
    /// Replaces one complete transcript and upserts its summary without changing selection.
    case conversationUpdated(ConversationSnapshot)
}

/// Implemented by #7 PiChatBackend and #8 CursorChatBackend. Implementations must serialize mutations.
/// Each subscriber gets an atomic initial .snapshot followed by ordered changes with no subscription gap.
/// Events are authoritative: commands publish their effects; callers do not synthesize transcript updates.
/// snapshot() is a read-only point-in-time view; use events() for observation, not snapshot()+events().
/// Canceling observation releases its resources but DOES NOT stop generation. Only stop does that.
public protocol ChatBackend: Sendable {
    func snapshot() async throws -> ChatSnapshot
    func events() async -> AsyncThrowingStream<ChatEvent, any Error>
    /// Creates AND selects a conversation; emits a snapshot with its empty transcript before returning.
    func createConversation(title: String?) async throws -> ConversationID
    /// Loads and selects a conversation (nil clears selection); emits an authoritative snapshot.
    func selectConversation(_ id: ConversationID?) async throws
    /// Returns when accepted, not when generation completes. Reject empty/busy/unconfigured submissions.
    func send(_ request: SendRequest) async throws
    /// Stops only this conversation; preserve partial output and publish .stopped / idle state.
    func stop(conversationID: ConversationID) async throws
}

public enum ChatBackendError: Error, Equatable, Sendable, LocalizedError {
    case disconnected, demoReadOnly, emptyMessage, noConversation, noModel, busy
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .disconnected: "No backend is connected."
        case .demoReadOnly: "Demo data is read-only. Connect a backend to send messages."
        case .emptyMessage: "Enter a message."
        case .noConversation: "Select or create a conversation."
        case .noModel: "Select a configured provider and model."
        case .busy: "This conversation is busy."
        case .unavailable(let reason): reason
        }
    }
}

public struct ChatFailure: Equatable, Sendable {
    public let operation: String
    public let message: String
    public let conversationID: ConversationID?
    public init(operation: String, message: String, conversationID: ConversationID? = nil) {
        self.operation = operation
        self.message = message
        self.conversationID = conversationID
    }
}
