import AgentRuntime
import ChatCore
import ChatUI
import Foundation
import Observation
import PiDurableKit

@MainActor @Observable
final class AppSession {
    enum Mode { case live, demo, testRuntime }
    let mode: Mode
    private(set) var store: ChatStore?
    let navigation = TranscriptNavigation()
    private(set) var settings: CompositeProviderSettingsService?
    private(set) var failure: String?
    private(set) var testDirectory: URL?
    private var router: ChatBackendRouter?
    private var opening = false
    private var shuttingDown = false
    private var observation: Task<Void, Never>?
    private var startup: Task<Void, Never>?
    private var settingsRevision = 0
    private let isolatedDirectory: URL?

    init(arguments: [String] = ProcessInfo.processInfo.arguments, isolatedDirectory: URL? = nil) {
        self.isolatedDirectory = isolatedDirectory
        mode = arguments.contains("--demo") ? .demo : (arguments.contains("--test-runtime") ? .testRuntime : .live)
    }

    /// The single app owner starts observation; child views never create runtimes/subscriptions.
    func start() async {
        guard store == nil, !opening, !shuttingDown else { return }
        opening = true
        let task = Task { await openWorkspace() }
        startup = task
        await task.value
        startup = nil
        opening = false
    }

    private func openWorkspace() async {
        if mode == .demo {
            let store = ChatStore(backend: ShellChatBackend(mode: .demo))
            self.store = store
            observation = Task { await store.start() }
            return
        }
        var openedPi: PiChatBackend?
        var openedCodex: CodexChatBackend?
        var openedCodexSettings: CodexProviderSettingsService?
        do {
            let root: URL
            let piSettings: PiProviderSettingsService
            let cursorSettings: CursorProviderSettingsService
            let codexSettings: CodexProviderSettingsService
            if mode == .testRuntime {
                root = isolatedDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("DurableChat-Isolated-\(UUID())", isDirectory: true)
                testDirectory = root
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [DenyTestNetwork.self]
                let models = Models(credentials: InMemoryCredentialStore(), builtinProviders: false, catalog: nil,
                                    runtime: Runtime(configuration: .init(urlSessionConfiguration: configuration, log: { _, _ in })))
                let faux = FauxProvider(tokensPerSecond: 15)
                try await models.register(faux)
                try await faux.respond { _, _ in
                    FauxResponse([.text("SIMULATED Pi response from FauxProvider. No AI service was contacted. " + String(repeating: "Use Stop to preserve this partial response. ", count: 12))])
                }
                piSettings = try PiProviderSettingsService(models: models, preferencesURL: root.appendingPathComponent("providers.json"))
                let model = ModelSelection(account: ProviderAccount(option: .apiKey, providerID: "faux"), modelID: "faux-1")
                try await piSettings.setAPIKey("isolated-faux-only", for: model.account)
                try await piSettings.update(ProviderConfiguration(account: model.account, selectedModelID: model.modelID))
                let cursorRoot = root.appendingPathComponent("Cursor", isDirectory: true)
                try TestRuntimeFixture.prepareCursor(at: cursorRoot)
                cursorSettings = try CursorProviderSettingsService(storageDirectory: cursorRoot)
                try await cursorSettings.update(ProviderConfiguration(account: CursorProviderSettingsService.account,
                    selectedModelID: "simulated-cursor", executablePath: cursorRoot.appendingPathComponent("simulated-agent").path))
                let codexRoot = root.appendingPathComponent("Codex", isDirectory: true)
                try TestRuntimeFixture.prepareCodex(at: codexRoot)
                codexSettings = try CodexProviderSettingsService(storageDirectory: codexRoot, requestTimeout: 5,
                    isolatedExecutable: codexRoot.appendingPathComponent("simulated-codex"))
                openedCodexSettings = codexSettings
                // Pin every probe and generation to our executable before taking any snapshot.
                if !FileManager.default.fileExists(atPath: codexRoot.appendingPathComponent("preferences.json").path) {
                    try await codexSettings.update(ProviderConfiguration(account: CodexProviderSettingsService.account,
                        executablePath: codexRoot.appendingPathComponent("simulated-codex").path))
                } else {
                    // A copied QA workspace keeps its explicit model; it can never discover the personal CLI.
                    let configuration = try JSONDecoder().decode(ProviderConfiguration.self,
                        from: Data(contentsOf: codexRoot.appendingPathComponent("preferences.json")))
                    try await codexSettings.update(ProviderConfiguration(account: CodexProviderSettingsService.account,
                        selectedModelID: configuration.selectedModelID, executablePath: codexRoot.appendingPathComponent("simulated-codex").path))
                }
            } else {
                root = try PiChatBackend.applicationSupportDirectory()
                piSettings = try PiProviderSettingsService.open(directory: root)
                cursorSettings = try CursorProviderSettingsService(storageDirectory: root.appendingPathComponent("Cursor", isDirectory: true))
                codexSettings = try CodexProviderSettingsService(storageDirectory: root.appendingPathComponent("Codex", isDirectory: true))
                openedCodexSettings = codexSettings
            }
            let pi = try await PiChatBackend.open(settings: piSettings, databaseURL: root.appendingPathComponent("conversations.sqlite"))
            openedPi = pi
            let cursor = try CursorChatBackend(storageDirectory: root.appendingPathComponent("Cursor", isDirectory: true), settings: cursorSettings)
            let codex = try CodexChatBackend(storageDirectory: root.appendingPathComponent("Codex", isDirectory: true), settings: codexSettings)
            openedCodex = codex
            let restoring = FileManager.default.fileExists(atPath: root.appendingPathComponent("routing.json").path)
            let router = try await ChatBackendRouter.open(pi: pi, cursor: cursor, codex: codex, preferencesURL: root.appendingPathComponent("routing.json"))
            self.router = router
            let composite = CompositeProviderSettingsService(pi: piSettings, cursor: cursorSettings, codex: codexSettings)
            await composite.setObserver { [weak router] statuses in await router?.updateProviderStatuses(statuses) }
            settings = composite
            _ = try await composite.snapshot()
            if mode == .testRuntime && !restoring {
                try await router.useModel(ModelSelection(account: ProviderAccount(option: .apiKey, providerID: "faux"), modelID: "faux-1"))
                _ = try await router.createConversation(title: "Simulated Pi • scratch conversation")
            }
            if shuttingDown || Task.isCancelled {
                await composite.shutdown()
                try await router.shutdown()
                return
            }
            let store = ChatStore(backend: router)
            self.store = store
            observation = Task { await store.start() }
        } catch {
            await settings?.shutdown()
            await openedCodexSettings?.shutdown()
            if let router { try? await router.shutdown() }
            else { try? await openedPi?.close() }
            await openedCodex?.shutdown()
            settings = nil; router = nil
            failure = "DurableChat could not open its saved workspace. Check that another copy is not running and that Application Support/DurableChat is readable. Your files have not been reset."
        }
    }

    func useModel(_ model: ModelSelection?) async {
        guard !shuttingDown else { return }
        settingsRevision += 1
        let revision = settingsRevision
        do {
            _ = try await settings?.snapshot()
            guard revision == settingsRevision, !shuttingDown else { return }
            try await router?.useModel(model)
            failure = nil
        } catch { failure = "The model could not be applied. Refresh Settings and choose an available model." }
    }
    func dismissFailure() { failure = nil }
    func shutdown() async {
        guard !shuttingDown else { return }
        shuttingDown = true
        startup?.cancel()
        await startup?.value
        observation?.cancel(); observation = nil
        await settings?.shutdown()
        do { try await router?.shutdown() }
        catch { failure = "Some active work could not be saved while closing the runtime." }
        router = nil; settings = nil
        // Router.shutdown releases its backend owners even though the store can still render history.
        if let testDirectory { try? FileManager.default.removeItem(at: testDirectory) }
    }
}

/// Deny all URLSession traffic in explicit isolated QA mode, including accidental catalog/auth requests.
private final class DenyTestNetwork: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
