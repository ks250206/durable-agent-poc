import AgentRuntime
import ChatCore
import Foundation
import Testing

private actor SettingsFixture: ProviderSettingsService {
    var statuses: [ProviderStatus]
    private(set) var operations: [(String, ProviderAccount)] = []
    init(_ accounts: [ProviderAccount]) {
        statuses = accounts.map { account in ProviderStatus(configuration: ProviderConfiguration(account: account), authentication: .signedOut) }
    }
    func snapshot() async throws -> [ProviderStatus] { statuses }
    func update(_ configuration: ProviderConfiguration) async throws { operations.append(("update", configuration.account)) }
    func setAPIKey(_ key: String?, for account: ProviderAccount) async throws { operations.append(("key", account)) }
    func login(to account: ProviderAccount) async throws { operations.append(("login", account)) }
    func cancelLogin(to account: ProviderAccount) async { operations.append(("cancel", account)) }
    func logout(from account: ProviderAccount) async throws { operations.append(("logout", account)) }
}

struct CompositeSettingsTests {
    @Test func exactAccountDispatchAndRefreshNeverBecomeImplicitModelSelection() async throws {
        let api = ProviderAccount(option: .apiKey, providerID: "openai")
        let oauth = ProviderAccount(option: .chatGPT, providerID: "openai-codex")
        let cursor = CursorProviderSettingsService.account
        let piService = SettingsFixture([api, oauth]), cursorService = SettingsFixture([cursor])
        let composite = CompositeProviderSettingsService(pi: piService, cursor: cursorService)
        #expect(try await composite.snapshot().map(\.configuration.account) == [api, oauth, cursor])
        try await composite.setAPIKey("fixture-only", for: api)
        try await composite.login(to: oauth)
        await composite.cancelLogin(to: oauth)
        try await composite.logout(from: oauth)
        try await composite.update(ProviderConfiguration(account: cursor, selectedModelID: "fixture"))
        try await composite.login(to: cursor)
        await composite.cancelLogin(to: cursor)
        try await composite.logout(from: cursor)
        #expect(await piService.operations.map(\.0) == ["key", "login", "cancel", "logout"])
        #expect(await piService.operations.map(\.1) == [api, oauth, oauth, oauth])
        #expect(await cursorService.operations.map(\.0) == ["update", "login", "cancel", "logout"])
        await #expect(throws: ChatBackendError.noModel) {
            try await composite.login(to: ProviderAccount(option: .chatGPT, providerID: "openai"))
        }
        await composite.cancelAuthentication()
        #expect(await cursorService.operations.last?.0 == "cancel")
    }
}

private actor BlockingControlSettings: ProviderSettingsService {
    private(set) var started: Set<String> = []
    private(set) var cancelled: Set<String> = []
    private func block(_ operation: String) async throws {
        started.insert(operation)
        do { try await Task.sleep(for: .seconds(30)) }
        catch { cancelled.insert(operation); throw error }
    }
    func snapshot() async throws -> [ProviderStatus] { try await block("status"); return [] }
    func update(_ configuration: ProviderConfiguration) async throws {}
    func setAPIKey(_ key: String?, for account: ProviderAccount) async throws {}
    func login(to account: ProviderAccount) async throws { try await block("login") }
    func cancelLogin(to account: ProviderAccount) async {}
    func logout(from account: ProviderAccount) async throws { try await block("logout") }
}

extension CompositeSettingsTests {
    @Test func shutdownCancelsAndAwaitsOutstandingControlProbesAndLogout() async throws {
        let cursor = BlockingControlSettings()
        let service = CompositeProviderSettingsService(pi: SettingsFixture([]), cursor: cursor)
        let probe = Task { try await service.snapshot() }
        let logout = Task { try await service.logout(from: CursorProviderSettingsService.account) }
        let deadline = ContinuousClock.now + .seconds(3)
        while await cursor.started.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await cursor.started == Set(["status", "logout"]))
        await service.shutdown()
        await #expect(throws: CancellationError.self) { try await probe.value }
        await #expect(throws: CancellationError.self) { try await logout.value }
        #expect(await cursor.cancelled == Set(["status", "logout"]))
        await #expect(throws: CancellationError.self) { try await service.snapshot() }
    }
}
