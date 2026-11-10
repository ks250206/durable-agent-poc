import AppKit
import AppLocalization
import ChatCore
@testable import ChatUI
import SwiftUI
import Testing

private let railConversation = ConversationID("rail:test")
private func railMessages(_ inputs: Int, conversation: ConversationID = railConversation) -> [ChatMessage] {
    (0..<inputs).flatMap { index in
        [ChatMessage(id: MessageID("\(conversation):user:\(index)"), conversationID: conversation, role: .user,
                     content: "Input \(index)\n  **plain** 日本語 中文 한국어 {count} %n\n"),
         ChatMessage(id: MessageID("\(conversation):assistant:\(index)"), conversationID: conversation, role: .assistant,
                     content: "Assistant reply \(index)")]
    }
}

@Test func promptRailRetainsZeroOneAndTenThousandInputsAndEveryPrecedingTurn() {
    for count in [0, 1, 10_000] {
        let messages = railMessages(count)
        let model = PromptRailModel(messages: messages)
        #expect(model.inputs.count == count)
        for index in 0..<count {
            let input = messages[index * 2]
            #expect(model.index(for: input.id) == index)
            for row in [input, messages[index * 2 + 1]] {
                #expect(model.currentInput(in: TranscriptViewport(centerVisibleMessageID: row.id)) == input.id)
            }
            #expect(model.inputs[index].content == input.content)
        }
        #expect(model.currentInput(in: TranscriptViewport(centerVisibleMessageID: MessageID("missing"))) == nil)
        #expect(model.currentInput(in: TranscriptViewport(firstVisibleMessageID: messages.first?.id,
                                                          lastVisibleMessageID: messages.last?.id)) == nil)
    }
    let preamble = ChatMessage(id: MessageID("preamble"), conversationID: railConversation, role: .system, content: "System")
    #expect(PromptRailModel(messages: [preamble] + railMessages(1))
        .currentInput(in: TranscriptViewport(centerVisibleMessageID: preamble.id)) == nil)
}

@Test func promptRailCenterUsesActualIntervalsIncludingHugeAssistantAndSpacing() {
    let messages = railMessages(3)
    let ids = messages.map(\.id)
    let frames = TranscriptMeasurements(frames: [
        ids[0]: CGRect(x: 0, y: -100, width: 300, height: 80),
        ids[1]: CGRect(x: 0, y: -5000, width: 300, height: 10_000),
        ids[2]: CGRect(x: 0, y: 5001, width: 300, height: 50),
    ])
    let viewport = frames.viewport(orderedIDs: ids, height: 300)
    #expect(viewport.centerVisibleMessageID == ids[1])
    #expect(PromptRailModel(messages: messages).currentInput(in: viewport) == ids[0])
    let gap = TranscriptMeasurements(frames: [ids[0]: CGRect(x: 0, y: 0, width: 100, height: 40),
                                              ids[1]: CGRect(x: 0, y: 60, width: 100, height: 40)])
    #expect(gap.viewport(orderedIDs: ids, height: 100).centerVisibleMessageID == ids[0])
    let nearLater = TranscriptMeasurements(frames: [ids[0]: CGRect(x: 0, y: 0, width: 100, height: 30),
                                                    ids[1]: CGRect(x: 0, y: 55, width: 100, height: 45)])
    #expect(nearLater.viewport(orderedIDs: ids, height: 100).centerVisibleMessageID == ids[1])
}

@Test func promptRailGeometryWindowsExplicitlyAndHitCellsNeverDependOnBarWidth() {
    for width in [CGFloat(1), 16, 40] {
        for count in [0, 1, 10_000] {
            var visited = Set<Int>()
            var start = 0
            repeat {
                let geometry = PromptRailGeometry(size: CGSize(width: width, height: 400), count: count, proposedStart: start)
                for index in geometry.visible {
                    let cell = geometry.cell(for: index)
                    #expect(geometry.index(at: CGPoint(x: width / 2, y: cell.midY)) == index)
                    for state in [(false, false), (true, false), (false, true), (true, true)] {
                        #expect(geometry.barWidth(current: state.0, hovered: state.1) <= max(0, width - 12))
                        #expect(geometry.cell(for: index) == cell)
                    }
                    visited.insert(index)
                }
                if !geometry.hasLater { break }
                start = geometry.visible.upperBound
            } while true
            #expect(visited.count == count)
        }
    }
    let geometry = PromptRailGeometry(size: CGSize(width: 40, height: 400), count: 10_000)
    #expect(geometry.isWindowed && geometry.hasLater)
    #expect(geometry.barWidth(current: false, hovered: false) == 10)
    #expect(geometry.barWidth(current: true, hovered: false) == 22)
    #expect(geometry.barWidth(current: true, hovered: true) == 28)
    #expect(geometry.index(at: CGPoint(x: 40, y: 30)) == nil)
    #expect(geometry.index(at: CGPoint(x: 20, y: 0)) == nil)
    #expect(PromptRailGeometry(size: .zero, count: 10_000).visible.isEmpty)
}

private actor RailTestBackend: ChatBackend {
    var conversation: ConversationSnapshot
    var selected: ConversationID? = railConversation
    var continuation: AsyncThrowingStream<ChatEvent, any Error>.Continuation?
    init(messages: [ChatMessage]) {
        conversation = ConversationSnapshot(summary: ConversationSummary(id: railConversation, title: "Rail host test"), messages: messages)
    }
    func snapshot() async throws -> ChatSnapshot { value }
    var value: ChatSnapshot { ChatSnapshot(connection: .demo, conversations: [conversation.summary],
                                           selectedConversationID: selected, loadedConversations: [conversation]) }
    func events() async -> AsyncThrowingStream<ChatEvent, any Error> {
        let pair = AsyncThrowingStream<ChatEvent, any Error>.makeStream()
        continuation = pair.continuation
        continuation?.yield(.snapshot(value))
        return pair.stream
    }
    func selectConversation(_ id: ConversationID?) async throws {
        selected = id
        if let id {
            conversation = ConversationSnapshot(summary: ConversationSummary(id: id, title: "Other"),
                                                messages: railMessages(1, conversation: id))
        }
        continuation?.yield(.snapshot(value))
    }
    func grow() {
        guard !conversation.messages.isEmpty else { return }
        conversation.messages[conversation.messages.count - 1].content += String(repeating: "More streamed text. ", count: 200)
        conversation.messages[conversation.messages.count - 1].status = .streaming
        continuation?.yield(.conversationUpdated(conversation))
    }
    func createConversation(title: String?) async throws -> ConversationID { throw ChatBackendError.demoReadOnly }
    func send(_ request: SendRequest) async throws { throw ChatBackendError.demoReadOnly }
    func stop(conversationID: ConversationID) async throws {}
}

@MainActor private func railFind<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
    (root as? T).map { [$0] } ?? root.subviews.flatMap { railFind($0, type) }
}
@MainActor private func railPump() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005)) }
@MainActor private func railSettle(_ predicate: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now + .seconds(6)
    while !predicate(), ContinuousClock.now < deadline {
        railPump()
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(predicate(), sourceLocation: sourceLocation)
}
@MainActor private func railKey(_ code: UInt16, _ window: NSWindow) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: code == 36 ? "\r" : "",
        charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
}
@MainActor private func railMouse(_ type: NSEvent.EventType, _ point: CGPoint, _ view: NSView) throws -> NSEvent {
    if type == .mouseEntered || type == .mouseExited {
        return try #require(NSEvent.enterExitEvent(with: type, location: view.convert(point, to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil,
            eventNumber: 1, trackingNumber: 1, userData: nil))
    }
    return try #require(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
        windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
}
@MainActor private func railCapture(_ view: NSView, _ name: String) throws {
    guard let path = ProcessInfo.processInfo.environment["CHAT_UI_ARTIFACTS_DIR"] else { return }
    view.layoutSubtreeIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
}
@MainActor private func railWindow(_ view: NSView, width: CGFloat = 40, height: CGFloat = 400) -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: width, height: height),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    if let screen = NSScreen.main {
        let visible = screen.visibleFrame
        // CI may have a 1024 pt display while the offscreen render host is 1200 pt.
        // Keep the trailing interactive strip reachable instead of synthesizing hover offscreen.
        window.setFrameOrigin(CGPoint(x: min(200, visible.maxX - window.frame.width - 12),
                                      y: max(visible.minY + 12, min(200, visible.maxY - window.frame.height - 12))))
    }
    window.makeKeyAndOrderFront(nil)
    view.layoutSubtreeIfNeeded()
    return window
}

extension NativeUITests {
@Suite @MainActor struct PromptRailNativeTests {
    @Test func fixedHitboxesHoverExitPopoverAndStableIDKeyboardAXAcrossAllInputs() async throws {
        var messages = railMessages(10_000)
        messages[0].content = "  **literal**\n" + String(repeating: "Long original input 日本語 中文 한국어\n", count: 200)
        let model = PromptRailModel(messages: messages)
        let navigation = TranscriptNavigation()
        let input = PromptRailInputView(frame: CGRect(x: 0, y: 0, width: 40, height: 400))
        let window = railWindow(input)
        defer { window.close() }
        let viewport = TranscriptViewport(centerVisibleMessageID: messages[1].id)
        navigation.viewport = viewport
        input.configure(model: model, conversationID: railConversation, navigation: navigation, viewport: viewport,
                        localizer: Localizer(language: .english), reduceMotion: false, increasedContrast: false)
        let cell = input.geometry.cell(for: 0)
        let point = CGPoint(x: 3, y: cell.midY) // outside even the extended bar; fixed cell still works
        let enter = try railMouse(.mouseEntered, point, input)
        input.mouseEntered(with: enter)
        #expect(input.hoveredID == messages[0].id)
        #expect(input.currentID == messages[0].id)
        #expect(input.previewText == messages[0].content)
        // Streaming/manual measurement can move the center without touching a hovered input.
        input.configure(model: model, conversationID: railConversation, navigation: navigation,
                        viewport: TranscriptViewport(centerVisibleMessageID: messages[3].id),
                        localizer: Localizer(language: .english), reduceMotion: false, increasedContrast: false)
        #expect(input.currentID == messages[2].id)
        #expect(input.hoveredID == messages[0].id && input.previewText == messages[0].content)
        input.configure(model: model, conversationID: railConversation, navigation: navigation,
                        viewport: viewport, localizer: Localizer(language: .english),
                        reduceMotion: false, increasedContrast: false)
        #expect(input.geometry.cell(for: 0) == cell)
        let popup = try #require(NSApplication.shared.windows.first { $0.isVisible && $0 !== window && railFind($0.contentView ?? NSView(), NSTextView.self).contains { $0.string == messages[0].content } })
        let popupContent = try #require(popup.contentView)
        let text = try #require(railFind(popupContent, NSTextView.self).first)
        #expect(text.isSelectable && !text.isEditable && !text.isRichText)
        #expect(text.string == messages[0].content)
        #expect(text.accessibilityValue() == messages[0].content)
        let previewScroll = try #require(text.enclosingScrollView)
        #expect(text.frame.height > previewScroll.contentView.bounds.height)
        #expect(popup.frame.width < 400 && popup.frame.height < 320)
        if let screen = popup.screen { #expect(screen.visibleFrame.insetBy(dx: -2, dy: -2).contains(popup.frame)) }
        try railCapture(popupContent, "prompt-rail-long-popover")
        for _ in 0..<20 {
            input.mouseMoved(with: try railMouse(.mouseMoved, point, input))
            #expect(input.geometry.cell(for: 0) == cell)
            #expect(input.hoveredID == messages[0].id)
        }
        let second = input.geometry.cell(for: 1)
        input.mouseMoved(with: try railMouse(.mouseMoved, CGPoint(x: 3, y: second.midY), input))
        #expect(input.hoveredID == messages[2].id && input.currentID == messages[0].id)
        input.mouseExited(with: enter)
        #expect(input.hoveredID == nil && input.currentID == messages[0].id)
        try await railSettle { input.previewText == nil }
        #expect(navigation.scrollRequest == nil)
        #expect(window.makeFirstResponder(input))
        input.mouseDown(with: try railMouse(.leftMouseDown, CGPoint(x: 3, y: second.midY), input))
        #expect(navigation.scrollRequest?.messageID == messages[2].id)
        input.keyDown(with: try railKey(119, window))
        #expect(navigation.scrollRequest?.messageID == messages[19_998].id)
        #expect(input.geometry.visible.contains(9999))
        let request = navigation.scrollRequest?.id
        input.keyDown(with: try railKey(36, window))
        #expect(navigation.scrollRequest?.id != request)
        #expect(input.accessibilityPerformDecrement())
        #expect(navigation.scrollRequest?.messageID == messages[19_996].id)
        #expect(input.accessibilityPerformIncrement())
        #expect(navigation.scrollRequest?.messageID == messages[19_998].id)
        input.keyDown(with: try railKey(115, window))
        #expect(navigation.scrollRequest?.messageID == messages[0].id)
        // Every AX step resolves an exact stable user ID, including offscreen windows.
        for index in 1..<10_000 {
            #expect(input.accessibilityPerformIncrement())
            #expect(navigation.scrollRequest?.messageID == messages[index * 2].id)
        }
        #expect((input.accessibilityValue() as? String)?.hasSuffix(messages[19_998].content) == true)
        #expect(input.accessibilityHelp()?.contains("Showing inputs") == true)
        let next = NSTextField(frame: .zero)
        input.addSubview(next)
        input.nextKeyView = next
        input.keyDown(with: try railKey(48, window))
        #expect(window.firstResponder !== input)
    }

    @Test func fourLocaleNarrowAndDesktopNativeTranscriptRailMatrix() async throws {
        let backend = RailTestBackend(messages: railMessages(3))
        let store = ChatStore(backend: backend)
        let observation = Task { await store.start() }
        defer { observation.cancel() }
        try await railSettle { store.messages.count == 6 }
        for language in AppLanguage.allCases {
            for dark in [false, true] {
                for width in [CGFloat(400), 1200] {
                    let navigation = TranscriptNavigation()
                    let host = NSHostingView(rootView: HStack(spacing: 0) {
                        TranscriptView(store: store, navigation: navigation)
                        PromptRail(store: store, navigation: navigation)
                    }.background(ChatTheme.background).environment(\.locale, language.locale)
                        .environment(\.colorScheme, dark ? .dark : .light))
                    host.sizingOptions = []
                    let window = railWindow(host, width: width, height: 500)
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    defer { window.close() }
                    try await railSettle { railFind(host, PromptRailInputView.self).first?.currentID != nil }
                    let input = try #require(railFind(host, PromptRailInputView.self).first)
                    #expect(input.frame.width == 40)
                    #expect(input.accessibilityLabel() == Localizer(language: language).chat("User input navigation"))
                    #expect(railFind(host, NSScrollView.self).allSatisfy { $0.frame.width <= width - 40 })
                    // Exercise the first and last popup anchors at every locale/host size.
                    for index in [0, 2] {
                        let cell = input.geometry.cell(for: index)
                        let hoverPoint = CGPoint(x: 3, y: cell.midY)
                        let screenPoint = window.convertPoint(toScreen: input.convert(hoverPoint, to: nil))
                        if let screen = window.screen { try #require(screen.visibleFrame.contains(screenPoint)) }
                        input.mouseEntered(with: try railMouse(.mouseEntered, hoverPoint, input))
                        #expect(input.previewText == store.messages[index * 2].content)
                        let popup = try #require(NSApplication.shared.windows.first { $0.isVisible && $0 !== window && railFind($0.contentView ?? NSView(), NSTextView.self).contains { $0.string == store.messages[index * 2].content } })
                        if let screen = popup.screen { #expect(screen.visibleFrame.insetBy(dx: -2, dy: -2).contains(popup.frame)) }
                        let content = try #require(popup.contentView)
                        let text = try #require(railFind(content, NSTextView.self).first)
                        #expect(text.accessibilityLabel() == Localizer(language: language).chat("User input {current} of {total}", ["current": .integer(index + 1), "total": .integer(3)]))
                        text.cancelOperation(nil)
                        #expect(input.previewText == nil)
                    }
                    try railCapture(host, "prompt-rail-\(language.rawValue)-\(Int(width))-\(dark ? "dark" : "light")")
                }
            }
        }
    }

    @Test func publicRailKeepsNativeIdentityThroughLocalesAppearanceStreamAndConversationReset() async throws {
        let backend = RailTestBackend(messages: railMessages(3))
        let store = ChatStore(backend: backend)
        let observation = Task { await store.start() }
        defer { observation.cancel() }
        try await railSettle { store.messages.count == 6 }
        let navigation = TranscriptNavigation()
        let suite = "PromptRailTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = LocalizationSettings(defaults: defaults, preferredLanguages: { ["en"] })
        let host = NSHostingView(rootView: PromptRail(store: store, navigation: navigation)
            .background(ChatTheme.background).environment(settings))
        host.sizingOptions = []
        let window = railWindow(host)
        defer { window.close() }
        try await railSettle { railFind(host, PromptRailInputView.self).first?.model.inputs.count == 3 }
        let input = try #require(railFind(host, PromptRailInputView.self).first)
        navigation.viewport = TranscriptViewport(centerVisibleMessageID: store.messages[3].id)
        try await railSettle { input.currentID == store.messages[2].id }
        #expect(window.makeFirstResponder(input))
        let viewport = navigation.viewport
        for choice in [LanguageChoice.english, .japanese, .simplifiedChinese, .korean] {
            settings.choice = choice
            for dark in [false, true] {
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                try await railSettle { input.accessibilityLabel() == settings.localizer.chat("User input navigation") }
                #expect(railFind(host, PromptRailInputView.self).first === input)
                #expect(window.firstResponder === input)
                #expect(navigation.viewport == viewport && navigation.scrollRequest == nil)
                #expect(input.frame.width == 40)
                #expect(input.currentID == store.messages[2].id)
                try railCapture(host, "prompt-rail-\(choice.rawValue)-\(dark ? "dark" : "light")")
            }
        }
        await backend.grow()
        try await railSettle { store.messages.last?.status == .streaming }
        #expect(navigation.viewport == viewport && navigation.scrollRequest == nil)
        #expect(input.currentID == store.messages[2].id)
        let retainedCursor = try #require(input.cursorID)
        navigation.viewport = TranscriptViewport(centerVisibleMessageID: MessageID("missing"))
        try await railSettle { input.currentID == nil }
        input.keyDown(with: try railKey(36, window))
        #expect(navigation.scrollRequest?.messageID == retainedCursor)
        await store.selectConversation(ConversationID("rail:other"))
        try await railSettle { input.model.inputs.count == 1 && navigation.scrollRequest == nil }
        #expect(input.hoveredID == nil && input.cursorID == nil && input.currentID == nil)
        await store.selectConversation(nil)
        try await railSettle { input.model.inputs.isEmpty && navigation.viewport == TranscriptViewport() }
        #expect(!input.accessibilityPerformIncrement())
    }

    @Test func actualHugeAssistantCenterManualScrollAndStreamingKeepRailSynchronizedWithoutTakeover() async throws {
        var messages = railMessages(5)
        messages[3].content = String(repeating: "Huge assistant line in the actual viewport.\n\n", count: 100)
        let backend = RailTestBackend(messages: messages)
        let store = ChatStore(backend: backend)
        let navigation = TranscriptNavigation()
        let observation = Task { await store.start() }
        defer { observation.cancel() }
        try await railSettle { store.messages.count == 10 }
        let host = NSHostingView(rootView: HStack(spacing: 0) {
            TranscriptView(store: store, navigation: navigation)
            PromptRail(store: store, navigation: navigation)
        }.background(ChatTheme.background).environment(\.locale, Locale(identifier: "en")))
        host.sizingOptions = []
        let window = railWindow(host, width: 400, height: 420)
        defer { window.close() }
        try await railSettle { navigation.viewport.lastVisibleMessageID == messages.last?.id }
        let input = try #require(railFind(host, PromptRailInputView.self).first)
        navigation.jump(to: messages[3].id)
        try await railSettle { navigation.viewport.centerVisibleMessageID == messages[3].id && input.currentID == messages[2].id }
        let scroll = try #require(railFind(host, NSScrollView.self).first)
        let clip = scroll.contentView
        try await Task.sleep(for: .milliseconds(100))
        clip.scroll(to: CGPoint(x: 0, y: clip.bounds.origin.y + 300))
        scroll.reflectScrolledClipView(clip)
        try await Task.sleep(for: .milliseconds(100))
        #expect(navigation.viewport.firstVisibleMessageID == messages[3].id)
        #expect(navigation.viewport.lastVisibleMessageID == messages[3].id)
        #expect(navigation.viewport.centerVisibleMessageID == messages[3].id)
        #expect(input.currentID == messages[2].id)
        let offset = clip.bounds.origin.y
        let viewport = navigation.viewport
        let request = navigation.scrollRequest?.id
        await backend.grow()
        try await railSettle { store.messages.last?.status == .streaming }
        try await Task.sleep(for: .milliseconds(100))
        #expect(abs(clip.bounds.origin.y - offset) < 1)
        #expect(navigation.viewport == viewport && navigation.scrollRequest?.id == request)
        // Native manual scroll to the top changes the preceding user selection.
        clip.scroll(to: .zero)
        scroll.reflectScrolledClipView(clip)
        try await railSettle { input.currentID == messages[0].id }
        try railCapture(host, "prompt-rail-actual-transcript-400")
    }

    @Test func shortTurnJumpsKeepKeyboardTargetAfterCenterMoves() async throws {
        let messages = railMessages(24)
        let backend = RailTestBackend(messages: messages)
        let store = ChatStore(backend: backend)
        let navigation = TranscriptNavigation()
        let observation = Task { await store.start() }
        defer { observation.cancel() }
        try await railSettle { store.messages.count == messages.count }
        let host = NSHostingView(rootView: HStack(spacing: 0) {
            TranscriptView(store: store, navigation: navigation)
            PromptRail(store: store, navigation: navigation)
        }.environment(\.locale, Locale(identifier: "en")))
        host.sizingOptions = []
        let window = railWindow(host, width: 760, height: 720)
        defer { window.close() }
        try await railSettle { navigation.viewport.lastVisibleMessageID == messages.last?.id }
        let input = try #require(railFind(host, PromptRailInputView.self).first)
        #expect(window.makeFirstResponder(input))
        input.keyDown(with: try railKey(115, window))
        try await railSettle { navigation.viewport.firstVisibleMessageID == messages[0].id }
        try await railSettle { input.currentID != messages[0].id }
        #expect(input.cursorID == messages[0].id)
        let focusRing = try #require(input.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
        #expect(!focusRing.isHidden && (focusRing.path?.boundingBox.height ?? 0) >= 8)
        for index in [1, 2] {
            input.keyDown(with: try railKey(125, window))
            #expect(navigation.scrollRequest?.messageID == messages[index * 2].id)
            try await railSettle { navigation.viewport.firstVisibleMessageID == messages[index * 2].id }
            #expect(input.cursorID == messages[index * 2].id)
            #expect((input.accessibilityValue() as? String)?.hasSuffix(messages[index * 2].content) == true)
        }
        input.keyDown(with: try railKey(119, window))
        try await railSettle { navigation.viewport.lastVisibleMessageID == messages.last?.id }
        try await railSettle { input.currentID != messages[messages.count - 2].id }
        #expect(input.cursorID == messages[messages.count - 2].id)
        input.keyDown(with: try railKey(126, window))
        #expect(navigation.scrollRequest?.messageID == messages[messages.count - 4].id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(input.cursorID == messages[messages.count - 4].id)
    }

    @Test func reduceMotionAndIncreasedContrastKeepReadableNativeBarsAndStableCells() throws {
        let messages = railMessages(3)
        let input = PromptRailInputView(frame: CGRect(x: 0, y: 0, width: 40, height: 400))
        let window = railWindow(input)
        defer { window.close() }
        let navigation = TranscriptNavigation()
        let viewport = TranscriptViewport(centerVisibleMessageID: messages[1].id)
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for increased in [false, true] {
                input.configure(model: PromptRailModel(messages: messages), conversationID: railConversation,
                    navigation: navigation, viewport: viewport, localizer: Localizer(language: .english),
                    reduceMotion: true, increasedContrast: increased)
                let cell = input.geometry.cell(for: 1)
                input.mouseEntered(with: try railMouse(.mouseEntered, CGPoint(x: 3, y: cell.midY), input))
                let bars = input.layer?.sublayers?.filter { $0.bounds.height == 2.5 } ?? []
                #expect(Set(bars.map { $0.bounds.width }) == Set([CGFloat(10), 22, 28]))
                #expect(bars.allSatisfy { $0.animationKeys()?.isEmpty != false })
                #expect(input.geometry.cell(for: 1) == cell)
                input.effectiveAppearance.performAsCurrentDrawingAppearance {
                    for bar in bars {
                        guard let color = bar.backgroundColor,
                              let foreground = NSColor(cgColor: color)?.usingColorSpace(.sRGB),
                              let background = NSColor.textBackgroundColor.usingColorSpace(.sRGB) else {
                            Issue.record("Native bar must resolve to an RGB color")
                            return
                        }
                        func luminance(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat {
                            func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
                            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
                        }
                        let alpha = foreground.alphaComponent
                        let fg = luminance(foreground.redComponent * alpha + background.redComponent * (1 - alpha),
                            foreground.greenComponent * alpha + background.greenComponent * (1 - alpha),
                            foreground.blueComponent * alpha + background.blueComponent * (1 - alpha))
                        let bg = luminance(background.redComponent, background.greenComponent, background.blueComponent)
                        #expect((max(fg, bg) + 0.05) / (min(fg, bg) + 0.05) >= 3)
                    }
                }
                input.mouseExited(with: try railMouse(.mouseExited, CGPoint(x: -1, y: cell.midY), input))
                #expect(input.currentID == messages[0].id && input.hoveredID == nil)
            }
        }
    }
}
}
