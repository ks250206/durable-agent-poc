import AgentRuntime
import AppLocalization
import ChatCore
import ChatUI
import SwiftUI

@MainActor
struct NativeWorkspaceView: View {
    let session: AppSession
    private var localization: LocalizationSettings { session.localization }
    private func label(_ key: String) -> String { localization.string(key, table: .app) }
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            if session.mode != .live {
                Text(verbatim: label(session.mode == .demo ? "DEMO • deterministic, read-only sample data" : "ISOLATED TEST RUNTIME • SIMULATED responses • temporary history • no AI calls"))
                    .font(.caption.bold()).frame(maxWidth: .infinity).padding(8).background(.yellow.opacity(0.18))
            }
            if let store = session.store {
                if session.mode != .demo {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: store.routingNotice.map { RuntimePresentation.diagnostic($0, localizer: localization.localizer) } ?? label("Ready. Only an explicit Send starts a model request."))
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if store.modelSelection?.account == CodexProviderSettingsService.account {
                                Text(verbatim: label("Codex CLI · existing ChatGPT login · usage limits unknown"))
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("app.codex-route")
                            }
                        }
                        Spacer(minLength: 12)
                        Button(label("Settings…")) { openSettings() }
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
                ProgressView(label("Opening saved workspace…")).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let failure = session.failure {
                HStack {
                    Text(verbatim: localization.diagnostic(failure, table: .app)).foregroundStyle(.red).textSelection(.enabled)
                    Button(label("Dismiss")) { session.dismissFailure() }
                }.padding()
            }
        }
        .frame(minWidth: 360, minHeight: 500)
        .background(.background)
        .appAppearance(session.appearance)
        .environment(localization)
        .environment(\.locale, localization.locale)
        .environment(\.chatDiagnosticTemplates, RuntimePresentation.diagnosticTemplates)
    }
}

@MainActor
struct NativeSettingsView: View {
    let session: AppSession
    private var localization: LocalizationSettings { session.localization }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                LanguagePickerView(localization: localization)
                    .accessibilityIdentifier("settings.language")
                Button(localization.string("Reset to System")) { localization.resetToSystem() }
                    .accessibilityIdentifier("settings.reset-language")
            }.padding()
            AppearancePickerView(settings: session.appearance, localizer: localization.localizer)
                .accessibilityIdentifier("settings.appearance")
                .padding()
            Divider()
            if let service = session.settings {
                ProviderSettingsView(service: service, initialAccount: session.store?.modelSelection?.account) { selection in
                    Task { await session.useModel(selection) }
                }
            } else {
                Text(verbatim: localization.string(session.mode == .demo
                    ? "Demo is read-only. Relaunch without --demo to configure providers."
                    : "Provider settings will be available after the workspace opens.", table: .app))
                    .padding(24).frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 360, idealWidth: 600, maxWidth: .infinity,
               minHeight: 420, maxHeight: .infinity, alignment: .top)
        .background(.background)
        .appAppearance(session.appearance)
        .environment(localization)
        .environment(\.locale, localization.locale)
    }
}
