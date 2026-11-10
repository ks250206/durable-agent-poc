import AppKit
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

/// AppKit tests are serialized because NSApplication and the key-view loop are process-global.
/// Events travel through a real NSWindow to the same NSViewRepresentable input surface used by Canvas.
@Suite(.serialized) @MainActor
struct MinimapNativeHostTests {
    @Test func workspaceSlotUsesRealTranscriptViewportAndStableIDJumps() async throws {
        _ = NSApplication.shared
        let backend = MinimapTestBackend(messages: minimapMessages(160))
        let store = ChatStore(backend: backend)
        let navigation = TranscriptNavigation()
        let observation = Task { await store.start() }
        defer { observation.cancel() }
        try await settle { store.messages.count == 160 }
        let workspace = ChatWorkspaceView(
            store: store, navigation: navigation, composer: { _ in EmptyView() },
            minimap: { store, navigation in ConversationMinimap(store: store, navigation: navigation) }
        )
        let host = NSHostingView(rootView: workspace)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 760), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        let input = try await surface(in: host)
        try await settle { navigation.viewport.lastVisibleMessageID == store.messages.last?.id }
        let target = 40
        let node = input.layout.nodes[target]
        let point = input.convert(
            CGPoint(x: input.bounds.midX, y: (node.start + node.end) / 2 * input.bounds.height), to: nil)
        let click = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        window.sendEvent(click)
        try await settle { navigation.viewport.firstVisibleMessageID == store.messages[target].id }
        #expect(navigation.scrollRequest?.messageID == store.messages[target].id)
        #expect(input.layout.visibleIndices(navigation.viewport)?.contains(target) == true)
        window.sendEvent(try key(126, window: window))
        try await settle { navigation.viewport.firstVisibleMessageID == store.messages[target - 1].id }
        #expect(navigation.scrollRequest?.messageID == store.messages[target - 1].id)
        try capture(host, name: "workspace-slot")
        await store.selectConversation(ConversationID("map:b"))
        try await settle { navigation.viewport.firstVisibleMessageID == store.messages.first?.id }
        #expect(navigation.scrollRequest == nil)
        let replacement = try await surface(in: host)
        #expect(replacement !== input)
        #expect(replacement.layout.visibleIndices(navigation.viewport) == 0...0)
    }

    @Test func pointerKeyboardHoverAndAccessibilityNavigateExactIDs() throws {
        _ = NSApplication.shared
        let messages = minimapMessages(200)
        let layout = MinimapLayout(messages: messages)
        let navigation = TranscriptNavigation()
        navigation.viewport = TranscriptViewport(
            firstVisibleMessageID: messages[87].id, lastVisibleMessageID: messages[91].id)
        let view = MinimapInputView(frame: NSRect(x: 0, y: 0, width: 120, height: 480))
        view.layout = layout
        view.navigation = navigation
        var hoverID: MessageID?
        view.onHover = { hoverID = $0 }
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        pumpRunLoop()
        #expect(window.makeFirstResponder(view))

        // Starts at the actual viewport rather than an assumed beginning or latest message.
        window.sendEvent(try key(125, window: window))
        #expect(navigation.scrollRequest?.messageID == messages[88].id)
        #expect(navigation.viewport.firstVisibleMessageID == messages[87].id)
        window.sendEvent(try key(119, window: window))
        #expect(navigation.scrollRequest?.messageID == messages.last?.id)
        let request = navigation.scrollRequest?.id
        window.sendEvent(try key(36, window: window))
        #expect(navigation.scrollRequest?.id != request)
        #expect(navigation.scrollRequest?.messageID == messages.last?.id)
        window.sendEvent(try key(115, window: window))
        #expect(navigation.scrollRequest?.messageID == messages.first?.id)
        window.sendEvent(try key(121, window: window))
        #expect(navigation.scrollRequest?.messageID == messages[10].id)
        window.sendEvent(try key(116, window: window))
        #expect(navigation.scrollRequest?.messageID == messages.first?.id)

        let node = layout.nodes[137]
        let local = CGPoint(x: 60, y: (node.start + node.end) / 2 * view.bounds.height)
        let location = view.convert(local, to: nil)
        let click = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        window.sendEvent(click)
        #expect(navigation.scrollRequest?.messageID == messages[137].id)
        #expect(window.firstResponder === view)
        let hover = try #require(
            NSEvent.mouseEvent(
                with: .mouseMoved, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 0, pressure: 0))
        view.mouseMoved(with: hover)
        #expect(hoverID == messages[137].id)
        view.mouseExited(with: hover)
        #expect(hoverID == nil)
        #expect(view.accessibilityPerformIncrement())
        #expect(navigation.scrollRequest?.messageID == messages[138].id)
        #expect(view.accessibilityPerformDecrement())
        #expect(navigation.scrollRequest?.messageID == messages[137].id)
        #expect((view.accessibilityValue() as? String)?.contains("138 of 200") == true)
        var openedList = false
        view.onOpenList = { openedList = true }
        #expect(view.accessibilityPerformShowMenu())
        #expect(openedList)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 60, height: 20))
        view.addSubview(field)
        view.nextKeyView = field
        window.sendEvent(try key(48, window: window))
        #expect(window.firstResponder !== view)
    }

    @Test func publicSwiftUIHostHandlesStreamingSelectionResetAndNarrowResizing() async throws {
        _ = NSApplication.shared
        let backend = MinimapTestBackend(messages: minimapMessages(10_000))
        let store = ChatStore(backend: backend)
        let navigation = TranscriptNavigation()
        let observation = Task { await store.start() }
        defer { observation.cancel() }
        try await settle { store.messages.count == 10_000 }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 700), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ConversationMinimap(store: store, navigation: navigation))
        window.contentView = host
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        let input = try await surface(in: host)
        #expect(input.layout.nodes.count == 10_000)
        navigation.viewport = TranscriptViewport(
            firstVisibleMessageID: store.messages[6500].id, lastVisibleMessageID: store.messages[6510].id)
        try await settle { input.accessibilityValue() as? String != nil }
        input.keyDown(with: try key(125, window: window))
        #expect(navigation.scrollRequest?.messageID == store.messages[6501].id)
        try capture(host, name: "history-10000")
        for width in [64.0, 100, 240] {
            host.setFrameSize(CGSize(width: width, height: 700))
            host.layoutSubtreeIfNeeded()
            #expect(input.frame.width > 0)
            #expect(input.frame.width <= width)
            try capture(host, name: "width-\(Int(width))")
        }
        let stableID = try #require(store.messages.last?.id)
        await backend.streamLastMessage()
        try await settle { store.messages.last?.status == .streaming }
        try await settle { input.layout.nodes.last?.status == .streaming }
        #expect(input.layout.nodes.last?.id == stableID)
        input.keyDown(with: try key(119, window: window))
        #expect(navigation.scrollRequest?.messageID == stableID)

        // The opt-in list is a real native sheet. Exact-number entry can reach a message
        // too small to target with a pointer, even in a ten-thousand-message history.
        #expect(input.accessibilityPerformShowMenu())
        try await settle { !window.sheets.isEmpty }
        let sheet = try #require(window.sheets.first)
        let sheetContent = try #require(sheet.contentView)
        try await settle { Self.findTextField(in: sheetContent) != nil }
        let numberField = try #require(Self.findTextField(in: sheetContent))
        sheet.makeFirstResponder(numberField)
        numberField.selectText(nil)
        let editor = try #require(numberField.currentEditor())
        editor.insertText("10000")
        pumpRunLoop()
        try capture(sheetContent, name: "all-messages")
        let beforeListJump = navigation.scrollRequest?.id
        sheet.sendEvent(try key(36, window: sheet))
        try await settle { navigation.scrollRequest?.id != beforeListJump }
        #expect(navigation.scrollRequest?.messageID == stableID)
        try await settle { window.sheets.isEmpty }

        await store.selectConversation(ConversationID("map:b"))
        try await settle { store.selectedConversationID == ConversationID("map:b") }
        try await settle { navigation.scrollRequest == nil && navigation.viewport == TranscriptViewport() }
        let replacement = try await surface(in: host)
        try await settle { replacement.layout.nodes.count == 1 }
        try capture(host, name: "single-message")
        #expect(replacement !== input)
        #expect(replacement.activeID == nil)
        replacement.keyDown(with: try key(36, window: window))
        #expect(navigation.scrollRequest?.messageID == store.messages.first?.id)
        await store.selectConversation(nil)
        try await settle { store.messages.isEmpty }
        try await settle { Self.findSurface(in: host) == nil }
        #expect(navigation.scrollRequest == nil)
        try capture(host, name: "no-selection")
    }

    private func key(_ code: UInt16, window: NSWindow) throws -> NSEvent {
        let characters = code == 36 ? "\r" : (code == 48 ? "\t" : "")
        return try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                keyCode: code))
    }

    private func settle(_ predicate: @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation)
        async throws
    {
        for _ in 0..<200 {
            if predicate() { return }
            // Service SwiftUI/AppKit layout and Observation callbacks, not just Swift tasks.
            pumpRunLoop()
            try await Task.sleep(for: .milliseconds(5))
        }
        _ = try #require(predicate(), sourceLocation: sourceLocation)
    }

    private func pumpRunLoop() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005)) }

    /// Opt-in native render artifacts; ordinary tests leave the filesystem untouched.
    private func capture(_ host: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["MINIMAP_CAPTURE_DIR"] else { return }
        pumpRunLoop()
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private func surface(in host: NSView) async throws -> MinimapInputView {
        try await settle {
            host.layoutSubtreeIfNeeded()
            return Self.findSurface(in: host) != nil
        }
        return try #require(Self.findSurface(in: host))
    }

    private static func findSurface(in view: NSView) -> MinimapInputView? {
        if let surface = view as? MinimapInputView { return surface }
        return view.subviews.lazy.compactMap { findSurface(in: $0) }.first
    }

    private static func findTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap { findTextField(in: $0) }.first
    }

}

private actor MinimapTestBackend: ChatBackend {
    private var current: ConversationSnapshot
    private var selected: ConversationID?
    private var continuation: AsyncThrowingStream<ChatEvent, any Error>.Continuation?

    init(messages: [ChatMessage]) {
        current = ConversationSnapshot(
            summary: ConversationSummary(id: ConversationID("map:a"), title: "Map test"), messages: messages)
        selected = current.id
    }

    func snapshot() async throws -> ChatSnapshot { snapshotValue() }
    private func snapshotValue() -> ChatSnapshot {
        ChatSnapshot(
            connection: .demo, conversations: [current.summary], selectedConversationID: selected,
            loadedConversations: [current])
    }
    func events() async -> AsyncThrowingStream<ChatEvent, any Error> {
        let pair = AsyncThrowingStream<ChatEvent, any Error>.makeStream()
        continuation = pair.continuation
        pair.continuation.yield(.snapshot(snapshotValue()))
        return pair.stream
    }
    func selectConversation(_ id: ConversationID?) async throws {
        selected = id
        if let id {
            current = ConversationSnapshot(
                summary: ConversationSummary(id: id, title: "Other"), messages: minimapMessages(1, conversation: id))
        }
        continuation?.yield(.snapshot(snapshotValue()))
    }
    func streamLastMessage() {
        current.messages[current.messages.count - 1].content += String(repeating: "streaming ", count: 1000)
        current.messages[current.messages.count - 1].status = .streaming
        continuation?.yield(.conversationUpdated(current))
    }
    func createConversation(title: String?) async throws -> ConversationID { throw ChatBackendError.demoReadOnly }
    func send(_ request: SendRequest) async throws { throw ChatBackendError.demoReadOnly }
    func stop(conversationID: ConversationID) async throws { throw ChatBackendError.demoReadOnly }
}
