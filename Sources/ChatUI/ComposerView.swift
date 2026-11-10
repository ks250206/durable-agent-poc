import AppKit
import AppLocalization
import ChatCore
import Observation
import SwiftUI

// Select the macOS 14 property wrapper rather than the newer SDK's unshipped State macro.
private typealias ComposerState<Value> = SwiftUI.State<Value>

/// Insert into the workspace's composer slot with `{ ComposerView(store: $0) }`.
/// The owner starts ChatStore observation. This component does not start a second subscription.
/// Enter/Cmd+Enter sends committed text; Shift+Enter inserts a newline. Editing remains available
/// during streaming. Physical Japanese IME GUI QA is separate from the AppKit synthetic tests.
@MainActor
public struct ComposerView: View {
    @ChatLocalization private var localization
    @ChatAppearance private var appearance
    @Bindable private var store: ChatStore
    @ComposerState<ComposerInput> private var input = ComposerInput()

    public init(store: ChatStore) { self.store = store }

    public var body: some View {
        let palette = appearance.palette
        VStack(alignment: .leading, spacing: ChatTheme.Spacing.small) {
            CompositionTextView(text: $store.draft, input: input) { input.submit(store: store) }
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .center, spacing: ChatTheme.Spacing.small) {
                Text(localization.chat("↵ Send · ⇧↵ New line"))
                    .font(ChatTheme.Typography.caption)
                    .foregroundStyle(palette.secondaryText.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(localization.chat("Enter / ⌘Enter to send · Shift+Enter for a new line\nConfirm IME composition before sending."))
                Spacer(minLength: 0)
                if store.isSending {
                    actionButton(label: localization.chat("Stop"), symbol: "stop.fill") { input.stop(store: store) }
                        .disabled(input.isStopping)
                } else {
                    actionButton(label: localization.chat("Send"), symbol: "arrow.up") { input.submit(store: store) }
                        .disabled(!input.canSubmit(store: store))
                }
            }
            .padding(.leading, ChatTheme.Spacing.small)
        }
        .padding(ChatTheme.Spacing.medium)
        .background {
            RoundedRectangle(cornerRadius: ChatTheme.Radii.composer)
                .fill(palette.composer.color)
                .shadow(color: palette.shadow.color, radius: ChatTheme.Shadows.composerRadius,
                        y: ChatTheme.Shadows.composerY)
        }
        .overlay(RoundedRectangle(cornerRadius: ChatTheme.Radii.composer)
            .strokeBorder(input.isFocused ? palette.focus.color : palette.stroke.color.opacity(0.45),
                          lineWidth: input.isFocused ? appearance.focusWidth : appearance.strokeWidth))
        .padding(ChatTheme.Spacing.medium)
    }

    private func actionButton(label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: ChatTheme.Dimensions.controlHeight, height: ChatTheme.Dimensions.controlHeight)
                .foregroundStyle(appearance.palette.textOnAccent.color)
                .background(appearance.palette.accent.color, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// Button and keyboard use the same synchronous gate, and revalidate after the Task hop.
@MainActor @Observable
final class ComposerInput {
    var isFocused = false
    private(set) var isCompositionBlocking = false
    private(set) var isSubmitting = false
    private(set) var isStopping = false
    @ObservationIgnored private(set) weak var editor: CompositionNSTextView?

    func attach(_ editor: CompositionNSTextView) {
        self.editor = editor
        refreshCompositionState()
    }

    func detach(_ editor: CompositionNSTextView) {
        if self.editor === editor {
            self.editor = nil
            isFocused = false
            isCompositionBlocking = false
        }
    }

    func refreshCompositionState() {
        isCompositionBlocking = editor?.blocksSubmission ?? false
    }

    func canSubmit(store: ChatStore) -> Bool {
        !isSubmitting && !isCompositionBlocking && editor != nil && !(editor?.blocksSubmission ?? true)
            && store.canSend && !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !(editor?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func submit(store: ChatStore) {
        guard canSubmit(store: store), let editor else { return }
        let submitted = editor.string
        let conversationID = store.selectedConversationID
        let model = store.modelSelection
        store.draft = submitted
        isSubmitting = true
        Task { @MainActor in
            defer { isSubmitting = false }
            guard self.editor === editor, !editor.blocksSubmission, store.canSend,
                  store.selectedConversationID == conversationID, store.modelSelection == model,
                  store.draft == submitted, editor.string == submitted else { return }
            await store.sendDraft()
        }
    }

    func stop(store: ChatStore) {
        guard store.isSending, !isStopping else { return }
        let origin = store.selectedConversationID
        isStopping = true
        Task { @MainActor in
            defer { isStopping = false }
            await store.stop(conversationID: origin)
        }
    }
}
