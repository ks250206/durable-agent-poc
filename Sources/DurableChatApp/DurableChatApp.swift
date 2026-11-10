import AgentRuntime
import ChatCore
import ChatUI
import SwiftUI

// Explicit alias selects the macOS 14-compatible State property wrapper, including on SDKs
// that also declare a State macro whose plugin is not shipped in Command Line Tools.
private typealias StoredState<Value> = SwiftUI.State<Value>

@main
@MainActor
struct DurableChatApp: App {
    @StoredState<ChatStore> private var store: ChatStore
    @StoredState<TranscriptNavigation> private var navigation = TranscriptNavigation()

    init() {
        let mode = ShellLaunchMode(arguments: ProcessInfo.processInfo.arguments)
        _store = State(initialValue: ChatStore(backend: ShellChatBackend(mode: mode)))
    }

    var body: some Scene {
        Window("DurableChat", id: "main") {
            ChatShellView(store: store, navigation: navigation)
                .task { await store.start() }
        }
        // #7 supplies ProviderSettingsView; #9 injects its ProviderSettingsService here.
        Settings {
            VStack(alignment: .leading, spacing: 12) {
                Text("Providers").font(.headline)
                ForEach(ProviderOption.allCases) { option in Text(option.displayName) }
                Text("Provider configuration will be connected by the runtime integration.")
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(width: 400)
        }
    }
}
