import Foundation

public enum MessageRole: String, Codable, CaseIterable, Sendable {
    case system, user, assistant, tool
}

public enum MessageStatus: String, Codable, Sendable {
    case complete, streaming, stopped, failed
}

public struct ChatMessage: Identifiable, Equatable, Codable, Sendable {
    public let id: MessageID
    public let conversationID: ConversationID
    public let role: MessageRole
    public let createdAt: Date
    public var content: String
    public var status: MessageStatus

    public init(
        id: MessageID, conversationID: ConversationID, role: MessageRole, content: String,
        createdAt: Date = .now, status: MessageStatus = .complete
    ) {
        self.id = id
        self.conversationID = conversationID
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.status = status
    }
}

public struct ConversationSummary: Identifiable, Equatable, Codable, Sendable {
    public let id: ConversationID
    public var title: String
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: ConversationID, title: String, createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum ConversationActivity: Equatable, Codable, Sendable {
    case idle, sending, streaming, stopping
    case failed(String)

    public var isBusy: Bool {
        switch self {
        case .sending, .streaming, .stopping: true
        case .idle, .failed: false
        }
    }
}

public struct ConversationSnapshot: Identifiable, Equatable, Codable, Sendable {
    public var summary: ConversationSummary
    /// Ordered complete transcript, including the current streaming message with its stable ID.
    public var messages: [ChatMessage]
    public var activity: ConversationActivity
    public var id: ConversationID { summary.id }

    public init(summary: ConversationSummary, messages: [ChatMessage] = [], activity: ConversationActivity = .idle) {
        self.summary = summary
        self.messages = messages
        self.activity = activity
    }
}

public enum ConnectionState: Equatable, Codable, Sendable {
    case disconnected, connecting, connected, demo
    case failed(String)

    public var canSend: Bool { self == .connected }
}

/// A complete replacement of the list, selection, connection, and loaded transcript cache.
/// Include the selected transcript in loadedConversations. Unloaded conversations still appear in the list.
public struct ChatSnapshot: Equatable, Codable, Sendable {
    public var connection: ConnectionState
    public var conversations: [ConversationSummary]
    public var selectedConversationID: ConversationID?
    public var loadedConversations: [ConversationSnapshot]

    public init(
        connection: ConnectionState = .disconnected, conversations: [ConversationSummary] = [],
        selectedConversationID: ConversationID? = nil, loadedConversations: [ConversationSnapshot] = []
    ) {
        self.connection = connection
        self.conversations = conversations
        self.selectedConversationID = selectedConversationID
        self.loadedConversations = loadedConversations
    }
}
