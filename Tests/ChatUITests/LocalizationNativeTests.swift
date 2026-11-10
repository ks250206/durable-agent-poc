import AppKit
import AppLocalization
import ChatCore
@testable import ChatUI
import SwiftUI
import Testing

private let localizedConversationID = ConversationID("localization:stable")
private let verbatimTitle = "Saved title / New conversation 日本語 {count}"
private let verbatimContent = "Model text stays verbatim: Send 日本語 {count} %n"

private actor LocalizationBackend: ChatBackend {
    let state: ChatSnapshot
    init(connection: ConnectionState = .connected, messages: Bool = true) {
        let conversation = ConversationSnapshot(
            summary: ConversationSummary(id: localizedConversationID, title: verbatimTitle),
            messages: messages ? [
                ChatMessage(id: MessageID("localization:user"), conversationID: localizedConversationID,
                            role: .user, content: "User text 日本語"),
                ChatMessage(id: MessageID("localization:assistant"), conversationID: localizedConversationID,
                            role: .assistant, content: verbatimContent + "\n\n```\nlet code = \"Send 日本語\"\n```", status: .stopped),
            ] : [])
        state = ChatSnapshot(connection: connection, conversations: [conversation.summary],
                             selectedConversationID: conversation.id, loadedConversations: [conversation])
    }
    init(state: ChatSnapshot) { self.state = state }
    func snapshot() async throws -> ChatSnapshot { state }
    func events() async -> AsyncThrowingStream<ChatEvent, any Error> {
        AsyncThrowingStream { $0.yield(.snapshot(state)) }
    }
    func createConversation(title: String?) async throws -> ConversationID { throw ChatBackendError.demoReadOnly }
    func selectConversation(_ id: ConversationID?) async throws {}
    func send(_ request: SendRequest) async throws { throw ChatBackendError.demoReadOnly }
    func stop(conversationID: ConversationID) async throws {}
}

@MainActor private final class LocalizationHost {
    let host: NSHostingView<AnyView>
    let window: NSWindow

    init<V: View>(_ view: V, width: CGFloat, height: CGFloat = 760) {
        _ = NSApplication.shared
        host = NSHostingView(rootView: AnyView(view))
        host.sizingOptions = []
        window = NSWindow(contentRect: NSRect(x: -16000, y: -16000, width: width, height: height),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
    }

    func capture(_ name: String) throws {
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        if let path = ProcessInfo.processInfo.environment["CHAT_UI_ARTIFACTS_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
        }
    }
}

@MainActor private func descendants<T: NSView>(_ root: NSView, of type: T.Type) -> [T] {
    (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, of: type) }
}

// SwiftUI's virtual AX nodes expose NSObject's attribute interface without adopting
// the full NSAccessibilityProtocol. Include both them and native NSView descendants.
@MainActor private func accessibilityNodes(_ root: Any) -> [NSObject] {
    var seen = Set<ObjectIdentifier>()
    func walk(_ object: Any) -> [NSObject] {
        guard let node = object as? NSObject, seen.insert(ObjectIdentifier(node)).inserted else { return [] }
        let selector = NSSelectorFromString("accessibilityChildren")
        let children = node.responds(to: selector)
            ? (node.perform(selector)?.takeUnretainedValue() as? [Any] ?? []) : []
        let views = (node as? NSView)?.subviews ?? []
        return [node] + children.flatMap(walk) + views.flatMap(walk)
    }
    return walk(root)
}

@MainActor private func nodeLabels(_ node: NSObject) -> [String] {
    // SwiftUI virtual nodes implement these public ObjC AX getters without declaring
    // the full protocol. Object-returning getters are safe to query via NSObject.
    ["accessibilityLabel", "accessibilityValue", "accessibilityTitle", "accessibilityHelp"].compactMap { name in
        let selector = NSSelectorFromString(name)
        guard node.responds(to: selector) else { return nil }
        return node.perform(selector)?.takeUnretainedValue() as? String
    }
}

@MainActor private func labels(_ root: Any) -> [String] {
    accessibilityNodes(root).flatMap(nodeLabels)
}

@MainActor private func pumpLocalizationLoop() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005)) }

@MainActor private func localizedSettle(_ predicate: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !predicate(), ContinuousClock.now < deadline {
        pumpLocalizationLoop()
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(predicate(), sourceLocation: sourceLocation)
}

@MainActor private func sharedSettings() throws -> (LocalizationSettings, UserDefaults, String) {
    let suite = "ChatUILocalizationTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    return (LocalizationSettings(defaults: defaults, preferredLanguages: { ["en"] }), defaults, suite)
}

extension NativeUITests {
@Suite @MainActor struct ChatUILocalizationNativeTests {
    @Test func fourLanguagesRenderRealWorkspaceComposerMinimapAt400And1200InLightAndDark() async throws {
        let store = ChatStore(backend: LocalizationBackend())
        let observation = Task { await store.start() }
        defer { observation.cancel() }
        try await localizedSettle { store.messages.count == 2 }
        store.modelSelection = ModelSelection(account: ProviderAccount(option: .apiKey, providerID: "verbatim-provider"), modelID: "verbatim-model")
        for language in AppLanguage.allCases {
            let localizer = Localizer(language: language)
            for scheme in [ColorScheme.light, .dark] {
                for width in [CGFloat(400), 1200] {
                    let navigation = TranscriptNavigation()
                    let view = ChatWorkspaceView(store: store, navigation: navigation) { ComposerView(store: $0) }
                        minimap: { ConversationMinimap(store: $0, navigation: $1) }
                        .environment(\.locale, language.locale) // Exercises fallback without Settings injection.
                        .environment(\.colorScheme, scheme)
                    let hosted = LocalizationHost(view, width: width)
                    hosted.window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    defer { hosted.window.close() }
                    try await localizedSettle { descendants(hosted.host, of: CompositionNSTextView.self).count == 1 }
                    let editor = try #require(descendants(hosted.host, of: CompositionNSTextView.self).first)
                    #expect(editor.accessibilityLabel() == localizer.chat("Message"))
                    #expect(editor.accessibilityHelp() == localizer.chat("Enter or Command+Enter sends committed text. Shift+Enter inserts a new line. Confirm IME composition before sending."))
                    try await localizedSettle { labels(hosted.host).contains(localizer.chat("Send")) }
                    #expect(labels(hosted.host).contains(verbatimTitle))
                    #expect(labels(hosted.host).contains(localizer.chat("Copy message")))
                    #expect(labels(hosted.host).contains(localizer.chat("Response stopped")))
                    if width == 1200 {
                        try await localizedSettle { descendants(hosted.host, of: MinimapInputView.self).count == 1 }
                        let map = try #require(descendants(hosted.host, of: MinimapInputView.self).first)
                        #expect(map.accessibilityLabel() == localizer.chat("Conversation map"))
                        #expect(labels(hosted.host).contains(localizer.chat("Search conversations")))
                    }
                    #expect(hosted.host.frame.width == width)
                    #expect(descendants(hosted.host, of: NSScrollView.self).allSatisfy { $0.frame.width <= width })
                    try hosted.capture("localized-\(language.rawValue)-\(Int(width))-\(scheme)")
                }
            }
        }
    }

    @Test func realEmptyLoadingAndActivityStatesUseEachLanguage() async throws {
        let summary = ConversationSummary(id: localizedConversationID, title: verbatimTitle)
        let states: [(ChatSnapshot, String)] = [
            (ChatSnapshot(connection: .disconnected), "How can I help?"),
            (ChatSnapshot(connection: .connecting, conversations: [summary], selectedConversationID: summary.id), "Conversation not loaded"),
            (ChatSnapshot(connection: .connected, conversations: [summary], selectedConversationID: summary.id,
                          loadedConversations: [ConversationSnapshot(summary: summary, activity: .streaming)]), "Responding…"),
        ]
        for language in AppLanguage.allCases {
            let localizer = Localizer(language: language)
            for (state, expected) in states {
                let store = ChatStore(backend: LocalizationBackend(state: state))
                let observation = Task { await store.start() }
                defer { observation.cancel() }
                try await localizedSettle { store.connection == state.connection && store.selectedConversationID == state.selectedConversationID }
                let hosted = LocalizationHost(ChatWorkspaceView(store: store, navigation: TranscriptNavigation())
                    .environment(\.locale, language.locale), width: 400)
                defer { hosted.window.close() }
                try await localizedSettle { labels(hosted.host).contains { $0.contains(localizer.chat(expected)) } }
            }
        }
    }

    @Test func realCopyButtonsPreserveContentAndLocalizeFeedbackWithoutTouchingGeneralClipboard() async throws {
        for language in AppLanguage.allCases {
            let localizer = Localizer(language: language)
            for key in ["Copy message", "Copy code"] {
                let pasteboard = NSPasteboard.withUniqueName()
                defer { pasteboard.releaseGlobally() }
                let hosted = LocalizationHost(CopyTextButton(text: verbatimContent, label: localizer.chat(key), pasteboard: pasteboard)
                    .padding(30).environment(\.locale, language.locale), width: 400, height: 160)
                defer { hosted.window.close() }
                try await localizedSettle { labels(hosted.host).contains(localizer.chat(key)) }
                let button = try #require(accessibilityNodes(hosted.host).first { nodeLabels($0).contains(localizer.chat(key)) })
                // The public ObjC AX frame getter boxes its NSRect through KVC. Dispatch a
                // real native click to the hosted control, without moving the system pointer.
                #expect(button.responds(to: NSSelectorFromString("accessibilityFrame")))
                let rect = try #require(button.value(forKey: "accessibilityFrame") as? NSValue).rectValue
                let point = hosted.window.convertPoint(fromScreen: NSPoint(x: rect.midX, y: rect.midY))
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                        windowNumber: hosted.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                    hosted.window.sendEvent(event)
                }
                try await localizedSettle { pasteboard.string(forType: .string) == verbatimContent }
                try await localizedSettle { labels(hosted.host).contains(localizer.chat("Copied to clipboard")) }
            }
        }
    }

    @Test func settingsSwitchDuringRealComposerCompositionPreservesEditorDraftFocusAndNavigation() async throws {
        let (settings, defaults, suite) = try sharedSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatStore(backend: LocalizationBackend())
        let observation = Task { await store.start() }
        defer { observation.cancel() }
        try await localizedSettle { store.messages.count == 2 }
        store.draft = "draft / user text "
        let navigation = TranscriptNavigation()
        let hosted = LocalizationHost(ChatWorkspaceView(store: store, navigation: navigation) { ComposerView(store: $0) }
            minimap: { ConversationMinimap(store: $0, navigation: $1) }.environment(settings), width: 1200)
        defer { hosted.window.close() }
        try await localizedSettle { descendants(hosted.host, of: CompositionNSTextView.self).count == 1 && descendants(hosted.host, of: MinimapInputView.self).count == 1 }
        let editor = try #require(descendants(hosted.host, of: CompositionNSTextView.self).first)
        let map = try #require(descendants(hosted.host, of: MinimapInputView.self).first)
        navigation.viewport = TranscriptViewport(firstVisibleMessageID: store.messages[0].id, lastVisibleMessageID: store.messages[1].id)
        navigation.jump(to: store.messages[0].id)
        try await Task.sleep(for: .milliseconds(100))
        let request = navigation.scrollRequest
        let viewport = navigation.viewport
        let messages = store.messages
        let draft = store.draft
        #expect(hosted.window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 5, length: 4))
        editor.setMarkedText("にほん", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let text = editor.string, marked = editor.markedRange(), selection = editor.selectedRange()
        #expect(editor.hasMarkedText())
        for choice in [LanguageChoice.japanese, .simplifiedChinese, .korean, .english] {
            settings.choice = choice
            let localizer = settings.localizer
            try await localizedSettle { editor.accessibilityLabel() == localizer.chat("Message") && map.accessibilityLabel() == localizer.chat("Conversation map") }
            #expect(descendants(hosted.host, of: CompositionNSTextView.self).first === editor)
            #expect(descendants(hosted.host, of: MinimapInputView.self).first === map)
            #expect(editor.hasMarkedText())
            #expect(editor.string == text)
            #expect(editor.markedRange() == marked)
            #expect(editor.selectedRange() == selection)
            #expect(hosted.window.firstResponder === editor)
            #expect(store.draft == draft)
            #expect(store.selectedConversationID == localizedConversationID)
            #expect(store.messages == messages)
            #expect(navigation.scrollRequest?.id == request?.id)
            #expect(navigation.viewport == viewport)
            #expect(labels(hosted.host).contains(localizer.chat("Send")))
        }
        editor.insertText("日本", replacementRange: editor.markedRange())
        try await localizedSettle { store.draft == editor.string }
        #expect(!editor.hasMarkedText())
    }

    @Test func minimapNativeKeyLoopAndOpenMessageSheetSwitchInPlaceWithNumberEntry() async throws {
        let (settings, defaults, suite) = try sharedSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatStore(backend: LocalizationBackend())
        let observation = Task { await store.start() }
        defer { observation.cancel() }
        try await localizedSettle { store.messages.count == 2 }
        let navigation = TranscriptNavigation()
        let hosted = LocalizationHost(ConversationMinimap(store: store, navigation: navigation).environment(settings), width: 400)
        defer { hosted.window.close() }
        try await localizedSettle { descendants(hosted.host, of: MinimapInputView.self).count == 1 }
        let map = try #require(descendants(hosted.host, of: MinimapInputView.self).first)
        #expect(hosted.window.makeFirstResponder(map))
        #expect(map.accessibilityPerformIncrement())
        let target = navigation.scrollRequest?.messageID
        for choice in [LanguageChoice.japanese, .simplifiedChinese, .korean, .english] {
            settings.choice = choice
            try await localizedSettle { map.accessibilityLabel() == settings.localizer.chat("Conversation map") }
            #expect(descendants(hosted.host, of: MinimapInputView.self).first === map)
            #expect(hosted.window.firstResponder === map)
            #expect(navigation.scrollRequest?.messageID == target)
            #expect((map.accessibilityValue() as? String)?.contains(settings.localizer.role(.assistant)) == true)
        }
        #expect(map.accessibilityPerformShowMenu())
        try await localizedSettle { !hosted.window.sheets.isEmpty }
        let sheet = try #require(hosted.window.sheets.first)
        let content = try #require(sheet.contentView)
        try await localizedSettle { descendants(content, of: NSTextField.self).contains { $0.isEditable } }
        let field = try #require(descendants(content, of: NSTextField.self).first { $0.isEditable })
        #expect(sheet.makeFirstResponder(field))
        field.selectText(nil)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText("2", replacementRange: editor.selectedRange())
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        for choice in [LanguageChoice.japanese, .simplifiedChinese, .korean, .english] {
            settings.choice = choice
            try await localizedSettle { labels(content).contains(settings.localizer.chat("Message number")) }
            #expect(field.currentEditor() === editor)
            #expect(editor.string == "2")
            #expect(editor.selectedRange() == NSRange(location: 1, length: 0))
            #expect(sheet.firstResponder === editor)
            #expect(labels(content).contains(settings.localizer.chat("Go")))
        }
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: sheet.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        sheet.sendEvent(enter)
        try await localizedSettle { hosted.window.sheets.isEmpty }
        #expect(navigation.scrollRequest?.messageID == store.messages[1].id)
        #expect(hosted.window.makeFirstResponder(map))
        // A language change did not replace the native key-view-loop participant.
        let next = NSTextField(frame: .zero)
        map.addSubview(next)
        map.nextKeyView = next
        let tab = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: hosted.window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        map.keyDown(with: tab)
        #expect(hosted.window.firstResponder !== map)
    }
}
}
