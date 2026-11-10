import Foundation

public struct LocalizationResolution: Equatable, Sendable {
    public enum Source: Equatable, Sendable { case localized, englishFallback, sourceFallback, keyFallback }
    public let text: String
    public let source: Source
}

/// Immutable, Sendable presentation snapshot. No global language, AppleLanguages mutation, or swizzling.
public struct Localizer: Sendable {
    public static var resources: Bundle { .module }
    public let language: AppLanguage
    public let locale: Locale
    /// Exact language sub-bundle, useful for simple `Text(tableName:bundle:)` lookups.
    /// Use `string`/`text` for the explicit per-key English fallback and interpolation contract.
    public let bundle: Bundle
    private let selectedBundle: Bundle?
    private let englishBundle: Bundle?

    public init(language: AppLanguage, resources: Bundle = Localizer.resources) {
        self.init(language: language, locale: language.locale, resources: resources)
    }

    /// A supported regional locale keeps its number/date conventions and selects matching resources.
    /// Unsupported locales (including zh-Hant) consistently use English resources AND locale.
    public init(locale: Locale, resources: Bundle = Localizer.resources) {
        let language = AppLanguage(identifier: locale.identifier)
        self.init(language: language ?? .english, locale: language == nil ? AppLanguage.english.locale : locale,
                  resources: resources)
    }

    private init(language: AppLanguage, locale: Locale, resources: Bundle) {
        self.language = language
        self.locale = locale
        selectedBundle = Self.languageBundle(language, resources: resources)
        englishBundle = Self.languageBundle(.english, resources: resources)
        bundle = selectedBundle ?? englishBundle ?? resources
    }

    static func languageBundle(_ language: AppLanguage, resources: Bundle) -> Bundle? {
        guard let url = resources.url(forResource: language.resourceIdentifier, withExtension: "lproj") else { return nil }
        return Bundle(url: url)
    }

    private func raw(_ key: String, table: LocalizationTable, bundle: Bundle?) -> String? {
        guard let bundle else { return nil }
        let missing = "\u{1F}AppLocalization.missing\u{1F}"
        let value = bundle.localizedString(forKey: key, value: missing, table: table.rawValue)
        return value == missing ? nil : value
    }

    public func string(_ key: String, table: LocalizationTable = .common, fallback: String? = nil,
                       arguments: [String: LocalizationArgument] = [:]) -> String {
        string(LocalizedMessage(key, table: table, fallback: fallback, arguments: arguments))
    }

    public func string(_ message: LocalizedMessage) -> String { resolve(message).text }

    public func resolve(_ message: LocalizedMessage) -> LocalizationResolution {
        switch message.content {
        case .plural(let count, let one, let other):
            return resolve(language == .english && count == 1 ? one : other)
        case .key(let key, let table, let fallback, let arguments):
            let english = raw(key, table: table, bundle: englishBundle)
            let source = english ?? fallback ?? key
            let sourceNames = LocalizationTemplate.placeholders(in: source)
            // Reject malformed or incompatible translations before interpolation.
            let candidates: [(String?, LocalizationResolution.Source)] = [
                (raw(key, table: table, bundle: selectedBundle), .localized),
                (english, .englishFallback), (fallback, .sourceFallback), (key, .keyFallback),
            ]
            for (candidate, origin) in candidates {
                guard let candidate, let sourceNames,
                      LocalizationTemplate.placeholders(in: candidate) == sourceNames,
                      let text = LocalizationTemplate.render(candidate, arguments: arguments, locale: locale) else { continue }
                return LocalizationResolution(text: text, source: origin)
            }
            // A bad caller template/argument contract must never crash or execute a format string.
            return LocalizationResolution(text: fallback ?? key, source: fallback == nil ? .keyFallback : .sourceFallback)
        }
    }

    /// For app-owned diagnostics already carried through Foundation contracts as English strings.
    /// Exact source-key lookup only; unknown provider/error text, braces and '%' remain verbatim.
    /// Call only at presentation, never on arbitrary transcript/user/model/code content.
    public func diagnostic(_ source: String, table: LocalizationTable = .runtime) -> String {
        guard let message = diagnosticMessage(source, table: table) else { return source }
        return string(message)
    }

    func diagnosticMessage(_ source: String, table: LocalizationTable) -> LocalizedMessage? {
        guard let english = raw(source, table: table, bundle: englishBundle),
              LocalizationTemplate.placeholders(in: english) == [] else { return nil }
        return LocalizedMessage(source, table: table, fallback: source)
    }
}
