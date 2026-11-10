import AppLocalization
import Foundation
import Observation
import SwiftUI
import Testing
import ChatUI

private final class AppearanceChanges: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func record() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@MainActor @Test func appearancePersistsCanonicalChoicesReopensRepairsAndResetsOnlyItsOwnKey() throws {
    let suite = "AppearanceTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let key = AppearanceSettings.defaultStorageKey
    defaults.set("ja-JP", forKey: LocalizationSettings.defaultStorageKey)
    defaults.set("keep", forKey: "unrelated")
    let settings = AppearanceSettings(defaults: defaults)
    #expect(settings.choice == .system)
    #expect(settings.preferredColorScheme == nil)
    #expect(defaults.object(forKey: key) == nil)

    for choice in AppearanceChoice.allCases {
        settings.choice = choice
        let reopened = AppearanceSettings(defaults: defaults)
        #expect(reopened.choice == choice)
        #expect(reopened.preferredColorScheme == choice.preferredColorScheme)
        #expect(defaults.string(forKey: key) == (choice == .system ? nil : choice.rawValue))
    }
    settings.resetToSystem()
    #expect(AppearanceSettings(defaults: defaults).choice == .system)
    #expect(defaults.object(forKey: key) == nil)
    for invalid: Any in ["Dark", " light ", "dark\n", "unsupported", "", 123, true, ["dark"], ["choice": "light"], "system"] {
        defaults.set(invalid, forKey: key)
        #expect(AppearanceSettings(defaults: defaults).choice == .system)
        #expect(defaults.object(forKey: key) == nil)
    }
    let other = AppearanceSettings(defaults: defaults, storageKey: "independent.appearance")
    other.choice = .light
    #expect(defaults.string(forKey: "independent.appearance") == "light")
    #expect(defaults.object(forKey: key) == nil)
    #expect(defaults.string(forKey: LocalizationSettings.defaultStorageKey) == "ja-JP")
    #expect(defaults.string(forKey: "unrelated") == "keep")
    #expect(defaults.persistentDomain(forName: suite)?["AppleInterfaceStyle"] == nil)
    #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] == nil)
}

@MainActor @Test func appearanceInvalidatesSynchronouslyAndSystemResolvesLiveWithoutPersistingOSState() throws {
    let suite = "AppearanceObservationTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppearanceSettings(defaults: defaults)
    let changes = AppearanceChanges()
    withObservationTracking {
        _ = settings.resolve(systemColorScheme: .light).palette
        _ = settings.preferredColorScheme
    } onChange: { changes.record() }
    settings.choice = .dark
    #expect(changes.value == 1)
    #expect(settings.preferredColorScheme == .dark)
    #expect(settings.resolve(systemColorScheme: .light).colorScheme == .dark)
    settings.choice = .light
    #expect(settings.resolve(systemColorScheme: .dark).colorScheme == .light)
    settings.resetToSystem()
    for scheme in [ColorScheme.light, .dark] {
        let resolved = settings.resolve(systemColorScheme: scheme, contrast: .increased, reduceMotion: true)
        #expect(resolved.colorScheme == scheme)
        #expect(resolved.contrast == .increased)
        #expect(resolved.reduceMotion)
        #expect(resolved.feedbackAnimation == nil)
        #expect(resolved.strokeWidth > 1)
        #expect(resolved.focusWidth > 2)
        #expect(defaults.object(forKey: AppearanceSettings.defaultStorageKey) == nil)
    }
    #expect(ResolvedAppearance(colorScheme: .light).feedbackAnimation != nil)
}

private func luminance(_ color: ThemeColor) -> Double {
    func linear(_ component: Double) -> Double {
        component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
}

private func ratio(_ first: ThemeColor, _ second: ThemeColor) -> Double {
    let a = luminance(first), b = luminance(second)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

@Test func palettesHaveDistinctLayersReadableTextAndAccessibleFocusInBothSchemesAndContrasts() {
    for scheme in [ColorScheme.light, .dark] {
        for contrast in [ColorSchemeContrast.standard, .increased] {
            let palette = ChatTheme.palette(colorScheme: scheme, contrast: contrast)
            let surfaces = [palette.mainCanvas, palette.sidebar, palette.raised, palette.composer,
                            palette.code, palette.userBubble, palette.active, palette.hover]
            for (index, surface) in surfaces.enumerated() {
                #expect(!surfaces.prefix(index).contains(surface))
                for text in [palette.primaryText, palette.secondaryText, palette.mutedText,
                             palette.accent, palette.success, palette.warning, palette.error] {
                    #expect(ratio(text, surface) >= 4.5, "Text contrast \(ratio(text, surface)), \(scheme)/\(contrast)")
                }
                #expect(ratio(palette.focus, surface) >= 3)
                if contrast == .increased { #expect(ratio(palette.stroke, surface) >= 3) }
            }
            #expect(ratio(palette.textOnAccent, palette.accent) >= 4.5)
            #expect(palette.shadow.opacity == (contrast == .increased ? 0 : (scheme == .dark ? 0.25 : 0.1)))
        }
    }
    #expect(ChatTheme.Dimensions.readableWidth == ChatTheme.transcriptWidth)
    #expect(ChatTheme.Dimensions.composerMinHeight < ChatTheme.Dimensions.composerMaxHeight)
}

@Test func appearanceTableHasExactFourLanguageCoverageAndRealTranslations() {
    let expected: Set<String> = ["Appearance", "System", "Light", "Dark",
                               "Use the system appearance, or always use Light or Dark.", "Reset to System"]
    #expect(LocalizationValidation.issues(tables: [.appearance]).isEmpty)
    let titles: [AppLanguage: String] = [.english: "Appearance", .japanese: "外観",
                                       .simplifiedChinese: "外观", .korean: "화면 모드"]
    for language in AppLanguage.allCases {
        #expect(LocalizationValidation.keys(table: .appearance, language: language) == expected)
        let localizer = Localizer(language: language)
        for key in expected {
            let resolution = localizer.resolve(LocalizedMessage(key, table: .appearance))
            #expect(resolution.source == .localized)
            #expect(!resolution.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if language != .english { #expect(resolution.text != key) }
        }
        #expect(localizer.string("Appearance", table: .appearance) == titles[language])
        for choice in AppearanceChoice.allCases { #expect(expected.contains(choice.nameKey)) }
    }
}
