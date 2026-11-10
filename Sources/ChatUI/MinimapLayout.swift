import ChatCore
import Foundation

/// Text-weighted coordinates for the *entire* transcript. No minimum row height or truncation:
/// dense messages can occupy subpixels; binary hit testing and keyboard navigation retain every ID.
struct MinimapLayout {
    struct Node {
        let id: MessageID
        let role: MessageRole
        let byteCount: Int
        let status: MessageStatus
        let start: Double
        let end: Double
    }

    let nodes: [Node]
    private let indices: [MessageID: Int]
    private let trajectoryLanes: [[Int]]

    init(messages: [ChatMessage]) {
        let lengths = messages.map { $0.content.utf8.count }
        // Square-root compression preserves length differences without letting a huge tool result
        // consume the entire overview. These are text weights, not transcript pixel measurements.
        let weights = lengths.map { 1 + sqrt(Double($0) / 80) }
        let total = weights.reduce(0, +)
        var offset = 0.0
        nodes = messages.indices.map { index in
            let start = offset
            offset += weights[index] / total
            return Node(
                id: messages[index].id, role: messages[index].role,
                byteCount: lengths[index], status: messages[index].status,
                start: start, end: index == messages.count - 1 ? 1 : offset
            )
        }
        indices = Dictionary(uniqueKeysWithValues: messages.enumerated().map { ($0.element.id, $0.offset) })
        trajectoryLanes = (0..<3).map { lane in messages.indices.filter { Self.trajectoryLane(messages[$0].role) == lane } }
    }

    func index(for id: MessageID?) -> Int? { id.flatMap { indices[$0] } }

    func index(at fraction: Double) -> Int? {
        guard !nodes.isEmpty, fraction.isFinite else { return nil }
        let position = min(1, max(0, fraction))
        var low = 0
        var high = nodes.count - 1
        while low < high {
            let mid = low + (high - low) / 2
            if position < nodes[mid].end { high = mid } else { low = mid + 1 }
        }
        return low
    }

    /// A viewport is only known when both reported IDs belong to this transcript.
    func visibleIndices(_ viewport: TranscriptViewport) -> ClosedRange<Int>? {
        guard let first = index(for: viewport.firstVisibleMessageID),
            let last = index(for: viewport.lastVisibleMessageID)
        else { return nil }
        return min(first, last)...max(first, last)
    }

    func viewportRect(_ viewport: TranscriptViewport, size: CGSize) -> CGRect? {
        guard let range = visibleIndices(viewport), valid(size) else { return nil }
        let top = nodes[range.lowerBound].start * size.height
        let bottom = nodes[range.upperBound].end * size.height
        // A bounded minimum makes a subpixel viewport visible without shifting it past the ends.
        let height = min(size.height, max(3, bottom - top))
        let y = min(size.height - height, max(0, (top + bottom - height) / 2))
        return CGRect(x: 0, y: y, width: size.width, height: height)
    }

    func rect(for index: Int, size: CGSize) -> CGRect {
        guard nodes.indices.contains(index), valid(size) else { return .zero }
        let node = nodes[index]
        let inset = min(5, size.width / 10)
        let laneWidth = (size.width - 2 * inset) / 4
        let lane = Double(MessageRole.allCases.firstIndex(of: node.role) ?? 0)
        let width = laneWidth * (0.45 + 0.55 * min(1, log2(1 + Double(node.byteCount)) / 14))
        return CGRect(
            x: inset + lane * laneWidth, y: node.start * size.height,
            width: width, height: (node.end - node.start) * size.height
        )
    }

    static func trajectoryLane(_ role: MessageRole) -> Int {
        switch role { case .user: 0; case .assistant: 1; case .tool, .system: 2 }
    }

    func trajectoryRect(for index: Int, plot: CGRect) -> CGRect {
        guard nodes.indices.contains(index), valid(plot.size) else { return .zero }
        let node = nodes[index]
        let x = plot.minX + node.start * plot.width
        let width = min(plot.width, max(1, (node.end - node.start) * plot.width))
        return CGRect(x: min(x, plot.maxX - width), y: plot.minY + CGFloat(Self.trajectoryLane(node.role)) * 26 + 5,
                      width: width, height: 13)
    }

    func trajectoryViewportRect(_ viewport: TranscriptViewport, plot: CGRect) -> CGRect? {
        guard let vertical = viewportRect(viewport, size: CGSize(width: plot.height, height: plot.width)) else { return nil }
        return CGRect(x: plot.minX + vertical.minY, y: plot.minY, width: vertical.height, height: plot.height)
    }

    /// Nearest original interval in the clicked lane; absent roles never generate a target.
    func trajectoryIndex(at point: CGPoint, plot: CGRect) -> Int? {
        guard valid(plot.size), plot.contains(point) else { return nil }
        let lane = Int((point.y - plot.minY) / 26)
        let fraction = (point.x - plot.minX) / plot.width
        guard trajectoryLanes.indices.contains(lane), !trajectoryLanes[lane].isEmpty else { return nil }
        let candidates = trajectoryLanes[lane]
        var low = 0
        var high = candidates.count
        while low < high {
            let mid = low + (high - low) / 2
            if nodes[candidates[mid]].end < fraction { low = mid + 1 } else { high = mid }
        }
        let after = min(low, candidates.count - 1)
        let before = max(0, after - 1)
        func distance(_ ordinal: Int) -> Double {
            let node = nodes[candidates[ordinal]]
            return max(node.start - fraction, fraction - node.end, 0)
        }
        return candidates[distance(before) <= distance(after) ? before : after]
    }

    private func valid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
}

/// Accept plain digits or the exact localized integer format displayed by the number hint.
/// Canonical comparison rejects partial parses, decimals and malformed grouping.
enum MessageNumberInput {
    static func targetIndex(_ source: String, count: Int, locale: Locale) -> Int? {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        let separator = formatter.groupingSeparator ?? ""
        let digits = separator.isEmpty ? text : text.replacingOccurrences(of: separator, with: "")
        guard !digits.isEmpty,
              digits.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(digits), value > 0, value <= count,
              text == digits || text == value.formatted(.number.locale(locale))
        else { return nil }
        return value - 1
    }
}
