import AgentRuntime
import ChatCore
import ChatUI
import SwiftUI

@MainActor
struct NativeWorkspaceView: View {
    let session: AppSession
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            if session.mode != .live {
                Text(session.mode == .demo ? "DEMO • deterministic, read-only sample data" : "ISOLATED TEST RUNTIME • SIMULATED responses • temporary history • no AI calls")
                    .font(.caption.bold()).frame(maxWidth: .infinity).padding(8).background(.yellow.opacity(0.18))
            }
            if let store = session.store {
                if session.mode != .demo {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.routingNotice ?? "Ready. Only an explicit Send starts a model request.")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if store.modelSelection?.account == CodexProviderSettingsService.account {
                                Text("Codex CLI · existing ChatGPT login · usage limits unknown")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("app.codex-route")
                            }
                        }
                        Spacer(minLength: 12)
                        Button("Settings…") { openSettings() }
                            .accessibilityIdentifier("app.open-settings")
                    }.padding(12)
                    Divider()
                }
                ChatWorkspaceView(store: store, navigation: session.navigation) {
                    ComposerView(store: $0)
                } minimap: {
                    ConversationMinimap(store: $0, navigation: $1)
                }
            } else if session.failure == nil {
                ProgressView("Opening saved workspace…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let failure = session.failure {
                HStack {
                    Text(failure).foregroundStyle(.red).textSelection(.enabled)
                    Button("Dismiss") { session.dismissFailure() }
                }.padding()
            }
        }
        .frame(minWidth: 360, minHeight: 500)
        .background(.background)
    }
}

@MainActor
struct NativeSettingsView: View {
    let session: AppSession
    var body: some View {
        if let service = session.settings {
            ProviderSettingsView(service: service, initialAccount: session.store?.modelSelection?.account) { selection in
                Task { await session.useModel(selection) }
            }
        } else {
            Text(session.mode == .demo ? "Demo is read-only. Relaunch without --demo to configure providers." : "Provider settings will be available after the workspace opens.")
                .padding(24).frame(width: 480)
        }
    }
}
