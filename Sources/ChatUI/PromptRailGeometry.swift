import ChatCore
import Foundation

/// Every input and every message-to-preceding-input association is retained.
/// Length, status, localization and appearance never influence this mapping.
struct PromptRailModel {
    let inputs: [ChatMessage]
    private let indices: [MessageID: Int]
    private let precedingInputs: [MessageID: MessageID]

    init(messages: [ChatMessage]) {
        var inputs: [ChatMessage] = []
        var indices: [MessageID: Int] = [:]
        var preceding: [MessageID: MessageID] = [:]
        var user: MessageID?
        for message in messages {
            if message.role == .user {
                indices[message.id] = inputs.count
                inputs.append(message)
                user = message.id
            }
            if let user { preceding[message.id] = user }
        }
        self.inputs = inputs
        self.indices = indices
        precedingInputs = preceding
    }

    func index(for id: MessageID?) -> Int? { id.flatMap { indices[$0] } }
    func currentInput(in viewport: TranscriptViewport) -> MessageID? {
        viewport.centerVisibleMessageID.flatMap { precedingInputs[$0] }
    }
}

/// Fixed full-width hit cells are independent of animated bar width. When there is
/// insufficient height, an explicitly announced window replaces subpixel crowding.
struct PromptRailGeometry {
    static let width: CGFloat = 40
    static let pitch: CGFloat = 12
    static let controlHeight: CGFloat = 18
    let size: CGSize
    let count: Int
    let start: Int
    let capacity: Int
    let isWindowed: Bool

    init(size: CGSize, count: Int, proposedStart: Int = 0) {
        self.size = size
        self.count = max(0, count)
        let height = size.height.isFinite ? max(0, size.height) : 0
        let fullCapacity = Int(min(100_000, height / Self.pitch))
        isWindowed = count > fullCapacity
        capacity = max(0, isWindowed
                       ? Int(min(100_000, max(0, height - 2 * Self.controlHeight) / Self.pitch))
                       : fullCapacity)
        start = min(max(0, proposedStart), max(0, count - capacity))
    }

    var visible: Range<Int> { start..<min(count, start + capacity) }
    var topInset: CGFloat { isWindowed ? Self.controlHeight : 0 }
    var hasEarlier: Bool { start > 0 }
    var hasLater: Bool { visible.upperBound < count }
    func cell(for index: Int) -> CGRect {
        guard visible.contains(index), size.width.isFinite, size.width > 0 else { return .zero }
        return CGRect(x: 0, y: topInset + CGFloat(index - start) * Self.pitch,
                      width: size.width, height: Self.pitch)
    }
    func index(at point: CGPoint) -> Int? {
        guard size.width.isFinite, point.x >= 0, point.x < size.width,
              point.y >= topInset, point.y < topInset + CGFloat(visible.count) * Self.pitch else { return nil }
        let index = start + Int((point.y - topInset) / Self.pitch)
        return visible.contains(index) ? index : nil
    }
    func start(revealing index: Int) -> Int {
        guard !visible.contains(index) else { return start }
        return min(max(0, index - capacity / 2), max(0, count - capacity))
    }
    func barWidth(current: Bool, hovered: Bool) -> CGFloat {
        min(max(0, size.width - 12), hovered ? 28 : (current ? 22 : 10))
    }
}
