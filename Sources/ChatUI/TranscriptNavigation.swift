import ChatCore
import Foundation
import Observation

/// #4 reports first/last visible stable IDs; #6 uses the range to draw its viewport.
public struct TranscriptViewport: Equatable, Sendable {
    public var firstVisibleMessageID: MessageID?
    public var lastVisibleMessageID: MessageID?
    public init(firstVisibleMessageID: MessageID? = nil, lastVisibleMessageID: MessageID? = nil) {
        self.firstVisibleMessageID = firstVisibleMessageID
        self.lastVisibleMessageID = lastVisibleMessageID
    }
}

public struct MessageScrollRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let messageID: MessageID
    public init(messageID: MessageID) {
        id = UUID()
        self.messageID = messageID
    }
}

/// Shared UI-only insertion point. #4 observes scrollRequest with ScrollViewReader; #6 calls jump(to:).
/// Call reset() on conversation switch. Repeated jumps to the same message still produce a new request ID.
@MainActor @Observable
public final class TranscriptNavigation {
    public var viewport = TranscriptViewport()
    public private(set) var scrollRequest: MessageScrollRequest?
    public init() {}
    public func jump(to id: MessageID) { scrollRequest = MessageScrollRequest(messageID: id) }
    public func reset() {
        viewport = TranscriptViewport()
        scrollRequest = nil
    }
}
