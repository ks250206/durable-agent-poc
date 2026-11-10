import Foundation
import Observation
import SwiftUI

/// Stored identifiers are independent of language and of the current macOS appearance.
public enum AppearanceChoice: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    public var id: Self { self }
    public init(persistedValue: String?) { self = persistedValue.flatMap(Self.init(rawValue:)) ?? .system }

    /// Keys belong to LocalizationTable.appearance, including System (not Common).
    public var nameKey: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Apply at each presentation root. nil releases the override and follows macOS.
    public var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Own one instance and inject it into every presentation. No personal defaults are implicit.
/// This model owns only the override; SwiftUI's live environment supplies System and a11y values.
@MainActor @Observable public final class AppearanceSettings {
    public static let defaultStorageKey = "DurableChat.appearanceOverride"
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String

    public var choice: AppearanceChoice {
        didSet { persist() }
    }

    public init(defaults: UserDefaults, storageKey: String = AppearanceSettings.defaultStorageKey) {
        self.defaults = defaults
        self.storageKey = storageKey
        choice = AppearanceChoice(persistedValue: defaults.string(forKey: storageKey))
        persist()
    }

    public var preferredColorScheme: ColorScheme? { choice.preferredColorScheme }
    public func resetToSystem() { choice = .system }

    /// Read during body/updateNSView, not once at initialization. Explicit choices override the
    /// supplied environment scheme; System resolves again whenever that environment changes.
    public func resolve(systemColorScheme: ColorScheme, contrast: ColorSchemeContrast = .standard,
                        reduceMotion: Bool = false) -> ResolvedAppearance {
        ResolvedAppearance(colorScheme: preferredColorScheme ?? systemColorScheme,
                           contrast: contrast, reduceMotion: reduceMotion)
    }

    private func persist() {
        if choice == .system { defaults.removeObject(forKey: storageKey) }
        else { defaults.set(choice.rawValue, forKey: storageKey) }
    }
}
