import AgentRuntime
import AppKit
import ChatCore
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
