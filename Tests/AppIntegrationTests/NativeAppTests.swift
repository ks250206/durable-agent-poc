import AgentRuntime
import AppLocalization
import AppKit
import ChatCore
import Darwin
import SwiftUI
import Testing
@testable import ChatUI
@testable import DurableChatApp

@MainActor
private func eventually(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(condition(), sourceLocation: sourceLocation)
}

@MainActor
private final class HostedApp {
    let host: NSHostingView<AnyView>
    let window: NSWindow
    init<V: View>(_ view: V, width: CGFloat, height: CGFloat = 800) {
        _ = NSApplication.shared
        host = NSHostingView(rootView: AnyView(view))
        host.sizingOptions = []
        window = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: width, height: height),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
    }
    func close() { window.close() }
    func descendants<T: NSView>(_ type: T.Type) -> [T] {
        func find(_ view: NSView) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap(find) }
        return find(host)
    }
    func capture(_ name: String) throws {
        pumpAppLoop()
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); window.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        if let path = ProcessInfo.processInfo.environment["CHAT_UI_ARTIFACTS_DIR"] {
            let root = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("\(name).png"))
        }
    }
}

/// Real NSHostingView composition and AppKit events; not a physical IME or signed-in-provider test.
@Suite(.serialized) @MainActor
struct NativeAppTests {
    @Test func fullCompositionSendStopSwitchMinimapAndSettingsBrowsingPreservesExplicitModel() async throws {
        let session = AppSession(arguments: ["DurableChat", "--test-runtime"])
        await session.start()
        let store = try #require(session.store)
        try await eventually { store.canSend }
        let root = try #require(session.testDirectory)
        #expect(root.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        let origin = try #require(store.selectedConversationID)
        let piModel = try #require(store.modelSelection)
        #expect(piModel.account.providerID == "faux")
        let hosted = HostedApp(NativeWorkspaceView(session: session), width: 1200)
        defer { hosted.close() }
        try await eventually { !hosted.descendants(CompositionNSTextView.self).isEmpty }
        let editor = try #require(hosted.descendants(CompositionNSTextView.self).first)
        #expect(hosted.window.makeFirstResponder(editor))
        editor.insertText("isolated native composer submission", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await eventually { store.draft == editor.string }
        editor.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: hosted.window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)))
        try await eventually { store.messages.contains { $0.role == .user } && store.isSending }
        try await eventually { store.messages.contains { $0.role == .assistant && !$0.content.isEmpty } }
        #expect(store.messages.first?.content == "isolated native composer submission")
        try hosted.capture("app-composed-simulated-streaming")
        // A browsed settings account, including its persisted model, must not apply itself on refresh.
        var implicitSelections: [ModelSelection?] = []
        let browse = HostedApp(ProviderSettingsView(service: try #require(session.settings),
            initialAccount: CursorProviderSettingsService.account) { implicitSelections.append($0) }, width: 680)
        try await Task.sleep(for: .milliseconds(200))
        browse.close()
        #expect(implicitSelections.isEmpty)
        #expect(store.modelSelection == piModel && store.selectedConversationID == origin)
        let cursorHistory = ConversationID("cursor:conversation:simulated-history")
        await store.selectConversation(cursorHistory)
        try await eventually { store.selectedConversationID == cursorHistory && store.messages.count == 48 }
        #expect(store.modelSelection == nil) // No implicit model inferred from a browsed account's preferences.
        await store.stop(conversationID: origin)
        try await eventually { store.loadedConversations[origin]?.activity == .idle }
        #expect(store.messages.allSatisfy { $0.conversationID == cursorHistory })
        #expect(store.loadedConversations[origin]?.messages.last?.status == .stopped)
        try await eventually { session.navigation.viewport.lastVisibleMessageID == store.messages.last?.id }
        let target = store.messages[7].id
        session.navigation.jump(to: target)
        try await eventually { session.navigation.viewport.firstVisibleMessageID == target }
        #expect(session.navigation.viewport.lastVisibleMessageID != nil)
        try hosted.capture("app-composed-cursor-minimap-jump")

        let cursorModel = ModelSelection(account: CursorProviderSettingsService.account, modelID: "simulated-cursor")
        await session.useModel(cursorModel)
        try await eventually { store.modelSelection == cursorModel && store.canSend }
        let settingsHost = HostedApp(NativeSettingsView(session: session), width: 680)
        try await Task.sleep(for: .milliseconds(200))
        try settingsHost.capture("app-provider-settings-cursor")
        settingsHost.close()
        #expect(store.modelSelection == cursorModel)
        _ = try await session.settings?.snapshot()
        #expect(store.modelSelection == cursorModel)
        // Real CursorProcess with local executable, no production CLI or credential store.
        #expect(await store.send("isolated Cursor send"))
        try await eventually { store.isSending }
        await store.stop(conversationID: cursorHistory)
        try await eventually { !store.isSending }
        #expect(store.messages.last?.status == .stopped)
        await store.selectConversation(origin)
        try await eventually { store.modelSelection == piModel && store.selectedConversationID == origin }
        // Selection is committed before SwiftUI runs the transcript/minimap onChange reset.
        try await eventually { session.navigation.scrollRequest == nil }
        await session.shutdown()
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func completeAppAndSettingsHostAtDesktopAnd400InBothAppearances() async throws {
        let session = AppSession(arguments: ["DurableChat", "--test-runtime"])
        await session.start()
        let store = try #require(session.store)
        try await eventually { store.canSend }
        for scheme in [ColorScheme.light, .dark] {
            for width: CGFloat in [400, 1200] {
                let hosted = HostedApp(NativeWorkspaceView(session: session).environment(\.colorScheme, scheme), width: width)
                try await Task.sleep(for: .milliseconds(100))
                try hosted.capture("app-full-\(Int(width))-\(scheme)")
                #expect(hosted.host.frame.width == width)
                #expect(hosted.descendants(CompositionNSTextView.self).count == 1)
                hosted.close()
            }
        }
        let settingsHost = HostedApp(NativeSettingsView(session: session), width: 680)
        try await Task.sleep(for: .milliseconds(100))
        try settingsHost.capture("app-provider-settings-pi")
        settingsHost.close()
        await session.shutdown()
    }

    @Test func explicitDemoNeverInitializesProvidersOrAllowsSending() async throws {
        let session = AppSession(arguments: ["DurableChat", "--demo"])
        await session.start()
        let store = try #require(session.store)
        try await eventually { store.connection == .demo }
        #expect(session.settings == nil && session.testDirectory == nil)
        #expect(!store.canSend && store.messages.count == 2)
        let hosted = HostedApp(NativeWorkspaceView(session: session), width: 1200)
        try hosted.capture("app-demo-read-only")
        hosted.close()
        await session.shutdown()
    }

    @Test func quittingCancelsAnOpeningIsolatedRuntimeAndReleasesStorage() async throws {
        let session = AppSession(arguments: ["DurableChat", "--test-runtime"])
        let startup = Task { await session.start() }
        await Task.yield()
        await session.shutdown()
        await startup.value
        if let root = session.testDirectory { #expect(!FileManager.default.fileExists(atPath: root.path)) }
        #expect(session.settings == nil)
    }
}

private func fixtureCalls(_ root: URL) throws -> [[String: Any]] {
    let url = root.appendingPathComponent("Codex/fixture-calls.jsonl")
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
        try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
}

extension NativeAppTests {
    @Test func codexSettingsExplicitSelectionSendStopAndDurableReopen() async throws {
        let session = AppSession(arguments: ["DurableChat", "--test-runtime"])
        await session.start()
        let store = try #require(session.store), settings = try #require(session.settings)
        try await eventually { store.canSend }
        let root = try #require(session.testDirectory)
        let statuses = try await settings.snapshot()
        let status = try #require(statuses.first { $0.configuration.account == CodexProviderSettingsService.account })
        #expect(status.configuration.selectedModelID == nil && status.authentication == .configured)
        #expect(status.models.map(\.id.modelID) == ["simulated-codex"])
        await #expect(throws: (any Error).self) {
            try await settings.update(ProviderConfiguration(account: CodexProviderSettingsService.account,
                executablePath: "/usr/bin/false"))
        }
        await #expect(throws: (any Error).self) {
            try await settings.update(ProviderConfiguration(account: CodexProviderSettingsService.account))
        }
        let original = store.modelSelection
        var selections: [ModelSelection?] = []
        let browse = HostedApp(ProviderSettingsView(service: settings, initialAccount: CodexProviderSettingsService.account) { selections.append($0) }, width: 680, height: 900)
        try await Task.sleep(for: .milliseconds(300))
        try browse.capture("app-provider-settings-codex-unselected")
        browse.close()
        #expect(selections.isEmpty && store.modelSelection == original)
        let model = try #require(status.models.first?.id)
        var configuration = status.configuration; configuration.selectedModelID = model.modelID
        try await settings.update(configuration)
        #expect(store.modelSelection == original) // A persisted settings picker choice does not apply itself.
        await session.useModel(model)
        try await eventually { store.modelSelection == model && store.selectedConversationID == nil }
        let origin = try #require(await store.createConversation(title: "Simulated Codex • native integration"))
        try await eventually { store.canSend }
        let hosted = HostedApp(NativeWorkspaceView(session: session), width: 1200)
        defer { hosted.close() }
        try await eventually { !hosted.descendants(CompositionNSTextView.self).isEmpty }
        let editor = try #require(hosted.descendants(CompositionNSTextView.self).first)
        #expect(hosted.window.makeFirstResponder(editor))
        editor.insertText("isolated native Codex submission", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await eventually { store.draft == editor.string }
        editor.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: hosted.window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)))
        try await eventually { store.messages.last?.role == .assistant && store.messages.last?.content.contains("SIMULATED Codex") == true }
        try hosted.capture("app-codex-simulated-streaming")
        let cursor = ConversationID("cursor:conversation:simulated-history")
        await store.selectConversation(cursor)
        try await eventually { store.selectedConversationID == cursor }
        await store.stop(conversationID: origin)
        try await eventually { store.loadedConversations[origin]?.activity == .idle }
        let stopped = try #require(store.loadedConversations[origin])
        #expect(stopped.messages.last?.status == .stopped)
        #expect(stopped.messages.allSatisfy { !$0.content.contains("LATE AFTER STOP") })
        #expect(store.messages.count == 48 && store.selectedConversationID == cursor)
        await store.selectConversation(origin)
        try await eventually { store.modelSelection == model && store.canSend }
        #expect(await store.send("fixture-complete"))
        try await eventually { !store.isSending && store.messages.count == 4 }
        let savedMessages = store.messages
        let settingsHost = HostedApp(NativeSettingsView(session: session), width: 680, height: 900)
        try await Task.sleep(for: .milliseconds(200))
        try settingsHost.capture("app-provider-settings-codex-selected")
        settingsHost.close()
        #expect(store.modelSelection == model)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("DurableChat-Reopen-\(UUID())")
        try FileManager.default.copyItem(at: root, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let calls = try fixtureCalls(root)
        await session.shutdown()
        #expect(!FileManager.default.fileExists(atPath: root.path))
        for call in calls where ["launch", "owned-child"].contains(call["method"] as? String ?? "") {
            #expect(kill(try #require(call["pid"] as? Int32), 0) != 0)
        }
        let reopened = AppSession(arguments: ["DurableChat", "--test-runtime"], isolatedDirectory: copy)
        await reopened.start()
        let restored = try #require(reopened.store)
        try await eventually { restored.selectedConversationID == origin && restored.canSend }
        #expect(restored.modelSelection == model && restored.messages == savedMessages)
        let reopenedHost = HostedApp(NativeWorkspaceView(session: reopened), width: 400)
        try await Task.sleep(for: .milliseconds(100)); try reopenedHost.capture("app-codex-reopened-400")
        reopenedHost.close()
        #expect(await restored.send("fixture-complete"))
        try await eventually { !restored.isSending && restored.messages.count == 6 }
        #expect(try fixtureCalls(copy).filter { $0["method"] as? String == "thread/resume" }.count == 2)
        await reopened.shutdown()
    }

    @Test func codexStartupFailureNeverProbesAndReleasesLockWhileSessionLives() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DurableChat-Failed-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let corrupt = Data("invalid routing archive".utf8)
        try corrupt.write(to: root.appendingPathComponent("routing.json"))
        let session = AppSession(arguments: ["DurableChat", "--test-runtime"], isolatedDirectory: root)
        await session.start()
        #expect(session.failure != nil && session.store == nil && session.settings == nil)
        #expect(try fixtureCalls(root).isEmpty)
        #expect(try Data(contentsOf: root.appendingPathComponent("routing.json")) == corrupt)
        let settings = try CodexProviderSettingsService(storageDirectory: root.appendingPathComponent("Codex"))
        let backend = try CodexChatBackend(storageDirectory: root.appendingPathComponent("Codex"), settings: settings)
        await backend.shutdown(); await settings.shutdown()
        await session.shutdown()
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func codexSettingsProbeIsCancelledOnEarlyShutdownWithoutPersonalCLI() async throws {
        let session = AppSession(arguments: ["DurableChat", "--test-runtime"])
        await session.start()
        let root = try #require(session.testDirectory), service = try #require(session.settings)
        try Data("preflight".utf8).write(to: root.appendingPathComponent("Codex/fixture-mode"))
        let refresh = Task { try await service.snapshot() }
        try await eventually { FileManager.default.fileExists(atPath: root.appendingPathComponent("Codex/fixture-probing").path) }
        let calls = try fixtureCalls(root)
        await session.shutdown()
        await #expect(throws: (any Error).self) { _ = try await refresh.value }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        for call in calls where call["method"] as? String == "launch" {
            #expect(kill(try #require(call["pid"] as? Int32), 0) != 0)
        }
    }
}

@MainActor private func appAXLabels(_ root: Any) -> [String] {
    var seen = Set<ObjectIdentifier>()
    func walk(_ object: Any) -> [String] {
        guard let node = object as? NSObject, seen.insert(ObjectIdentifier(node)).inserted else { return [] }
        let labels = ["accessibilityLabel", "accessibilityValue", "accessibilityTitle", "accessibilityHelp"].compactMap { name -> String? in
            let selector = NSSelectorFromString(name)
            guard node.responds(to: selector) else { return nil }
            return node.perform(selector)?.takeUnretainedValue() as? String
        }
        let childrenSelector = NSSelectorFromString("accessibilityChildren")
        let children = node.responds(to: childrenSelector)
            ? (node.perform(childrenSelector)?.takeUnretainedValue() as? [Any] ?? []) : []
        return labels + children.flatMap(walk) + ((node as? NSView)?.subviews ?? []).flatMap(walk)
    }
    return walk(root)
}

@MainActor private func pumpAppLoop() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005)) }
@MainActor private func appLocalizedSettle(_ predicate: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !predicate(), ContinuousClock.now < deadline {
        pumpAppLoop()
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(predicate(), sourceLocation: sourceLocation)
}

private actor PresentationSettingsFixture: ProviderSettingsService {
    let status: ProviderStatus
    private(set) var snapshots = 0
    init(account: ProviderAccount, authentication: AuthenticationState) {
        status = ProviderStatus(configuration: ProviderConfiguration(account: account, selectedModelID: "raw-{model}-%n",
            executablePath: "/tmp/raw-{path}-%n"), authentication: authentication,
            models: [ChatModel(id: ModelSelection(account: account, modelID: "raw-{model}-%n"), displayName: "Raw Model 日本語 {name} %n")])
    }
    func snapshot() async throws -> [ProviderStatus] { snapshots += 1; return [status] }
    func update(_ configuration: ProviderConfiguration) async throws {}
    func setAPIKey(_ key: String?, for account: ProviderAccount) async throws {}
    func login(to account: ProviderAccount) async throws {}
    func cancelLogin(to account: ProviderAccount) async {}
    func logout(from account: ProviderAccount) async throws {}
}

extension NativeAppTests {
    @Test func appLanguageOwnerPersistsReopensRepairsResetsAndRefreshesWithoutGlobalPreferences() async throws {
        let name = "AppLanguageOwnership.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["untouched-system-sentinel"], forKey: "AppleLanguages")
        defaults.set("invalid-override", forKey: LocalizationSettings.defaultStorageKey)
        let preferences = AppLanguagePreferencesFixture()
        let localization = LocalizationSettings(defaults: defaults, preferredLanguages: { preferences.values })
        let session = AppSession(arguments: ["--demo"], localization: localization)
        #expect(session.localization === localization)
        #expect(localization.choice == .system && localization.language == .japanese)
        #expect(defaults.object(forKey: LocalizationSettings.defaultStorageKey) == nil)
        let delegate = AppDelegate(); delegate.session = session
        for choice in [LanguageChoice.japanese, .english, .simplifiedChinese, .korean] {
            localization.choice = choice
            let reopened = AppSession(arguments: ["--demo"], localization: LocalizationSettings(defaults: defaults, preferredLanguages: { ["ja"] }))
            #expect(reopened.localization.choice == choice)
            #expect(reopened.localization.language == choice.language)
            preferences.values = ["en"]
            delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
            #expect(localization.choice == choice && localization.language == choice.language)
            await reopened.shutdown()
        }
        preferences.values = ["ko-KR"]
        localization.resetToSystem()
        #expect(localization.language == .korean && defaults.object(forKey: LocalizationSettings.defaultStorageKey) == nil)
        preferences.values = ["zh-Hans"]
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        NotificationCenter.default.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        try await appLocalizedSettle { localization.language == .simplifiedChinese }
        #expect(localization.choice == .system)
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["untouched-system-sentinel"])
        await session.shutdown()
    }

    @Test func sharedAppLanguageChangesDuringCodexStreamingPreserveNativeCompositionOwnersAndCanonicalFailure() async throws {
        let session = AppSession(arguments: ["--test-runtime"])
        await session.start()
        let store = try #require(session.store), settings = try #require(session.settings)
        let navigation = session.navigation, localization = session.localization
        let status = try #require(try await settings.snapshot().first { $0.configuration.account == CodexProviderSettingsService.account })
        let model = try #require(status.models.first?.id)
        await session.useModel(model)
        try await eventually { store.modelSelection == model }
        let notice = try #require(store.routingNotice)
        let host = HostedApp(NativeWorkspaceView(session: session), width: 1200)
        defer { host.close() }
        for choice in [LanguageChoice.japanese, .english, .simplifiedChinese, .korean] {
            localization.choice = choice
            try await appLocalizedSettle { appAXLabels(host.host).contains(RuntimePresentation.diagnostic(notice, localizer: localization.localizer)) }
            #expect(store.routingNotice == notice && store.modelSelection == model && store.selectedConversationID == nil)
        }
        let origin = try #require(await store.createConversation(title: "User title 日本語 {name} %n"))
        try await eventually { store.canSend }
        #expect(await store.send("stream while changing language"))
        try await eventually { store.messages.last?.content.contains("SIMULATED Codex") == true && store.isSending }
        #expect(!(await store.send("rejected busy send")))
        let failure = try #require(store.visibleFailure)
        #expect(failure.message == "This conversation is busy.")
        store.draft = "draft / 日本語 {count} %n "
        try await appLocalizedSettle { host.descendants(CompositionNSTextView.self).first?.string == store.draft }
        let editor = try #require(host.descendants(CompositionNSTextView.self).first)
        #expect(host.window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 5, length: 3))
        editor.setMarkedText("にほん", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let text = editor.string, marked = editor.markedRange(), selection = editor.selectedRange(), draft = store.draft
        let messages = store.messages, viewport = navigation.viewport, request = navigation.scrollRequest
        for choice in [LanguageChoice.japanese, .english, .simplifiedChinese, .korean] {
            localization.choice = choice
            try await appLocalizedSettle { editor.accessibilityLabel() == localization.string("Message", table: .chatUI) }
            try await appLocalizedSettle { appAXLabels(host.host).contains(localization.diagnostic(failure.message)) }
            #expect(session.store === store && session.navigation === navigation && session.localization === localization)
            #expect(host.descendants(CompositionNSTextView.self).first === editor)
            #expect(host.window.firstResponder === editor)
            #expect(editor.string == text && editor.hasMarkedText() && editor.markedRange() == marked && editor.selectedRange() == selection)
            #expect(store.draft == draft && store.messages == messages && store.visibleFailure == failure)
            #expect(store.isSending && store.selectedConversationID == origin && store.modelSelection == model)
            #expect(navigation.viewport == viewport && navigation.scrollRequest?.id == request?.id)
        }
        editor.insertText("日本", replacementRange: editor.markedRange())
        try await appLocalizedSettle { store.draft == editor.string && !editor.hasMarkedText() }
        await store.stop(conversationID: origin)
        try await eventually { !store.isSending }
        #expect(store.messages.last?.status == .stopped && !store.messages.last!.content.contains("LATE AFTER STOP"))
        await session.shutdown()
    }

    @Test func appAndProviderSettingsShowFourLanguagesAt400And1200LightAndDarkWithoutApplyingModels() async throws {
        let session = AppSession(arguments: ["--test-runtime"])
        await session.start()
        let store = try #require(session.store)
        try await eventually { store.canSend }
        let original = store.modelSelection, origin = store.selectedConversationID
        let accounts: [ProviderAccount] = [ProviderAccount(option: .apiKey, providerID: "raw-api"),
            ProviderAccount(option: .chatGPT, providerID: "openai-codex"), CursorProviderSettingsService.account, CodexProviderSettingsService.account]
        for choice in [LanguageChoice.japanese, .english, .simplifiedChinese, .korean] {
            session.localization.choice = choice
            let localization = session.localization
            for scheme in [ColorScheme.light, .dark] {
                for width: CGFloat in [400, 1200] {
                    let host = HostedApp(NativeWorkspaceView(session: session).environment(\.colorScheme, scheme), width: width)
                    host.window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    try await appLocalizedSettle { appAXLabels(host.host).contains(localization.string("Settings…", table: .app)) }
                    #expect(host.host.frame.width == width)
                    try host.capture("issue23-workspace-\(localization.language.rawValue)-\(Int(width))-\(scheme)")
                    host.close()
                    let settings = HostedApp(NativeSettingsView(session: session).environment(\.colorScheme, scheme), width: width)
                    settings.window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    try await appLocalizedSettle {
                        appAXLabels(settings.host).contains(localization.string("Language")) &&
                        appAXLabels(settings.host).contains(localization.string("API key", table: .runtime) + " · faux")
                    }
                    #expect(settings.host.frame.width == width)
                    try settings.capture("issue23-settings-\(localization.language.rawValue)-\(Int(width))-\(scheme)")
                    settings.close()
                    for account in accounts {
                        let fixture = PresentationSettingsFixture(account: account, authentication: .configured)
                        var selections: [ModelSelection?] = []
                        let view = ProviderSettingsView(service: fixture, initialAccount: account) { selections.append($0) }
                            .environment(localization).environment(\.locale, localization.locale).environment(\.colorScheme, scheme)
                        let provider = HostedApp(view, width: width, height: 1000)
                        provider.window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                        try await appLocalizedSettle { appAXLabels(provider.host).contains(localization.string("Use selected model", table: .runtime)) }
                        if account == CodexProviderSettingsService.account {
                            #expect(appAXLabels(provider.host).contains(localization.string("Existing CLI ChatGPT login detected", table: .runtime)))
                            #expect(appAXLabels(provider.host).contains(localization.string(CodexProviderSettingsService.loginInstructions, table: .runtime)))
                        }
                        #expect(appAXLabels(provider.host).contains("Raw Model 日本語 {name} %n"))
                        #expect(provider.host.frame.width == width && provider.descendants(NSScrollView.self).allSatisfy { $0.frame.width <= width })
                        try provider.capture("issue23-provider-\(account.option.rawValue)-\(localization.language.rawValue)-\(Int(width))-\(scheme)")
                        provider.close()
                        #expect(selections.isEmpty)
                    }
                    #expect(store.modelSelection == original && store.selectedConversationID == origin)
                }
            }
        }
        await session.shutdown()
    }

    @Test func openAppStartupAndProviderFailuresRetranslateInPlaceAndUnknownStatusIsVerbatim() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DurableChat-LocalizedFailure-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("invalid archive".utf8).write(to: root.appendingPathComponent("routing.json"))
        let session = AppSession(arguments: ["--test-runtime"], isolatedDirectory: root)
        await session.start()
        let canonical = try #require(session.failure)
        let host = HostedApp(NativeWorkspaceView(session: session), width: 400)
        defer { host.close() }
        let account = CodexProviderSettingsService.account
        let source = "Codex CLI is using API-key authentication. Choose ChatGPT with codex login in Terminal, then refresh."
        let fixture = PresentationSettingsFixture(account: account, authentication: .unavailable(source))
        let provider = HostedApp(ProviderSettingsView(service: fixture, initialAccount: account)
            .environment(session.localization).environment(\.locale, session.localization.locale), width: 400, height: 1000)
        defer { provider.close() }
        for choice in [LanguageChoice.japanese, .english, .simplifiedChinese, .korean] {
            session.localization.choice = choice
            try await appLocalizedSettle { appAXLabels(host.host).contains(session.localization.diagnostic(canonical, table: .app)) }
            try await appLocalizedSettle { appAXLabels(provider.host).contains(session.localization.diagnostic(source)) }
            #expect(session.failure == canonical)
            try host.capture("issue23-startup-error-\(session.localization.language.rawValue)-400")
            try provider.capture("issue23-provider-error-\(session.localization.language.rawValue)-400")
        }
        #expect(await fixture.snapshots == 1) // Language changes never restart provider discovery.
        let unknown = "Provider-owned failure /path/{name} %n 日本語"
        let external = HostedApp(ProviderSettingsView(service: PresentationSettingsFixture(account: account, authentication: .failed(unknown)), initialAccount: account)
            .environment(session.localization), width: 400, height: 1000)
        defer { external.close() }
        try await appLocalizedSettle { appAXLabels(external.host).contains(unknown) }
        session.localization.choice = .japanese
        try await appLocalizedSettle { appAXLabels(external.host).contains(session.localization.string("Refresh provider state", table: .runtime)) }
        #expect(appAXLabels(external.host).contains(unknown))
        await session.shutdown()
    }
}

@MainActor private final class AppLanguagePreferencesFixture { var values = ["ja-JP"] }

extension NativeAppTests {
    @Test func allAuthenticationStatesAndOpenSettingsFailureUseCurrentLanguage() async throws {
        let session = AppSession(arguments: ["--demo"])
        let account = ProviderAccount(option: .chatGPT, providerID: "openai-codex")
        let states: [(AuthenticationState, String)] = [
            (.unconfigured, "Not configured"), (.signedOut, "Signed out"), (.signingIn, "Signing in…"),
            (.configured, "Configured"), (.failed("Sign-in failed. Try again."), "Sign-in failed. Try again."),
            (.unavailable(CursorRuntimeError.processFailed(123).localizedDescription), CursorRuntimeError.processFailed(123).localizedDescription),
        ]
        for choice in [LanguageChoice.japanese, .english, .simplifiedChinese, .korean] {
            session.localization.choice = choice
            for (state, key) in states {
                let host = HostedApp(ProviderSettingsView(service: PresentationSettingsFixture(account: account, authentication: state), initialAccount: account)
                    .environment(session.localization), width: 400, height: 1000)
                try await appLocalizedSettle { appAXLabels(host.host).contains(RuntimePresentation.diagnostic(key, localizer: session.localization.localizer)) }
                host.close()
            }
        }
        let failureHost = HostedApp(ProviderSettingsView(service: FailingPresentationSettingsFixture()).environment(session.localization), width: 400)
        defer { failureHost.close() }
        for choice in [LanguageChoice.japanese, .english, .simplifiedChinese, .korean] {
            session.localization.choice = choice
            let message = session.localization.diagnostic("Provider settings could not be loaded.")
            let accessible = session.localization.string("Settings error: {message}", table: .runtime, arguments: ["message": .string(message)])
            try await appLocalizedSettle { appAXLabels(failureHost.host).contains(accessible) }
        }
        await session.shutdown()
    }
}

private actor FailingPresentationSettingsFixture: ProviderSettingsService {
    func snapshot() async throws -> [ProviderStatus] { throw ChatBackendError.disconnected }
    func update(_ configuration: ProviderConfiguration) async throws {}
    func setAPIKey(_ key: String?, for account: ProviderAccount) async throws {}
    func login(to account: ProviderAccount) async throws {}
    func cancelLogin(to account: ProviderAccount) async {}
    func logout(from account: ProviderAccount) async throws {}
}

extension NativeAppTests {
    /// Final aggregate: a real fixture turn stopped in another account, then reopened with the
    /// same explicitly selected model and language. Locale changes must issue no extra CLI calls.
    @Test func finalFourLanguageCodexHistoryAndAccountIsolationWithLiveMinimap() async throws {
        for choice in [LanguageChoice.english, .japanese, .simplifiedChinese, .korean] {
            let suite = "DurableChat.FinalQA.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let localization = LocalizationSettings(defaults: defaults, preferredLanguages: { ["en"] })
            localization.choice = choice
            let session = AppSession(arguments: ["--test-runtime"], localization: localization)
            do {
                await session.start()
                let store = try #require(session.store), settings = try #require(session.settings)
                let root = try #require(session.testDirectory)
                let statuses = try await settings.snapshot()
                let status = try #require(statuses.first { $0.configuration.account == CodexProviderSettingsService.account })
                #expect(status.configuration.selectedModelID == nil && status.authentication == .configured)
                let model = try #require(status.models.first?.id)
                await session.useModel(model)
                try await eventually { store.modelSelection == model && store.selectedConversationID == nil }
                let origin = try #require(await store.createConversation(title: "Final QA 日本語 {count} %n"))
                try await eventually { store.canSend }
                #expect(await store.send("Final four-language fixture turn"))
                try await eventually { store.messages.last?.content.contains("SIMULATED Codex") == true }
                let cursor = ConversationID("cursor:conversation:simulated-history")
                await store.selectConversation(cursor)
                try await eventually { store.messages.count == 48 && store.selectedConversationID == cursor }
                #expect(store.modelSelection == nil && !store.canSend)
                let callsBefore = try fixtureCalls(root).count
                let host = HostedApp(NativeWorkspaceView(session: session), width: 1200)
                defer { host.close() }
                try await appLocalizedSettle { host.descendants(MinimapInputView.self).count == 1 }
                let map = try #require(host.descendants(MinimapInputView.self).first)
                #expect(map.accessibilityLabel() == localization.string("Full-history role overview", table: .chatUI))
                try await appLocalizedSettle { session.navigation.viewport.lastVisibleMessageID == store.messages.last?.id }
                #expect(host.window.makeFirstResponder(map))
                map.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: host.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 116)))
                try await appLocalizedSettle { session.navigation.scrollRequest != nil }
                let target = try #require(session.navigation.scrollRequest?.messageID)
                try await appLocalizedSettle { session.navigation.viewport.firstVisibleMessageID == target }
                let request = session.navigation.scrollRequest?.id
                localization.choice = choice == .english ? .japanese : .english
                try await appLocalizedSettle { map.accessibilityLabel() == localization.string("Full-history role overview", table: .chatUI) }
                localization.choice = choice
                try await appLocalizedSettle { map.accessibilityLabel() == localization.string("Full-history role overview", table: .chatUI) }
                #expect(host.descendants(MinimapInputView.self).first === map && host.window.firstResponder === map)
                #expect(session.navigation.scrollRequest?.id == request && store.selectedConversationID == cursor)
                #expect(try fixtureCalls(root).count == callsBefore) // Presentation never re-probes or starts a turn.
                await store.stop(conversationID: origin)
                try await eventually { store.loadedConversations[origin]?.activity == .idle }
                #expect(store.selectedConversationID == cursor && store.messages.count == 48)
                let stopped = try #require(store.loadedConversations[origin])
                #expect(stopped.messages.last?.status == .stopped)
                #expect(stopped.messages.allSatisfy { !$0.content.contains("LATE AFTER STOP") })
                try host.capture("issue24-minimap-origin-stop-\(localization.language.resourceIdentifier)-1200")
                host.close()
                await store.selectConversation(origin)
                try await eventually { store.canSend && store.modelSelection == model }
                let saved = store.messages
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent("DurableChat-FinalReopen-\(UUID())")
                try FileManager.default.copyItem(at: root, to: copy)
                defer { try? FileManager.default.removeItem(at: copy) }
                let calls = try fixtureCalls(root)
                await session.shutdown()
                #expect(!FileManager.default.fileExists(atPath: root.path))
                for call in calls where ["launch", "owned-child"].contains(call["method"] as? String ?? "") {
                    #expect(kill(try #require(call["pid"] as? Int32), 0) != 0)
                }
                let reopened = AppSession(arguments: ["--test-runtime"], isolatedDirectory: copy,
                    localization: LocalizationSettings(defaults: defaults, preferredLanguages: { ["ko"] }))
                await reopened.start()
                let restored = try #require(reopened.store)
                try await eventually { restored.selectedConversationID == origin && restored.canSend }
                #expect(reopened.localization.choice == choice && restored.messages == saved && restored.modelSelection == model)
                let narrow = HostedApp(NativeWorkspaceView(session: reopened), width: 400)
                try await appLocalizedSettle { appAXLabels(narrow.host).contains(reopened.localization.string("Response stopped", table: .chatUI)) }
                try narrow.capture("issue24-codex-language-reopen-\(reopened.localization.language.resourceIdentifier)-400")
                narrow.close()
                await reopened.shutdown()
                #expect(!FileManager.default.fileExists(atPath: copy.path))
            } catch {
                await session.shutdown()
                throw error
            }
        }
    }
}
