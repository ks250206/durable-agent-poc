import AgentRuntime
import ChatCore
import Foundation
import PiDurableKit
import Testing
import os

@Suite(.serialized) struct PiProviderSettingsTests {
    private let api = ProviderAccount(option: .apiKey, providerID: "openai")
    private let chatGPT = ProviderAccount(option: .chatGPT, providerID: "openai-codex")

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DurableChat-settings-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func credentialReadFailureDoesNotHideSavedConversations() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = FailingPiCredentials()
        let models = piTestModels(credentials: credentials)
        let faux = FauxProvider()
        try await models.register(faux)
        let service = try PiProviderSettingsService(models: models, preferencesURL: directory.appendingPathComponent("providers.json"))
        let account = ProviderAccount(option: .apiKey, providerID: "faux")
        try await service.setAPIKey("isolated-key", for: account)
        let database = directory.appendingPathComponent("history.sqlite")
        let backend = try await PiChatBackend.open(settings: service, databaseURL: database)
        let id = try await backend.createConversation(title: "Keep my history")
        try await faux.append(.text("Persisted answer"))
        try await backend.send(SendRequest(conversationID: id, text: "Saved question", model: ModelSelection(account: account, modelID: "faux-1")))
        let expected = try await piWait(backend, id: id) { $0.activity == .idle && $0.messages.last?.content == "Persisted answer" }
        try await backend.close()
        await credentials.failReads()
        let status = try #require(try await service.snapshot().first)
        if case .unavailable = status.authentication {} else { Issue.record("Expected isolated credential failure") }
        let reopened = try await PiChatBackend.open(settings: service, databaseURL: database)
        let state = try await reopened.snapshot()
        #expect(state.connection == .disconnected)
        #expect(state.loadedConversations.first { $0.id == id } == expected)
        try await reopened.close()
    }

    @Test func slowLoginCancellationDoesNotHoldSettingsOrBackendLocks() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let models = piTestModels()
        try await models.register(CustomProvider(id: "openai-codex", baseURL: URL(string: "https://isolated.invalid/v1")!,
            oauth: .init(signIn: .browser(authorizationURL: URL(string: "https://isolated.invalid/authorize")!,
                redirectURI: URL(string: "http://127.0.0.1:59173/callback")!),
                tokenURL: URL(string: "https://isolated.invalid/token")!, clientID: "isolated-client"),
            models: [.init(id: "isolated-model")]))
        let gate = PiLoginGate()
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let (entered, signal) = AsyncStream<Void>.makeStream()
        let service = try PiProviderSettingsService(models: models, preferencesURL: directory.appendingPathComponent("providers.json"), installationID: UUID(), loginInteraction: {
            signal.yield(())
            await withTaskCancellationHandler { await gate.wait() } onCancel: { cancelled.withLock { $0 = true } }
            return LoginInteraction(presentSignInPage: { _ in throw CancellationError() })
        })
        let backend = try await PiChatBackend.open(settings: service, databaseURL: directory.appendingPathComponent("runtime.sqlite"))
        let id = try await backend.createConversation(title: "Still responsive")
        let login = Task { try await service.login(to: chatGPT) }
        var entering = entered.makeAsyncIterator()
        _ = await entering.next()
        let cancelling = Task { await service.cancelLogin(to: chatGPT) }
        let deadline = ContinuousClock.now + .seconds(2)
        while !cancelled.withLock({ $0 }), ContinuousClock.now < deadline { await Task.yield() }
        #expect(cancelled.withLock { $0 })
        let responsive = OSAllocatedUnfairLock(initialState: false)
        let checking = Task {
            _ = try await service.snapshot()
            try await backend.selectConversation(id)
            try await backend.stop(conversationID: id)
            responsive.withLock { $0 = true }
        }
        let responseDeadline = ContinuousClock.now + .seconds(2)
        while !responsive.withLock({ $0 }), ContinuousClock.now < responseDeadline { await Task.yield() }
        #expect(responsive.withLock { $0 }) // Must finish BEFORE the authentication task can unwind.
        await gate.release()
        _ = await checking.result
        await cancelling.value
        _ = await login.result
        try await backend.close()
    }

    @Test func discoversModelsAndActualCredentialStateWithSeparateRoutes() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let models = piTestModels(builtinProviders: true)
        let preferences = directory.appendingPathComponent("providers.json")
        let service = try PiProviderSettingsService(models: models, preferencesURL: preferences)
        let initial = try await service.snapshot()
        #expect(initial.first { $0.configuration.account == api }?.authentication == .unconfigured)
        #expect(initial.first { $0.configuration.account == chatGPT }?.authentication == .signedOut)
        #expect(!initial.contains { $0.configuration.account.option == .cursor })
        let actual = try await models.models(for: "openai")
        let discovered = try #require(initial.first { $0.configuration.account == api })
        #expect(discovered.models.map(\.id.modelID) == actual.map(\.modelId))
        #expect(!discovered.models.isEmpty)
        #expect(discovered.configuration.selectedModelID == nil)
        let modelID = try #require(actual.first?.modelId)
        try await service.update(ProviderConfiguration(account: api, selectedModelID: modelID))
        try await service.setAPIKey("fake-test-api-key", for: api)
        try await models.setCredential(.oauth(accessToken: "fake-oauth-access", refreshToken: "fake-oauth-refresh",
                                             expiresAt: Date().addingTimeInterval(3600)), for: "openai-codex")
        let configured = try await service.snapshot()
        #expect(configured.first { $0.configuration.account == api }?.authentication == .configured)
        #expect(configured.first { $0.configuration.account == chatGPT }?.authentication == .configured)
        let saved = try String(contentsOf: preferences, encoding: .utf8)
        let encoded = String(decoding: try JSONEncoder().encode(configured), as: UTF8.self)
        for secret in ["fake-test-api-key", "fake-oauth-access", "fake-oauth-refresh"] {
            #expect(!saved.contains(secret))
            #expect(!encoded.contains(secret))
        }
        let reopened = try PiProviderSettingsService(models: models, preferencesURL: preferences)
        #expect(try await reopened.snapshot().first { $0.configuration.account == api }?.configuration.selectedModelID == modelID)
        try await service.logout(from: chatGPT)
        #expect(try await models.credential(for: "openai-codex") == nil)
        #expect(try await models.credential(for: "openai")?.kind == .apiKey)
        try await service.setAPIKey(nil, for: api)
        #expect(try await service.snapshot().first { $0.configuration.account == api }?.authentication == .unconfigured)
        // An OAuth credential in the API provider's slot must never configure the API-key route.
        try await models.setCredential(.oauth(accessToken: "wrong-kind", refreshToken: "wrong-kind", expiresAt: .distantFuture), for: "openai")
        #expect(try await service.snapshot().first { $0.configuration.account == api }?.authentication == .unconfigured)
    }

    @Test func rejectsUnsupportedRoutesAndInvalidModelsWithoutChangingCredentials() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let models = piTestModels(builtinProviders: true)
        let service = try PiProviderSettingsService(models: models, preferencesURL: directory.appendingPathComponent("providers.json"))
        for account in [ProviderAccount(option: .cursor, providerID: "cursor"),
                        ProviderAccount(option: .apiKey, providerID: "openai-codex"),
                        ProviderAccount(option: .chatGPT, providerID: "openai")] {
            await #expect(throws: ChatBackendError.self) { try await service.update(ProviderConfiguration(account: account)) }
            await #expect(throws: ChatBackendError.self) { try await service.setAPIKey("fake-key", for: account) }
            await #expect(throws: ChatBackendError.self) { try await service.login(to: account) }
            await #expect(throws: ChatBackendError.self) { try await service.logout(from: account) }
            await service.cancelLogin(to: account)
        }
        await #expect(throws: ChatBackendError.self) { try await service.setAPIKey("fake-key", for: chatGPT) }
        await #expect(throws: ChatBackendError.self) { try await service.login(to: api) }
        await #expect(throws: ChatBackendError.noModel) {
            try await service.update(ProviderConfiguration(account: api, selectedModelID: "not-in-catalog"))
        }
        await #expect(throws: ChatBackendError.self) {
            try await service.update(ProviderConfiguration(account: api, executablePath: "/fake/cursor"))
        }
        #expect(try await models.credentials.providers().isEmpty)
    }

    @Test func unconfiguredRuntimeStaysDisconnectedAndTracksKeyRemoval() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let models = piTestModels(builtinProviders: true)
        let service = try PiProviderSettingsService(models: models, preferencesURL: directory.appendingPathComponent("providers.json"))
        let backend = try await PiChatBackend.open(settings: service, databaseURL: directory.appendingPathComponent("runtime.sqlite"))
        do {
            #expect(try await backend.snapshot().connection == .disconnected)
            let id = try await backend.createConversation(title: nil)
            let modelID = try #require(try await models.models(for: "openai").first?.modelId)
            await #expect(throws: ChatBackendError.disconnected) {
                try await backend.send(SendRequest(conversationID: id, text: "Must not reach a provider", model: ModelSelection(account: api, modelID: modelID)))
            }
            let stream = await backend.events()
            try await service.setAPIKey("fake-key-never-used", for: api)
            try await piTimeout {
                for try await event in stream {
                    if case .snapshot(let snapshot) = event, snapshot.connection == .connected { return }
                }
                throw PiTestError.ended
            }
            let disconnected = await backend.events()
            try await service.logout(from: api)
            try await piTimeout {
                for try await event in disconnected {
                    if case .snapshot(let snapshot) = event, snapshot.connection == .disconnected { return }
                }
                throw PiTestError.ended
            }
            #expect(try await backend.snapshot().loadedConversations.first?.messages.isEmpty == true)
            try await backend.close()
        } catch { try? await backend.close(); throw error }
    }

    @Test func realPiLoginCancellationUsesInjectedInteractionAndNeverSignsIn() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let models = piTestModels()
        // A local, custom OAuth definition exercises Models.login and its cancellation machinery.
        // No browser, token exchange, personal credential, or real sign-in is involved.
        try await models.register(CustomProvider(
            id: "openai-codex", name: "Isolated OAuth fixture", baseURL: URL(string: "https://isolated.invalid/v1")!,
            oauth: .init(signIn: .browser(authorizationURL: URL(string: "https://isolated.invalid/authorize")!,
                                         redirectURI: URL(string: "http://127.0.0.1:59173/callback")!),
                         tokenURL: URL(string: "https://isolated.invalid/token")!, clientID: "isolated-client"),
            models: [.init(id: "isolated-model")]))
        let (pages, page) = AsyncStream<URL>.makeStream()
        let service = try PiProviderSettingsService(models: models, preferencesURL: directory.appendingPathComponent("providers.json"), installationID: UUID(), loginInteraction: {
            LoginInteraction(presentSignInPage: { url in
                page.yield(url)
                try await Task.sleep(for: .seconds(3600))
            })
        })
        for cancellation in 0..<3 {
            let login = Task { try await service.login(to: chatGPT) }
            let url = try await piTimeout {
                for await url in pages { return url }
                throw PiTestError.ended
            }
            #expect(url.host == "isolated.invalid")
            #expect(try await service.snapshot().first?.authentication == .signingIn)
            await #expect(throws: ChatBackendError.busy) { try await service.login(to: chatGPT) }
            switch cancellation {
            case 0: await service.cancelLogin(to: chatGPT)
            case 1: login.cancel()
            default: try await service.logout(from: chatGPT)
            }
            await #expect(throws: CancellationError.self) { try await piTimeout { try await login.value } }
            #expect(try await service.snapshot().first?.authentication == .signedOut)
            #expect(try await models.credential(for: "openai-codex") == nil)
        }
        try await service.logout(from: chatGPT)
        #expect(try await service.snapshot().first?.authentication == .signedOut)
        #expect(PiDenyNetwork.requestCount == 0)
    }
}

private actor FailingPiCredentials: CredentialStore {
    private let backing = InMemoryCredentialStore()
    private var failing = false
    func failReads() { failing = true }
    func credential(for provider: ProviderID) async throws -> Credential? {
        if failing { throw ChatBackendError.unavailable("synthetic Keychain error") }
        return await backing.credential(for: provider)
    }
    func setCredential(_ credential: Credential?, for provider: ProviderID) async throws {
        await backing.setCredential(credential, for: provider)
    }
    func providers() async throws -> [ProviderID] { await backing.providers() }
}
private actor PiLoginGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}
