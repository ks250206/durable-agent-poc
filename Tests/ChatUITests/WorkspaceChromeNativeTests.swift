import AppKit
import AppLocalization
import ChatCore
@testable import ChatUI
import SwiftUI
import Testing

private let chromeFirst = ConversationID("chrome:first")
private let chromeSecond = ConversationID("chrome:second")
private let chromeTitle = "Readable architecture / 読みやすい設計 / 可读的设计 / 읽기 쉬운 설계 — " + String(repeating: "Long title ", count: 8)

private actor ChromeBackend: ChatBackend {
    private var state: ChatSnapshot
    private var observers: [UUID: AsyncThrowingStream<ChatEvent, any Error>.Continuation] = [:]
    private(set) var stops: [ConversationID] = []
    private(set) var creates = 0
    private var rejectSelection = false

    init(connection: ConnectionState = .connected, activity: ConversationActivity = .idle, empty: Bool = false, unloaded: Bool = false,
         runtimeIDs: [ConversationID]? = nil) {
        let first = ConversationSnapshot(summary: ConversationSummary(id: chromeFirst, title: chromeTitle), messages: [
            ChatMessage(id: MessageID("chrome:question"), conversationID: chromeFirst, role: .user,
                        content: "How should a readable conversation workspace behave?"),
            ChatMessage(id: MessageID("chrome:answer"), conversationID: chromeFirst, role: .assistant,
                        content: "## A clear place to think\n\nKeep the conversation readable, with a calm sidebar and a compact header.\n\n```swift\nlet conversation = store.selectedConversation\n```\n\n日本語・简体中文・한국어 titles remain verbatim.",
                        status: activity.isBusy ? .streaming : .complete)
        ], activity: activity)
        let second = ConversationSnapshot(summary: ConversationSummary(id: chromeSecond, title: "Café layout"))
        state = ChatSnapshot(connection: connection, conversations: empty ? [] : [first.summary, second.summary],
                             selectedConversationID: empty ? nil : chromeFirst,
                             loadedConversations: empty || unloaded ? [] : [first, second])
        if let runtimeIDs {
            let summaries = runtimeIDs.map { ConversationSummary(id: $0, title: "Same conversation title") }
            state = ChatSnapshot(connection: .connected, conversations: summaries, selectedConversationID: runtimeIDs.first,
                                 loadedConversations: summaries.map { ConversationSnapshot(summary: $0) })
        }
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
        guard state.connection.canSend else { throw ChatBackendError.demoReadOnly }
        creates += 1
        let summary = ConversationSummary(id: ConversationID("chrome:created:\(creates)"), title: title ?? "")
        state.conversations.append(summary)
        state.loadedConversations.append(ConversationSnapshot(summary: summary))
        state.selectedConversationID = summary.id
        publish()
        return summary.id
    }
    func selectConversation(_ id: ConversationID?) async throws {
        if rejectSelection { throw ChatBackendError.unavailable("Selection fixture failed") }
        state.selectedConversationID = id
        publish()
    }
    func send(_ request: SendRequest) async throws { throw ChatBackendError.unavailable("Unused fixture command") }
    func stop(conversationID: ConversationID) async throws {
        stops.append(conversationID)
        if let index = state.loadedConversations.firstIndex(where: { $0.id == conversationID }) {
            state.loadedConversations[index].activity = .idle
            state.loadedConversations[index].messages = state.loadedConversations[index].messages.map {
                var message = $0
                if message.status == .streaming { message.status = .stopped }
                return message
            }
        }
        publish()
    }
    func failSelections() { rejectSelection = true }
}

@MainActor private func chromeNodes(_ root: Any) -> [NSObject] {
    var seen = Set<ObjectIdentifier>()
    func walk(_ object: Any) -> [NSObject] {
        guard let node = object as? NSObject, seen.insert(ObjectIdentifier(node)).inserted else { return [] }
        let selector = NSSelectorFromString("accessibilityChildren")
        let children = node.responds(to: selector) ? (node.perform(selector)?.takeUnretainedValue() as? [Any] ?? []) : []
        return [node] + children.flatMap(walk) + ((node as? NSView)?.subviews ?? []).flatMap(walk)
    }
    return walk(root)
}

@MainActor private func chromeAttribute(_ node: NSObject, _ name: String) -> String? {
    let selector = NSSelectorFromString(name)
    guard node.responds(to: selector) else { return nil }
    return node.perform(selector)?.takeUnretainedValue() as? String
}

@MainActor private func chromeLabels(_ root: Any) -> [String] {
    chromeNodes(root).flatMap { node in
        ["accessibilityLabel", "accessibilityValue", "accessibilityTitle", "accessibilityHelp"].compactMap { chromeAttribute(node, $0) }
    }
}

@MainActor private func chromeDescendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
    (root as? T).map { [$0] } ?? root.subviews.flatMap { chromeDescendants($0, type) }
}

@MainActor private func chromePump() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005)) }

@MainActor private func chromeSettle(_ predicate: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now + .seconds(6)
    while !predicate(), ContinuousClock.now < deadline {
        chromePump()
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(predicate(), sourceLocation: sourceLocation)
}

@MainActor private final class ChromeHost {
    let view: NSHostingView<AnyView>
    let window: NSWindow
    init<V: View>(_ root: V, width: CGFloat, height: CGFloat = 760) {
        _ = NSApplication.shared
        view = NSHostingView(rootView: AnyView(root))
        view.sizingOptions = []
        window = NSWindow(contentRect: NSRect(x: -16000, y: -16000, width: width, height: height),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        window.makeKeyAndOrderFront(nil)
        view.layoutSubtreeIfNeeded()
    }
    func capture(_ name: String, content: NSView? = nil) throws {
        let target = content ?? view
        target.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try #require(target.bitmapImageRepForCachingDisplay(in: target.bounds))
        target.cacheDisplay(in: target.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        if let path = ProcessInfo.processInfo.environment["CHAT_UI_ARTIFACTS_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
        }
    }
    func click(_ id: String, in targetWindow: NSWindow? = nil) throws {
        let targetWindow = targetWindow ?? window
        let content = try #require(targetWindow.contentView)
        chromePump()
        content.layoutSubtreeIfNeeded()
        let nodes = chromeNodes(content)
        let node = try #require(nodes.first { chromeAttribute($0, "accessibilityIdentifier") == id })
        let rect = try #require(node.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        #expect(rect.width > 0 && rect.height > 0)
        let point = targetWindow.convertPoint(fromScreen: NSPoint(x: rect.midX, y: rect.midY))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            targetWindow.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: targetWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)))
        }
    }
}

extension NativeUITests {
@Suite @MainActor struct WorkspaceChromeNativeTests {
    @Test func searchFocusSelectionAndCreationUseNativeControlsAndRetainStateAcrossAppearanceAndLanguage() async throws {
        let backend = ChromeBackend()
        let store = ChatStore(backend: backend)
        let observation = Task { await store.start() }
        defer { observation.cancel() }
        try await chromeSettle { store.selectedConversationID == chromeFirst }
        let suite = "WorkspaceChrome.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = AppearanceSettings(defaults: defaults)
        let localization = LocalizationSettings(defaults: defaults, preferredLanguages: { ["en"] })
        let hosted = ChromeHost(ConversationSidebar(store: store).environment(appearance).environment(localization), width: 248)
        defer { hosted.window.close() }
        try await chromeSettle { chromeLabels(hosted.view).contains("Search conversations") }
        try hosted.click("chat.sidebar.search")
        let field = try #require(chromeDescendants(hosted.view, NSTextField.self).first { $0.isEditable })
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText("cafe", replacementRange: editor.selectedRange())
        try await chromeSettle { !chromeLabels(hosted.view).contains(chromeTitle) }
        #expect(store.selectedConversationID == chromeFirst)
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        for choice in [AppearanceChoice.dark, .light] {
            appearance.choice = choice
            for language in [LanguageChoice.japanese, .simplifiedChinese, .korean, .english] {
                localization.choice = language
                try await chromeSettle { chromeLabels(hosted.view).contains(localization.localizer.chat("Search conversations")) }
                #expect(field.currentEditor() === editor)
                #expect(hosted.window.firstResponder === editor)
                #expect(editor.string == "cafe")
                #expect(editor.selectedRange() == NSRange(location: 2, length: 0))
                #expect(store.selectedConversationID == chromeFirst)
            }
        }
        try hosted.capture("chrome-search-focused")
        try hosted.click("chat.sidebar.row.chrome:second")
        try await chromeSettle { store.selectedConversationID == chromeSecond }
        try hosted.click("chat.sidebar.create")
        try await chromeSettle { store.selectedConversationID == ConversationID("chrome:created:1") }
        #expect(await backend.creates == 1)
        try await chromeSettle { chromeLabels(hosted.view).contains(chromeTitle) } // successful creation clears search
        let commandN = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: hosted.window.windowNumber, context: nil,
            characters: "n", charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45))
        #expect(hosted.window.performKeyEquivalent(with: commandN))
        try await chromeSettle { store.selectedConversationID == ConversationID("chrome:created:2") }
        #expect(await backend.creates == 2)
        await backend.failSelections()
        try await Task.sleep(for: .milliseconds(100)) // commit the newly inserted row's native hit-test geometry
        try hosted.click("chat.sidebar.row.chrome:first")
        try await chromeSettle { store.lastFailure?.operation == "select" }
        try await chromeSettle { chromeLabels(hosted.view).contains("Selection fixture failed") }
        #expect(store.selectedConversationID == ConversationID("chrome:created:2"))
    }

    @Test func runtimeCaptionsDistinguishOtherwiseIdenticalConversationRows() async throws {
        let ids = ["pi:conversation:one", "cursor:conversation:two", "codex:conversation:three"].map { ConversationID($0) }
        let store = ChatStore(backend: ChromeBackend(runtimeIDs: ids))
        let observation = Task { await store.start() }
        defer { observation.cancel() }
        try await chromeSettle { store.conversations.count == 3 }
        let hosted = ChromeHost(ConversationSidebar(store: store), width: 248)
        defer { hosted.window.close() }
        for (id, runtime) in zip(ids, ["Pi", "Cursor", "Codex CLI"]) {
            try await chromeSettle {
                chromeNodes(hosted.view).contains {
                    chromeAttribute($0, "accessibilityIdentifier") == "chat.sidebar.row.\(id.rawValue)" &&
                    chromeAttribute($0, "accessibilityValue") == runtime
                }
            }
        }
    }

    @Test func escapeClosesNarrowDrawerWithFocusedNonemptyAndEmptySearch() async throws {
        let store = ChatStore(backend: ChromeBackend())
        let observation = Task { await store.start() }
        defer { observation.cancel() }
        try await chromeSettle { store.selectedConversationID == chromeFirst }
        let hosted = ChromeHost(ChatWorkspaceView(store: store, navigation: TranscriptNavigation()), width: 400)
        defer { hosted.window.close() }
        for query in ["cafe", ""] {
            try hosted.click("chat.workspace.sidebar")
            try await chromeSettle { !hosted.window.sheets.isEmpty }
            let sheet = try #require(hosted.window.sheets.first)
            try hosted.click("chat.sidebar.search", in: sheet)
            let content = try #require(sheet.contentView)
            let field = try #require(chromeDescendants(content, NSTextField.self).first { $0.isEditable })
            let editor = try #require(field.currentEditor() as? NSTextView)
            editor.insertText(query, replacementRange: editor.selectedRange())
            let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            #expect(sheet.performKeyEquivalent(with: escape))
            try await chromeSettle { hosted.window.sheets.isEmpty }
            #expect(store.selectedConversationID == chromeFirst)
        }
    }

    @Test func narrowSheetSelectsAndClosesThenStopTargetsTheActualBusyConversation() async throws {
        let backend = ChromeBackend(activity: .streaming)
        let store = ChatStore(backend: backend)
        let observation = Task { await store.start() }
        defer { observation.cancel() }
        try await chromeSettle { store.isSending }
        let hosted = ChromeHost(ChatWorkspaceView(store: store, navigation: TranscriptNavigation())
            .environment(\.locale, AppLanguage.english.locale), width: 400)
        defer { hosted.window.close() }
        try await chromeSettle { chromeLabels(hosted.view).contains("Stop response") }
        try hosted.click("chat.workspace.stop")
        try await chromeSettle { !store.isSending }
        #expect(await backend.stops == [chromeFirst])
        #expect(store.messages.last?.status == .stopped)
        try hosted.click("chat.workspace.sidebar")
        try await chromeSettle { !hosted.window.sheets.isEmpty }
        let sheet = try #require(hosted.window.sheets.first)
        let content = try #require(sheet.contentView)
        try await chromeSettle { chromeLabels(content).contains("Café layout") }
        #expect(content.frame.width <= 400)
        try hosted.capture("chrome-400-sidebar-sheet", content: content)
        try hosted.click("chat.sidebar.row.chrome:second", in: sheet)
        try await chromeSettle { hosted.window.sheets.isEmpty && store.selectedConversationID == chromeSecond }
        #expect(await backend.stops == [chromeFirst])
    }

    @Test func narrowSidebarSheetsKeepExplicitLocaleAndSchemeAndLegacyShellKeepsItsSlots() async throws {
        let store = ChatStore(backend: ChromeBackend())
        let observation = Task { await store.start() }
        defer { observation.cancel() }
        try await chromeSettle { store.selectedConversationID == chromeFirst }
        for language in AppLanguage.allCases {
            let localizer = Localizer(language: language)
            for scheme in [ColorScheme.light, .dark] {
                let shell = ChatShellView(store: store, navigation: TranscriptNavigation()) { ComposerView(store: $0) }
                    minimap: { _, _ in EmptyView() }
                    .environment(\.locale, language.locale).environment(\.colorScheme, scheme)
                let hosted = ChromeHost(shell, width: 400)
                hosted.window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                defer { hosted.window.close() }
                try await chromeSettle { chromeLabels(hosted.view).contains(localizer.chat("Message")) }
                #expect(hosted.view.frame.width == 400)
                try hosted.click("chat.workspace.sidebar")
                try await chromeSettle { !hosted.window.sheets.isEmpty }
                let sheet = try #require(hosted.window.sheets.first)
                let content = try #require(sheet.contentView)
                try await chromeSettle { chromeLabels(content).contains(localizer.chat("Search conversations")) }
                #expect(chromeLabels(content).contains(localizer.chat("New conversation")))
                #expect(chromeLabels(content).contains(localizer.chat("Done")))
                try hosted.capture("chrome-sheet-\(language.resourceIdentifier)-400-\(scheme)", content: content)
                try hosted.click("chat.sidebar.row.chrome:second", in: sheet)
                try await chromeSettle { hosted.window.sheets.isEmpty && store.selectedConversationID == chromeSecond }
                await store.selectConversation(chromeFirst)
                try await chromeSettle { store.selectedConversationID == chromeFirst }
            }
        }
    }

    @Test func longTitlesAndAllOperationalStatesRenderFourLanguagesAt400And1200InLightAndDark() async throws {
        let cases: [(String, ConnectionState, ConversationActivity, Bool, Bool, String)] = [
            ("long", .connected, .idle, false, false, "Selected model"),
            ("empty", .disconnected, .idle, true, false, "Connect a provider in Settings to send messages."),
            ("loading", .connecting, .idle, false, true, "Conversation not loaded"),
            ("failed", .failed("Connection fixture failed"), .failed("Response fixture failed"), false, false, "Connection failed"),
            ("busy", .connected, .streaming, false, false, "Responding…"),
            ("demo", .demo, .idle, false, false, "Demo · Read only"),
        ]
        for (name, connection, activity, empty, unloaded, key) in cases {
            let store = ChatStore(backend: ChromeBackend(connection: connection, activity: activity, empty: empty, unloaded: unloaded))
            let observation = Task { await store.start() }
            defer { observation.cancel() }
            try await chromeSettle { store.isObserving && store.connection == connection }
            store.modelSelection = ModelSelection(account: ProviderAccount(option: .apiKey, providerID: "fixture-provider"), modelID: "fixture-model-with-a-long-name")
            for language in AppLanguage.allCases {
                let localizer = Localizer(language: language)
                for scheme in [ColorScheme.light, .dark] {
                    for width in [CGFloat(400), 1200] {
                        let root = ChatWorkspaceView(store: store, navigation: TranscriptNavigation()) { ComposerView(store: $0) }
                            minimap: { _, _ in EmptyView() }
                            .environment(\.locale, language.locale).environment(\.colorScheme, scheme)
                        let hosted = ChromeHost(root, width: width)
                        hosted.window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                        defer { hosted.window.close() }
                        try await chromeSettle { chromeLabels(hosted.view).contains { $0.contains(localizer.chat(key)) } }
                        #expect(hosted.view.frame.width == width)
                        #expect(chromeDescendants(hosted.view, NSScrollView.self).allSatisfy { $0.frame.width <= width })
                        if name == "failed" {
                            #expect(chromeLabels(hosted.view).contains { $0.contains("Connection fixture failed") })
                            #expect(chromeLabels(hosted.view).contains("Response fixture failed"))
                        }
                        try hosted.capture("chrome-\(name)-\(language.resourceIdentifier)-\(Int(width))-\(scheme)")
                    }
                }
            }
            observation.cancel()
        }
    }
}
}
