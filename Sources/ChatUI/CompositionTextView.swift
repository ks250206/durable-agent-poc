import AppKit
import SwiftUI

/// The editor stays enabled while the store streams. Only committed text is written to the binding.
@MainActor
struct CompositionTextView: NSViewRepresentable {
    @Binding var text: String
    let input: ComposerInput
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let editor = CompositionNSTextView(frame: .zero)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.font = .preferredFont(forTextStyle: .body)
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel("Message")
        editor.string = text
        editor.delegate = context.coordinator
        editor.onCommittedChange = { [weak coordinator = context.coordinator] in
            coordinator?.committedTextChanged($0)
        }
        editor.onCompositionChange = { [weak input] in input?.refreshCompositionState() }
        editor.onSubmit = { [weak coordinator = context.coordinator] in coordinator?.parent.onSubmit() }
        scroll.documentView = editor
        input.attach(editor)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? CompositionNSTextView else { return }
        editor.synchronize(draft: text)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let editor = scroll.documentView as? CompositionNSTextView else { return }
        coordinator.parent.input.detach(editor)
        editor.delegate = nil
        editor.onSubmit = nil
        editor.onCommittedChange = nil
        editor.onCompositionChange = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CompositionTextView
        init(_ parent: CompositionTextView) { self.parent = parent }

        func committedTextChanged(_ text: String) {
            if parent.text != text { parent.text = text }
        }

        func textDidChange(_ notification: Notification) {
            (notification.object as? CompositionNSTextView)?.publishCommittedText()
        }
    }
}

/// All shortcut handling is local to this text responder, never an app-wide monitor/SwiftUI shortcut.
@MainActor
class CompositionNSTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCommittedChange: ((String) -> Void)?
    var onCompositionChange: (() -> Void)?

    private var mutationDepth = 0
    private var keyBeganWithMarkedText = false
    private var handlingKey = false
    private var handlingSubmissionKey = false
    private var requestingSubmission = false
    private var commitPending = false
    private var commitGeneration = 0

    var blocksSubmission: Bool {
        hasMarkedText() || mutationDepth > 0 || keyBeganWithMarkedText || commitPending
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        // Holding the confirmation/send key must never become a second submission.
        if isReturn && (event.isARepeat || handlingKey) { return }
        let previousHandlingKey = handlingKey
        let previousMarked = keyBeganWithMarkedText
        let previousSubmissionKey = handlingSubmissionKey
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        handlingKey = true
        handlingSubmissionKey = isReturn && modifiers.intersection([.shift, .control, .option]).isEmpty
        keyBeganWithMarkedText = hasMarkedText()
        commitPending = false
        commitGeneration += 1
        onCompositionChange?()
        defer {
            handlingKey = previousHandlingKey
            keyBeganWithMarkedText = previousMarked
            handlingSubmissionKey = previousSubmissionKey
            onCompositionChange?()
        }

        if isReturn && !keyBeganWithMarkedText {
            if modifiers.contains(.shift) {
                // Shift wins even for Cmd+Shift+Enter. Insert using AppKit's normal edit/undo path.
                super.insertNewline(nil)
            } else if modifiers.intersection([.control, .option]).isEmpty {
                insertNewline(nil)
            } else {
                interpretInputEvent(event)
            }
        } else {
            // In particular, Cmd+Enter while marked must still reach the input method.
            interpretInputEvent(event)
        }
    }

    /// Kept separate so synthetic tests can reproduce input-method callback ordering inside keyDown.
    /// Production always uses NSTextView's native input-context processing.
    func interpretInputEvent(_ event: NSEvent) { super.keyDown(with: event) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self,
           event.modifierFlags.contains(.command), event.keyCode == 36 || event.keyCode == 76 {
            keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        guard !blocksSubmission, !requestingSubmission else { return }
        // Input contexts can deliver a delayed command after the key's dispatch turn. Only an
        // explicit, current Return/Cmd+Return is a send gesture; callbacks alone cannot submit.
        guard handlingKey else { return }
        guard handlingSubmissionKey else {
            super.insertNewline(sender)
            return
        }
        requestingSubmission = true
        defer { requestingSubmission = false }
        onSubmit?()
    }

    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) { insertNewline(sender) }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        mutationDepth += 1
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        mutationDepth -= 1
        onCompositionChange?()
        publishCommittedText()
    }

    override func unmarkText() {
        let wasMarked = hasMarkedText()
        mutationDepth += 1
        super.unmarkText()
        mutationDepth -= 1
        if wasMarked { protectCommitCallbacks() }
        onCompositionChange?()
        publishCommittedText()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let wasMarked = hasMarkedText()
        mutationDepth += 1
        super.insertText(string, replacementRange: replacementRange)
        mutationDepth -= 1
        if wasMarked { protectCommitCallbacks() }
        onCompositionChange?()
        publishCommittedText()
    }

    private func protectCommitCallbacks() {
        // Some input methods unmark/insert BEFORE delivering insertNewline. Protect that entire
        // dispatch turn too, including a button action caused by focus loss. A fresh keyDown clears
        // this latch immediately, so the next physical Enter sends without a timing threshold.
        commitPending = true
        commitGeneration += 1
        let generation = commitGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.commitGeneration == generation else { return }
            self.commitPending = false
            self.onCompositionChange?()
        }
    }

    func publishCommittedText() {
        guard mutationDepth == 0, !hasMarkedText() else { return }
        onCommittedChange?(string)
    }

    func synchronize(draft: String) {
        // Streaming and other SwiftUI invalidations normally bring back the same committed draft.
        // Never write it over preedit, even when it differs from the editor's visible string.
        guard !blocksSubmission, string != draft else { return }
        let selections = selectedRanges.map(\.rangeValue)
        string = draft
        let length = (draft as NSString).length
        selectedRanges = selections.map { range in
            let location = min(range.location, length)
            return NSValue(range: NSRange(location: location, length: min(range.length, length - location)))
        }
    }
}
