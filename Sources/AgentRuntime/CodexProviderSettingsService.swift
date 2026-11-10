import ChatCore
import Foundation

/// Reuses an existing official Codex CLI login. Never logs in/out, reads auth.json or handles OAuth tokens.
public actor CodexProviderSettingsService: ProviderSettingsService {
    public static let account = ProviderAccount(option: .codexCLI, providerID: "codex-cli")
    public static let loginInstructions = "In Terminal, run codex login and choose ChatGPT, then refresh Codex CLI settings here. The official CLI owns your login. To sign out, run codex logout yourself."
    private let workspace: URL
    private let preferencesURL: URL
    private let requestTimeout: TimeInterval
    private var configuration: ProviderConfiguration
    private var processes: [UUID: CodexProcess] = [:]
    private var revision = 0
    private var closed = false

    public init(storageDirectory: URL = CodexProcess.defaultStorageDirectory, requestTimeout: TimeInterval = 20) throws {
        try CodexFiles.prepare(storageDirectory)
        workspace = storageDirectory.resolvingSymlinksInPath().appendingPathComponent("control", isDirectory: true)
        try CodexFiles.prepare(workspace)
        preferencesURL = storageDirectory.appendingPathComponent("preferences.json")
        self.requestTimeout = requestTimeout
        configuration = try CodexFiles.read(ProviderConfiguration.self, from: preferencesURL) ?? ProviderConfiguration(account: Self.account)
        guard configuration.account == Self.account,
              configuration.selectedModelID.map(Self.validIdentifier) ?? true,
              configuration.executablePath.map({ $0.hasPrefix("/") }) ?? true else { throw CodexRuntimeError.storage }
    }

    public func update(_ configuration: ProviderConfiguration) async throws {
        try check(configuration.account)
        if let model = configuration.selectedModelID, !Self.validIdentifier(model) { throw ChatBackendError.noModel }
        if let path = configuration.executablePath { _ = try CodexProcess.discover(executablePath: path) }
        try CodexFiles.write(configuration, to: preferencesURL)
        self.configuration = configuration
        revision += 1
        // Invalidates in-flight probes of the old executable; never returns stale availability.
        for process in processes.values { await process.shutdown() }
    }

    /// Refreshes account/read(refreshToken:false) and every catalog page via a short-lived connection.
    public func snapshot() async throws -> [ProviderStatus] {
        try check(Self.account)
        let current = configuration, version = revision, id = UUID()
        do {
            let executable = try CodexProcess.discover(executablePath: current.executablePath)
            let process = CodexProcess(executable: executable, workingDirectory: workspace, requestTimeout: requestTimeout)
            processes[id] = process
            defer { processes.removeValue(forKey: id) }
            let result: ProviderStatus
            do {
                result = try await withTaskCancellationHandler {
                    try await process.start()
                    let account = try await process.request("account/read", .object(["refreshToken": .bool(false)]))
                    let auth = try Self.authentication(account)
                    let models = auth == .configured ? try await Self.catalog(process) : []
                    return ProviderStatus(configuration: current, authentication: auth, models: models)
                } onCancel: { Task { await process.shutdown() } }
            } catch {
                await process.shutdown()
                throw error
            }
            await process.shutdown()
            try Task.checkCancellation()
            guard !closed, version == revision else { throw CancellationError() }
            return [result]
        } catch {
            try Task.checkCancellation()
            guard !closed, version == revision else { throw CancellationError() }
            let message = ((error as? CodexRuntimeError) ?? .invalidOutput).localizedDescription
            return [ProviderStatus(configuration: current, authentication: .unavailable(message))]
        }
    }

    func prepare(model: ModelSelection) async throws -> URL {
        guard model.account == Self.account, Self.validIdentifier(model.modelID) else { throw ChatBackendError.noModel }
        let status = try await snapshot()[0]
        guard status.authentication == .configured else { throw ChatBackendError.unavailable("Codex CLI requires an existing ChatGPT login. \(Self.loginInstructions)") }
        guard status.models.contains(where: { $0.id == model }) else { throw ChatBackendError.noModel }
        return try CodexProcess.discover(executablePath: status.configuration.executablePath)
    }

    static func authentication(_ result: CodexJSON) throws -> AuthenticationState {
        guard case .bool = result["requiresOpenaiAuth"], case .object(let fields) = result else { throw CodexRuntimeError.invalidOutput }
        guard let account = fields["account"] else { throw CodexRuntimeError.invalidOutput }
        if account == .null { return .signedOut }
        switch account["type"].string {
        case "chatgpt":
            // Plans/entitlements are provider-controlled, including free and future plan names.
            guard case .object(let fields) = account, fields["email"] != nil,
                  account["email"] == .null || account["email"].string != nil,
                  let plan = account["planType"].string, Self.validIdentifier(plan) else { throw CodexRuntimeError.invalidOutput }
            return .configured
        case "apiKey": return .unavailable("Codex CLI is using API-key authentication. Choose ChatGPT with codex login in Terminal, then refresh.")
        default: return .unavailable("Codex CLI authentication kind is unsupported. An existing ChatGPT CLI login is required.")
        }
    }

    private static func catalog(_ process: CodexProcess) async throws -> [ChatModel] {
        var models: [ChatModel] = [], ids = Set<String>(), cursors = Set<String>()
        var cursor: CodexJSON = .null
        // Bounds reject a malicious/nonterminating catalog; never return a silently truncated result.
        for _ in 0..<1000 {
            try Task.checkCancellation()
            let result = try await process.request("model/list", .object(["cursor": cursor, "limit": .number(100), "includeHidden": .bool(false)]))
            guard let data = result["data"].array else { throw CodexRuntimeError.invalidOutput }
            for item in data {
                guard let id = item["model"].string, validIdentifier(id), let name = item["displayName"].string,
                      !name.isEmpty, name.utf8.count <= 1024 else { throw CodexRuntimeError.invalidOutput }
                if ids.insert(id).inserted { models.append(ChatModel(id: ModelSelection(account: account, modelID: id), displayName: name)) }
                guard models.count <= 10_000 else { throw CodexRuntimeError.invalidOutput }
            }
            if result["nextCursor"] == .null { return models }
            guard let next = result["nextCursor"].string, !next.isEmpty, next.utf8.count <= 4096,
                  cursors.insert(next).inserted else { throw CodexRuntimeError.invalidOutput }
            cursor = .string(next)
        }
        throw CodexRuntimeError.invalidOutput
    }

    static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    private func check(_ account: ProviderAccount) throws {
        guard !closed else { throw CodexRuntimeError.closed }
        guard account == Self.account else { throw ChatBackendError.noModel }
    }
    public func setAPIKey(_ key: String?, for account: ProviderAccount) async throws {
        try check(account); throw ChatBackendError.unavailable("Codex CLI credentials are managed by the official CLI. API keys are unsupported on this route.")
    }
    public func login(to account: ProviderAccount) async throws {
        try check(account); throw ChatBackendError.unavailable(Self.loginInstructions)
    }
    public func cancelLogin(to account: ProviderAccount) async {} // This service never owns a login.
    public func logout(from account: ProviderAccount) async throws {
        try check(account); throw ChatBackendError.unavailable(Self.loginInstructions)
    }
    public func shutdown() async {
        closed = true; revision += 1
        let active = Array(processes.values)
        for process in active { await process.shutdown() }
        processes.removeAll()
    }
}
