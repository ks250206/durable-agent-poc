import ChatCore
import Foundation
import Observation

/// Measured row IDs in the transcript's actual viewport, independent of message counts.
public struct TranscriptViewport: Equatable, Sendable {
    public var firstVisibleMessageID: MessageID?
    public var lastVisibleMessageID: MessageID?
    public var centerVisibleMessageID: MessageID?
    public init(firstVisibleMessageID: MessageID? = nil, lastVisibleMessageID: MessageID? = nil,
                centerVisibleMessageID: MessageID? = nil) {
        self.firstVisibleMessageID = firstVisibleMessageID
        self.lastVisibleMessageID = lastVisibleMessageID
        self.centerVisibleMessageID = centerVisibleMessageID
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
