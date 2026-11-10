import AppKit
import AppLocalization
import SwiftUI

private typealias StoredState<Value> = SwiftUI.State<Value>

@main
@MainActor
struct DurableChatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StoredState private var session = AppSession()

    var body: some Scene {
        Window("DurableChat", id: "main") {
            NativeWorkspaceView(session: session)
                .frame(idealWidth: 1180, idealHeight: 800)
                .task {
                    delegate.session = session
                    await session.start()
                }
        }
        .environment(session.localization)
        .environment(\.locale, session.localization.locale)
        .commands { LocalizedAppCommands(localization: session.localization) }
        Settings { NativeSettingsView(session: session) }
            .environment(session.localization)
            .environment(\.locale, session.localization.locale)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var session: AppSession?
    func applicationDidBecomeActive(_ notification: Notification) { session?.refreshSystemLanguage() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(self, selector: #selector(localeDidChange),
            name: NSLocale.currentLocaleDidChangeNotification, object: nil)
    }
    @objc private func localeDidChange(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.session?.refreshSystemLanguage() }
    }
    private var terminating = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task { @MainActor in
            await session?.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor
private struct LocalizedAppCommands: Commands {
    let localization: LocalizationSettings
    @Environment(\.openSettings) private var openSettings
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(localization.string("Settings…", table: .app)) { openSettings() }
                .keyboardShortcut(",")
        }
        CommandGroup(replacing: .appTermination) {
            Button(localization.string("Quit DurableChat", table: .app)) { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
