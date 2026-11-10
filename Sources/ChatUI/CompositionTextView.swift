import AppKit
import AppLocalization
import SwiftUI

/// The editor stays enabled while the store streams. Only committed text is written to the binding.
@MainActor
struct CompositionTextView: NSViewRepresentable {
    @ChatLocalization private var localization
    @ChatAppearance private var appearance
    @Binding var text: String
    let input: ComposerInput
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0,
              let editor = scroll.documentView as? CompositionNSTextView else { return nil }
        // Measure a snapshot, never the live editor's text container: resizing must not
        // disturb an input method's marked text, selection, layout or undo transaction.
        let storage = NSTextStorage(attributedString: editor.attributedString())
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(
            width: max(1, width - editor.textContainerInset.width * 2),
            height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = editor.textContainer?.lineFragmentPadding ?? 5
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let textHeight = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
        let height = min(ChatTheme.Dimensions.composerMaxHeight,
                         max(44, ceil(textHeight + editor.textContainerInset.height * 2)))
        return CGSize(width: width, height: height)
    }

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
        editor.textContainerInset = NSSize(width: ChatTheme.Spacing.small, height: ChatTheme.Spacing.small)
        applyAppearance(to: editor)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel(localization.chat("Message"))
        editor.setAccessibilityHelp(localization.chat("Enter or Command+Enter sends committed text. Shift+Enter inserts a new line. Confirm IME composition before sending."))
        editor.string = text
        context.coordinator.editor = editor
        editor.delegate = context.coordinator
        editor.textStorage?.delegate = context.coordinator
        editor.onCommittedChange = { [weak coordinator = context.coordinator] in
            coordinator?.committedTextChanged($0)
        }
        editor.onCompositionChange = { [weak input] in input?.refreshCompositionState() }
        editor.onFocusChange = { [weak input] in input?.isFocused = $0 }
        editor.onSubmit = { [weak coordinator = context.coordinator] in coordinator?.parent.onSubmit() }
        scroll.documentView = editor
        input.attach(editor)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? CompositionNSTextView else { return }
        editor.setAccessibilityLabel(localization.chat("Message"))
        editor.setAccessibilityHelp(localization.chat("Enter or Command+Enter sends committed text. Shift+Enter inserts a new line. Confirm IME composition before sending."))
        applyAppearance(to: editor)
        editor.synchronize(draft: text)
    }

    /// Update the retained editor in place. These setters never replace its storage, delegate,
    /// selection or undo manager, and do not synchronize an uncommitted IME buffer.
    private func applyAppearance(to editor: CompositionNSTextView) {
        let resolved = appearance
        let palette = resolved.palette
        editor.appearance = resolved.nsAppearance
        if editor.font != ChatTheme.Typography.editor { editor.font = ChatTheme.Typography.editor }
        if editor.textColor != palette.primaryText.nsColor { editor.textColor = palette.primaryText.nsColor }
        editor.backgroundColor = palette.composer.nsColor
        editor.insertionPointColor = palette.primaryText.nsColor
        editor.selectedTextAttributes = [.backgroundColor: palette.active.nsColor,
                                         .foregroundColor: palette.primaryText.nsColor]
        var typing = editor.typingAttributes
        typing[.font] = ChatTheme.Typography.editor
        typing[.foregroundColor] = palette.primaryText.nsColor
        editor.typingAttributes = typing
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let editor = scroll.documentView as? CompositionNSTextView else { return }
        coordinator.parent.input.detach(editor)
        editor.textStorage?.delegate = nil
        editor.delegate = nil
        coordinator.editor = nil
        editor.onSubmit = nil
        editor.onCommittedChange = nil
        editor.onCompositionChange = nil
        editor.onFocusChange = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
        // This NSTextStorage belongs to a main-actor NSTextView; AppKit delivers its edits here.
        weak var editor: CompositionNSTextView?
        var parent: CompositionTextView
        init(_ parent: CompositionTextView) { self.parent = parent }

        func committedTextChanged(_ text: String) {
            if parent.text != text { parent.text = text }
        }

        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            // Undo/redo can edit storage without NSTextView.textDidChange. The editor guards
            // in-flight marked-text mutations before exposing committed text to SwiftUI.
            guard editedMask.contains(.editedCharacters) else { return }
            editor?.publishCommittedText()
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
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }

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
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Repeated confirmation/send keys cannot submit; Shift+Return remains normal editing.
        if isReturn && (handlingKey || (event.isARepeat && (!modifiers.contains(.shift) || hasMarkedText()))) { return }
        let previousHandlingKey = handlingKey
        let previousMarked = keyBeganWithMarkedText
        let previousSubmissionKey = handlingSubmissionKey
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
        let range = NSRange(location: 0, length: (string as NSString).length)
        guard shouldChangeText(in: range, replacementString: draft) else { return }
        breakUndoCoalescing()
        replaceCharacters(in: range, with: draft)
        didChangeText()
        breakUndoCoalescing()
        let length = (draft as NSString).length
        selectedRanges = selections.map { range in
            let location = min(range.location, length)
            return NSValue(range: NSRange(location: location, length: min(range.length, length - location)))
        }
    }
}
