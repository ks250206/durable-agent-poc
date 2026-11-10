import AppKit
import AppLocalization
import ChatCore
import SwiftUI
import Testing

@testable import ChatUI

private func minimapMessages(_ count: Int, conversation: ConversationID = ConversationID("map:a")) -> [ChatMessage] {
    (0..<count).map { index in
        ChatMessage(
            id: MessageID("\(conversation.rawValue):entry:\(index * 7):0"), conversationID: conversation,
            role: MessageRole.allCases[index % 4],
            content: String(repeating: index % 2 == 0 ? "a" : "🧭", count: index % 137),
            createdAt: Date(timeIntervalSince1970: Double(index))
        )
    }
}

@Test func minimapEmptySingletonAndInvalidGeometry() {
    let empty = MinimapLayout(messages: [])
    #expect(empty.nodes.isEmpty)
    #expect(empty.index(at: 0) == nil)
    #expect(empty.viewportRect(TranscriptViewport(), size: CGSize(width: 50, height: 300)) == nil)
    let messages = minimapMessages(1)
    let layout = MinimapLayout(messages: messages)
    #expect(layout.nodes[0].start == 0)
    #expect(layout.nodes[0].end == 1)
    for fraction in [-2.0, 0, 0.5, 1, 2] { #expect(layout.index(at: fraction) == 0) }
    #expect(layout.index(at: .nan) == nil)
    #expect(layout.index(at: .infinity) == nil)
    let viewport = TranscriptViewport(firstVisibleMessageID: messages[0].id, lastVisibleMessageID: messages[0].id)
    #expect(layout.viewportRect(viewport, size: CGSize(width: 2, height: 1)) == CGRect(x: 0, y: 0, width: 2, height: 1))
    for size in [CGSize.zero, CGSize(width: -1, height: 10), CGSize(width: 10, height: CGFloat.infinity)] {
        #expect(layout.rect(for: 0, size: size) == .zero)
        #expect(layout.viewportRect(viewport, size: size) == nil)
    }
}

@Test func minimapTenThousandMessagesHaveBoundedCompleteCoordinatesAndExactIDs() throws {
    let messages = minimapMessages(10_000)
    let layout = MinimapLayout(messages: messages)
    #expect(layout.nodes.count == messages.count)
    #expect(layout.nodes.first?.start == 0)
    #expect(layout.nodes.last?.end == 1)
    for index in messages.indices {
        let node = layout.nodes[index]
        #expect(node.id == messages[index].id)
        #expect(node.role == messages[index].role)
        #expect(node.start < node.end)
        #expect(layout.index(at: (node.start + node.end) / 2) == index)
        #expect(layout.index(for: messages[index].id) == index)
        if index > 0 { #expect(layout.nodes[index - 1].end == node.start) }
        for width in [1.0, 24, 64, 180] {
            let size = CGSize(width: width, height: 480)
            let rect = layout.rect(for: index, size: size)
            #expect(rect.minX >= 0 && rect.maxX <= size.width)
            #expect(rect.minY >= 0 && rect.maxY <= size.height + 0.000_001)
            #expect(rect.width > 0 && rect.height > 0)
        }
    }
    let viewport = TranscriptViewport(
        firstVisibleMessageID: messages[9_997].id, lastVisibleMessageID: messages[9_999].id)
    let rect = try #require(layout.viewportRect(viewport, size: CGSize(width: 1, height: 2)))
    #expect(rect.minY >= 0 && rect.maxY <= 2)
    #expect(layout.index(at: 1) == 9_999)
}

@Test func minimapVariableLengthStreamingAndViewportUseStableIdentity() throws {
    var messages = minimapMessages(5)
    messages[2].content = String(repeating: "long tool output\n", count: 10_000)
    messages[4].status = .streaming
    let before = MinimapLayout(messages: messages)
    #expect(before.nodes[2].end - before.nodes[2].start > before.nodes[1].end - before.nodes[1].start)
    let viewport = TranscriptViewport(firstVisibleMessageID: messages[3].id, lastVisibleMessageID: messages[1].id)
    #expect(before.visibleIndices(viewport) == 1...3)
    #expect(
        before.visibleIndices(
            TranscriptViewport(firstVisibleMessageID: MessageID("missing"), lastVisibleMessageID: messages[4].id))
            == nil)
    #expect(before.visibleIndices(TranscriptViewport(firstVisibleMessageID: messages[0].id)) == nil)
    messages[4].content += String(repeating: "stream", count: 2000)
    let after = MinimapLayout(messages: messages)
    #expect(before.nodes.map(\.id) == after.nodes.map(\.id))
    #expect(before.nodes[4].start != after.nodes[4].start)
    #expect(after.visibleIndices(viewport) == 1...3)
    let size = CGSize(width: 100, height: 500)
    let rect = try #require(after.viewportRect(viewport, size: size))
    #expect(abs(rect.minY - after.nodes[1].start * 500) < 0.000_001)
    #expect(abs(rect.maxY - after.nodes[3].end * 500) < 0.000_001)
    messages[4].status = .complete
    messages.append(contentsOf: minimapMessages(1, conversation: ConversationID("new-id")))
    let appended = MinimapLayout(messages: messages)
    #expect(appended.index(for: after.nodes[4].id) == 4)
    #expect(appended.nodes[4].status == .complete)
    #expect(appended.nodes.last?.end == 1)
}
