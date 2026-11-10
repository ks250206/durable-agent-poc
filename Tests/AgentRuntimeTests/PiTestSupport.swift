import AgentRuntime
import ChatCore
import Foundation
import PiDurableKit
import Testing
import os

/// Every injected runtime denies HTTP, including unexpected catalog/auth/model traffic.
final class PiDenyNetwork: URLProtocol, @unchecked Sendable {
    private static let requests = OSAllocatedUnfairLock(initialState: 0)
    static var requestCount: Int { requests.withLock { $0 } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.withLock { $0 += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

func piTestModels(builtinProviders: Bool = false, credentials: any CredentialStore = InMemoryCredentialStore()) -> Models {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PiDenyNetwork.self]
    let runtime = Runtime(configuration: .init(urlSessionConfiguration: configuration, log: { _, _ in }))
    return Models(credentials: credentials, builtinProviders: builtinProviders, catalog: nil, runtime: runtime)
}

struct PiFixture: Sendable {
    let directory: URL
    let models: Models
    let faux: FauxProvider
    let settings: PiProviderSettingsService
    let backend: PiChatBackend
    var databaseURL: URL { directory.appendingPathComponent("conversations.sqlite") }
    let account = ProviderAccount(option: .apiKey, providerID: "faux")
    var selection: ModelSelection { ModelSelection(account: account, modelID: "faux-1") }

    static func withFixture<T: Sendable>(
        tokensPerSecond: Double = 120, _ body: @Sendable (PiFixture) async throws -> T
    ) async throws -> T {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DurableChat-Pi-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let models = piTestModels()
        let faux = FauxProvider(tokensPerSecond: tokensPerSecond)
        try await models.register(faux)
        let settings = try PiProviderSettingsService(models: models, preferencesURL: directory.appendingPathComponent("providers.json"))
        try await settings.setAPIKey("isolated-faux-key", for: ProviderAccount(option: .apiKey, providerID: "faux"))
        let backend = try await PiChatBackend.open(settings: settings, databaseURL: directory.appendingPathComponent("conversations.sqlite"))
        let fixture = PiFixture(directory: directory, models: models, faux: faux, settings: settings, backend: backend)
        do {
            let result = try await body(fixture)
            try await backend.close()
            #expect(PiDenyNetwork.requestCount == 0)
            return result
        } catch {
            try? await backend.close()
            throw error
        }
    }
}

enum PiTestError: Error { case timeout, ended }

func piTimeout<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask { try await Task.sleep(for: .seconds(12)); throw PiTestError.timeout }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw PiTestError.ended }
        return result
    }
}

func piConversation(_ event: ChatEvent, id: ChatCore.ConversationID) -> ConversationSnapshot? {
    switch event {
    case .snapshot(let snapshot): return snapshot.loadedConversations.first { $0.id == id }
    case .conversationUpdated(let conversation): return conversation.id == id ? conversation : nil
    }
}

func piWait(
    _ backend: PiChatBackend, id: ChatCore.ConversationID,
    until predicate: @escaping @Sendable (ConversationSnapshot) -> Bool
) async throws -> ConversationSnapshot {
    let stream = await backend.events()
    return try await piTimeout {
        for try await event in stream {
            if let conversation = piConversation(event, id: id), predicate(conversation) { return conversation }
        }
        throw PiTestError.ended
    }
}
