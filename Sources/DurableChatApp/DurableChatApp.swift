import AppKit
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
        Settings { NativeSettingsView(session: session) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var session: AppSession?
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
