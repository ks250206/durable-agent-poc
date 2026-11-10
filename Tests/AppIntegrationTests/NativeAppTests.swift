import AgentRuntime
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
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
    }
    func close() { window.close() }
    func descendants<T: NSView>(_ type: T.Type) -> [T] {
        func find(_ view: NSView) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap(find) }
        return find(host)
    }
    func capture(_ name: String) throws {
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
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
