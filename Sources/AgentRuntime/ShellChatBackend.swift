import ChatCore
import Foundation
import PiDurableKit

public enum ShellLaunchMode: Equatable, Sendable {
    case empty, demo
    /// Demo mode is opt-in; never read credentials or infer demo mode from connection failure.
    public init(arguments: [String]) { self = arguments.contains("--demo") ? .demo : .empty }
}

/// #3 placeholder only. Does not instantiate Pi runtime, discover CLI, access credentials, or make network requests.
/// #9 will inject #7's PiChatBackend or #8's CursorChatBackend instead of this type.
public actor ShellChatBackend: ChatBackend {
    private let state: ChatSnapshot
    private var subscribers: [UUID: AsyncThrowingStream<ChatEvent, any Error>.Continuation] = [:]

    public init(mode: ShellLaunchMode = .empty) {
        if mode == .demo {
            let id = ChatCore.ConversationID("demo:conversation:1")
            let date = Date(timeIntervalSince1970: 0)
            let summary = ConversationSummary(id: id, title: "Demo (sample data)", createdAt: date, updatedAt: date)
            let messages = [
                ChatMessage(id: ChatCore.MessageID("demo:message:1"), conversationID: id, role: .user,
                            content: "This is an explicitly selected demo.", createdAt: date),
                ChatMessage(id: ChatCore.MessageID("demo:message:2"), conversationID: id, role: .assistant,
                            content: "Sample text only — no AI provider was contacted.", createdAt: date),
            ]
            state = ChatSnapshot(connection: .demo, conversations: [summary], selectedConversationID: id,
                                 loadedConversations: [ConversationSnapshot(summary: summary, messages: messages)])
        } else {
            state = ChatSnapshot()
        }
    }

    public func snapshot() async throws -> ChatSnapshot { state }

    public func events() async -> AsyncThrowingStream<ChatEvent, any Error> {
        let id = UUID()
        let (stream, continuation) = AsyncThrowingStream<ChatEvent, any Error>.makeStream()
        subscribers[id] = continuation
        continuation.yield(.snapshot(state))
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    public func createConversation(title: String?) async throws -> ChatCore.ConversationID { throw unavailable }
    public func selectConversation(_ id: ChatCore.ConversationID?) async throws { throw unavailable }
    public func send(_ request: SendRequest) async throws { throw unavailable }
    public func stop(conversationID: ChatCore.ConversationID) async throws { throw unavailable }

    private var unavailable: ChatBackendError { state.connection == .demo ? .demoReadOnly : .disconnected }
    private func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }
}
