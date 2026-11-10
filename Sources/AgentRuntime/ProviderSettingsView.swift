import AppLocalization
import ChatCore
import SwiftUI

// Explicit property wrapper for SDKs that also expose the SwiftUI State macro.
private typealias PiStoredState<Value> = SwiftUI.State<Value>

/// Native settings surface. AppSession injects the service and copies onSelection into ChatStore.modelSelection.
/// This view owns its authentication task and cancels it when dismissed.
@MainActor
public struct ProviderSettingsView: View {
    @Environment(LocalizationSettings.self) private var settings: LocalizationSettings?
    @Environment(\.locale) private var locale
    private var localization: Localizer { settings?.localizer ?? Localizer(locale: locale) }
    private func label(_ key: String, _ arguments: [String: LocalizationArgument] = [:]) -> String {
        localization.string(key, table: .runtime, arguments: arguments)
    }

    private let service: any ProviderSettingsService
    private let onSelection: @MainActor (ModelSelection?) -> Void
    @PiStoredState<[ProviderStatus]> private var statuses: [ProviderStatus] = []
    @PiStoredState<ProviderAccount?> private var account: ProviderAccount?
    @PiStoredState<String> private var apiKey = ""
    @PiStoredState<String> private var executablePath = ""
    @PiStoredState<String?> private var failure: String?
    @PiStoredState<Bool> private var working = false
    @PiStoredState<ProviderAccount?> private var signingIn: ProviderAccount?
    @PiStoredState<Task<Void, Never>?> private var operationTask: Task<Void, Never>?
    @PiStoredState<Task<Void, Never>?> private var loginTask: Task<Void, Never>?

    public init(service: any ProviderSettingsService, initialAccount: ProviderAccount? = nil,
                onSelection: @escaping @MainActor (ModelSelection?) -> Void = { _ in }) {
        self.service = service
        self.onSelection = onSelection
        _account = PiStoredState(initialValue: initialAccount)
    }

    public var body: some View {
        Form {
            Section(label("Provider")) {
                Picker(label("Account"), selection: $account) {
                    Text(label("Choose a provider")).tag(Optional<ProviderAccount>.none)
                    ForEach(statuses, id: \.configuration.account) { status in
                        Text(verbatim: "\((status.configuration.account.option == .apiKey ? label("API key") : status.configuration.account.option.displayName)) · \(status.configuration.account.providerID)")
                            .tag(Optional(status.configuration.account))
                    }
                }
                .disabled(working || signingIn != nil)
                if let status = current {
                    LabeledContent {
                        Text(verbatim: statusText(status)).fixedSize(horizontal: false, vertical: true)
                    } label: { Text(verbatim: label("Status")) }
                    if status.configuration.account.option == .apiKey {
                        SecureField(label("API key"), text: $apiKey)
                            .disabled(working)
                            .onSubmit { saveKey() }
                        HStack {
                            Button(label("Save API key")) { saveKey() }
                                .disabled(working || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button(label("Remove API key"), role: .destructive) {
                                operate { try await service.setAPIKey(nil, for: status.configuration.account) }
                            }.disabled(working)
                        }
                        Text(label("The key is stored in Keychain. Its value is never loaded into this field."))
                            .font(.caption).foregroundStyle(.secondary)
                    } else if status.configuration.account == CodexProviderSettingsService.account {
                        TextField(label("Codex CLI absolute path (blank: discover)"), text: $executablePath)
                            .accessibilityIdentifier("settings.codex-path")
                            .disabled(working)
                        Button(label("Save Codex CLI path")) { saveExecutable(status) }
                            .disabled(working).accessibilityIdentifier("settings.codex-save-path")
                        Text(label("Install the official Codex CLI, or enter its absolute executable path. Only use a trusted executable."))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(verbatim: label(CodexProviderSettingsService.loginInstructions))
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Text(label("This reuses your existing Codex CLI ChatGPT login, separately from Pi ChatGPT OAuth and Cursor. API-key CLI authentication is unsupported. Credentials remain owned by the official CLI."))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(label("Usage limits and remaining quota are unknown here; login detection does not guarantee model access or availability."))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(label("Refresh existing CLI login and models")) { operate {} }
                            .disabled(working).accessibilityIdentifier("settings.codex-refresh")
                    } else if status.configuration.account.option == .cursor {
                        TextField(label("Cursor CLI absolute path (blank: discover)"), text: $executablePath)
                            .disabled(working || signingIn != nil)
                        Button(label("Save CLI path")) {
                            saveExecutable(status)
                        }.disabled(working || signingIn != nil)
                        Text(verbatim: label(CursorProviderSettingsService.loginInstructions))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(label("Credentials remain in Cursor's official CLI store. Only use a trusted executable."))
                            .font(.caption).foregroundStyle(.secondary)
                        authenticationControls(status.configuration.account, title: "Sign in with Cursor")
                    } else if status.configuration.account.option == .chatGPT {
                        Text(label("ChatGPT subscription sign-in requires your interaction in the secure authentication session. It is separate from an OpenAI API key."))
                            .font(.caption).foregroundStyle(.secondary)
                        authenticationControls(status.configuration.account, title: "Sign in with ChatGPT")
                    }
                    Picker(label("Model"), selection: Binding(
                        get: { current?.configuration.selectedModelID },
                        set: { model in chooseModel(model) }
                    )) {
                        Text(label("Choose a model")).tag(Optional<String>.none)
                        if let selected = status.configuration.selectedModelID,
                           !status.models.contains(where: { $0.id.modelID == selected }) {
                            Text(verbatim: label("Unavailable: {model}", ["model": .string(selected)])).tag(Optional(selected))
                        }
                        ForEach(status.models) { model in
                            Text(verbatim: model.displayName).tag(Optional(model.id.modelID))
                        }
                    }.disabled(working || signingIn != nil)
                    Button(label("Use selected model")) {
                        publishSelection()
                    }.disabled(working || signingIn != nil || status.authentication != .configured
                               || !status.models.contains(where: { $0.id.modelID == status.configuration.selectedModelID }))
                    if status.models.isEmpty {
                        Text(label("This provider has no available models.")).foregroundStyle(.secondary)
                    }
                }
            }
            if let failure {
                Section {
                    let message = RuntimePresentation.diagnostic(failure, localizer: localization)
                    Text(verbatim: message).foregroundStyle(.red)
                        .accessibilityLabel(label("Settings error: {message}", ["message": .string(message)]))
                }
            }
            Button(label("Disable sending (clear active model)")) { onSelection(nil) }
                .disabled(working || signingIn != nil)
            Button(label("Refresh provider state")) { operate {} }.disabled(working || signingIn != nil)
        }
        .formStyle(.grouped)
        .frame(minWidth: 360, minHeight: 360)
        .task { await refresh() }
        .onChange(of: account) { _, _ in
            apiKey = ""
            failure = nil
            executablePath = current?.configuration.executablePath ?? ""
        }
        .onDisappear {
            apiKey = ""
            operationTask?.cancel()
            cancelSignIn()
        }
    }

    @ViewBuilder private func authenticationControls(_ account: ProviderAccount, title: String) -> some View {
        HStack {
            if signingIn != nil {
                ProgressView().controlSize(.small)
                Button(label("Cancel sign-in")) { cancelSignIn() }
            } else {
                Button(label(title)) { signIn(account) }
                Button(label("Sign out")) { operate { try await service.logout(from: account) } }
            }
        }.disabled(working)
    }

    private var current: ProviderStatus? { statuses.first { $0.configuration.account == account } }
    private func statusText(_ status: ProviderStatus) -> String {
        let state = status.authentication
        if status.configuration.account == CodexProviderSettingsService.account, state == .configured {
            return label("Existing CLI ChatGPT login detected")
        }
        if signingIn == account { return label("Signing in…") }
        switch state {
        case .unconfigured: return label("Not configured")
        case .signedOut: return label("Signed out")
        case .signingIn: return label("Signing in…")
        case .configured: return label("Configured")
        case .unavailable(let message), .failed(let message): return RuntimePresentation.diagnostic(message, localizer: localization)
        }
    }
    private func publishSelection() {
        guard let account else { return }
        let active = statuses.first { $0.configuration.account == account }
        guard let current = active, current.authentication == .configured,
              let modelID = current.configuration.selectedModelID,
              current.models.contains(where: { $0.id.modelID == modelID }) else {
            return
        }
        onSelection(ModelSelection(account: current.configuration.account, modelID: modelID))
    }
    private func refresh() async {
        do {
            statuses = try await service.snapshot()
            if let account, !statuses.contains(where: { $0.configuration.account == account }) { self.account = nil }
            executablePath = current?.configuration.executablePath ?? ""
        } catch { failure = "Provider settings could not be loaded." }
    }
    private func operate(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        working = true
        failure = nil
        operationTask = Task { @MainActor in
            defer { working = false; operationTask = nil }
            do { try await operation() }
            catch is CancellationError { return }
            catch { failure = "The settings operation failed. Check the provider and try again." }
            await refresh()
        }
    }
    private func saveExecutable(_ status: ProviderStatus) {
        var configuration = status.configuration
        let path = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.executablePath = path.isEmpty ? nil : path
        let saved = configuration
        operate { try await service.update(saved) }
    }
    private func saveKey() {
        guard let account, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let key = apiKey
        apiKey = ""
        operate { try await service.setAPIKey(key, for: account) }
    }
    private func chooseModel(_ modelID: String?) {
        guard var configuration = current?.configuration else { return }
        configuration.selectedModelID = modelID
        let selected = configuration
        operate { try await service.update(selected) }
    }
    private func signIn(_ account: ProviderAccount) {
        guard loginTask == nil else { return }
        signingIn = account
        failure = nil
        loginTask = Task { @MainActor in
            defer { signingIn = nil; loginTask = nil }
            do { try await service.login(to: account) }
            catch is CancellationError { }
            catch { failure = "Sign-in failed. Try again." }
            await refresh()
        }
    }
    private func cancelSignIn() {
        guard let signingIn else { return }
        loginTask?.cancel()
        Task { await service.cancelLogin(to: signingIn) }
    }
}
