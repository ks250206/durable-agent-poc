import ChatCore
import Foundation

/// Cursor owns browser credentials. This service persists preferences and calls only official CLI commands.
public actor CursorProviderSettingsService: ProviderSettingsService {
    public static let account = ProviderAccount(option: .cursor, providerID: "cursor")
    public static let loginInstructions = "Install Cursor CLI, then run agent login in Terminal to open Cursor's official browser login. Use agent status to check authentication."

    private let root: URL
    private let configurationURL: URL
    private var configuration: ProviderConfiguration
    private var loginProcess: CursorProcess?
    private var loginID: UUID?
    private var revision = 0

    public init(storageDirectory: URL = CursorProcess.defaultStorageDirectory) throws {
        root = storageDirectory.appendingPathComponent("control", isDirectory: true)
        configurationURL = storageDirectory.appendingPathComponent("preferences.json")
        try CursorFiles.prepare(storageDirectory)
        try CursorFiles.prepare(root)
        if FileManager.default.fileExists(atPath: configurationURL.path) {
            do {
                configuration = try JSONDecoder().decode(ProviderConfiguration.self, from: Data(contentsOf: configurationURL))
            } catch { throw CursorRuntimeError.storage }
            guard configuration.account == Self.account else { throw CursorRuntimeError.storage }
        } else { configuration = ProviderConfiguration(account: Self.account) }
    }

    public func update(_ configuration: ProviderConfiguration) async throws {
        try validate(configuration.account)
        guard loginProcess == nil else { throw ChatBackendError.busy }
        if let model = configuration.selectedModelID, !Self.validModel(model) { throw ChatBackendError.noModel }
        if let path = configuration.executablePath { _ = try CursorProcess.discover(executablePath: path) }
        try CursorFiles.write(configuration, to: configurationURL)
        self.configuration = configuration
        revision += 1
    }

    public func snapshot() async throws -> [ProviderStatus] {
        if loginProcess != nil { return [ProviderStatus(configuration: configuration, authentication: .signingIn)] }
        let current = configuration
        let version = revision
        do {
            let executable = try CursorProcess.discover(executablePath: current.executablePath)
            let help = try await command(executable, ["--help"])
            guard Self.supports(help) else { throw CursorRuntimeError.unsupportedCLI }
            let statusData = try await command(executable, ["status", "--format", "json"])
            guard let object = try? JSONSerialization.jsonObject(with: statusData) as? [String: Any],
                  let authenticated = object["authenticated"] as? Bool ?? object["isAuthenticated"] as? Bool else {
                throw CursorRuntimeError.invalidOutput
            }
            var models: [ChatModel] = []
            if authenticated {
                let data = try await command(executable, ["models"])
                models = Self.models(data)
            }
            guard version == revision, loginProcess == nil else { return try await snapshot() }
            return [ProviderStatus(configuration: current, authentication: authenticated ? .configured : .signedOut, models: models)]
        } catch is CancellationError { throw CancellationError() }
        catch CursorRuntimeError.cancelled { throw CursorRuntimeError.cancelled }
        catch {
            guard version == revision, loginProcess == nil else { return try await snapshot() }
            let message = (error as? CursorRuntimeError)?.errorDescription ?? "Cursor status is unavailable."
            return [ProviderStatus(configuration: current, authentication: .unavailable(message))]
        }
    }

    /// Used by the backend immediately before acceptance. No model call or implicit login.
    public func prepare(model: ModelSelection) async throws -> URL {
        guard model.account == Self.account, Self.validModel(model.modelID) else { throw ChatBackendError.noModel }
        let statuses = try await snapshot()
        guard let status = statuses.first, status.authentication == .configured else { throw ChatBackendError.disconnected }
        guard status.models.contains(where: { $0.id == model }) else { throw ChatBackendError.noModel }
        return try CursorProcess.discover(executablePath: status.configuration.executablePath)
    }

    public func setAPIKey(_ key: String?, for account: ProviderAccount) async throws {
        try validate(account)
        throw ChatBackendError.unavailable("Cursor uses its official browser login; API keys are not accepted by this service.")
    }

    public func login(to account: ProviderAccount) async throws {
        try validate(account)
        guard loginProcess == nil else { throw ChatBackendError.busy }
        let executable = try CursorProcess.discover(executablePath: configuration.executablePath)
        let process = CursorProcess(executable: executable, workingDirectory: root)
        let id = UUID()
        loginID = id; loginProcess = process; revision += 1
        defer {
            if loginID == id { loginProcess = nil; loginID = nil; revision += 1 }
        }
        try await process.run(arguments: ["login"], timeout: 300) { _ in }
    }

    public func cancelLogin(to account: ProviderAccount) async {
        guard account == Self.account else { return }
        // Keep the slot occupied until its Process has actually exited.
        loginProcess?.cancel()
    }

    public func logout(from account: ProviderAccount) async throws {
        try validate(account)
        guard loginProcess == nil else { throw ChatBackendError.busy }
        let executable = try CursorProcess.discover(executablePath: configuration.executablePath)
        _ = try await command(executable, ["logout"])
        revision += 1
    }

    private func validate(_ account: ProviderAccount) throws {
        guard account == Self.account else { throw ChatBackendError.unavailable("Unsupported Cursor provider account.") }
    }

    private func command(_ executable: URL, _ arguments: [String]) async throws -> Data {
        let output = CursorOutput()
        try await CursorProcess(executable: executable, workingDirectory: root).run(arguments: arguments, timeout: 30) {
            try await output.append($0)
        }
        return await output.value()
    }

    static func validModel(_ model: String) -> Bool {
        !model.isEmpty && model.utf8.count <= 256 && !model.hasPrefix("-") && !model.contains(where: { $0.isNewline || $0.isWhitespace })
    }

    static func supports(_ data: Data) -> Bool {
        let help = String(decoding: data, as: UTF8.self)
        return ["Cursor", "--print", "--mode", "ask", "--model", "--resume", "stream-json", "--stream-partial-output", "status", "login", "models"]
            .allSatisfy { help.contains($0) }
    }

    /// Official `models` is human-readable: `model-id - Display name` (optional selection marker).
    /// Unknown formats yield no selectable models; never invent or silently default a model.
    static func models(_ data: Data) -> [ChatModel] {
        let text = String(decoding: data, as: UTF8.self)
        var seen = Set<String>()
        return text.components(separatedBy: .newlines).compactMap { line in
            let clean = line.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            let parts = clean.components(separatedBy: " - ")
            guard parts.count >= 2 else { return nil }
            let id = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "* "))
            guard validModel(id), seen.insert(id).inserted else { return nil }
            let name = parts.dropFirst().joined(separator: " - ")
            return ChatModel(id: ModelSelection(account: account, modelID: id), displayName: name)
        }
    }
}
