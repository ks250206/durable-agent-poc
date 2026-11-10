import AppKit
import AppLocalization
import ChatCore
import Observation
import SwiftUI
import Testing
@testable import ChatUI

private let presentationID = ConversationID("presentation:fixture")
private let userSource = "Compare the options. 日本語・中文・한국어 👩🏽‍💻\nhttps://example.invalid/" + String(repeating: "long-path-", count: 8)
private let codeSource = "let greeting = \"日本語・中文・한국어 👩🏽‍💻\"\r\n" + String(repeating: "wide_code_", count: 35) + "\r\n"
private let assistantSource = "## A clear reading column\n\nReadable **hierarchy**, a [safe link](https://example.invalid), and multilingual text.\n\n- Preserve the original source.\n> A useful distinction.\n\n```swift\n" + codeSource + "```"

private actor PresentationBackend: ChatBackend {
    private var conversation = ConversationSnapshot(summary: ConversationSummary(id: presentationID, title: "Component QA"))
    private var continuation: AsyncThrowingStream<ChatEvent, any Error>.Continuation?
    func snapshot() async throws -> ChatSnapshot {
        ChatSnapshot(connection: .connected, conversations: [conversation.summary], selectedConversationID: presentationID,
                     loadedConversations: [conversation])
    }
    func events() async -> AsyncThrowingStream<ChatEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<ChatEvent, any Error>.makeStream()
        self.continuation = continuation
        continuation.yield(.snapshot(try! await snapshot()))
        return stream
    }
    func createConversation(title: String?) async throws -> ConversationID { presentationID }
    func selectConversation(_ id: ConversationID?) async throws {}
    func send(_ request: SendRequest) async throws { throw ChatBackendError.demoReadOnly }
    func stop(conversationID: ConversationID) async throws {}
    func stream(_ chunk: String) {
        conversation.activity = .streaming
        conversation.messages = [ChatMessage(id: MessageID("stream"), conversationID: presentationID,
                                             role: .assistant, content: chunk, status: .streaming)]
        continuation?.yield(.conversationUpdated(conversation))
    }
}

@MainActor private final class PresentationHost {
    let host: NSHostingView<AnyView>
    let window: NSWindow
    let screen: NSScreen

    init<V: View>(_ view: V, width: CGFloat, height: CGFloat = 900) throws {
        _ = NSApplication.shared
        screen = try #require(NSScreen.main, "Native QA requires a display")
        host = NSHostingView(rootView: AnyView(view))
        host.sizingOptions = []
        window = NSWindow(contentRect: NSRect(x: screen.visibleFrame.minX, y: screen.visibleFrame.maxY - height,
                                              width: width, height: height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
    }

    func capture(_ name: String) throws {
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        if let path = ProcessInfo.processInfo.environment["CHAT_UI_ARTIFACTS_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try image.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
        }
    }

    /// A 1200pt render can exceed CI's 1024pt screen. Move the same window so the
    /// actual interactive target is on screen; never exempt it from screen bounds.
    func reveal(_ node: NSObject) throws {
        let rect = try frame(node)
        let visible = screen.visibleFrame
        var origin = window.frame.origin
        if rect.minX < visible.minX { origin.x += visible.minX - rect.minX + 8 }
        if rect.maxX > visible.maxX { origin.x -= rect.maxX - visible.maxX + 8 }
        if rect.minY < visible.minY { origin.y += visible.minY - rect.minY + 8 }
        if rect.maxY > visible.maxY { origin.y -= rect.maxY - visible.maxY + 8 }
        window.setFrameOrigin(origin)
        host.layoutSubtreeIfNeeded()
    }
}

@MainActor private func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
    (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, type) }
}

@MainActor private func nodes(_ root: Any) -> [NSObject] {
    var seen = Set<ObjectIdentifier>()
    func walk(_ value: Any) -> [NSObject] {
        guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return [] }
        let selector = NSSelectorFromString("accessibilityChildren")
        let children = object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() as? [Any] ?? [] : []
        return [object] + children.flatMap(walk) + ((object as? NSView)?.subviews ?? []).flatMap(walk)
    }
    return walk(root)
}

@MainActor private func axString(_ node: NSObject, _ property: String) -> String? {
    let selector = NSSelectorFromString(property)
    return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() as? String : nil
}

@MainActor private func frame(_ node: NSObject) throws -> CGRect {
    try #require(node.responds(to: NSSelectorFromString("accessibilityFrame")))
    return try #require(node.value(forKey: "accessibilityFrame") as? NSValue).rectValue
}

@MainActor private func identified(_ root: Any, _ id: String) throws -> NSObject {
    try #require(nodes(root).first { axString($0, "accessibilityIdentifier") == id }, "Missing AX node \(id)")
}

@MainActor private func pumpPresentationLoop() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005)) }

@MainActor private func settle(_ predicate: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate(), ContinuousClock.now < deadline {
        pumpPresentationLoop()
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(predicate(), sourceLocation: sourceLocation)
}

@MainActor private func assertColor(_ actual: NSColor?, _ expected: ThemeColor) throws {
    let rgb = try #require(actual?.usingColorSpace(.sRGB))
    #expect(abs(rgb.redComponent - expected.red) < 0.002)
    #expect(abs(rgb.greenComponent - expected.green) < 0.002)
    #expect(abs(rgb.blueComponent - expected.blue) < 0.002)
}

extension NativeUITests {
@Suite @MainActor struct MessagePresentationNativeTests {
    @Test func actualMessageFramesTextStatusAndCodeStayInsideColumnsInEveryLocaleAndScheme() async throws {
        let store = ChatStore(backend: PresentationBackend())
        let observation = Task { await store.start() }
        defer { observation.cancel() }
        try await settle { store.connection == .connected }
        store.draft = "An editable draft 日本語"
        store.modelSelection = ModelSelection(account: ProviderAccount(option: .apiKey, providerID: "test"), modelID: "fixture")
        for language in AppLanguage.allCases {
            let localizer = Localizer(language: language)
            for scheme in [ColorScheme.light, .dark] {
                for width: CGFloat in [400, 1200] {
                    let user = ChatMessage(id: MessageID("qa-user"), conversationID: presentationID, role: .user, content: userSource)
                    let assistant = ChatMessage(id: MessageID("qa-assistant"), conversationID: presentationID,
                                                role: .assistant, content: assistantSource, status: .stopped)
                    let view = VStack(spacing: 0) {
                        MessageRow(message: user)
                        MessageRow(message: assistant)
                        ComposerView(store: store)
                    }
                    .frame(maxWidth: ChatTheme.Dimensions.readableWidth)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(ChatPalette(colorScheme: scheme).mainCanvas.color)
                    .environment(\.locale, language.locale)
                    .environment(\.colorScheme, scheme)
                    let hosted = try PresentationHost(view, width: width)
                    defer { hosted.window.close() }
                    try await settle { descendants(hosted.host, CompositionNSTextView.self).count == 1 }
                    let userNode = try identified(hosted.host, "message.qa-user")
                    let assistantNode = try identified(hosted.host, "message.qa-assistant")
                    let userFrame = try frame(userNode), assistantFrame = try frame(assistantNode)
                    let columnWidth = min(width - 32, ChatTheme.Dimensions.readableWidth)
                    let localColumn = CGRect(x: (width - columnWidth) / 2, y: 0, width: columnWidth, height: hosted.host.bounds.height)
                    let column = hosted.window.convertToScreen(hosted.host.convert(localColumn, to: nil))
                    #expect(abs(userFrame.maxX - column.maxX) < 1)
                    #expect(abs(userFrame.width - columnWidth * 0.82) < 1)
                    // A transparent assistant has no bubble: AX reports its visible content,
                    // excluding the deliberate 16pt reading inset. The user AX frame includes
                    // its actual colored bubble. Assert both independently.
                    #expect(abs(assistantFrame.minX - (column.minX + 16)) < 1)
                    #expect(abs(assistantFrame.width - (columnWidth - 32)) < 1)
                    #expect(userFrame.minX > assistantFrame.minX + 40)
                    var controls: [NSObject] = []
                    for (id, outer) in [("qa-user", userFrame), ("qa-assistant", assistantFrame)] {
                        let body = try frame(identified(hosted.host, "message.\(id).body"))
                        let metadata = try frame(identified(hosted.host, "message.\(id).metadata"))
                        let inset: CGFloat = id == "qa-user" ? 15 : 0
                        #expect(body.minX >= outer.minX + inset && body.maxX <= outer.maxX - inset)
                        #expect(metadata.minX >= outer.minX + inset && metadata.maxX <= outer.maxX - inset)
                        #expect(body.minY - metadata.maxY >= 11) // Separate status/copy from prose.
                        let metadataNode = try identified(hosted.host, "message.\(id).metadata")
                        let copyNode = try #require(nodes(metadataNode).first { axString($0, "accessibilityLabel") == localizer.chat("Copy message") })
                        let copyFrame = try frame(copyNode)
                        #expect(copyFrame.width >= 28 && copyFrame.height >= 28)
                        #expect(metadata.insetBy(dx: -1, dy: -1).contains(copyFrame))
                        controls.append(copyNode)
                    }
                    let allNodes = nodes(hosted.host)
                    #expect(allNodes.contains { axString($0, "accessibilityValue") == localizer.chat("Response stopped") })
                    #expect(allNodes.contains { axString($0, "accessibilityLabel") == localizer.chat("Copy code") })
                    let sendNode = try #require(allNodes.first { axString($0, "accessibilityLabel") == localizer.chat("Send") })
                    controls.append(sendNode)
                    // Actual text bounds (not just the outer host width), excluding the deliberate
                    // code document whose own NSScrollView provides horizontal access.
                    for node in allNodes where axString(node, "accessibilityRole") == "AXStaticText" {
                        let rect = try frame(node)
                        if axString(node, "accessibilityValue")?.contains("wide_code_") == true { continue }
                        #expect(rect.minX >= column.minX - 1 && rect.maxX <= column.maxX + 1)
                    }
                    let scrolls = descendants(hosted.host, NSScrollView.self)
                    let codeScroll = try #require(scrolls.first { $0.hasHorizontalScroller })
                    #expect(abs(codeScroll.frame.width - assistantFrame.width) < 1)
                    let document = try #require(codeScroll.documentView)
                    #expect(document.bounds.width > codeScroll.contentView.bounds.width)
                    codeScroll.contentView.scroll(to: NSPoint(x: document.bounds.maxX - codeScroll.contentView.bounds.width, y: 0))
                    codeScroll.reflectScrolledClipView(codeScroll.contentView)
                    #expect(codeScroll.contentView.bounds.minX > 0)
                    codeScroll.contentView.scroll(to: .zero)
                    let renderOrigin = hosted.window.frame.origin
                    for control in controls {
                        try hosted.reveal(control)
                        try #require(hosted.screen.visibleFrame.contains(frame(control)), "Actual interactive edges must be on the connected screen")
                    }
                    hosted.window.setFrameOrigin(renderOrigin)
                    try hosted.capture("message-composer-\(language.rawValue)-\(Int(width))-\(scheme)")
                    #expect(store.draft == "An editable draft 日本語")
                    #expect(user.content == userSource && assistant.content == assistantSource)
                }
            }
        }
    }

    @Test func retainedProductionEditorFollowsForcedOppositeAppearanceDuringMarkedTextLocaleStreamAndUndo() async throws {
        let suite = "MessagePresentation.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = AppearanceSettings(defaults: defaults)
        let localization = LocalizationSettings(defaults: defaults, preferredLanguages: { ["en"] })
        let backend = PresentationBackend()
        let store = ChatStore(backend: backend)
        let observation = Task { await store.start() }
        defer { observation.cancel() }
        try await settle { store.connection == .connected }
        let hosted = try PresentationHost(ComposerView(store: store).environment(appearance).environment(localization)
            .environment(\.colorScheme, .dark), width: 400, height: 260)
        defer { hosted.window.close() }
        try await settle { descendants(hosted.host, CompositionNSTextView.self).count == 1 }
        let editor = try #require(descendants(hosted.host, CompositionNSTextView.self).first)
        try await Task.sleep(for: .milliseconds(100))
        try #require(hosted.window.makeFirstResponder(editor))
        let storage = try #require(editor.textStorage), undo = try #require(editor.undoManager)
        let coordinator = editor.delegate
        let storageDelegate = storage.delegate
        let scroll = editor.enclosingScrollView
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        editor.insertText("Unsent 日本語 ", replacementRange: NSRange(location: NSNotFound, length: 0))
        undo.endUndoGrouping()
        let committed = store.draft
        undo.beginUndoGrouping()
        editor.setSelectedRange(NSRange(location: 7, length: 3))
        editor.setMarkedText("かな", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let text = editor.string, selection = editor.selectedRanges, marked = editor.markedRange()
        for language in [LanguageChoice.japanese, .simplifiedChinese, .korean, .english] {
            localization.choice = language
            for choice in [AppearanceChoice.light, .dark] {
                appearance.choice = choice
                // Same SwiftUI identity, explicitly opposite ambient scheme, no root app wiring.
                hosted.host.rootView = AnyView(ComposerView(store: store).environment(appearance).environment(localization)
                    .environment(\.colorScheme, choice == .light ? .dark : .light))
                let chunk = "A genuine fixture chunk \(language.rawValue) \(choice.rawValue)"
                await backend.stream(chunk)
                let expected = appearance.resolve(systemColorScheme: choice == .light ? .dark : .light)
                try await settle { editor.appearance?.name == expected.nsAppearance.name && store.isSending && store.messages.last?.content == chunk
                    && editor.accessibilityLabel() == localization.localizer.chat("Message") }
                #expect(descendants(hosted.host, CompositionNSTextView.self).first === editor)
                #expect(editor.textStorage === storage && editor.undoManager === undo)
                #expect(editor.delegate === coordinator && storage.delegate === storageDelegate)
                #expect(editor.enclosingScrollView === scroll)
                #expect(editor.effectiveAppearance.name == expected.nsAppearance.name)
                #expect(editor.string == text && storage.string == text)
                #expect(editor.selectedRanges == selection && editor.markedRange() == marked && editor.hasMarkedText())
                #expect(hosted.window.firstResponder === editor && editor.isEditable)
                #expect(store.draft == committed)
                #expect(undo.canUndo)
                #expect(editor.font == ChatTheme.Typography.editor)
                try assertColor(editor.textColor, expected.palette.primaryText)
                try assertColor(editor.backgroundColor, expected.palette.composer)
                try assertColor(editor.insertionPointColor, expected.palette.primaryText)
                try assertColor(editor.selectedTextAttributes[.backgroundColor] as? NSColor, expected.palette.active)
                try assertColor(editor.selectedTextAttributes[.foregroundColor] as? NSColor, expected.palette.primaryText)
                try hosted.capture("editor-forced-\(language.rawValue)-\(choice.rawValue)-opposite-ambient")
            }
        }
        editor.insertText("確定", replacementRange: editor.markedRange())
        undo.endUndoGrouping()
        try await settle { store.draft == editor.string }
        undo.undo()
        try await settle { store.draft == committed && editor.string == committed }
        undo.redo()
        try await settle { store.draft == editor.string && editor.string.contains("確定") }
        #expect(descendants(hosted.host, CompositionNSTextView.self).first === editor)
    }

    @Test func copyControlCopiesOriginalUnicodeAndCRLFWithRealOnscreenClickInAllLocales() async throws {
        for language in AppLanguage.allCases {
            let localizer = Localizer(language: language)
            for (key, source) in [("Copy message", assistantSource), ("Copy code", codeSource)] {
                let pasteboard = NSPasteboard.withUniqueName()
                defer { pasteboard.releaseGlobally() }
                let hosted = try PresentationHost(CopyTextButton(text: source, label: localizer.chat(key), pasteboard: pasteboard)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(24).environment(\.locale, language.locale), width: 1200, height: 120)
                defer { hosted.window.close() }
                try await settle { nodes(hosted.host).contains { axString($0, "accessibilityLabel") == localizer.chat(key) } }
                let node = try #require(nodes(hosted.host).first { axString($0, "accessibilityLabel") == localizer.chat(key) })
                try hosted.reveal(node)
                let rect = try frame(node)
                try #require(hosted.screen.visibleFrame.contains(rect), "The actual copy target must be on screen")
                let point = hosted.window.convertPoint(fromScreen: NSPoint(x: rect.midX, y: rect.midY))
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                        windowNumber: hosted.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                    hosted.window.sendEvent(event)
                }
                try await settle { pasteboard.string(forType: .string) == source }
                #expect(pasteboard.string(forType: .string)?.utf8.elementsEqual(source.utf8) == true)
                try await settle { nodes(hosted.host).contains { axString($0, "accessibilityLabel") == localizer.chat("Copied to clipboard") } }
            }
        }
    }
}
}
