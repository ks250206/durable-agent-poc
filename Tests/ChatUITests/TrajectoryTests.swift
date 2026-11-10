import AppKit
import AppLocalization
import ChatCore
@testable import ChatUI
import SwiftUI
import Testing

private let trajectoryID = ConversationID("trajectory:test")
private func trajectoryMessages(_ count: Int, conversation: ConversationID = trajectoryID) -> [ChatMessage] {
    (0..<count).map { index in
        ChatMessage(id: MessageID("\(conversation):entry:\(index * 7):0"), conversationID: conversation,
                    role: MessageRole.allCases[index % 4],
                    content: index == 2 ? "```swift\nlet text = \"原文 {count} %n\"\n```\n  /tmp/read-only\n" : "Message \(index) 日本語 中文 한국어\nOriginal plain **text**",
                    createdAt: Date(timeIntervalSince1970: Double(index)),
                    status: [.complete, .streaming, .stopped, .failed][index % 4])
    }
}

@Test func trajectoryProjectionRetainsEveryIDInZeroOneAndTenThousandHistories() throws {
    for count in [0, 1, 10_000] {
        let messages = trajectoryMessages(count)
        let layout = MinimapLayout(messages: messages)
        let plot = CGRect(x: 140, y: 4, width: 230, height: 78)
        #expect(layout.nodes.count == count)
        for index in messages.indices {
            let node = layout.nodes[index]
            let point = CGPoint(x: plot.minX + (node.start + node.end) / 2 * plot.width,
                                y: plot.minY + CGFloat(MinimapLayout.trajectoryLane(node.role)) * 26 + 12)
            #expect(layout.trajectoryIndex(at: point, plot: plot) == index)
            let rect = layout.trajectoryRect(for: index, plot: plot)
            #expect(rect.minX >= plot.minX && rect.maxX <= plot.maxX)
            #expect(rect.minY >= plot.minY && rect.maxY <= plot.maxY)
            #expect(rect.width >= 1)
        }
        if let first = messages.first, let last = messages.last {
            let viewport = TranscriptViewport(firstVisibleMessageID: first.id, lastVisibleMessageID: last.id)
            #expect(layout.trajectoryViewportRect(viewport, plot: plot) == plot)
        }
        #expect(layout.trajectoryViewportRect(TranscriptViewport(firstVisibleMessageID: MessageID("missing")), plot: plot) == nil)
        #expect(layout.trajectoryIndex(at: CGPoint(x: -1, y: 2), plot: plot) == nil)
    }
    let oneUser = ChatMessage(id: MessageID("only-user"), conversationID: trajectoryID, role: .user, content: "")
    let layout = MinimapLayout(messages: [oneUser])
    #expect(layout.trajectoryIndex(at: CGPoint(x: 20, y: 40), plot: CGRect(x: 0, y: 0, width: 100, height: 78)) == nil)
}

@Test func trajectorySearchUsesEntireOriginalContentAndActualRolesInSourceOrder() {
    var messages = trajectoryMessages(10_000)
    messages[9999].content = String(repeating: "long ", count: 5000) + "NEEDLE 原文"
    let locale = Locale(identifier: "en")
    #expect(TrajectoryIndex.matching(messages, query: "needle 原文", role: nil, locale: locale) == [9999])
    #expect(TrajectoryIndex.matching(messages, query: "needle", role: .user, locale: locale).isEmpty)
    #expect(TrajectoryIndex.matching(messages, query: "no match", role: nil, locale: locale).isEmpty)
    #expect(TrajectoryIndex.matching(messages, query: "", role: nil, locale: locale) == Array(messages.indices))
    #expect(TrajectoryIndex.matching(messages, query: "", role: .tool, locale: locale).allSatisfy { messages[$0].role == .tool })
    messages.reverse()
    #expect(TrajectoryIndex.matching(messages, query: "NEEDLE", role: nil, locale: locale) == [0])
}

private actor TrajectoryBackend: ChatBackend {
    var current = ConversationSnapshot(summary: ConversationSummary(id: trajectoryID, title: "Trajectory fixture"))
    var selected: ConversationID? = trajectoryID
    var continuation: AsyncThrowingStream<ChatEvent, any Error>.Continuation?
    init(_ messages: [ChatMessage]) { current.messages = messages }
    var value: ChatSnapshot { ChatSnapshot(connection: .demo, conversations: [current.summary], selectedConversationID: selected, loadedConversations: [current]) }
    func snapshot() async throws -> ChatSnapshot { value }
    func events() async -> AsyncThrowingStream<ChatEvent, any Error> {
        let pair = AsyncThrowingStream<ChatEvent, any Error>.makeStream()
        continuation = pair.continuation
        continuation?.yield(.snapshot(value))
        return pair.stream
    }
    func selectConversation(_ id: ConversationID?) async throws {
        selected = id
        if let id { current = ConversationSnapshot(summary: ConversationSummary(id: id, title: "Other"), messages: trajectoryMessages(1, conversation: id)) }
        continuation?.yield(.snapshot(value))
    }
    func grow() {
        current.messages[current.messages.count - 1].content += String(repeating: " streamed", count: 100)
        current.messages[current.messages.count - 1].status = .streaming
        continuation?.yield(.conversationUpdated(current))
    }
    func late(_ old: ConversationSnapshot) { continuation?.yield(.conversationUpdated(old)) }
    func createConversation(title: String?) async throws -> ConversationID { throw ChatBackendError.demoReadOnly }
    func send(_ request: SendRequest) async throws { throw ChatBackendError.demoReadOnly }
    func stop(conversationID: ConversationID) async throws {}
}

@MainActor private func trajectoryPump() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005)) }
@MainActor private func trajectorySettle(_ predicate: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(predicate(), sourceLocation: sourceLocation)
}
@MainActor private func trajectoryFind<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
    (view as? T).map { [$0] } ?? view.subviews.flatMap { trajectoryFind($0, type) }
}
@MainActor private func trajectoryKey(_ code: UInt16, _ window: NSWindow, command: Bool = false) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: command ? [.command] : [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: command ? "c" : "", charactersIgnoringModifiers: command ? "c" : "",
        isARepeat: false, keyCode: code))
}
@MainActor private func trajectorySendKey(_ code: UInt16, _ window: NSWindow, command: Bool = false) throws {
    let down = try trajectoryKey(code, window, command: command)
    window.sendEvent(down)
    let up = try #require(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: down.modifierFlags,
        timestamp: down.timestamp + 0.01, windowNumber: window.windowNumber, context: nil,
        characters: down.characters ?? "", charactersIgnoringModifiers: down.charactersIgnoringModifiers ?? "", isARepeat: false, keyCode: code))
    window.sendEvent(up)
}
@MainActor private func trajectoryClick(_ view: NSView, _ point: CGPoint) throws {
    let window = try #require(view.window)
    let screenPoint = window.convertPoint(toScreen: view.convert(point, to: nil))
    #expect(try #require(window.screen).visibleFrame.contains(screenPoint))
    let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(point, to: nil), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    window.sendEvent(event)
    let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: event.locationInWindow, modifierFlags: [],
        timestamp: event.timestamp + 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
    window.sendEvent(up)
}
/// Permit wide render hosts on 1024 px CI displays. Trailing interaction stays inside visibleFrame.
@MainActor private final class TrajectoryRenderWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
@MainActor private func trajectoryWindow(_ view: NSView, width: CGFloat = 400, placementFrame: CGRect? = nil) throws -> NSWindow {
    _ = NSApplication.shared
    let screen = try #require(NSScreen.main)
    let visible = placementFrame ?? screen.visibleFrame
    let window = TrajectoryRenderWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.setFrameOrigin(CGPoint(x: min(visible.minX + 12, visible.maxX - window.frame.width - 12), y: visible.minY + 12))
    window.makeKeyAndOrderFront(nil)
    view.layoutSubtreeIfNeeded()
    trajectoryPump()
    return window
}
@MainActor private func trajectoryCapture(_ view: NSView, _ name: String) throws {
    guard let path = ProcessInfo.processInfo.environment["CHAT_UI_ARTIFACTS_DIR"] else { return }
    trajectoryPump()
    view.layoutSubtreeIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
    let directory = URL(fileURLWithPath: path).appendingPathComponent("issue-37")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
}

extension NativeUITests {
@Suite @MainActor struct TrajectoryNativeTests {
    @Test func compatibilityMapFitsExistingNarrowSlotsAndKeepsExactPromptJumps() async throws {
        let messages = trajectoryMessages(20)
        let store = ChatStore(backend: TrajectoryBackend(messages))
        let observation = Task { await store.start() }
        defer { observation.cancel() }
        try await trajectorySettle { store.messages.count == messages.count }
        for width: CGFloat in [144, 240] {
            let navigation = TranscriptNavigation()
            let host = NSHostingView(rootView: ConversationMinimap(store: store, navigation: navigation))
            host.sizingOptions = []
            let window = try trajectoryWindow(host, width: width)
            window.setContentSize(NSSize(width: width, height: 420))
            defer { window.close() }
            try await trajectorySettle { trajectoryFind(host, PromptRailInputView.self).count == 1 }
            #expect(trajectoryFind(host, TrajectoryView.self).isEmpty)
            let input = try #require(trajectoryFind(host, PromptRailInputView.self).first)
            try await trajectorySettle { input.frame.height <= 420 }
            #expect(input.frame.width == 40 && input.frame.height <= 420)
            let prompts = messages.filter { $0.role == .user }
            for prompt in prompts {
                #expect(input.accessibilityPerformIncrement())
                #expect(navigation.scrollRequest?.messageID == prompt.id)
            }
        }
    }

    @Test func realClickKeyboardHoverAXAndExactNumberReachFullHistoryWithoutChangingViewport() async throws {
        await Task.yield()
        let view = TrajectoryView(frame: CGRect(x: 0, y: 0, width: 400, height: 760))
        let window = try trajectoryWindow(view)
        view.pasteboard = NSPasteboard.withUniqueName()
        defer { window.close() }
        let messages = trajectoryMessages(10_000)
        let navigation = TranscriptNavigation()
        let viewport = TranscriptViewport(firstVisibleMessageID: messages[400].id, lastVisibleMessageID: messages[420].id, centerVisibleMessageID: messages[410].id)
        navigation.viewport = viewport
        view.configure(messages: messages, conversationID: trajectoryID, loaded: true, navigation: navigation,
                       localizer: Localizer(language: .english), resolved: ResolvedAppearance(colorScheme: .dark))
        view.layoutSubtreeIfNeeded()
        let overview = view.overview
        let index = 137
        let node = overview.layout.nodes[index]
        let point = CGPoint(x: overview.plot.minX + (node.start + node.end) / 2 * overview.plot.width,
                            y: overview.plot.minY + CGFloat(MinimapLayout.trajectoryLane(node.role)) * 26 + 12)
        try trajectoryClick(overview, point)
        #expect(navigation.scrollRequest?.messageID == messages[index].id)
        #expect(view.selectedID == messages[index].id)
        #expect(window.firstResponder === overview)
        try trajectorySendKey(124, window)
        #expect(navigation.scrollRequest?.messageID == messages[index + 1].id)
        try trajectorySendKey(119, window)
        #expect(navigation.scrollRequest?.messageID == messages.last?.id)
        let request = navigation.scrollRequest?.id
        try trajectorySendKey(36, window)
        #expect(navigation.scrollRequest?.id != request)
        #expect(overview.accessibilityPerformDecrement())
        #expect(navigation.scrollRequest?.messageID == messages[9998].id)
        try trajectorySendKey(115, window)
        overview.onTarget = { _ in } // AX reaches every dense node without materializing every log cell.
        for index in 1..<messages.count {
            // Simulate separate user events without retaining ten thousand events' Foundation
            // formatting/AX autoreleases inside one synchronous test invocation.
            autoreleasepool {
                #expect(overview.accessibilityPerformIncrement())
                #expect(navigation.scrollRequest?.messageID == messages[index].id)
            }
        }
        #expect((overview.accessibilityValue() as? String)?.contains("10,000") == true)
        #expect(view.table.numberOfRows == 10_000)
        #expect(trajectoryFind(view.table, NSTableCellView.self).count < 100)
        view.numberField.stringValue = "9,000"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: view.numberField))
        view.goButton.performClick(nil)
        #expect(navigation.scrollRequest?.messageID == messages[8999].id)
        #expect(view.selectedID == messages[8999].id)
        #expect(navigation.viewport == viewport)
        let hover = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: overview.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 0, pressure: 0))
        overview.mouseMoved(with: hover)
        #expect(overview.hoverID == messages[137].id)
        overview.mouseExited(with: hover)
        #expect(overview.hoverID == nil)
        window.makeFirstResponder(overview)
        overview.keyDown(with: try trajectoryKey(48, window))
        #expect(window.firstResponder !== overview)
        try trajectoryCapture(view, "history-10000-dark-400")
    }

    @Test func actualSearchFilterSelectionCopyAndNoResultsAreNativeAndVerbatim() async throws {
        await Task.yield()
        let view = TrajectoryView(frame: CGRect(x: 0, y: 0, width: 400, height: 760))
        let window = try trajectoryWindow(view)
        view.pasteboard = NSPasteboard.withUniqueName()
        defer { window.close() }
        let messages = trajectoryMessages(20)
        let navigation = TranscriptNavigation()
        view.configure(messages: messages, conversationID: trajectoryID, loaded: true, navigation: navigation,
                       localizer: Localizer(language: .japanese), resolved: ResolvedAppearance(colorScheme: .light))
        #expect(window.makeFirstResponder(view.search))
        view.search.selectText(nil)
        let editor = try #require(view.search.currentEditor() as? NSTextView)
        editor.insertText("原文", replacementRange: editor.selectedRange())
        trajectoryPump()
        #expect(view.filtered == [2])
        view.layoutSubtreeIfNeeded()
        view.table.layoutSubtreeIfNeeded()
        let tablePoint = CGPoint(x: 20, y: 30)
        try trajectoryCapture(view, "search-before-click-ja-400")
        try trajectoryClick(view.table, tablePoint)
        #expect(view.selectedID == messages[2].id)
        #expect(view.detail.string == messages[2].content)
        view.copyButton.performClick(nil)
        #expect(view.pasteboard.string(forType: .string) == messages[2].content)
        view.jumpButton.performClick(nil)
        #expect(navigation.scrollRequest?.messageID == messages[2].id)
        #expect(window.makeFirstResponder(view.table))
        try trajectorySendKey(8, window, command: true)
        #expect(view.pasteboard.string(forType: .string) == messages[2].content)
        try trajectorySendKey(36, window)
        #expect(navigation.scrollRequest?.messageID == messages[2].id)
        // Use the native popup action, preserving its real source-role mapping.
        view.roleFilter.selectItem(at: 2) // User (system, user, assistant, tool source enum order)
        view.roleFilter.sendAction(view.roleFilter.action, to: view.roleFilter.target)
        #expect(view.filtered.isEmpty)
        #expect(view.emptyLabel.stringValue == Localizer(language: .japanese).chat("No matching messages"))
        #expect(!view.emptyLabel.isHidden)
        // A hidden selected row remains inspectable, with exact copy/jump actions.
        #expect(view.selectedID == messages[2].id && view.detail.string == messages[2].content)
        try trajectoryCapture(view, "search-no-result-ja-400")
        view.search.stringValue = ""
        #expect(view.search.sendAction(view.search.action, to: view.search.target))
        #expect(view.filtered.allSatisfy { messages[$0].role == .user })
    }

    @Test func publicHostStreamingAndLateEventsPreserveLocalReaderSearchCursorAndSharedState() async throws {
        let backend = TrajectoryBackend(trajectoryMessages(10_000))
        let store = ChatStore(backend: backend)
        let observation = Task { await store.start() }
        defer { observation.cancel() }
        try await trajectorySettle { store.messages.count == 10_000 }
        let navigation = TranscriptNavigation()
        let host = NSHostingView(rootView: ConversationTrajectory(store: store, navigation: navigation))
        host.sizingOptions = []
        let window = try trajectoryWindow(host)
        defer { window.close() }
        try await trajectorySettle { !trajectoryFind(host, TrajectoryView.self).isEmpty }
        let view = try #require(trajectoryFind(host, TrajectoryView.self).first)
        view.numberField.stringValue = "10000"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: view.numberField))
        // This is state setup for streaming/identity coverage. Dispatch the real action
        // without NSButton's blocking press animation in the async-main test host.
        // The separate native pointer/key test still exercises the interactive Go control.
        #expect(view.goButton.sendAction(view.goButton.action, to: view.goButton.target))
        view.search.stringValue = "Message"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: view.search))
        view.table.scrollRowToVisible(7000)
        trajectoryPump()
        let scroll = view.logScroll.contentView.bounds.origin
        view.detail.setSelectedRange(NSRange(location: 3, length: 5))
        window.makeFirstResponder(view.detail)
        let detail = view.detail
        let search = view.search
        let request = navigation.scrollRequest
        let cursor = view.overview.activeID
        navigation.viewport = TranscriptViewport(firstVisibleMessageID: store.messages[600].id, lastVisibleMessageID: store.messages[620].id)
        let viewport = navigation.viewport
        let model = store.modelSelection
        store.draft = "Unsent 原文"
        await backend.grow()
        try await trajectorySettle { view.detail.string.contains("streamed") }
        #expect(view.detail === detail && view.search === search)
        #expect(view.detail.selectedRange() == NSRange(location: 3, length: 5))
        #expect(view.search.stringValue == "Message")
        #expect(view.logScroll.contentView.bounds.origin == scroll)
        #expect(view.overview.activeID == cursor)
        #expect(window.firstResponder === detail)
        #expect(navigation.scrollRequest == request && navigation.viewport == viewport)
        #expect(store.draft == "Unsent 原文" && store.modelSelection == model)
        let old = try #require(store.selectedConversation)
        await store.selectConversation(ConversationID("other"))
        try await trajectorySettle { view.conversationID == ConversationID("other") }
        #expect(view.selectedID == nil && view.search.stringValue.isEmpty && view.numberField.stringValue.isEmpty)
        #expect(view.overview.activeID == nil && view.overview.hoverID == nil)
        #expect(navigation.scrollRequest == request && navigation.viewport == viewport)
        await backend.late(old)
        trajectoryPump()
        #expect(view.messages.count == 1 && view.messages[0].conversationID == ConversationID("other"))
        #expect(navigation.scrollRequest == request && navigation.viewport == viewport)
        await store.selectConversation(nil)
        try await trajectorySettle { view.messages.isEmpty }
        #expect(!view.jumpButton.isEnabled && !view.copyButton.isEnabled)
    }

    @Test func allLanguagesAppearancesAndWidthsRenderOwnDataAndKeepNativeEditors() async throws {
        await Task.yield()
        let messages = trajectoryMessages(18)
        for language in AppLanguage.allCases {
            for scheme in [ColorScheme.light, .dark] {
                for width in [CGFloat(400), 1200] {
                    let view = TrajectoryView(frame: CGRect(x: 0, y: 0, width: width, height: 760))
                    let visible = try #require(NSScreen.main).visibleFrame
                    let placement = CGRect(x: visible.minX, y: visible.minY, width: min(1024, visible.width), height: visible.height)
                    let window = try trajectoryWindow(view, width: width, placementFrame: placement)
                    defer { window.close() }
                    let navigation = TranscriptNavigation()
                    navigation.viewport = TranscriptViewport(firstVisibleMessageID: messages[3].id, lastVisibleMessageID: messages[6].id)
                    let localizer = Localizer(language: language)
                    view.configure(messages: messages, conversationID: trajectoryID, loaded: true, navigation: navigation, localizer: localizer,
                                   resolved: ResolvedAppearance(colorScheme: scheme, reduceMotion: true))
                    view.table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
                    view.layoutSubtreeIfNeeded()
                    #expect(view.title.stringValue == localizer.chat("Trajectory"))
                    #expect(view.overview.accessibilityLabel() == localizer.chat("Full-history role overview"))
                    #expect(view.detail.string == messages[2].content)
                    #expect(view.search.frame.maxX < view.roleFilter.frame.minX)
                    #expect(view.copyButton.frame.maxX <= width)
                    #expect(view.detailScroll.frame.maxY <= view.jumpButton.frame.minY)
                    #expect(view.jumpButton.frame.maxY <= view.bounds.maxY)
                    // CI's 1024 px desktop still exposes the wide host's trailing controls.
                    let trailing = window.convertPoint(toScreen: view.convert(CGPoint(x: view.copyButton.frame.maxX - 4, y: view.copyButton.frame.midY), to: nil))
                    #expect(try #require(window.screen).visibleFrame.contains(trailing))
                    let leading = window.convertPoint(toScreen: view.convert(CGPoint(x: view.search.frame.minX + 4, y: view.search.frame.midY), to: nil))
                    #expect(try #require(window.screen).visibleFrame.contains(leading))
                    #expect(placement.contains(leading) && placement.contains(trailing))
                    try trajectoryCapture(view, "trajectory-\(language.resourceIdentifier)-\(Int(width))-\(scheme)")
                }
            }
        }
    }

    @Test func presentationUpdatesPreserveNativeFocusSelectionAndContrast() async throws {
        await Task.yield()
        let view = TrajectoryView(frame: CGRect(x: 0, y: 0, width: 400, height: 760))
        let window = try trajectoryWindow(view)
        view.pasteboard = NSPasteboard.withUniqueName()
        defer { window.close() }
        let navigation = TranscriptNavigation()
        let messages = trajectoryMessages(30)
        view.configure(messages: messages, conversationID: trajectoryID, loaded: true, navigation: navigation,
                       localizer: Localizer(language: .english), resolved: ResolvedAppearance(colorScheme: .light))
        view.table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        view.detail.setSelectedRange(NSRange(location: 3, length: 5))
        #expect(window.makeFirstResponder(view.search))
        view.search.selectText(nil)
        let editor = try #require(view.search.currentEditor() as? NSTextView)
        editor.insertText("原文", replacementRange: editor.selectedRange())
        editor.setSelectedRange(NSRange(location: 1, length: 1))
        let query = editor.string
        let range = editor.selectedRange()
        let request = navigation.scrollRequest
        for language in AppLanguage.allCases {
            for scheme in [ColorScheme.light, .dark] {
                for contrast in [ColorSchemeContrast.standard, .increased] {
                    let resolved = ResolvedAppearance(colorScheme: scheme, contrast: contrast, reduceMotion: true)
                    view.configure(messages: messages, conversationID: trajectoryID, loaded: true, navigation: navigation,
                                   localizer: Localizer(language: language), resolved: resolved)
                    #expect(view.search.currentEditor() === editor && window.firstResponder === editor)
                    #expect(editor.string == query && editor.selectedRange() == range)
                    #expect(view.detail.selectedRange() == NSRange(location: 3, length: 5))
                    #expect(view.selectedID == messages[2].id)
                    #expect(navigation.scrollRequest == request)
                    #expect(resolved.feedbackAnimation == nil)
                    func luminance(_ color: NSColor) throws -> Double {
                        let rgb = try #require(color.usingColorSpace(.sRGB))
                        func linear(_ value: CGFloat) -> Double {
                            let x = Double(value)
                            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
                        }
                        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
                    }
                    let background = try luminance(resolved.palette.sidebar.nsColor)
                    for lane in 0..<3 {
                        let foreground = try luminance(view.overview.roleColor(lane))
                        #expect((max(background, foreground) + 0.05) / (min(background, foreground) + 0.05) >= 3)
                    }
                }
            }
        }
    }

    @Test func emptySingletonMissingRoleAndMissingIDsAreExplicitAndDoNotInventEvents() async throws {
        await Task.yield()
        let view = TrajectoryView(frame: CGRect(x: 0, y: 0, width: 400, height: 760))
        let window = try trajectoryWindow(view)
        view.pasteboard = NSPasteboard.withUniqueName()
        defer { window.close() }
        let navigation = TranscriptNavigation()
        let localizer = Localizer(language: .english)
        for (id, loaded, text) in [(nil as ConversationID?, false, "Select a conversation"), (trajectoryID, false, "Loading messages…"), (trajectoryID, true, "No messages yet")] {
            view.configure(messages: [], conversationID: id, loaded: loaded, navigation: navigation, localizer: localizer, resolved: ResolvedAppearance(colorScheme: .light))
            // A loaded-state change with the same empty data must update its empty presentation.
            #expect(view.emptyLabel.stringValue == localizer.chat(text))
            #expect(!view.jumpButton.isEnabled && !view.copyButton.isEnabled)
            #expect(!view.overview.accessibilityPerformPress())
        }
        let only = ChatMessage(id: MessageID("only"), conversationID: trajectoryID, role: .user, content: "", status: .failed)
        view.configure(messages: [only], conversationID: trajectoryID, loaded: true, navigation: navigation, localizer: localizer, resolved: ResolvedAppearance(colorScheme: .dark))
        #expect(view.overview.accessibilityPerformPress())
        #expect(navigation.scrollRequest?.messageID == only.id)
        #expect(view.detail.string.isEmpty)
        view.copyButton.performClick(nil)
        #expect(view.pasteboard.string(forType: .string) == "")
        view.roleFilter.selectItem(at: 4)
        view.roleFilter.sendAction(view.roleFilter.action, to: view.roleFilter.target)
        #expect(view.emptyLabel.stringValue == localizer.chat("No messages for this role"))
        try trajectoryCapture(view, "missing-role-400")
        view.configure(messages: [], conversationID: trajectoryID, loaded: true, navigation: navigation, localizer: localizer, resolved: ResolvedAppearance(colorScheme: .dark))
        #expect(view.selectedID == nil && view.overview.activeID == nil)
        #expect(!view.jumpButton.isEnabled && !view.copyButton.isEnabled)
    }
}
}
