import Foundation
import Observation

/// Own in SwiftUI @State and read in body (directly or through typed environment injection).
@MainActor @Observable public final class LocalizationSettings {
    public static let defaultStorageKey = "DurableChat.languageOverride"
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String
    @ObservationIgnored private let preferredLanguages: @MainActor () -> [String]
    private var systemLanguage: AppLanguage

    public var choice: LanguageChoice {
        didSet {
            if choice == .system {
                defaults.removeObject(forKey: storageKey)
                refreshSystemLanguage()
            } else {
                defaults.set(choice.rawValue, forKey: storageKey)
            }
        }
    }

    public init(defaults: UserDefaults = .standard, storageKey: String = LocalizationSettings.defaultStorageKey,
                preferredLanguages: @escaping @MainActor () -> [String] = { Locale.preferredLanguages }) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.preferredLanguages = preferredLanguages
        systemLanguage = AppLanguage.negotiate(preferredLanguages())
        choice = LanguageChoice(persistedValue: defaults.string(forKey: storageKey))
        // Repair invalid values and canonicalize old language aliases without touching other defaults.
        if choice == .system { defaults.removeObject(forKey: storageKey) }
        else { defaults.set(choice.rawValue, forKey: storageKey) }
    }

    public var language: AppLanguage { choice.language ?? systemLanguage }
    public var locale: Locale { language.locale }
    /// Capture this on the main actor before passing it to detached/background work.
    public var localizer: Localizer { Localizer(language: language) }

    /// App integration should call on activation / NSLocale.currentLocaleDidChangeNotification.
    /// Explicit choice remains selected; resetting subsequently uses the newest preferences.
    public func refreshSystemLanguage() { systemLanguage = AppLanguage.negotiate(preferredLanguages()) }
    public func resetToSystem() { choice = .system }

    public func string(_ key: String, table: LocalizationTable = .common, fallback: String? = nil,
                       arguments: [String: LocalizationArgument] = [:]) -> String {
        localizer.string(key, table: table, fallback: fallback, arguments: arguments)
    }

    public func string(_ message: LocalizedMessage) -> String { localizer.string(message) }
    public func diagnostic(_ source: String, table: LocalizationTable = .runtime) -> String {
        localizer.diagnostic(source, table: table)
    }
}
