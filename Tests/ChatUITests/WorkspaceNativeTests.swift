import AppKit
import AppLocalization
import ChatCore
@testable import ChatUI
import SwiftUI
import Testing

private let firstID = ConversationID("ui:first")
private let secondID = ConversationID("ui:second")

private func uiConversation(_ id: ConversationID, count: Int) -> ConversationSnapshot {
    ConversationSnapshot(
        summary: ConversationSummary(id: id, title: id == firstID ? "Café architecture" : "Second conversation"),
        messages: (0..<count).map { index in
            ChatMessage(id: MessageID("\(id.rawValue):\(index)"), conversationID: id,
                        role: index.isMultiple(of: 2) ? .user : .assistant,
                        content: "Message \(index). " + String(repeating: "Readable transcript content with a stable identity. ", count: 5))
        }
    )
}

private actor WorkspaceBackend: ChatBackend {
    private var state: ChatSnapshot
    private var observers: [UUID: AsyncThrowingStream<ChatEvent, any Error>.Continuation] = [:]
    private(set) var selections: [ConversationID?] = []
    private let rejectSelection: Bool

    init(count: Int = 24, rejectSelection: Bool = false) {
        self.rejectSelection = rejectSelection
        let first = uiConversation(firstID, count: count)
        let second = uiConversation(secondID, count: 2)
        state = ChatSnapshot(connection: .connected, conversations: [first.summary, second.summary],
                             selectedConversationID: firstID, loadedConversations: [first, second])
    }
    func snapshot() async throws -> ChatSnapshot { state }
    func events() async -> AsyncThrowingStream<ChatEvent, any Error> {
        let id = UUID()
        let (stream, continuation) = AsyncThrowingStream<ChatEvent, any Error>.makeStream()
        observers[id] = continuation
        continuation.yield(.snapshot(state))
        continuation.onTermination = { @Sendable [weak self] _ in Task { await self?.remove(id) } }
        return stream
    }
    private func remove(_ id: UUID) { observers.removeValue(forKey: id) }
    private func publish() { for observer in observers.values { observer.yield(.snapshot(state)) } }
    func createConversation(title: String?) async throws -> ConversationID {
        var conversation = uiConversation(ConversationID("ui:created"), count: 0)
        conversation.summary.title = title ?? "New conversation"
        state.conversations.append(conversation.summary)
        state.loadedConversations.append(conversation)
        state.selectedConversationID = conversation.id
        publish()
        return conversation.id
    }
    func selectConversation(_ id: ConversationID?) async throws {
        selections.append(id)
        if rejectSelection { throw ChatBackendError.unavailable("Unable to open this conversation") }
        state.selectedConversationID = id
        publish()
    }
    func send(_ request: SendRequest) async throws { throw ChatBackendError.unavailable("Not used by workspace tests") }
    func stop(conversationID: ConversationID) async throws {}
    func setConnection(_ connection: ConnectionState) { state.connection = connection; publish() }
    func growFirstConversation(repetitions: Int = 80) {
        var conversation = uiConversation(firstID, count: 25)
        conversation.activity = .streaming
        conversation.messages[24].status = .streaming
        conversation.messages[24].content = String(repeating: "Incoming response. ", count: repetitions)
        state.loadedConversations.removeAll { $0.id == firstID }
        state.loadedConversations.append(conversation)
        for observer in observers.values { observer.yield(.conversationUpdated(conversation)) }
    }
}

@MainActor
private final class HostedWorkspace {
    let host: NSHostingView<AnyView>
    let window: NSWindow

    init<V: View>(_ view: V, width: CGFloat, height: CGFloat = 720) {
        _ = NSApplication.shared
        host = NSHostingView(rootView: AnyView(view.environment(\.locale, Locale(identifier: "en"))))
        host.sizingOptions = []
        window = NSWindow(contentRect: NSRect(x: -16000, y: -16000, width: width, height: height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }
    func close() { window.close() }

    func capture(_ name: String) throws -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        if let path = ProcessInfo.processInfo.environment["CHAT_UI_ARTIFACTS_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try image.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
        }
        return image
    }

    var scrollViews: [NSScrollView] {
        func find(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(find)
        }
        return find(host)
    }

}

@MainActor
private func eventually(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    try #require(condition(), sourceLocation: sourceLocation)
}

extension NativeUITests {
@Suite
@MainActor
struct WorkspaceNativeTests {
    @Test func streamingFollowsLatestUntilNativeScrollMovesUp() async throws {
        let backend = WorkspaceBackend()
        let store = ChatStore(backend: backend)
        let observation = Task { await store.start() }
        defer { observation.cancel() }
        try await eventually { store.messages.count == 24 }
        let navigation = TranscriptNavigation()
        let hosted = HostedWorkspace(TranscriptView(store: store, navigation: navigation), width: 600, height: 440)
        defer { hosted.close() }
        try await eventually { navigation.viewport.lastVisibleMessageID == store.messages.last?.id }
        await backend.growFirstConversation()
        try await eventually { navigation.viewport.lastVisibleMessageID == MessageID("ui:first:24") }
        try await Task.sleep(for: .milliseconds(100))
        let latest = navigation.viewport
        let scrollView = try #require(hosted.scrollViews.first)
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: max(0, clip.bounds.origin.y - 700)))
        scrollView.reflectScrolledClipView(clip)
        try await eventually { navigation.viewport.firstVisibleMessageID != latest.firstVisibleMessageID }
        try await Task.sleep(for: .milliseconds(100))
        let earlier = navigation.viewport
        let offset = clip.bounds.origin.y
        await backend.growFirstConversation(repetitions: 160)
        try await eventually { store.messages.last?.content.count == "Incoming response. ".count * 160 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(navigation.viewport == earlier)
        #expect(abs(clip.bounds.origin.y - offset) < 1)
    }

    @Test func realScrollViewReportsViewportJumpsRetainsReadingAndResetsOnSwitch() async throws {
        let backend = WorkspaceBackend()
        let store = ChatStore(backend: backend)
        let observation = Task { await store.start() }
        defer { observation.cancel() }
        try await eventually { store.messages.count == 24 }
        let navigation = TranscriptNavigation()
        let hosted = HostedWorkspace(TranscriptView(store: store, navigation: navigation), width: 600, height: 440)
        defer { hosted.close() }
        try await eventually { navigation.viewport.lastVisibleMessageID == store.messages.last?.id }
        #expect(navigation.viewport.firstVisibleMessageID != store.messages.first?.id)

        let target = store.messages[5].id
        navigation.jump(to: target)
        try await eventually { navigation.viewport.firstVisibleMessageID == target }
        // Preferences can report the new SwiftUI geometry a frame before AppKit commits its clip bounds.
        try await Task.sleep(for: .milliseconds(100))
        let before = navigation.viewport
        let scrollView = try #require(hosted.scrollViews.first)
        let offset = scrollView.contentView.bounds.origin.y
        await backend.growFirstConversation()
        try await eventually { store.messages.count == 25 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(navigation.viewport == before)
        #expect(abs(scrollView.contentView.bounds.origin.y - offset) < 1)

        navigation.jump(to: MessageID("missing"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(navigation.viewport == before)
        navigation.jump(to: target) // repeating the same target remains actionable
        try await eventually { navigation.viewport.firstVisibleMessageID == target }

        await store.selectConversation(secondID)
        try await eventually { navigation.viewport.lastVisibleMessageID?.rawValue.hasPrefix(secondID.rawValue) == true }
        #expect(navigation.scrollRequest == nil)
        await backend.growFirstConversation() // background output must not change the selected transcript
        try await Task.sleep(for: .milliseconds(100))
        #expect(navigation.viewport.firstVisibleMessageID?.rawValue.hasPrefix(secondID.rawValue) == true)
        await store.selectConversation(nil)
        try await eventually { navigation.viewport == TranscriptViewport() }
    }

    @Test func sidebarActionsKeepSelectionWhenFilteredAndCreateThroughSharedStore() async throws {
        let backend = WorkspaceBackend(count: 0)
        let store = ChatStore(backend: backend)
        let observation = Task { await store.start() }
        defer { observation.cancel() }
        try await eventually { store.connection == .connected }
        let actions = ConversationSidebarActions(store: store)
        await actions.select(secondID)
        try await eventually { store.selectedConversationID == secondID }
        #expect(await backend.selections == [secondID])
        actions.query = "cafe"
        #expect(actions.filtered.map(\.id) == [firstID])
        #expect(store.selectedConversationID == secondID) // filtering does not select a different conversation
        await actions.create()
        try await eventually { store.selectedConversationID == ConversationID("ui:created") }
        #expect(actions.query.isEmpty)
        #expect(!actions.isBusy)
        #expect(store.messages.isEmpty)
    }

    @Test func sidebarSelectionFailureKeepsCurrentConversationAndReadOnlyRejectsCreation() async throws {
        let backend = WorkspaceBackend(count: 0, rejectSelection: true)
        let store = ChatStore(backend: backend)
        let observation = Task { await store.start() }
        defer { observation.cancel() }
        try await eventually { store.selectedConversationID == firstID }
        let actions = ConversationSidebarActions(store: store)
        actions.query = "cafe"
        await actions.select(secondID)
        #expect(store.selectedConversationID == firstID)
        #expect(store.lastFailure?.operation == "select")
        #expect(store.lastFailure?.conversationID == secondID)
        #expect(actions.query == "cafe")
        #expect(!actions.isBusy)
        await backend.setConnection(.demo)
        try await eventually { store.connection == .demo }
        await actions.create()
        #expect(store.conversations.count == 2)
        #expect(store.selectedConversationID == firstID)
        #expect(actions.query == "cafe")
    }

    @Test func messageLayoutWrapsLongWordsAndContainsHorizontallyScrollableCode() throws {
        let message = ChatMessage(id: MessageID("long"), conversationID: firstID, role: .assistant,
                                  content: "# A readable heading\n\n" + String(repeating: "longword", count: 80)
                                    + "\n\n```swift\nlet value = \"" + String(repeating: "wide_code_", count: 80) + "\"\n```\n\n> A quote\n- A list item")
        for scheme in [ColorScheme.light, .dark] {
            let content = MessageRow(message: message).environment(\.colorScheme, scheme)
            let narrowRenderer = ImageRenderer(content: content)
            narrowRenderer.proposedSize = ProposedViewSize(width: 360, height: nil)
            let narrow = try #require(narrowRenderer.cgImage)
            let wideRenderer = ImageRenderer(content: content)
            wideRenderer.proposedSize = ProposedViewSize(width: 760, height: nil)
            let wide = try #require(wideRenderer.cgImage)
            #expect(narrow.width == 360)
            #expect(wide.width == 760)
            #expect(narrow.height > wide.height) // prose wraps; code keeps its own horizontal axis

            let hosted = HostedWorkspace(content, width: 360, height: CGFloat(narrow.height))
            defer { hosted.close() }
            let bitmap = try hosted.capture("message-360-\(scheme)")
            #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
            #expect(hosted.scrollViews.contains { $0.hasHorizontalScroller })
        }
    }

    @Test func workspaceHostsRealSlotsAtDesktopAndNarrowWidthsInBothAppearances() async throws {
        let backend = WorkspaceBackend(count: 2)
        let store = ChatStore(backend: backend)
        let observation = Task { await store.start() }
        defer { observation.cancel() }
        try await eventually { store.messages.count == 2 }
        store.modelSelection = ModelSelection(account: ProviderAccount(option: .apiKey, providerID: "test-provider"), modelID: "test-model")
        for scheme in [ColorScheme.light, .dark] {
            for width in [CGFloat(360), 1200] {
                let workspace = ChatWorkspaceView(store: store, navigation: TranscriptNavigation()) { _ in
                    Text("Injected composer").padding(12).frame(maxWidth: .infinity).border(.secondary)
                } minimap: { _, _ in
                    Text("Injected overview").frame(maxWidth: .infinity, maxHeight: .infinity)
                }.environment(\.colorScheme, scheme)
                let hosted = HostedWorkspace(workspace, width: width)
                defer { hosted.close() }
                try await Task.sleep(for: .milliseconds(100))
                let image = try hosted.capture("workspace-\(Int(width))-\(scheme)")
                #expect(image.pixelsWide > 0 && image.pixelsHigh > 0)
                // Native hosting proves the generic slots and adaptive tree lay out without an app entrypoint.
                #expect(hosted.host.frame.width == width)
                #expect(hosted.scrollViews.allSatisfy { $0.frame.width <= width })
            }
        }
    }
}

}
