import AppLocalization
import Foundation
import Observation
import Testing

@Test func languageAliasesAndOrderedNegotiation() {
    let aliases: [(String, AppLanguage)] = [
        ("en", .english), ("en-US", .english), ("en_GB", .english), ("en-Latn-001", .english),
        ("ja", .japanese), ("ja-jp", .japanese), ("JA_JP", .japanese),
        ("zh", .simplifiedChinese), ("zh-CN", .simplifiedChinese), ("zh_SG", .simplifiedChinese),
        ("zh-Hans", .simplifiedChinese), ("zh-Hans-CN", .simplifiedChinese),
        ("ko", .korean), ("ko-KR", .korean),
    ]
    for (identifier, language) in aliases {
        #expect(AppLanguage(identifier: identifier) == language)
        #expect(LanguageChoice(persistedValue: identifier).language == language)
    }
    for invalid in ["", "fr-FR", "zh-Hant", "zh-TW", "zh-HK", "zh-MO", "zh-Hant-CN", "zh-Abcd", "bogus", "ja-invalid", "en--US", " ja ", "en-US\n"] {
        #expect(AppLanguage(identifier: invalid) == nil)
        #expect(LanguageChoice(persistedValue: invalid) == .system)
    }
    #expect(LanguageChoice(persistedValue: nil) == .system)
    #expect(LanguageChoice(persistedValue: "system") == .system)
    #expect(AppLanguage.negotiate(["fr-FR", "ja-JP", "en-US"]) == .japanese)
    #expect(AppLanguage.negotiate(["zh-Hant-TW", "ko-KR", "en"]) == .korean)
    #expect(AppLanguage.negotiate(["de-DE", "fr"]) == .english)
    #expect(AppLanguage.negotiate([]) == .english)
    #expect(AppLanguage.japanese.resourceIdentifier == "ja")
}

@MainActor @Test func overridePersistenceReopenResetAndInvalidStorage() throws {
    let suite = "AppLocalizationTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let key = "test.language"
    defaults.set("keep", forKey: "unrelated")
    let settings = LocalizationSettings(defaults: defaults, storageKey: key, preferredLanguages: { ["fr", "ko-KR"] })
    #expect(settings.choice == .system)
    #expect(settings.language == .korean)
    for choice in LanguageChoice.allCases where choice != .system {
        settings.choice = choice
        #expect(defaults.string(forKey: key) == choice.rawValue)
        let reopened = LocalizationSettings(defaults: defaults, storageKey: key, preferredLanguages: { ["ja-JP"] })
        #expect(reopened.choice == choice)
        #expect(reopened.language == choice.language)
    }
    settings.resetToSystem()
    #expect(settings.choice == .system)
    #expect(settings.language == .korean)
    #expect(defaults.object(forKey: key) == nil)
    #expect(LocalizationSettings(defaults: defaults, storageKey: key, preferredLanguages: { ["ja"] }).language == .japanese)
    for invalid: Any in ["fr-FR", "en-corrupt", 123, ["ja"], "zh-Hant"] {
        defaults.set(invalid, forKey: key)
        let repaired = LocalizationSettings(defaults: defaults, storageKey: key, preferredLanguages: { ["zh-CN"] })
        #expect(repaired.choice == .system)
        #expect(repaired.language == .simplifiedChinese)
        #expect(defaults.object(forKey: key) == nil)
    }
    defaults.set("ja", forKey: key)
    #expect(LocalizationSettings(defaults: defaults, storageKey: key).choice == .japanese)
    #expect(defaults.string(forKey: key) == "ja-JP")
    #expect(defaults.string(forKey: "unrelated") == "keep")
}

private final class Changes: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func record() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@MainActor private final class Preferences {
    var languages = ["ja-JP"]
}

@MainActor @Test func switchingImmediatelyInvalidatesBodyReadsAndRefreshesSystem() throws {
    let suite = "AppLocalizationTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = Preferences()
    let settings = LocalizationSettings(defaults: defaults, preferredLanguages: { preferences.languages })
    let changes = Changes()
    let initial = withObservationTracking {
        settings.string("Language")
    } onChange: { changes.record() }
    #expect(initial == "言語")
    settings.choice = .korean
    // No task hop or view rebuild / `.id(language)` is required.
    #expect(changes.value == 1)
    #expect(settings.string("Language") == "언어")
    #expect(settings.locale == AppLanguage.korean.locale)
    preferences.languages = ["zh-Hans"]
    settings.refreshSystemLanguage()
    #expect(settings.language == .korean)
    settings.resetToSystem()
    #expect(settings.string("Language") == "语言")
    let systemChanges = Changes()
    withObservationTracking {
        _ = settings.localizer.string("Language")
        _ = settings.locale
    } onChange: { systemChanges.record() }
    preferences.languages = ["unsupported", "en-GB"]
    settings.refreshSystemLanguage()
    #expect(systemChanges.value == 1)
    #expect(settings.string("Language") == "Language")
}
