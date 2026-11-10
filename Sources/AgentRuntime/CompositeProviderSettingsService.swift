import ChatCore
import Foundation

/// Dispatches by the complete account. Owns/cancels CLI control work as well as login on shutdown.
public actor CompositeProviderSettingsService: ProviderSettingsService {
    private let pi: any ProviderSettingsService
    private let cursor: any ProviderSettingsService
    private var onSnapshot: (@Sendable ([ProviderStatus]) async -> Void)?
    private var reads: [UUID: Task<[ProviderStatus], any Error>] = [:]
    private var operations: [UUID: Task<Void, any Error>] = [:]
    private var closed = false

    public init(pi: any ProviderSettingsService, cursor: any ProviderSettingsService) {
        self.pi = pi; self.cursor = cursor
    }
    public func setObserver(_ observer: @escaping @Sendable ([ProviderStatus]) async -> Void) { onSnapshot = observer }
    public func snapshot() async throws -> [ProviderStatus] {
        guard !closed else { throw CancellationError() }
        let id = UUID()
        let task = Task { [pi, cursor] in
            try Task.checkCancellation()
            async let piStatuses = pi.snapshot()
            async let cursorStatuses = cursor.snapshot()
            return try await piStatuses + cursorStatuses
        }
        reads[id] = task
        defer { reads.removeValue(forKey: id) }
        let statuses = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        await onSnapshot?(statuses)
        return statuses
    }
    private func service(for account: ProviderAccount) throws -> any ProviderSettingsService {
        guard let route = ChatBackendRouter.route(for: account) else { throw ChatBackendError.noModel }
        return route == .pi ? pi : cursor
    }
    private func perform(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        guard !closed else { throw CancellationError() }
        let id = UUID()
        let task = Task { try Task.checkCancellation(); try await operation() }
        operations[id] = task
        defer { operations.removeValue(forKey: id) }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        _ = try await snapshot()
    }
    public func update(_ configuration: ProviderConfiguration) async throws {
        let service = try service(for: configuration.account)
        try await perform { try await service.update(configuration) }
    }
    public func setAPIKey(_ key: String?, for account: ProviderAccount) async throws {
        let service = try service(for: account)
        try await perform { try await service.setAPIKey(key, for: account) }
    }
    public func login(to account: ProviderAccount) async throws {
        let service = try service(for: account)
        try await perform { try await service.login(to: account) }
    }
    public func cancelLogin(to account: ProviderAccount) async {
        try? await service(for: account).cancelLogin(to: account)
    }
    public func logout(from account: ProviderAccount) async throws {
        let service = try service(for: account)
        try await perform { try await service.logout(from: account) }
    }
    public func cancelAuthentication() async {
        await pi.cancelLogin(to: ProviderAccount(option: .chatGPT, providerID: "openai-codex"))
        await cursor.cancelLogin(to: CursorProviderSettingsService.account)
    }
    public func shutdown() async {
        guard !closed else { return }
        closed = true; onSnapshot = nil
        let pendingReads = Array(reads.values), pendingOperations = Array(operations.values)
        for task in pendingReads { task.cancel() }
        for task in pendingOperations { task.cancel() }
        await cancelAuthentication()
        for task in pendingReads { _ = await task.result }
        for task in pendingOperations { _ = await task.result }
        reads.removeAll(); operations.removeAll()
    }
}
