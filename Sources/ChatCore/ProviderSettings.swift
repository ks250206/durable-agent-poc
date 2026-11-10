import Foundation

public enum ProviderOption: String, CaseIterable, Identifiable, Codable, Sendable {
    case apiKey, chatGPT, cursor
    public var id: Self { self }
    public var displayName: String {
        switch self {
        case .apiKey: "API key"
        case .chatGPT: "ChatGPT"
        case .cursor: "Cursor"
        }
    }
}

/// Authentication route plus runtime provider ID. OpenAI API and ChatGPT must have distinct accounts.
/// Examples: (.apiKey, "openai"), (.chatGPT, "openai-codex"), (.cursor, "cursor").
public struct ProviderAccount: Hashable, Codable, Sendable {
    public var option: ProviderOption
    public var providerID: String
    public init(option: ProviderOption, providerID: String) {
        self.option = option
        self.providerID = providerID
    }
}

public struct ModelSelection: Hashable, Codable, Sendable {
    public var account: ProviderAccount
    public var modelID: String
    public init(account: ProviderAccount, modelID: String) {
        self.account = account
        self.modelID = modelID
    }
}

public struct ChatModel: Identifiable, Equatable, Codable, Sendable {
    public var id: ModelSelection
    public var displayName: String
    public init(id: ModelSelection, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// Safe to persist with preferences. Never put keys, OAuth tokens, or CLI credentials here.
public struct ProviderConfiguration: Equatable, Codable, Sendable {
    public var account: ProviderAccount
    public var selectedModelID: String?
    public var executablePath: String?
    public init(account: ProviderAccount, selectedModelID: String? = nil, executablePath: String? = nil) {
        self.account = account
        self.selectedModelID = selectedModelID
        self.executablePath = executablePath
    }
}

public enum AuthenticationState: Equatable, Codable, Sendable {
    case unconfigured, signedOut, signingIn, configured
    case unavailable(String)
    case failed(String)
}

public struct ProviderStatus: Equatable, Codable, Sendable {
    public var configuration: ProviderConfiguration
    public var authentication: AuthenticationState
    public var models: [ChatModel]
    public init(
        configuration: ProviderConfiguration, authentication: AuthenticationState, models: [ChatModel] = []
    ) {
        self.configuration = configuration
        self.authentication = authentication
        self.models = models
    }
}

/// Runtime-owned settings/authentication boundary for #7/#8. No implementation or implicit login in #3.
/// Refresh snapshot after each operation. The UI owns the login Task; cancellation must dismiss authentication.
/// API keys/OAuth belong in Keychain; Cursor owns its official CLI credential store (do not extract tokens).
public protocol ProviderSettingsService: Sendable {
    func snapshot() async throws -> [ProviderStatus]
    func update(_ configuration: ProviderConfiguration) async throws
    func setAPIKey(_ key: String?, for account: ProviderAccount) async throws
    func login(to account: ProviderAccount) async throws
    func cancelLogin(to account: ProviderAccount) async
    func logout(from account: ProviderAccount) async throws
}
