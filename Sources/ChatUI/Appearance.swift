import AppKit
import SwiftUI

/// A presentation snapshot, shared by SwiftUI colors and AppKit native controls.
/// Recompute on scheme/contrast/motion/choice changes; never use it as a view identity.
public struct ResolvedAppearance: Equatable, Sendable {
    public let colorScheme: ColorScheme
    public let contrast: ColorSchemeContrast
    public let reduceMotion: Bool

    public init(colorScheme: ColorScheme, contrast: ColorSchemeContrast = .standard, reduceMotion: Bool = false) {
        self.colorScheme = colorScheme
        self.contrast = contrast
        self.reduceMotion = reduceMotion
    }

    public var palette: ChatPalette { ChatPalette(colorScheme: colorScheme, contrast: contrast) }
    public var strokeWidth: CGFloat { contrast == .increased ? 1.5 : 1 }
    public var focusWidth: CGFloat { contrast == .increased ? 3 : 2 }
    /// Use for hover/selection feedback. Reduced motion makes updates immediate, with no spatial animation.
    public var feedbackAnimation: Animation? { reduceMotion ? nil : .easeOut(duration: 0.14) }

    /// Assign to a native view/window, never NSApp.appearance. Assign the base Aqua/Dark Aqua;
    /// AppKit applies the user's Increase Contrast setting itself. Accessibility appearance names
    /// are matching-only, not valid overrides. Custom chrome uses this snapshot's contrast palette.
    @MainActor public var nsAppearance: NSAppearance {
        NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)!
    }

    /// Resolve system/selection colors using this snapshot, rather than ambient drawing appearance.
    /// Semantic palette colors are already concrete and can use ThemeColor.nsColor directly.
    @MainActor public func resolveAppKitColor(_ color: NSColor) -> NSColor? {
        var resolved: NSColor?
        nsAppearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
        return resolved
    }
}

/// Reads live scheme and accessibility values. An optional injected owner honors forced choices;
/// standalone previews/consumers use their SwiftUI environment and never read UserDefaults.
@propertyWrapper @MainActor public struct ChatAppearance: DynamicProperty {
    @Environment(AppearanceSettings.self) private var settings: AppearanceSettings?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}
    public var wrappedValue: ResolvedAppearance {
        settings?.resolve(systemColorScheme: colorScheme, contrast: contrast, reduceMotion: reduceMotion)
            ?? ResolvedAppearance(colorScheme: colorScheme, contrast: contrast, reduceMotion: reduceMotion)
    }
}
