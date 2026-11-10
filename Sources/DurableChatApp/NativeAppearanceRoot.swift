import AppKit
import ChatUI
import SwiftUI

private typealias AppearanceRootState<Value> = SwiftUI.State<Value>

extension View {
    /// Apply to every app-owned presentation root (including future #38 tab/rail popovers).
    /// Share the session owner; this modifier never owns preferences or an editor.
    func appAppearance(_ settings: AppearanceSettings) -> some View {
        modifier(AppAppearanceRoot(settings: settings)).environment(settings)
    }
}

private struct AppAppearanceRoot: ViewModifier {
    let settings: AppearanceSettings
    @ChatAppearance private var appearance
    @AppearanceRootState<ColorScheme?> private var systemColorScheme = nil

    func body(content: Content) -> some View {
        let resolved = settings.resolve(systemColorScheme: systemColorScheme ?? appearance.colorScheme,
                                        contrast: appearance.contrast, reduceMotion: appearance.reduceMotion)
        content
            // SwiftUI can retain a forced scheme in a representable's platform host
            // while marked text is active. Supply the live system scheme explicitly
            // when the preference is cleared, without recreating that native editor.
            .environment(\.colorScheme, resolved.colorScheme)
            .background(NativeWindowAppearance(choice: settings.choice, resolved: resolved) { scheme in
                if systemColorScheme != scheme { systemColorScheme = scheme }
            })
            .preferredColorScheme(settings.preferredColorScheme)
    }
}

/// SwiftUI's preference controls its presentation; the owning native window also needs the
/// override for inherited AppKit controls, window chrome and native popovers. Never set NSApp.
private struct NativeWindowAppearance: NSViewRepresentable {
    let choice: AppearanceChoice
    let resolved: ResolvedAppearance
    let onSystemColorScheme: (ColorScheme) -> Void

    func makeNSView(context: Context) -> AppearanceAnchor {
        let view = AppearanceAnchor()
        view.observeSystemAppearance()
        return view
    }
    func updateNSView(_ view: AppearanceAnchor, context: Context) {
        view.preferredAppearance = choice == .system ? nil : resolved.nsAppearance
        view.onSystemColorScheme = onSystemColorScheme
        view.apply()
    }
    static func dismantleNSView(_ view: AppearanceAnchor, coordinator: ()) {
        view.stopObservingSystemAppearance()
    }

    final class AppearanceAnchor: NSView {
        var preferredAppearance: NSAppearance?
        var onSystemColorScheme: ((ColorScheme) -> Void)?
        private var systemAppearanceObservation: NSKeyValueObservation?
        func observeSystemAppearance() {
            systemAppearanceObservation = NSApplication.shared.observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.reportSystemColorScheme() }
            }
        }
        func stopObservingSystemAppearance() {
            systemAppearanceObservation?.invalidate()
            systemAppearanceObservation = nil
            onSystemColorScheme = nil
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            reportSystemColorScheme()
        }
        func apply() {
            guard let window else { return }
            // nil restores live AppKit inheritance when returning to System.
            if window.appearance?.name != preferredAppearance?.name { window.appearance = preferredAppearance }
            reportSystemColorScheme()
        }
        private func reportSystemColorScheme() {
            let scheme: ColorScheme = NSApplication.shared.effectiveAppearance
                .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
            // AppKit may call during updateNSView. Publish after the update transaction.
            Task { @MainActor [weak self] in self?.onSystemColorScheme?(scheme) }
        }
    }
}
