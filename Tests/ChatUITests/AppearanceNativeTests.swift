import AppKit
import AppLocalization
import Observation
import SwiftUI
import Testing
@testable import ChatUI

@MainActor @Observable private final class AppearanceHostState {
    var systemScheme: ColorScheme = .light
    var language: AppLanguage = .english
    var contrast: ColorSchemeContrast = .standard
    var reduceMotion = false
}

@MainActor private final class AppearanceNativeProbe {
    var snapshots: [ResolvedAppearance] = []
    weak var view: NSView?
    var latest: ResolvedAppearance? { snapshots.last }
}

/// A native consumer of the public contract, deliberately independent of future composer wiring.
@MainActor private struct AppearanceSwatch: NSViewRepresentable {
    let appearance: ResolvedAppearance
    let probe: AppearanceNativeProbe
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        probe.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        view.appearance = appearance.nsAppearance
        view.layer?.backgroundColor = appearance.palette.composer.nsColor.cgColor
        probe.snapshots.append(appearance)
    }
}

@MainActor private struct AppearanceTestContent: View {
    @ChatAppearance private var appearance
    let settings: AppearanceSettings
    let state: AppearanceHostState
    let input: ComposerInput
    let probe: AppearanceNativeProbe
    @Binding var draft: String

    var body: some View {
        // Accessibility environment values are OS-owned/read-only. Inject deterministic values
        // through the public resolver instead of changing the user's accessibility preferences.
        let appearance = settings.resolve(systemColorScheme: self.appearance.colorScheme,
                                          contrast: state.contrast, reduceMotion: state.reduceMotion)
        VStack(spacing: ChatTheme.Spacing.large) {
            AppearancePickerView(settings: settings, localizer: Localizer(language: state.language))
            HStack(spacing: ChatTheme.Spacing.small) {
                ForEach(0..<6) { index in
                    let colors = [appearance.palette.mainCanvas, appearance.palette.sidebar,
                                  appearance.palette.raised, appearance.palette.composer,
                                  appearance.palette.code, appearance.palette.userBubble]
                    RoundedRectangle(cornerRadius: ChatTheme.Radii.control).fill(colors[index].color)
                        .overlay(RoundedRectangle(cornerRadius: ChatTheme.Radii.control)
                            .stroke(appearance.palette.stroke.color, lineWidth: appearance.strokeWidth))
                }
            }.frame(height: 72)
            CompositionTextView(text: $draft, input: input, onSubmit: {})
                .frame(height: 140)
            AppearanceSwatch(appearance: appearance, probe: probe).frame(height: 40)
        }
        .font(ChatTheme.Typography.body)
        .foregroundStyle(appearance.palette.primaryText.color)
        .padding(ChatTheme.Spacing.xLarge)
        .background(appearance.palette.mainCanvas.color)
    }
}

@MainActor private struct AppearanceTestRoot: View {
    let settings: AppearanceSettings
    let state: AppearanceHostState
    let input: ComposerInput
    let probe: AppearanceNativeProbe
    @Binding var draft: String
    var body: some View {
        AppearanceTestContent(settings: settings, state: state, input: input, probe: probe, draft: $draft)
            .environment(settings)
            .environment(\.colorScheme, state.systemScheme)
            .environment(\.locale, state.language.locale)
            .preferredColorScheme(settings.preferredColorScheme)
    }
}

@MainActor private func pumpAppearanceLoop() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005)) }

@MainActor private func settleAppearance(_ predicate: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !predicate(), ContinuousClock.now < deadline {
        pumpAppearanceLoop()
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(predicate(), sourceLocation: sourceLocation)
}

@MainActor private func assertColor(_ actual: NSColor, equals expected: ThemeColor) throws {
    let rgb = try #require(actual.usingColorSpace(.sRGB))
    #expect(abs(rgb.redComponent - expected.red) < 0.002)
    #expect(abs(rgb.greenComponent - expected.green) < 0.002)
    #expect(abs(rgb.blueComponent - expected.blue) < 0.002)
}

extension NativeUITests {
@Suite @MainActor struct AppearanceNativeTests {
    @Test func appKitResolutionAndCompatibilitySurfacesHonorForcedSchemeAndContrast() throws {
        _ = NSApplication.shared
        let originalApplicationAppearance = NSApp.appearance
        for scheme in [ColorScheme.light, .dark] {
            for contrast in [ColorSchemeContrast.standard, .increased] {
                let snapshot = ResolvedAppearance(colorScheme: scheme, contrast: contrast)
                let view = NSView()
                view.appearance = snapshot.nsAppearance
                #expect(view.effectiveAppearance.name == snapshot.nsAppearance.name)
                #expect(snapshot.nsAppearance.bestMatch(from: [.aqua, .darkAqua]) == (scheme == .dark ? .darkAqua : .aqua))
                // Native system contrast is OS-owned. Dynamic compatibility colors follow the
                // actual drawing appearance; explicit palette colors also support deterministic
                // increased contrast without changing the user's OS setting.
                let match = snapshot.nsAppearance.bestMatch(from: [.accessibilityHighContrastAqua,
                    .accessibilityHighContrastDarkAqua, .aqua, .darkAqua])
                let actualContrast: ColorSchemeContrast = match == .accessibilityHighContrastAqua
                    || match == .accessibilityHighContrastDarkAqua ? .increased : .standard
                let compatibility = ChatPalette(colorScheme: scheme, contrast: actualContrast)
                for (color, expected) in [(ChatTheme.background, compatibility.mainCanvas),
                                          (ChatTheme.sidebar, compatibility.sidebar),
                                          (ChatTheme.inset, compatibility.raised),
                                          (ChatTheme.separator, compatibility.stroke)] {
                    let resolved = try #require(snapshot.resolveAppKitColor(NSColor(color)))
                    try assertColor(resolved, equals: expected)
                }
                let systemText = try #require(snapshot.resolveAppKitColor(.textColor))
                let opposite = ResolvedAppearance(colorScheme: scheme == .dark ? .light : .dark)
                let oppositeText = try #require(opposite.resolveAppKitColor(.textColor))
                #expect(abs(systemText.redComponent - oppositeText.redComponent) > 0.5)
            }
        }
        #expect(NSApp.appearance === originalApplicationAppearance)
    }

    @Test func liveSettingsAndSystemChangesKeepRealEditorMarkedTextSelectionFocusAndDraft() async throws {
        _ = NSApplication.shared
        let suite = "AppearanceNativeTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppearanceSettings(defaults: defaults)
        let state = AppearanceHostState()
        let input = ComposerInput()
        let probe = AppearanceNativeProbe()
        var draft = "Unsent draft 日本語"
        let binding = Binding(get: { draft }, set: { draft = $0 })
        let root = AppearanceTestRoot(settings: settings, state: state, input: input, probe: probe, draft: binding)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: -16000, y: -16000, width: 760, height: 440),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await settleAppearance { input.editor != nil && probe.latest != nil }
        let editor = try #require(input.editor)
        // Let the hosting view's initial focus reconciliation complete before acquiring focus.
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        try #require(window.makeFirstResponder(editor))
        pumpAppearanceLoop()
        try #require(window.firstResponder === editor)
        editor.setSelectedRange(NSRange(location: 7, length: 5))
        editor.setMarkedText("かな", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        let visibleText = editor.string
        let selected = editor.selectedRanges
        let marked = editor.markedRange()
        #expect(editor.hasMarkedText())

        for language in AppLanguage.allCases {
            state.language = language
            for width: CGFloat in [400, 1200] {
                window.setContentSize(NSSize(width: width, height: 440))
                for choice in AppearanceChoice.allCases {
                    settings.choice = choice
                    // Always make the ambient environment opposite to the explicit choice.
                    state.systemScheme = choice == .dark ? .light : .dark
                    for increased in [false, true] {
                        state.contrast = increased ? .increased : .standard
                        state.reduceMotion = increased
                        let expected = settings.resolve(systemColorScheme: state.systemScheme,
                                                        contrast: state.contrast, reduceMotion: state.reduceMotion)
                        try await settleAppearance { probe.latest == expected }
                        host.layoutSubtreeIfNeeded()
                        #expect(probe.view?.effectiveAppearance.name == expected.nsAppearance.name)
                        #expect(input.editor === editor)
                        #expect(editor.string == visibleText)
                        #expect(editor.selectedRanges == selected)
                        #expect(editor.markedRange() == marked)
                        #expect(editor.hasMarkedText())
                        #expect(window.firstResponder === editor)
                        #expect(draft == "Unsent draft 日本語")
                        if !increased, choice != .system,
                           let path = ProcessInfo.processInfo.environment["CHAT_UI_ARTIFACTS_DIR"] {
                            let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                            host.cacheDisplay(in: host.bounds, to: image)
                            let directory = URL(fileURLWithPath: path, isDirectory: true)
                            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                            try image.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(
                                "appearance-\(language.rawValue)-\(Int(width))-\(choice.rawValue).png"))
                        }
                    }
                }
            }
        }
        settings.resetToSystem()
        state.systemScheme = .light
        try await settleAppearance { probe.latest?.colorScheme == .light }
        state.systemScheme = .dark
        try await settleAppearance { probe.latest?.colorScheme == .dark }
        #expect(settings.preferredColorScheme == nil)
        #expect(defaults.object(forKey: AppearanceSettings.defaultStorageKey) == nil)
        #expect(input.editor === editor)
        #expect(editor.hasMarkedText())
        editor.unmarkText()
        editor.setSelectedRange(NSRange(location: 2, length: 3))
        let committedSelection = editor.selectedRanges
        settings.choice = .light
        try await settleAppearance { probe.latest?.colorScheme == .light }
        #expect(input.editor === editor)
        #expect(editor.selectedRanges == committedSelection)
        #expect(window.firstResponder === editor)
    }
}
}
