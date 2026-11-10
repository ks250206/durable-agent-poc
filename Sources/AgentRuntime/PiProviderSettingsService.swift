import ChatCore
import Foundation
import PiDurableKit

/// Pi accounts only. Cursor is supplied by the integration router, never emulated here.
public actor PiProviderSettingsService: ProviderSettingsService {
    nonisolated let models: Models
    private let preferencesURL: URL
    private let interaction: @Sendable () async -> LoginInteraction
    private let installationID: UUID?
    private var configurations: [ProviderConfiguration]
    private var loginTask: (id: UUID, task: Task<Void, any Error>)?
    private var isLoggingOut = false
    private var loginState: AuthenticationState?
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Production credentials are read only when the caller explicitly opens this service.
    /// No catalog network refresh or provider request is performed by this factory.
    @MainActor
    public static func open(directory: URL? = nil) throws -> PiProviderSettingsService {
        let directory = try directory ?? PiChatBackend.applicationSupportDirectory()
        return try PiProviderSettingsService(
            models: Models(credentials: .keychain, catalog: nil, runtime: Runtime(configuration: .init(log: { _, _ in }))),
            preferencesURL: directory.appendingPathComponent("providers.json"),
            loginInteraction: { await MainActor.run { .webAuthenticationSession() } })
    }

    /// Inject Models(credentials: InMemoryCredentialStore(), catalog: nil) for isolated tests.
    /// Only nonsecret preferences are written to this URL.
    public init(
        models: Models, preferencesURL: URL, installationID: UUID? = nil,
        loginInteraction: @escaping @Sendable () async -> LoginInteraction = { await MainActor.run { .webAuthenticationSession() } }
    ) throws {
        self.models = models
        self.preferencesURL = preferencesURL
        interaction = loginInteraction
        self.installationID = installationID
        if FileManager.default.fileExists(atPath: preferencesURL.path) {
            do {
                configurations = try JSONDecoder().decode([ProviderConfiguration].self, from: Data(contentsOf: preferencesURL))
            } catch { throw ChatBackendError.unavailable("Provider preferences could not be read.") }
        } else { configurations = [] }
    }

    public func snapshot() async throws -> [ProviderStatus] {
        await acquire()
        defer { release() }
        do {
            let providers = try await models.providers()
            var result: [ProviderStatus] = []
            for provider in providers {
                let account: ProviderAccount
                if provider.id.rawValue == "openai-codex" {
                    account = ProviderAccount(option: .chatGPT, providerID: "openai-codex")
                } else if provider.acceptsAPIKey {
                    account = ProviderAccount(option: .apiKey, providerID: provider.id.rawValue)
                } else { continue }
                let configuration = configurations.first { $0.account == account } ?? ProviderConfiguration(account: account)
                do {
                    let runtimeConfigured = try await models.isConfigured(provider.id)
                    let credential = try await models.credential(for: provider.id)
                    let expectedKind: Credential.Kind = account.option == .chatGPT ? .oauth : .apiKey
                    let configured = runtimeConfigured && credential?.kind == expectedKind
                    let authentication: AuthenticationState
                    if account.option == .chatGPT, let loginState { authentication = loginState }
                    else { authentication = configured ? .configured : (account.option == .chatGPT ? .signedOut : .unconfigured) }
                    let catalog = try await models.models(for: provider.id)
                    result.append(ProviderStatus(configuration: configuration, authentication: authentication, models: catalog.map {
                        ChatModel(id: ModelSelection(account: account, modelID: $0.modelId), displayName: $0.name)
                    }))
                } catch {
                    // A locked/unavailable credential must not hide saved conversations or other accounts.
                    result.append(ProviderStatus(configuration: configuration,
                        authentication: .unavailable("This provider's credentials or models could not be loaded.")))
                }
            }
            return result
        } catch { throw ChatBackendError.unavailable("Provider configuration could not be loaded.") }
    }

    public func update(_ configuration: ProviderConfiguration) async throws {
        await acquire()
        defer { release() }
        try await validate(configuration.account)
        guard configuration.executablePath == nil else { throw unsupported }
        if let selected = configuration.selectedModelID {
            let catalog: [ModelInfo]
            do { catalog = try await models.models(for: ProviderID(configuration.account.providerID)) }
            catch { throw ChatBackendError.unavailable("Provider models could not be loaded.") }
            guard catalog.contains(where: { $0.modelId == selected }) else { throw ChatBackendError.noModel }
        }
        var next = configurations.filter { $0.account != configuration.account }
        next.append(configuration)
        do {
            try FileManager.default.createDirectory(at: preferencesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: preferencesURL, options: [.atomic])
        } catch { throw ChatBackendError.unavailable("Provider preferences could not be saved.") }
        configurations = next
        changed()
    }

    public func setAPIKey(_ key: String?, for account: ProviderAccount) async throws {
        await acquire()
        defer { release() }
        try await validate(account)
        guard account.option == .apiKey else { throw unsupported }
        guard key == nil || key?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw ChatBackendError.unavailable("Enter an API key, or remove the stored key.")
        }
        do { try await models.setAPIKey(key, for: ProviderID(account.providerID)) }
        catch { throw ChatBackendError.unavailable("The API key could not be saved.") }
        changed()
    }

    public func login(to account: ProviderAccount) async throws {
        await acquire()
        do {
            try await validate(account)
            guard account.option == .chatGPT else { throw unsupported }
            guard loginTask == nil, !isLoggingOut else { throw ChatBackendError.busy }
        } catch { release(); throw error }
        let id = UUID()
        let models = models
        let interaction = interaction
        let installationID = installationID ?? Models.installationID
        let task = Task {
            try Task.checkCancellation()
            let loginInteraction = await interaction()
            try Task.checkCancellation()
            try await models.login(to: "openai-codex", interaction: loginInteraction, installationID: installationID)
        }
        loginTask = (id, task)
        loginState = .signingIn
        changed()
        release()
        var failure: (any Error)?
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch { failure = error }
        await acquire()
        defer { release() }
        if loginTask?.id == id {
            loginTask = nil
            if task.isCancelled || isCancellation(failure) {
                loginState = nil
            } else if failure != nil { loginState = .failed("Sign-in failed. Try again.") }
            else { loginState = nil }
            changed()
        }
        if let failure {
            if task.isCancelled || isCancellation(failure) { throw CancellationError() }
            throw ChatBackendError.unavailable("Sign-in failed. Try again.")
        }
    }

    public func cancelLogin(to account: ProviderAccount) async {
        await acquire()
        let pending = cancelLoginLocked(to: account)
        release()
        // Never await the browser/auth task while holding the settings operation lock.
        if let pending { _ = await pending.task.result }
        await acquire()
        defer { release() }
        if let pending, loginTask?.id == pending.id {
            loginTask = nil
            loginState = nil
            changed()
        }
    }

    private func cancelLoginLocked(to account: ProviderAccount) -> (id: UUID, task: Task<Void, any Error>)? {
        guard account == ProviderAccount(option: .chatGPT, providerID: "openai-codex"), let loginTask else { return nil }
        loginTask.task.cancel()
        return loginTask
    }

    public func logout(from account: ProviderAccount) async throws {
        await acquire()
        do {
            try await validate(account)
            guard !isLoggingOut else { throw ChatBackendError.busy }
        } catch { release(); throw error }
        isLoggingOut = true
        let pending = cancelLoginLocked(to: account)
        release()
        if let pending { _ = await pending.task.result }
        await acquire()
        defer { isLoggingOut = false; release() }
        // New sign-ins remain blocked until the old task settles and its tokens are removed.
        do { try await models.logout(from: ProviderID(account.providerID)) }
        catch { throw ChatBackendError.unavailable("The credential could not be removed.") }
        if account.option == .chatGPT { loginState = nil }
        changed()
    }

    private func validate(_ account: ProviderAccount) async throws {
        guard account.providerID != "cursor", account.option != .cursor else { throw unsupported }
        let providers: [ProviderInfo]
        do { providers = try await models.providers() }
        catch { throw ChatBackendError.unavailable("Providers could not be loaded.") }
        guard let provider = providers.first(where: { $0.id.rawValue == account.providerID }) else { throw unsupported }
        switch account.option {
        case .apiKey:
            guard account.providerID != "openai-codex", provider.acceptsAPIKey else { throw unsupported }
        case .chatGPT:
            guard account.providerID == "openai-codex", provider.oauth != nil else { throw unsupported }
        case .cursor, .codexCLI: throw unsupported
        }
    }

    private func isCancellation(_ error: (any Error)?) -> Bool {
        if error is CancellationError { return true }
        if case .cancelled? = error as? PiDurableError { return true }
        return false
    }

    private var unsupported: ChatBackendError { .unavailable("This account or authentication route is not supported by Pi.") }
    private func changed() { for observer in observers.values { observer.yield(()) } }

    func changes() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.yield(())
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func acquire() async {
        if locked { await withCheckedContinuation { waiters.append($0) } }
        else { locked = true }
    }
    private func release() {
        if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
    }
}
