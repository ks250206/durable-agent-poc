import Foundation

/// Public identifiers are persisted; Japanese resources deliberately use `ja.lproj`.
public enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case english = "en"
    case japanese = "ja-JP"
    case simplifiedChinese = "zh-Hans"
    case korean = "ko"

    public var id: Self { self }
    public var locale: Locale { Locale(identifier: rawValue) }
    public var resourceIdentifier: String { self == .japanese ? "ja" : rawValue }

    public var nameKey: String {
        switch self {
        case .english: "English"
        case .japanese: "Japanese"
        case .simplifiedChinese: "Chinese (Simplified)"
        case .korean: "Korean"
        }
    }

    /// Accept language/region aliases, but never silently map Traditional Chinese to Simplified.
    public init?(identifier: String) {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        // Accept the language[-Script][-REGION] forms used by system preferences.
        // Do not accidentally treat arbitrary corrupt values like `ja-invalid` as overrides.
        guard normalized.range(of: "\\A[a-z]{2,3}(-[a-z]{4})?(-([a-z]{2}|[0-9]{3}))?\\z",
                               options: .regularExpression) != nil else { return nil }
        let parts = normalized.split(separator: "-").map(String.init)
        switch parts[0] {
        case "en": self = .english
        case "ja": self = .japanese
        case "ko": self = .korean
        case "zh":
            if parts.dropFirst().contains(where: { $0.count == 4 && $0 != "hans" && $0 != "hant" }) { return nil }
            if parts.contains("hant") { return nil }
            if !parts.contains("hans"), parts.contains(where: { ["tw", "hk", "mo"].contains($0) }) { return nil }
            self = .simplifiedChinese
        default: return nil
        }
    }

    /// Walk the ordered preferences before falling back to English (not just the first entry).
    public static func negotiate(_ preferredLanguages: [String]) -> Self {
        preferredLanguages.lazy.compactMap { Self(identifier: $0) }.first ?? .english
    }
}

public enum LanguageChoice: String, CaseIterable, Identifiable, Codable, Sendable {
    case system = "system"
    case japanese = "ja-JP"
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case korean = "ko"

    public var id: Self { self }
    public var language: AppLanguage? {
        self == .system ? nil : AppLanguage(rawValue: rawValue)
    }
    public var nameKey: String { language?.nameKey ?? "System" }

    /// Missing, corrupt, and unsupported saved overrides all mean System.
    public init(persistedValue: String?) {
        if let persistedValue, let language = AppLanguage(identifier: persistedValue) {
            self = Self(rawValue: language.rawValue) ?? .system
        } else {
            self = .system
        }
    }
}
