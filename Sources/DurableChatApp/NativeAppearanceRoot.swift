import AppKit
import ChatUI
import SwiftUI

extension View {
    /// Apply to every app-owned presentation root (including future #38 tab/rail popovers).
    /// Share the session owner; this modifier never owns state, defaults, or an editor.
    func appAppearance(_ settings: AppearanceSettings) -> some View {
        environment(settings).modifier(AppAppearanceRoot(settings: settings))
    }
}

private struct AppAppearanceRoot: ViewModifier {
    let settings: AppearanceSettings
    @ChatAppearance private var appearance

    func body(content: Content) -> some View {
        content
            .background(NativeWindowAppearance(choice: settings.choice, resolved: appearance))
            .preferredColorScheme(settings.preferredColorScheme)
    }
}

/// SwiftUI's preference controls its presentation; the owning native window also needs the
/// override for inherited AppKit controls, window chrome and native popovers. Never set NSApp.
private struct NativeWindowAppearance: NSViewRepresentable {
    let choice: AppearanceChoice
    let resolved: ResolvedAppearance

    func makeNSView(context: Context) -> AppearanceAnchor { AppearanceAnchor() }
    func updateNSView(_ view: AppearanceAnchor, context: Context) {
        view.preferredAppearance = choice == .system ? nil : resolved.nsAppearance
        view.apply()
    }

    final class AppearanceAnchor: NSView {
        var preferredAppearance: NSAppearance?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }
        func apply() {
            guard let window, window.appearance?.name != preferredAppearance?.name else { return }
            // nil restores live AppKit inheritance when returning to System. No launch-time
            // appearance snapshot or notification observer is retained.
            window.appearance = preferredAppearance
        }
    }
}
