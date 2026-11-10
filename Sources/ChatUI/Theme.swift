import AppKit
import AppLocalization
import ChatCore
import SwiftUI

/// Concrete sRGB components keep SwiftUI and AppKit on the same resolved palette.
public struct ThemeColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let opacity: Double

    public init(hex: UInt32, opacity: Double = 1) {
        red = Double((hex >> 16) & 0xff) / 255
        green = Double((hex >> 8) & 0xff) / 255
        blue = Double(hex & 0xff) / 255
        self.opacity = min(1, max(0, opacity))
    }

    public var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity) }
    public var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: opacity) }
}

/// Named roles, not AppKit ambient colors. All readable text roles work on every content surface.
public struct ChatPalette: Equatable, Sendable {
    public let mainCanvas: ThemeColor
    public let sidebar: ThemeColor
    public let raised: ThemeColor
    public let composer: ThemeColor
    public let code: ThemeColor
    public let userBubble: ThemeColor
    public let active: ThemeColor
    public let hover: ThemeColor
    public let stroke: ThemeColor
    public let focus: ThemeColor
    public let primaryText: ThemeColor
    public let secondaryText: ThemeColor
    public let mutedText: ThemeColor
    public let accent: ThemeColor
    public let success: ThemeColor
    public let warning: ThemeColor
    public let error: ThemeColor
    public let textOnAccent: ThemeColor
    public let shadow: ThemeColor

    public init(colorScheme: ColorScheme, contrast: ColorSchemeContrast = .standard) {
        let increased = contrast == .increased
        if colorScheme == .dark {
            mainCanvas = ThemeColor(hex: 0x151515)
            sidebar = ThemeColor(hex: 0x242426)
            raised = ThemeColor(hex: 0x29292c)
            composer = ThemeColor(hex: 0x2e2e30)
            code = ThemeColor(hex: 0x1c1c1e)
            userBubble = ThemeColor(hex: 0x2c3443)
            active = ThemeColor(hex: 0x303d52)
            hover = ThemeColor(hex: 0x303033)
            stroke = ThemeColor(hex: increased ? 0x94949b : 0x505055)
            focus = ThemeColor(hex: increased ? 0xb4d2ff : 0x88ade1)
            primaryText = ThemeColor(hex: increased ? 0xffffff : 0xf1f0ee)
            secondaryText = ThemeColor(hex: increased ? 0xe3e2df : 0xc9c7c3)
            mutedText = ThemeColor(hex: increased ? 0xcac9c5 : 0xa9a8a4)
            accent = ThemeColor(hex: increased ? 0xb4d2ff : 0x9abdec)
            success = ThemeColor(hex: 0x9bd2b1)
            warning = ThemeColor(hex: 0xe7c383)
            error = ThemeColor(hex: 0xf0a2a5)
            textOnAccent = ThemeColor(hex: 0x151515)
            shadow = ThemeColor(hex: 0x000000, opacity: increased ? 0 : 0.25)
        } else {
            mainCanvas = ThemeColor(hex: 0xfaf9f7)
            sidebar = ThemeColor(hex: 0xf0efed)
            raised = ThemeColor(hex: 0xffffff)
            composer = ThemeColor(hex: 0xe8e7e4)
            code = ThemeColor(hex: 0xf1f0ed)
            userBubble = ThemeColor(hex: 0xe0e8f3)
            active = ThemeColor(hex: 0xdce6f3)
            hover = ThemeColor(hex: 0xe5e4e1)
            stroke = ThemeColor(hex: increased ? 0x65636a : 0x9c9a95)
            focus = ThemeColor(hex: increased ? 0x254f83 : 0x456999)
            primaryText = ThemeColor(hex: increased ? 0x111113 : 0x242426)
            secondaryText = ThemeColor(hex: increased ? 0x36363b : 0x505055)
            mutedText = ThemeColor(hex: increased ? 0x4b4b51 : 0x626267)
            accent = ThemeColor(hex: increased ? 0x254f83 : 0x385f91)
            success = ThemeColor(hex: 0x2b6748)
            warning = ThemeColor(hex: 0x795400)
            error = ThemeColor(hex: 0xa5343d)
            textOnAccent = ThemeColor(hex: 0xffffff)
            shadow = ThemeColor(hex: 0x242426, opacity: increased ? 0 : 0.10)
        }
    }
}

/// Public metrics are shared by the later workspace, composer, transcript and navigation owners.
public enum ChatTheme {
    public static func palette(colorScheme: ColorScheme, contrast: ColorSchemeContrast = .standard) -> ChatPalette {
        ChatPalette(colorScheme: colorScheme, contrast: contrast)
    }

    // Compatibility surfaces: keep existing consumers source-compatible and resolve against the
    // supplied drawing appearance (including forced Light/Dark), never NSApp/system appearance.
    public static let background = adaptiveColor(\.mainCanvas)
    public static let sidebar = adaptiveColor(\.sidebar)
    public static let inset = adaptiveColor(\.raised)
    public static let separator = adaptiveColor(\.stroke)
    public static let transcriptWidth: CGFloat = 760

    private static func adaptiveColor(_ role: KeyPath<ChatPalette, ThemeColor> & Sendable) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.accessibilityHighContrastDarkAqua,
                .accessibilityHighContrastAqua, .darkAqua, .aqua])
            let dark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
            let increased = match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
            return palette(colorScheme: dark ? .dark : .light, contrast: increased ? .increased : .standard)[keyPath: role].nsColor
        })
    }

    public enum Spacing {
        public static let xSmall: CGFloat = 4
        public static let small: CGFloat = 8
        public static let medium: CGFloat = 12
        public static let large: CGFloat = 16
        public static let xLarge: CGFloat = 24
        public static let section: CGFloat = 32
    }
    public enum Radii {
        public static let control: CGFloat = 6
        public static let code: CGFloat = 8
        public static let message: CGFloat = 16
        public static let composer: CGFloat = 20
    }
    public enum Dimensions {
        public static let readableWidth: CGFloat = ChatTheme.transcriptWidth
        public static let sidebarWidth: CGFloat = 248
        public static let headerHeight: CGFloat = 52
        public static let controlHeight: CGFloat = 32
        public static let composerMinHeight: CGFloat = 80
        public static let composerMaxHeight: CGFloat = 180
        public static let promptRailWidth: CGFloat = 28
        public static let popoverWidth: CGFloat = 320
    }
    public enum Shadows {
        /// Pair with palette.shadow; increased contrast removes the shadow in favor of a stroke.
        public static let composerRadius: CGFloat = 16
        public static let composerY: CGFloat = 4
        public static let popoverRadius: CGFloat = 12
        public static let popoverY: CGFloat = 3
    }
    public enum Typography {
        public static let title: Font = .system(size: 22, weight: .semibold)
        public static let heading: Font = .system(size: 17, weight: .semibold)
        public static let body: Font = .system(size: 15)
        public static let secondary: Font = .system(size: 13)
        public static let caption: Font = .system(size: 11)
        public static let code: Font = .system(size: 13, design: .monospaced)
        @MainActor public static var editor: NSFont { .systemFont(ofSize: 15) }
        @MainActor public static var nativeCode: NSFont { .monospacedSystemFont(ofSize: 13, weight: .regular) }
    }
}

/// Keep the reading column usable before offering persistent auxiliary panes.
struct WorkspaceLayout: Equatable {
    let width: CGFloat
    var inlineSidebar: Bool { width >= 780 }
    var inlineMinimap: Bool { width >= 1080 }
    static let sidebarWidth: CGFloat = 248
    static let minimapWidth: CGFloat = 144
}

struct ConnectionPresentation: Equatable {
    let title: String
    let symbol: String
    let detail: String?

    init(_ state: ConnectionState, localizer: Localizer = Localizer(language: .english), diagnosticTemplates: [DiagnosticTemplate] = []) {
        switch state {
        case .connected: (title, symbol, detail) = (localizer.chat("Connected"), "checkmark.circle", nil)
        case .connecting: (title, symbol, detail) = (localizer.chat("Connecting…"), "network", localizer.chat("Waiting for the backend connection."))
        case .disconnected:
            (title, symbol, detail) = (localizer.chat("Disconnected"), "network.slash", localizer.chat("Connect a provider in Settings to send messages."))
        case .demo:
            (title, symbol, detail) = (localizer.chat("Demo · Read only"), "eye", localizer.chat("Sample conversations. Sending and creating conversations are disabled."))
        case .failed(let message): (title, symbol, detail) = (localizer.chat("Connection failed"), "exclamationmark.triangle", localizer.diagnostic(message, templates: diagnosticTemplates))
        }
    }
}
