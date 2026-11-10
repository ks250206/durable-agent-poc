import ChatCore
import SwiftUI

// Explicit property wrapper for SDKs that also expose the SwiftUI State macro.
private typealias PiStoredState<Value> = SwiftUI.State<Value>

/// Native settings surface. #9 injects the service and copies onSelection into ChatStore.modelSelection.
/// This view owns its authentication task and cancels it when dismissed.
@MainActor
public struct ProviderSettingsView: View {
    private let service: any ProviderSettingsService
    private let onSelection: @MainActor (ModelSelection?) -> Void
    @PiStoredState<[ProviderStatus]> private var statuses: [ProviderStatus] = []
    @PiStoredState<ProviderAccount?> private var account: ProviderAccount?
    @PiStoredState<ProviderAccount?> private var activeAccount: ProviderAccount?
    @PiStoredState<String> private var apiKey = ""
    @PiStoredState<String?> private var failure: String?
    @PiStoredState<Bool> private var working = false
    @PiStoredState<ProviderAccount?> private var signingIn: ProviderAccount?
    @PiStoredState<Task<Void, Never>?> private var loginTask: Task<Void, Never>?

    public init(service: any ProviderSettingsService, initialAccount: ProviderAccount? = nil,
                onSelection: @escaping @MainActor (ModelSelection?) -> Void = { _ in }) {
        self.service = service
        self.onSelection = onSelection
        _account = PiStoredState(initialValue: initialAccount)
        _activeAccount = PiStoredState(initialValue: initialAccount)
    }

    public var body: some View {
        Form {
            Section("Provider") {
                Picker("Account", selection: $account) {
                    Text("Choose a provider").tag(Optional<ProviderAccount>.none)
                    ForEach(statuses, id: \.configuration.account) { status in
                        Text("\(status.configuration.account.option.displayName) · \(status.configuration.account.providerID)")
                            .tag(Optional(status.configuration.account))
                    }
                }
                .disabled(working || signingIn != nil)
                if let status = current {
                    LabeledContent("Status", value: statusText(status.authentication))
                    if status.configuration.account.option == .apiKey {
                        SecureField("API key", text: $apiKey)
                            .disabled(working)
                            .onSubmit { saveKey() }
                        HStack {
                            Button("Save API key") { saveKey() }
                                .disabled(working || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("Remove API key", role: .destructive) {
                                operate { try await service.setAPIKey(nil, for: status.configuration.account) }
                            }.disabled(working)
                        }
                        Text("The key is stored in Keychain. Its value is never loaded into this field.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if status.configuration.account.option == .chatGPT {
                        Text("ChatGPT subscription sign-in requires your interaction in the secure authentication session. It is separate from an OpenAI API key.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            if signingIn != nil {
                                ProgressView().controlSize(.small)
                                Button("Cancel sign-in") { cancelSignIn() }
                            } else {
                                Button("Sign in with ChatGPT") { signIn(status.configuration.account) }
                                Button("Sign out") {
                                    operate { try await service.logout(from: status.configuration.account) }
                                }
                            }
                        }.disabled(working)
                    }
                    Picker("Model", selection: Binding(
                        get: { current?.configuration.selectedModelID },
                        set: { model in chooseModel(model) }
                    )) {
                        Text("Choose a model").tag(Optional<String>.none)
                        if let selected = status.configuration.selectedModelID,
                           !status.models.contains(where: { $0.id.modelID == selected }) {
                            Text("Unavailable: \(selected)").tag(Optional(selected))
                        }
                        ForEach(status.models) { model in
                            Text(model.displayName).tag(Optional(model.id.modelID))
                        }
                    }.disabled(working || signingIn != nil)
                    Button("Use selected model") {
                        activeAccount = account
                        publishSelection()
                    }.disabled(working || signingIn != nil || status.authentication != .configured
                               || status.configuration.selectedModelID == nil)
                    if status.models.isEmpty {
                        Text("This provider has no available models.").foregroundStyle(.secondary)
                    }
                }
            }
            if let failure {
                Section { Text(failure).foregroundStyle(.red).accessibilityLabel("Settings error: \(failure)") }
            }
            Button("Refresh provider state") { operate {} }.disabled(working || signingIn != nil)
        }
        .formStyle(.grouped)
        .frame(minWidth: 500, minHeight: 360)
        .task { await refresh() }
        .onChange(of: account) { _, _ in
            apiKey = ""
            failure = nil
        }
        .onDisappear {
            apiKey = ""
            cancelSignIn()
        }
    }

    private var current: ProviderStatus? { statuses.first { $0.configuration.account == account } }
    private func statusText(_ state: AuthenticationState) -> String {
        if signingIn == account { return "Signing in…" }
        switch state {
        case .unconfigured: return "Not configured"
        case .signedOut: return "Signed out"
        case .signingIn: return "Signing in…"
        case .configured: return "Configured"
        case .unavailable(let message), .failed(let message): return message
        }
    }
    private func publishSelection() {
        guard let activeAccount else { return }
        let active = statuses.first { $0.configuration.account == activeAccount }
        guard let current = active, current.authentication == .configured,
              let modelID = current.configuration.selectedModelID,
              current.models.contains(where: { $0.id.modelID == modelID }) else {
            onSelection(nil)
            return
        }
        onSelection(ModelSelection(account: current.configuration.account, modelID: modelID))
    }
    private func refresh() async {
        do {
            statuses = try await service.snapshot()
            if let account, !statuses.contains(where: { $0.configuration.account == account }) { self.account = nil }
            publishSelection()
        } catch { failure = "Provider settings could not be loaded." }
    }
    private func operate(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        working = true
        failure = nil
        Task { @MainActor in
            defer { working = false }
            do { try await operation() }
            catch { failure = "The settings operation failed. Check the provider and try again." }
            await refresh()
        }
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
