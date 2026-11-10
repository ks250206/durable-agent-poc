import AppKit
import AppLocalization
import SwiftUI
import Testing

@MainActor private final class EditorProbe {
    var editor: NSTextView?
    var creations = 0
}

@MainActor private struct StableEditor: NSViewRepresentable {
    let label: String
    let probe: EditorProbe

    func makeNSView(context: Context) -> NSTextView {
        let editor = NSTextView()
        editor.string = "Saved user / model / code: let x = 1"
        probe.editor = editor
        probe.creations += 1
        return editor
    }

    func updateNSView(_ editor: NSTextView, context: Context) {
        // A localized presentation property changes without replacing editor text/selection.
        editor.toolTip = label
    }
}

@MainActor private struct LiveLanguageFixture: View {
    let localization: LocalizationSettings
    let probe: EditorProbe

    var body: some View {
        VStack {
            localization.text(LocalizedMessage("Language"))
            LanguagePickerView(localization: localization)
            StableEditor(label: localization.string("Language"), probe: probe)
        }
        .environment(\.locale, localization.locale)
    }
}

@Suite(.serialized) @MainActor struct LocalizationLiveViewTests {
    @Test func hostedSwitchUpdatesPresentationAndPreservesNativeEditorIdentityAndMarkedText() async throws {
        _ = NSApplication.shared
        let suite = "AppLocalizationTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let localization = LocalizationSettings(defaults: defaults, preferredLanguages: { ["en-US"] })
        let probe = EditorProbe()
        let host = NSHostingView(rootView: LiveLanguageFixture(localization: localization, probe: probe))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: -16000, y: -16000, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let editor = try #require(probe.editor)
        #expect(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 5, length: 4))
        editor.setMarkedText("にほん", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        let text = editor.string
        let marked = editor.markedRange()
        let selected = editor.selectedRange()
        #expect(editor.hasMarkedText())
        let expected: [(LanguageChoice, String)] = [(.japanese, "言語"), (.simplifiedChinese, "语言"), (.korean, "언어"), (.english, "Language")]
        for (choice, label) in expected {
            localization.choice = choice
            let deadline = ContinuousClock.now + .seconds(3)
            while editor.toolTip != label, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
                host.layoutSubtreeIfNeeded()
            }
            #expect(editor.toolTip == label)
            #expect(probe.creations == 1)
            #expect(probe.editor === editor)
            #expect(editor.string == text)
            #expect(editor.markedRange() == marked)
            #expect(editor.selectedRange() == selected)
            #expect(window.firstResponder === editor)
        }
    }
}
