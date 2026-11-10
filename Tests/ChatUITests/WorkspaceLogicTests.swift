import ChatCore
import Foundation
@testable import ChatUI
import Testing

@Test func conversationSearchFoldsAccentsUsesAllTermsAndPreservesBackendOrder() {
    let summaries = [
        ConversationSummary(id: ConversationID("recent"), title: "Café SwiftUI layout"),
        ConversationSummary(id: ConversationID("older"), title: "SwiftUI café examples"),
        ConversationSummary(id: ConversationID("other"), title: "Runtime connection"),
        ConversationSummary(id: ConversationID("blank"), title: "  \n"),
    ]
    #expect(ConversationFilter.matching(summaries, query: "  CAFE\n swiftui ").map(\.id) == summaries.prefix(2).map(\.id))
    #expect(ConversationFilter.matching(summaries, query: " \n\t ") == summaries)
    #expect(ConversationFilter.matching(summaries, query: "missing").isEmpty)
    #expect(ConversationFilter.matching(summaries, query: "untitled").map(\.id) == [ConversationID("blank")])
}

@Test func viewportUsesActualIntersectionsInTranscriptOrderIncludingOversizedRows() {
    let ids = (0..<5).map { MessageID("m\($0)") }
    let geometry = TranscriptMeasurements(frames: [
        ids[0]: CGRect(x: 0, y: -100, width: 400, height: 100), // touches top; invisible
        ids[1]: CGRect(x: 0, y: -40, width: 400, height: 90),
        ids[2]: CGRect(x: 0, y: 70, width: 400, height: 600),
        ids[3]: CGRect(x: 0, y: 300, width: 400, height: 100), // touches bottom; invisible
        ids[4]: CGRect(x: 0, y: 50, width: 400, height: 0),
    ])
    #expect(geometry.viewport(orderedIDs: ids, height: 300) == TranscriptViewport(firstVisibleMessageID: ids[1], lastVisibleMessageID: ids[2]))
    #expect(geometry.viewport(orderedIDs: [ids[2]], height: 300) == TranscriptViewport(firstVisibleMessageID: ids[2], lastVisibleMessageID: ids[2]))
    #expect(geometry.viewport(orderedIDs: ids, height: 0) == TranscriptViewport())
    #expect(geometry.viewport(orderedIDs: [MessageID("not-measured")], height: 300) == TranscriptViewport())
}

@Test func streamingFollowsBottomButKeepsEarlierReadingPositionUntilExplicitResume() {
    var state = TranscriptScrollState()
    state.update(TranscriptMeasurements(top: -600, bottom: 400), height: 400)
    state.update(TranscriptMeasurements(top: -600, bottom: 520), height: 400) // streaming growth
    #expect(state.followsLatest)
    state.update(TranscriptMeasurements(top: -720, bottom: 400), height: 400) // automatic follow
    #expect(state.followsLatest)
    state.update(TranscriptMeasurements(top: -480, bottom: 640), height: 400) // reader scrolls up
    #expect(!state.followsLatest)
    state.update(TranscriptMeasurements(top: -480, bottom: 900), height: 400) // new output while reading
    #expect(!state.followsLatest)
    state.jump()
    state.update(TranscriptMeasurements(top: -200, bottom: 1180), height: 400)
    #expect(!state.followsLatest)
    state.resume()
    #expect(state.followsLatest)
    state.jump()
    state.update(TranscriptMeasurements(top: -980, bottom: 400), height: 400) // reader returns to bottom
    #expect(state.followsLatest)
}

@Test func narrowWorkspaceKeepsAuxiliaryPanesOutOfTheReadingColumn() {
    #expect(!WorkspaceLayout(width: 360).inlineSidebar)
    #expect(!WorkspaceLayout(width: 780).inlineMinimap)
    #expect(WorkspaceLayout(width: 780).inlineSidebar)
    let desktop = WorkspaceLayout(width: 1200)
    #expect(desktop.inlineSidebar && desktop.inlineMinimap)
    #expect(desktop.width - WorkspaceLayout.sidebarWidth - WorkspaceLayout.minimapWidth >= 760)
}

@Test func markdownRendersStructureAndPreservesCodeWhitespaceAndStreamingFences() {
    #expect(MessageBlock.parse("# Title\n\nHello **world**.\nSecond line\n\n- One\n2. Two\n> Quoted\n---") == [
        .heading(1, "Title"), .paragraph("Hello **world**.\nSecond line"), .listItem("•", "One"),
        .listItem("2.", "Two"), .quote("Quoted"), .divider,
    ])
    #expect(MessageBlock.parse("````swift\n  let x = `value`\n```\n````\nAfter") == [
        .code(language: "swift", text: "  let x = `value`\n```\n"), .paragraph("After"),
    ])
    #expect(MessageBlock.parse("~~~python\n  print('partial')\n") == [.code(language: "python", text: "  print('partial')\n")])
    #expect(MessageBlock.parse("```\n``` ") == [.code(language: nil, text: "")])
    #expect(MessageBlock.parse("```text\r\n  code\r\n```\r\nDone") == [.code(language: "text", text: "  code\n"), .paragraph("Done")])
    #expect(MessageBlock.parse("```ls -la``` lists files.\n\nNext paragraph") == [
        .paragraph("```ls -la``` lists files."), .paragraph("Next paragraph"),
    ])
    #expect(MessageBlock.parse("").isEmpty)
}

@Test func connectionLabelsDistinguishReadOnlyConnectingAndFailures() {
    #expect(ConnectionPresentation(.demo).title == "Demo · Read only")
    #expect(ConnectionPresentation(.connecting).title == "Connecting…")
    #expect(ConnectionPresentation(.connected).detail == nil)
    #expect(ConnectionPresentation(.failed("Backend unavailable")).detail == "Backend unavailable")
    #expect(ConnectionPresentation(.disconnected).title == "Disconnected")
}

@Test func messageLinksOnlyOpenWebSchemes() {
    #expect(MessageLinkPolicy.allows(URL(string: "https://example.com")!))
    #expect(MessageLinkPolicy.allows(URL(string: "http://example.com")!))
    #expect(!MessageLinkPolicy.allows(URL(string: "file:///tmp/private.txt")!))
    #expect(!MessageLinkPolicy.allows(URL(string: "custom-app://perform-action")!))
}
