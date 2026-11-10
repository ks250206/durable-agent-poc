import AppKit
import AppLocalization
import ChatCore
import SwiftUI

/// A read-only full-history inspector. Does not start the store or reset shared navigation.
/// Keep this mounted across tab changes to retain its local reader/search/selection state.
@MainActor public struct ConversationTrajectory: View {
    @ChatLocalization private var localization
    @ChatAppearance private var appearance
    private let store: ChatStore
    private let navigation: TranscriptNavigation

    public init(store: ChatStore, navigation: TranscriptNavigation) {
        self.store = store
        self.navigation = navigation
    }

    public var body: some View {
        TrajectorySurface(messages: store.messages, conversationID: store.selectedConversationID,
                          loaded: store.selectedConversation != nil, viewport: navigation.viewport,
                          requestID: navigation.scrollRequest?.id, navigation: navigation,
                          localizer: localization, resolved: appearance)
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor private struct TrajectorySurface: NSViewRepresentable {
    let messages: [ChatMessage]
    let conversationID: ConversationID?
    let loaded: Bool
    let viewport: TranscriptViewport
    let requestID: UUID?
    let navigation: TranscriptNavigation
    let localizer: Localizer
    let resolved: ResolvedAppearance

    func makeNSView(context: Context) -> TrajectoryView { TrajectoryView() }
    func updateNSView(_ view: TrajectoryView, context: Context) {
        view.configure(messages: messages, conversationID: conversationID,
                       loaded: loaded, navigation: navigation,
                       localizer: localizer, resolved: resolved)
    }
}

/// Native reusable table cells keep layout/AX bounded while retaining every message and its ID.
/// Plain-text inspector is persistent: append-only streaming edits preserve its selection/scroll.
@MainActor final class TrajectoryView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let title = NSTextField(labelWithString: "")
    let countLabel = NSTextField(labelWithString: "")
    let overview = TrajectoryOverview()
    let viewportLabel = NSTextField(labelWithString: "")
    let search = NSSearchField()
    let roleFilter = NSPopUpButton()
    let numberField = NSTextField()
    let goButton = NSButton()
    let resultLabel = NSTextField(labelWithString: "")
    let table = TrajectoryTable()
    let logScroll = NSScrollView()
    let emptyLabel = NSTextField(wrappingLabelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let detail = NSTextView()
    let detailScroll = NSScrollView()
    let jumpButton = NSButton()
    let copyButton = NSButton()
    private(set) var messages: [ChatMessage] = []
    private(set) var filtered: [Int] = []
    private(set) var selectedID: MessageID?
    private(set) var conversationID: ConversationID?
    private var initialized = false
    private var loaded = false
    private var navigation: TranscriptNavigation?
    private var localizer = Localizer(language: .english)
    private var resolved = ResolvedAppearance(colorScheme: .light)
    private var selectedRole: MessageRole?
    private var updating = false
    var pasteboard = NSPasteboard.general
    private var copiedID: MessageID?
    private var lastRequestID: UUID?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [title, countLabel, overview, viewportLabel, search, roleFilter, resultLabel,
                     logScroll, emptyLabel, detailLabel, detailScroll, jumpButton, copyButton, numberField, goButton] { addSubview(view) }
        wantsLayer = true
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        for label in [countLabel, viewportLabel, resultLabel, detailLabel] {
            label.font = .systemFont(ofSize: 11)
            label.lineBreakMode = .byTruncatingTail
        }
        search.delegate = self
        search.target = self
        search.action = #selector(searchChanged)
        search.sendsSearchStringImmediately = true
        search.setAccessibilityIdentifier("trajectory.search")
        numberField.delegate = self
        numberField.target = self
        numberField.action = #selector(jumpByNumber)
        numberField.setAccessibilityIdentifier("trajectory.number")
        goButton.target = self
        goButton.action = #selector(jumpByNumber)
        goButton.bezelStyle = .rounded
        roleFilter.target = self
        roleFilter.action = #selector(filterChanged)
        roleFilter.setAccessibilityIdentifier("trajectory.role")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("message"))
        column.minWidth = 0
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 64
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = true
        table.target = self
        table.doubleAction = #selector(jump)
        table.onJump = { [weak self] in self?.jump() }
        table.onCopy = { [weak self] in self?.copyMessage() }
        table.setAccessibilityIdentifier("trajectory.log")
        logScroll.documentView = table
        logScroll.hasVerticalScroller = true
        logScroll.autohidesScrollers = true
        logScroll.borderType = .noBorder
        detail.isEditable = false
        detail.isSelectable = true
        detail.isRichText = false
        detail.isAutomaticLinkDetectionEnabled = false
        detail.isAutomaticDataDetectionEnabled = false
        detail.isHorizontallyResizable = false
        detail.isVerticallyResizable = true
        detail.textContainerInset = NSSize(width: 8, height: 8)
        detail.autoresizingMask = [.width]
        detail.textContainer?.widthTracksTextView = true
        detailScroll.documentView = detail
        detailScroll.hasVerticalScroller = true
        detailScroll.autohidesScrollers = true
        detail.setAccessibilityIdentifier("trajectory.original")
        detailLabel.isSelectable = true
        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 13)
        jumpButton.target = self
        jumpButton.action = #selector(jump)
        copyButton.target = self
        copyButton.action = #selector(copyMessage)
        for button in [jumpButton, copyButton] { button.bezelStyle = .rounded }
        overview.onTarget = { [weak self] id in self?.reveal(id) }
        nextKeyView = search
        search.nextKeyView = roleFilter
        roleFilter.nextKeyView = numberField
        numberField.nextKeyView = goButton
        goButton.nextKeyView = overview
        overview.nextKeyView = table
        table.nextKeyView = detail
        detail.nextKeyView = jumpButton
        jumpButton.nextKeyView = copyButton
        copyButton.nextKeyView = search
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(messages: [ChatMessage], conversationID: ConversationID?, loaded: Bool,
                   navigation: TranscriptNavigation, localizer: Localizer, resolved: ResolvedAppearance) {
        let changedConversation = !initialized || self.conversationID != conversationID
        let changedMessages = self.messages != messages || self.loaded != loaded
        let changedPresentation = self.localizer.locale != localizer.locale || self.resolved != resolved
        self.navigation = navigation
        self.localizer = localizer
        self.resolved = resolved
        self.loaded = loaded
        self.conversationID = conversationID
        self.messages = messages
        initialized = true
        if changedConversation {
            selectedID = nil
            selectedRole = nil
            copiedID = nil
            search.stringValue = ""
            numberField.stringValue = ""
            overview.activeID = nil
            overview.hoverID = nil
            lastRequestID = navigation.scrollRequest?.id
            detail.string = ""
            detailScroll.contentView.scroll(to: .zero)
        }
        if changedPresentation || changedConversation { present() }
        if changedMessages || changedConversation || changedPresentation { rebuild(resetReader: changedConversation) }
        // External jumps are reflected only for valid current IDs. No shared mutation occurs here.
        if lastRequestID != navigation.scrollRequest?.id {
            lastRequestID = navigation.scrollRequest?.id
            if let id = navigation.scrollRequest?.messageID, messages.contains(where: { $0.id == id }) {
                overview.activeID = id
            }
        }
        overview.configure(layout: MinimapLayout(messages: messages), viewport: navigation.viewport,
                           localizer: localizer, resolved: resolved, navigation: navigation)
        if let range = overview.layout.visibleIndices(navigation.viewport) {
            viewportLabel.stringValue = localizer.chat("Viewing {first}–{last} of {total}", [
                "first": .integer(range.lowerBound + 1), "last": .integer(range.upperBound + 1), "total": .integer(messages.count)])
        } else { viewportLabel.stringValue = localizer.chat("Visible range unavailable") }
        viewportLabel.toolTip = viewportLabel.stringValue
    }

    private func present() {
        appearance = resolved.nsAppearance
        let p = resolved.palette
        layer?.backgroundColor = p.mainCanvas.nsColor.cgColor
        for label in [title, countLabel, viewportLabel, resultLabel, detailLabel, emptyLabel] {
            label.textColor = label === title ? p.primaryText.nsColor : p.secondaryText.nsColor
        }
        title.stringValue = localizer.chat("Trajectory")
        search.placeholderString = localizer.chat("Search message text")
        search.setAccessibilityLabel(localizer.chat("Search message text"))
        search.toolTip = localizer.chat("Search the entire original text. Previews are shortened; select a row to read and copy the full message.")
        roleFilter.removeAllItems()
        roleFilter.addItem(withTitle: localizer.chat("All roles"))
        for role in MessageRole.allCases { roleFilter.addItem(withTitle: localizer.role(role)) }
        roleFilter.selectItem(at: selectedRole.flatMap { MessageRole.allCases.firstIndex(of: $0).map { $0 + 1 } } ?? 0)
        numberField.placeholderString = localizer.chat("Message number")
        numberField.setAccessibilityLabel(localizer.chat("Message number"))
        numberField.toolTip = localizer.chat("Message number (1–{count})", ["count": .integer(messages.count)])
        goButton.title = localizer.chat("Go")
        roleFilter.setAccessibilityLabel(localizer.chat("Filter by role"))
        table.setAccessibilityLabel(localizer.chat("Chronological message log"))
        table.setAccessibilityHelp(localizer.chat("Select a row to read the original. Return jumps to its chat message. Command-C copies the whole message."))
        table.backgroundColor = p.mainCanvas.nsColor
        logScroll.backgroundColor = p.mainCanvas.nsColor
        detail.backgroundColor = p.code.nsColor
        detail.textColor = p.primaryText.nsColor
        detail.insertionPointColor = p.primaryText.nsColor
        detail.selectedTextAttributes = [.backgroundColor: resolved.resolveAppKitColor(.selectedTextBackgroundColor) ?? p.active.nsColor,
                                         .foregroundColor: resolved.resolveAppKitColor(.selectedTextColor) ?? p.primaryText.nsColor]
        detail.font = ChatTheme.Typography.nativeCode
        detail.setAccessibilityLabel(localizer.chat("Original message, plain text"))
        detailScroll.backgroundColor = p.code.nsColor
        detailScroll.wantsLayer = true
        detailScroll.layer?.cornerRadius = ChatTheme.Radii.code
        jumpButton.title = localizer.chat("Jump to message")
        jumpButton.toolTip = jumpButton.title
        copyButton.title = localizer.chat("Copy message")
        copyButton.toolTip = localizer.chat("Copy the entire original message verbatim")
        needsLayout = true
    }

    private func rebuild(resetReader: Bool = false) {
        // Anchor by stable ID + pixel offset, even when filtering membership changes during a stream.
        let origin = logScroll.contentView.bounds.origin
        let oldRow = table.row(at: NSPoint(x: 0, y: origin.y))
        let anchor = filtered.indices.contains(oldRow) ? tableRowIDs[safe: oldRow] : nil
        let offset = oldRow >= 0 ? origin.y - table.rect(ofRow: oldRow).minY : 0
        filtered = TrajectoryIndex.matching(messages, query: search.stringValue, role: selectedRole, locale: localizer.locale)
        tableRowIDs = filtered.map { messages[$0].id }
        if !messages.contains(where: { $0.id == selectedID }) { selectedID = nil; copiedID = nil }
        updating = true
        table.reloadData()
        if let selectedID, let row = tableRowIDs.firstIndex(of: selectedID) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        updating = false
        table.layoutSubtreeIfNeeded()
        if resetReader { logScroll.contentView.scroll(to: .zero) }
        else if let anchor, let row = tableRowIDs.firstIndex(of: anchor) {
            logScroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, table.rect(ofRow: row).minY + offset)))
        }
        logScroll.reflectScrolledClipView(logScroll.contentView)
        countLabel.stringValue = localizer.chatCount(messages.count, one: "{count} message · entire history", other: "{count} messages · entire history")
        goButton.isEnabled = MessageNumberInput.targetIndex(numberField.stringValue, count: messages.count, locale: localizer.locale) != nil
        numberField.toolTip = localizer.chat("Message number (1–{count})", ["count": .integer(messages.count)])
        resultLabel.stringValue = localizer.chat("{shown} of {total} messages", ["shown": .integer(filtered.count), "total": .integer(messages.count)])
        resultLabel.toolTip = resultLabel.stringValue
        if messages.isEmpty {
            emptyLabel.stringValue = localizer.chat(conversationID == nil ? "Select a conversation" : (loaded ? "No messages yet" : "Loading messages…"))
        } else if filtered.isEmpty {
            emptyLabel.stringValue = localizer.chat(selectedRole != nil && search.stringValue.isEmpty ? "No messages for this role" : "No matching messages")
        }
        emptyLabel.isHidden = !filtered.isEmpty
        logScroll.isHidden = filtered.isEmpty
        updateDetail()
    }
    private var tableRowIDs: [MessageID] = []

    override func layout() {
        super.layout()
        let width = min(ChatTheme.Dimensions.readableWidth, max(0, bounds.width - ChatTheme.Spacing.medium * 2))
        let inset = max(ChatTheme.Spacing.medium, (bounds.width - width) / 2)
        title.frame = NSRect(x: inset, y: 12, width: width, height: 24)
        countLabel.frame = NSRect(x: inset, y: 39, width: width, height: 16)
        overview.frame = NSRect(x: inset, y: 63, width: width, height: 112)
        viewportLabel.frame = NSRect(x: inset, y: 181, width: width, height: 18)
        let filterWidth = min(150, width * 0.43)
        search.frame = NSRect(x: inset, y: 207, width: max(0, width - filterWidth - 8), height: 28)
        roleFilter.frame = NSRect(x: inset + width - filterWidth, y: 207, width: filterWidth, height: 28)
        resultLabel.frame = NSRect(x: inset, y: 242, width: max(0, width - 174), height: 22)
        numberField.frame = NSRect(x: inset + max(0, width - 166), y: 240, width: 108, height: 24)
        goButton.frame = NSRect(x: inset + max(0, width - 54), y: 238, width: 54, height: 28)
        let inspectorHeight = min(180, max(80, bounds.height * 0.20))
        let bottom = max(340, bounds.height - inspectorHeight - 76)
        logScroll.frame = NSRect(x: inset, y: 269, width: width, height: max(0, bottom - 277))
        table.tableColumns.first?.width = max(0, logScroll.contentSize.width)
        table.setFrameSize(NSSize(width: logScroll.contentSize.width, height: table.frame.height))
        emptyLabel.frame = NSRect(x: inset + 12, y: 280, width: max(0, width - 24), height: max(30, bottom - 294))
        detailLabel.frame = NSRect(x: inset, y: bottom, width: width, height: 18)
        detailScroll.frame = NSRect(x: inset, y: bottom + 23, width: width, height: inspectorHeight)
        detail.setFrameSize(NSSize(width: detailScroll.contentSize.width, height: max(detail.frame.height, inspectorHeight)))
        let buttonY = bottom + inspectorHeight + 29
        let half = max(0, (width - 8) / 2)
        jumpButton.frame = NSRect(x: inset, y: buttonY, width: half, height: 28)
        copyButton.frame = NSRect(x: inset + half + 8, y: buttonY, width: half, height: 28)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("trajectory.cell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? TrajectoryCell ?? TrajectoryCell()
        cell.identifier = id
        let index = filtered[row]
        cell.configure(messages[index], ordinal: index + 1, localizer: localizer, resolved: resolved)
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating else { return }
        selectedID = tableRowIDs[safe: table.selectedRow]
        copiedID = nil
        overview.activeID = selectedID
        overview.updateAX()
        overview.needsDisplay = true
        updateDetail()
    }
    func controlTextDidChange(_ obj: Notification) {
        if obj.object as AnyObject? === numberField {
            goButton.isEnabled = MessageNumberInput.targetIndex(numberField.stringValue, count: messages.count, locale: localizer.locale) != nil
        } else { copiedID = nil; rebuild() }
    }
    @objc private func searchChanged() {
        copiedID = nil
        rebuild()
    }
    @objc private func jumpByNumber() {
        guard let index = MessageNumberInput.targetIndex(numberField.stringValue, count: messages.count, locale: localizer.locale) else { return }
        overview.activeID = messages[index].id
        reveal(messages[index].id)
        overview.updateAX()
        jump()
        overview.needsDisplay = true
    }
    @objc private func filterChanged() {
        let index = roleFilter.indexOfSelectedItem - 1
        selectedRole = MessageRole.allCases[safe: index]
        copiedID = nil
        rebuild()
    }
    private func reveal(_ id: MessageID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        // Overview always represents the full history. Keep filters intact, and inspect even a hidden row.
        selectedID = messages[index].id
        copiedID = nil
        updating = true
        if let row = tableRowIDs.firstIndex(of: id) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        } else { table.deselectAll(nil) }
        updating = false
        updateDetail()
    }
    private func updateDetail() {
        let message = messages.first(where: { $0.id == selectedID })
        let content = message?.content ?? ""
        if detail.string != content {
            let ranges = detail.selectedRanges
            let origin = detailScroll.contentView.bounds.origin
            if message?.id == detailMessageID, content.hasPrefix(detail.string) {
                let suffix = String(content.dropFirst(detail.string.count))
                detail.textStorage?.append(NSAttributedString(string: suffix, attributes: [.font: detail.font!, .foregroundColor: resolved.palette.primaryText.nsColor]))
                detail.selectedRanges = ranges
                detailScroll.contentView.scroll(to: origin)
                detailScroll.reflectScrolledClipView(detailScroll.contentView)
            } else {
                let sameMessage = message?.id == detailMessageID
                detail.string = content
                let length = (content as NSString).length
                detail.selectedRanges = sameMessage ? ranges.map { value in
                    let range = value.rangeValue
                    let start = min(range.location, length)
                    return NSValue(range: NSRange(location: start, length: min(range.length, length - start)))
                } : [NSValue(range: NSRange(location: 0, length: 0))]
                detailScroll.contentView.scroll(to: sameMessage ? origin : .zero)
            }
            copiedID = nil
        }
        detailMessageID = message?.id
        detailLabel.stringValue = message.map { $0.id.rawValue } ?? localizer.chat("Select a message to inspect its original text")
        detailLabel.toolTip = detailLabel.stringValue
        jumpButton.isEnabled = message != nil
        copyButton.isEnabled = message != nil
        copyButton.title = localizer.chat(copiedID != nil ? "Copied" : "Copy message")
    }
    private var detailMessageID: MessageID?
    @objc func jump() {
        guard let selectedID, messages.contains(where: { $0.id == selectedID }) else { return }
        navigation?.jump(to: selectedID)
    }
    @objc func copyMessage() {
        guard let message = messages.first(where: { $0.id == selectedID }) else { return }
        pasteboard.clearContents()
        let success = pasteboard.setString(message.content, forType: .string)
        copiedID = success ? message.id : nil
        copyButton.title = localizer.chat(success ? "Copied" : "Copy failed")
        NSAccessibility.post(element: copyButton, notification: .valueChanged)
    }
}

@MainActor final class TrajectoryTable: NSTableView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var onJump: () -> Void = {}
    var onCopy: () -> Void = {}
    override func mouseDown(with event: NSEvent) {
        // A read-only, single-selection log has no drag/edit tracking loop. Commit the exact
        // hit row on mouse-down, including the first click into an inactive inspector window.
        window?.makeFirstResponder(self)
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, row < numberOfRows else { return }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if event.clickCount > 1 { onJump() }
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty, [36, 76].contains(event.keyCode) { onJump(); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" { onCopy(); return }
        super.keyDown(with: event)
    }
}

@MainActor private final class TrajectoryCell: NSTableCellView {
    private let metadata = NSTextField(labelWithString: "")
    private let preview = NSTextField(wrappingLabelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(metadata)
        addSubview(preview)
        metadata.font = .systemFont(ofSize: 11, weight: .medium)
        metadata.lineBreakMode = .byTruncatingTail
        preview.maximumNumberOfLines = 2
        preview.lineBreakMode = .byTruncatingTail
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        metadata.frame = NSRect(x: 10, y: bounds.height - 24, width: max(0, bounds.width - 20), height: 18)
        preview.frame = NSRect(x: 10, y: 6, width: max(0, bounds.width - 20), height: 34)
    }
    func configure(_ message: ChatMessage, ordinal: Int, localizer: Localizer, resolved: ResolvedAppearance) {
        let date = DateFormatter()
        date.locale = localizer.locale
        date.dateStyle = .short
        date.timeStyle = .short
        let header = localizer.chat("{number} · {role} · {status}", ["number": .integer(ordinal),
            "role": .string(localizer.role(message.role)), "status": .string(localizer.status(message.status))])
        metadata.stringValue = header + "  ·  " + date.string(from: message.createdAt)
        metadata.textColor = resolved.palette.secondaryText.nsColor
        let code = message.content.contains("```")
        preview.font = code ? ChatTheme.Typography.nativeCode : .systemFont(ofSize: 13)
        preview.stringValue = message.content.isEmpty ? localizer.chat("Empty message") : String(message.content.prefix(320))
        preview.textColor = resolved.palette.primaryText.nsColor
        setAccessibilityLabel(metadata.stringValue)
        setAccessibilityValue(message.content.isEmpty ? localizer.chat("Empty message") : message.content)
        toolTip = localizer.chat("Select a row to read the original. Return jumps to its chat message. Command-C copies the whole message.")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
