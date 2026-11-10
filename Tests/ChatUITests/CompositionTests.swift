import AppKit
import AppLocalization
import ChatCore
@testable import ChatUI
import SwiftUI
import Testing

// These are AppKit synthetic input tests. They do not certify a physical Japanese input source,
// candidate-window navigation, Live Conversion, or hardware key/focus timing in a running app.
extension NativeUITests {
@Suite @MainActor
struct CompositionTests {
    private func key(_ flags: NSEvent.ModifierFlags = [], repeat repeating: Bool = false,
                     code: UInt16 = 36) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                         isARepeat: repeating, keyCode: code)!
    }

    private func mark(_ editor: CompositionNSTextView, _ text: String = "にほんご") {
        editor.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
    }

    private func window(containing view: NSView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    @Test func nativeMarkedReturnAndCommandReturnNeverSubmit() {
        let editor = CompositionNSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 160))
        let window = window(containing: editor)
        defer { window.close() }
        #expect(window.makeFirstResponder(editor))
        var sends = 0
        editor.onSubmit = { sends += 1 }
        mark(editor)
        // No input-method stub here: real NSTextView.keyDown handles the marked Return.
        editor.keyDown(with: key())
        #expect(sends == 0)
        mark(editor)
        #expect(editor.performKeyEquivalent(with: key(.command)))
        #expect(sends == 0)
        editor.insertText("日本語", replacementRange: editor.markedRange())
        #expect(!editor.hasMarkedText())
        editor.keyDown(with: key(repeat: true))
        #expect(sends == 0)
        editor.keyDown(with: key())
        #expect(sends == 1)
        editor.keyDown(with: key(repeat: true))
        #expect(sends == 1)
    }

    @Test(arguments: [false, true])
    func commitCallbackOrderingInsideConfirmationKey(unmarkFirst: Bool) {
        let editor = OrderedInputTextView(frame: .zero)
        let window = window(containing: editor)
        defer { window.close() }
        var sends = 0
        var committed = ""
        editor.onSubmit = { sends += 1 }
        editor.onCommittedChange = { committed = $0 }
        mark(editor)
        editor.inputCallbacks = { editor in
            if unmarkFirst {
                let range = editor.markedRange()
                editor.unmarkText()
                // A late command can arrive between unmarking and the final replacement.
                editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                editor.insertText("日本語", replacementRange: range)
            } else {
                editor.insertText("日本語", replacementRange: editor.markedRange())
            }
            editor.insertNewline(nil)
            editor.insertNewlineIgnoringFieldEditor(nil)
        }
        editor.keyDown(with: key(.command))
        #expect(!editor.hasMarkedText())
        #expect(editor.string == "日本語")
        #expect(committed == "日本語")
        #expect(sends == 0)
        editor.keyDown(with: key(repeat: true))
        #expect(sends == 0)
        editor.keyDown(with: key())
        #expect(sends == 1)
    }

    @Test func callbacksOutsideKeyDownAndSynchronousReentryAreProtected() {
        let editor = CompositionNSTextView(frame: .zero)
        let window = window(containing: editor)
        defer { window.close() }
        var sends = 0
        editor.onSubmit = {
            sends += 1
            editor.insertNewline(nil) // Synchronous responder reentry must not recurse/submit twice.
        }
        mark(editor)
        editor.unmarkText()
        editor.insertNewline(nil)
        #expect(sends == 0)
        editor.keyDown(with: key())
        #expect(sends == 1)
        mark(editor)
        editor.insertText("漢字", replacementRange: editor.markedRange())
        editor.insertNewlineIgnoringFieldEditor(nil)
        #expect(sends == 1)
        editor.keyDown(with: key(.command, code: 76))
        #expect(sends == 2)
    }

    @Test func delayedCommandAfterCommitStillRequiresFreshReturn() async {
        let editor = CompositionNSTextView(frame: .zero)
        let window = window(containing: editor)
        defer { window.close() }
        var sends = 0
        editor.onSubmit = { sends += 1 }
        mark(editor)
        editor.insertText("日本語", replacementRange: editor.markedRange())
        await eventually { !editor.blocksSubmission }
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        editor.insertNewlineIgnoringFieldEditor(nil)
        #expect(sends == 0)
        editor.keyDown(with: key(.command))
        #expect(sends == 1)
    }

    @Test func shiftReturnAndMultilinePasteUseNativeEditingWithoutSubmitting() {
        let editor = CompositionNSTextView(frame: .zero)
        let window = window(containing: editor)
        defer { window.close() }
        var sends = 0
        editor.onSubmit = { sends += 1 }
        editor.insertText("first", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.keyDown(with: key(.shift))
        editor.keyDown(with: key([.command, .shift]))
        #expect(editor.string == "first\n\n")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("日本語\nsecond line\n", forType: .string)
        #expect(editor.readSelection(from: pasteboard, type: .string))
        #expect(editor.string == "first\n\n日本語\nsecond line\n")
        #expect(sends == 0)
        editor.keyDown(with: key())
        #expect(sends == 1)
    }

    @Test func externalDraftClearPreservesValidUndoHistory() throws {
        let editor = CompositionNSTextView(frame: .zero)
        editor.allowsUndo = true
        let window = window(containing: editor)
        defer { window.close() }
        #expect(window.makeFirstResponder(editor))
        let undo = try #require(editor.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        editor.insertText("Hello 日本語", replacementRange: NSRange(location: NSNotFound, length: 0))
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        editor.synchronize(draft: "") // Accepted send clears the SwiftUI binding in a later event.
        undo.endUndoGrouping()
        #expect(editor.string.isEmpty)
        #expect(undo.canUndo)
        undo.undo() // Regression: stale typing ranges previously raised NSRangeException here.
        #expect(editor.string == "Hello 日本語")
        undo.redo()
        #expect(editor.string.isEmpty)
    }

    @Test func realSwiftUIBindingTracksUndoRedoAndSurvivesRefresh() async throws {
        let backend = ComposerBackend()
        let store = ChatStore(backend: backend)
        let observation = Task { await store.start() }
        defer { observation.cancel() }
        store.modelSelection = composerModel
        await eventually { store.canSend }
        let host = NSHostingView(rootView: ComposerView(store: store).environment(\.locale, Locale(identifier: "en")))
        let window = window(containing: host)
        defer { window.close() }
        await eventually { findEditor(host) != nil }
        let editor = try #require(findEditor(host))
        #expect(window.makeFirstResponder(editor))
        let undo = try #require(editor.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        editor.insertText("Hello 日本語", replacementRange: NSRange(location: NSNotFound, length: 0))
        undo.endUndoGrouping()
        #expect(store.draft == editor.string)
        undo.beginUndoGrouping()
        store.draft = ""
        await eventually { editor.string.isEmpty }
        undo.endUndoGrouping()
        undo.undo()
        await eventually { store.draft == "Hello 日本語" }
        #expect(editor.string == store.draft)
        host.rootView = ComposerView(store: store).environment(\.locale, Locale(identifier: "en"))
        host.layoutSubtreeIfNeeded()
        #expect(editor.string == "Hello 日本語")
        undo.redo()
        await eventually { store.draft.isEmpty }
        #expect(editor.string.isEmpty)
        // Undo of ordinary typing must update the binding too.
        undo.undo()
        undo.undo()
        await eventually { store.draft == editor.string }
        #expect(store.draft.isEmpty)
    }

    @Test func shiftReturnAutoRepeatRemainsNativeEditing() {
        let editor = CompositionNSTextView(frame: .zero)
        let window = window(containing: editor)
        defer { window.close() }
        var sends = 0
        editor.onSubmit = { sends += 1 }
        editor.keyDown(with: key(.shift))
        editor.keyDown(with: key(.shift, repeat: true))
        #expect(editor.string == "\n\n")
        #expect(sends == 0)
    }

    @Test func taskHopRejectsModelChange() async {
        let backend = ComposerBackend()
        let store = ChatStore(backend: backend)
        let observation = Task { await store.start() }
        defer { observation.cancel() }
        store.modelSelection = composerModel
        await eventually { store.canSend }
        let input = ComposerInput()
        let editor = CompositionNSTextView(frame: .zero)
        let window = window(containing: editor)
        defer { window.close() }
        input.attach(editor)
        editor.onCommittedChange = { store.draft = $0 }
        editor.insertText("belongs to the selected model", replacementRange: NSRange(location: NSNotFound, length: 0))
        input.submit(store: store)
        store.modelSelection = ModelSelection(account: composerModel.account, modelID: "different")
        await eventually { !input.isSubmitting }
        #expect(await backend.requests.isEmpty)
        #expect(!store.draft.isEmpty)
    }

    @Test func markedTextAndSelectionSurviveExternalSynchronization() {
        let editor = CompositionNSTextView(frame: .zero)
        let window = window(containing: editor)
        defer { window.close() }
        editor.string = "prefix "
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        var committed = "prefix "
        editor.onCommittedChange = { committed = $0 }
        mark(editor, "にほん")
        mark(editor, "日本") // Multi-stage conversion retains the same real marked range.
        let range = editor.markedRange()
        let selection = editor.selectedRange()
        editor.synchronize(draft: "prefix ")
        editor.synchronize(draft: "stale external update")
        #expect(editor.string == "prefix 日本")
        #expect(editor.markedRange() == range)
        #expect(editor.selectedRange() == selection)
        #expect(committed == "prefix ")
        editor.insertText("日本語", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(committed == "prefix 日本語")
        // Fresh key boundary, then an equal update must retain even a nontrivial selection.
        editor.keyDown(with: key(.shift))
        editor.setSelectedRange(NSRange(location: 7, length: 2))
        editor.synchronize(draft: editor.string)
        #expect(editor.selectedRange() == NSRange(location: 7, length: 2))
        editor.synchronize(draft: "短い")
        #expect(editor.selectedRange() == NSRange(location: 2, length: 0))
    }

    @Test func buttonUsesLiveMarkedStateAndRejectsEmptyBusyAndReentry() async {
        let backend = ComposerBackend(holdSend: true)
        let store = ChatStore(backend: backend)
        let observation = Task { await store.start() }
        defer { observation.cancel() }
        store.modelSelection = composerModel
        await eventually { store.canSend }
        let input = ComposerInput()
        let editor = CompositionNSTextView(frame: .zero)
        let window = window(containing: editor)
        defer { window.close() }
        input.attach(editor)
        // Leave composition observation deliberately stale to verify the button's live check.
        editor.onCommittedChange = { store.draft = $0 }
        editor.onSubmit = { input.submit(store: store) }
        editor.insertText(" \n\t", replacementRange: NSRange(location: NSNotFound, length: 0))
        input.submit(store: store)
        #expect(!input.isSubmitting)
        editor.insertText("hello", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        mark(editor)
        #expect(!input.isCompositionBlocking)
        input.submit(store: store)
        #expect(!input.isSubmitting)
        #expect(await backend.requests.isEmpty)
        editor.insertText("日本語", replacementRange: editor.markedRange())
        input.submit(store: store) // Same dispatch as a focus-loss commit is still protected.
        #expect(!input.isSubmitting)
        editor.keyDown(with: key())
        input.submit(store: store)
        editor.keyDown(with: key())
        #expect(input.isSubmitting)
        await eventually { await backend.requests.count == 1 }
        #expect(store.isSending)
        input.submit(store: store)
        #expect(await backend.requests.count == 1)
        // Busy does not disable editing/composition, and a newer draft survives send completion.
        mark(editor, "つぎ")
        editor.insertText("次", replacementRange: editor.markedRange())
        let newerDraft = store.draft
        await backend.releaseSend()
        await eventually { !input.isSubmitting }
        #expect(store.draft == newerDraft)
        #expect(editor.isEditable)
        input.submit(store: store) // Streaming remains busy even after the command lock is released.
        editor.keyDown(with: key())
        #expect(!input.isSubmitting)
        #expect(await backend.requests.count == 1)
        input.stop(store: store)
        input.stop(store: store)
        await eventually { await backend.stops == 1 }
        await eventually { !store.isSending && !input.isStopping }
        #expect(await backend.requests.first?.text == "hello日本語")
    }

    @Test func taskHopRevalidatesCompositionAndConnection() async {
        let backend = ComposerBackend()
        let store = ChatStore(backend: backend)
        let observation = Task { await store.start() }
        defer { observation.cancel() }
        store.modelSelection = composerModel
        await eventually { store.canSend }
        let input = ComposerInput()
        let editor = CompositionNSTextView(frame: .zero)
        let window = window(containing: editor)
        defer { window.close() }
        input.attach(editor)
        editor.onCommittedChange = { store.draft = $0 }
        editor.insertText("committed", replacementRange: NSRange(location: NSNotFound, length: 0))
        input.submit(store: store)
        mark(editor)
        await eventually { !input.isSubmitting }
        #expect(await backend.requests.isEmpty)
        editor.unmarkText()
        await backend.disconnect()
        await eventually { !store.canSend }
        editor.keyDown(with: key())
        input.submit(store: store)
        #expect(!input.isSubmitting)
        #expect(await backend.requests.isEmpty)
    }

    @Test func buttonSendsExactCommittedDraftAndRejectsMissingModel() async {
        let backend = ComposerBackend()
        let store = ChatStore(backend: backend)
        let observation = Task { await store.start() }
        defer { observation.cancel() }
        await eventually { store.connection == .connected }
        let input = ComposerInput()
        let editor = CompositionNSTextView(frame: .zero)
        let window = window(containing: editor)
        defer { window.close() }
        input.attach(editor)
        editor.onCommittedChange = { store.draft = $0 }
        editor.insertText("  日本語\nsecond line\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        input.submit(store: store)
        #expect(!input.isSubmitting)
        #expect(await backend.requests.isEmpty)
        store.modelSelection = composerModel
        input.submit(store: store)
        input.submit(store: store)
        await eventually { !input.isSubmitting && store.draft.isEmpty }
        #expect(await backend.requests.count == 1)
        #expect(await backend.requests.first?.text == "  日本語\nsecond line\n")
    }

    @Test func realSwiftUIUpdatesDuringStreamingPreservePreeditAndCommitSync() async throws {
        let backend = ComposerBackend()
        let store = ChatStore(backend: backend)
        let observation = Task { await store.start() }
        defer { observation.cancel() }
        store.modelSelection = composerModel
        store.draft = "prefix "
        await eventually { store.canSend }
        let host = NSHostingView(rootView: ComposerView(store: store).environment(\.locale, Locale(identifier: "en")))
        let window = window(containing: host)
        defer { window.close() }
        await eventually { findEditor(host) != nil }
        let editor = try #require(findEditor(host))
        #expect(window.makeFirstResponder(editor))
        #expect(editor.bounds.width > 100)
        #expect(editor.bounds.height > 0)
        #expect((editor.textContainer?.containerSize.width ?? 0) > 0)
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        mark(editor, "にほん")
        mark(editor, "日本")
        let selection = editor.selectedRange()
        let marked = editor.markedRange()
        for chunk in ["one", "two", "three"] {
            await backend.stream(chunk)
            await eventually { store.messages.last?.content == chunk }
            // Rebuild the real representable with the same view identity while AppKit owns preedit.
            host.rootView = ComposerView(store: store).environment(\.locale, Locale(identifier: "en"))
            host.layoutSubtreeIfNeeded()
            #expect(findEditor(host) === editor)
            #expect(editor.string == "prefix 日本")
            #expect(editor.markedRange() == marked)
            #expect(editor.selectedRange() == selection)
            #expect(store.draft == "prefix ")
        }
        editor.insertText("日本語", replacementRange: editor.markedRange())
        #expect(store.draft == "prefix 日本語")
        editor.keyDown(with: key()) // Store is busy; neither keyboard nor button gate can submit.
        #expect(await backend.requests.isEmpty)
        #expect(editor.isEditable)
        await backend.idle()
        await eventually { store.canSend }
        editor.keyDown(with: key(.command))
        await eventually { await backend.requests.count == 1 }
        await eventually { store.draft.isEmpty }
        await eventually { editor.string.isEmpty }
        #expect(await backend.requests.first?.text == "prefix 日本語")
        // The native editor is retained, with selection reset/clamped only for this actual draft clear.
        #expect(findEditor(host) === editor)
        #expect(editor.selectedRange() == NSRange(location: 0, length: 0))
    }
}

}

@MainActor
private final class OrderedInputTextView: CompositionNSTextView {
    var inputCallbacks: ((CompositionNSTextView) -> Void)?
    override func interpretInputEvent(_ event: NSEvent) {
        if let inputCallbacks { inputCallbacks(self) } else { super.interpretInputEvent(event) }
    }
}

@MainActor
private func findEditor(_ view: NSView) -> CompositionNSTextView? {
    if let editor = view as? CompositionNSTextView { return editor }
    return view.subviews.lazy.compactMap { findEditor($0) }.first
}

@MainActor
private func eventually(_ condition: @MainActor () async -> Bool,
                        sourceLocation: SourceLocation = #_sourceLocation) async {
    let deadline = ContinuousClock.now + .seconds(10)
    while !(await condition()), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10)) // Let AppKit and SwiftUI service the run loop.
    }
    #expect(await condition(), sourceLocation: sourceLocation)
}

private let composerID = ConversationID("composer:test")
private let composerModel = ModelSelection(account: ProviderAccount(option: .apiKey, providerID: "test"), modelID: "test")

private actor ComposerBackend: ChatBackend {
    private var state: ChatSnapshot
    private var continuation: AsyncThrowingStream<ChatEvent, any Error>.Continuation?
    private let holdSend: Bool
    private var heldSend: CheckedContinuation<Void, Never>?
    private(set) var requests: [SendRequest] = []
    private(set) var stops = 0

    init(holdSend: Bool = false) {
        self.holdSend = holdSend
        let conversation = ConversationSnapshot(summary: ConversationSummary(id: composerID, title: "Composer"))
        state = ChatSnapshot(connection: .connected, conversations: [conversation.summary],
                             selectedConversationID: composerID, loadedConversations: [conversation])
    }
    func snapshot() async throws -> ChatSnapshot { state }
    func events() async -> AsyncThrowingStream<ChatEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<ChatEvent, any Error>.makeStream()
        self.continuation = continuation
        continuation.yield(.snapshot(state))
        return stream
    }
    func createConversation(title: String?) async throws -> ConversationID { composerID }
    func selectConversation(_ id: ConversationID?) async throws {}
    func send(_ request: SendRequest) async throws {
        requests.append(request)
        if holdSend { await withCheckedContinuation { heldSend = $0 } }
        var conversation = state.loadedConversations[0]
        conversation.activity = .streaming
        conversation.messages = [ChatMessage(id: request.messageID, conversationID: composerID,
                                             role: .user, content: request.text)]
        publish(conversation)
    }
    func releaseSend() { heldSend?.resume(); heldSend = nil }
    func stop(conversationID: ConversationID) async throws {
        stops += 1
        idle()
    }
    func stream(_ text: String) {
        var conversation = state.loadedConversations[0]
        conversation.activity = .streaming
        conversation.messages = [ChatMessage(id: MessageID("assistant"), conversationID: composerID,
                                             role: .assistant, content: text, status: .streaming)]
        publish(conversation)
    }
    func idle() {
        var conversation = state.loadedConversations[0]
        conversation.activity = .idle
        publish(conversation)
    }
    func disconnect() {
        state.connection = .disconnected
        continuation?.yield(.snapshot(state))
    }
    private func publish(_ conversation: ConversationSnapshot) {
        state.loadedConversations = [conversation]
        continuation?.yield(.conversationUpdated(conversation))
    }
}
