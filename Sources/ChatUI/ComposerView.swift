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
    @Bindable private var store: ChatStore
    @ComposerState<ComposerInput> private var input = ComposerInput()

    public init(store: ChatStore) { self.store = store }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CompositionTextView(text: $store.draft, input: input) { input.submit(store: store) }
                .frame(minHeight: 80, idealHeight: 112, maxHeight: 160)
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            HStack {
                Text(localization.chat("Enter / ⌘Enter to send · Shift+Enter for a new line\nConfirm IME composition before sending."))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)
                Spacer()
                if store.isSending {
                    Button(localization.chat("Stop"), systemImage: "stop.fill") { input.stop(store: store) }
                        .disabled(input.isStopping).fixedSize()
                }
                Button(localization.chat("Send"), systemImage: "arrow.up") { input.submit(store: store) }
                    .disabled(!input.canSubmit(store: store)).fixedSize()
            }
        }
        .padding(12)
    }
}

/// Button and keyboard use the same synchronous gate, and revalidate after the Task hop.
@MainActor @Observable
final class ComposerInput {
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
