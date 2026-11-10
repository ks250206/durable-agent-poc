import AppKit
import AppLocalization
import ChatCore
import SwiftUI

// Select the property wrapper explicitly: newer SDKs also export an @State macro whose
// SwiftUIMacros plugin is not bundled with the supported Command Line Tools toolchain.
private typealias MinimapState<Value> = SwiftUI.State<Value>

/// A complete, compressed conversation overview for the workspace's `(store, navigation)` slot.
/// The transcript owns geometry: the solid viewport always uses `navigation.viewport`.
@MainActor
public struct ConversationMinimap: View {
    @ChatLocalization private var localization
    private let store: ChatStore
    private let navigation: TranscriptNavigation

    public init(store: ChatStore, navigation: TranscriptNavigation) {
        self.store = store
        self.navigation = navigation
    }

    public var body: some View {
        let messages = store.messages
        let layout = MinimapLayout(messages: messages)
        MinimapContent(
            messages: messages, layout: layout,
            emptyText: store.selectedConversationID == nil
                ? localization.chat("Select a conversation")
                : (store.selectedConversation == nil ? localization.chat("Loading messages…") : localization.chat("No messages yet")),
            navigation: navigation
        )
        .id(store.selectedConversationID)
        .onChange(of: store.selectedConversationID) { _, _ in
            // Transcript geometry may already have reported the *new* selection before this
            // sibling's change handler runs. Clear stale requests without erasing that report.
            let viewport = navigation.viewport
            let belongsToSelection = layout.visibleIndices(viewport) != nil
            navigation.reset()
            if belongsToSelection { navigation.viewport = viewport }
        }
    }
}

@MainActor
private struct MinimapContent: View {
    @ChatLocalization private var localization
    let messages: [ChatMessage]
    let layout: MinimapLayout
    let emptyText: String
    let navigation: TranscriptNavigation
    @MinimapState private var hoveredID: MessageID?
    @MinimapState private var cursorID: MessageID?
    @MinimapState private var keyboardFocused = false
    @MinimapState private var showsMessages = false
    @MinimapState private var showsHelp = false

    private var activeID: MessageID? {
        if layout.index(for: cursorID) != nil { return cursorID }
        return navigation.viewport.firstVisibleMessageID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Text(localization.chat("Conversation map")).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Button {
                    showsHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.plain).accessibilityLabel(localization.chat("Conversation map help"))
                .popover(isPresented: $showsHelp) {
                    Text(verbatim: localization.chat("Every message is included, from top (oldest) to bottom (newest). The four lanes show System, User, Assistant, and Tool messages. Height and width encode compressed UTF-8 text length, not measured transcript height. Very dense messages occupy subpixels.\n\nThe outlined band is the transcript’s visible range. The dotted line is the keyboard target; it can differ while a jump is pending. Click to jump. Up/Down, Page Up/Down, and Home/End jump through messages. Return or Space repeats a jump. Tab leaves the map. Open All messages for an accessible list and exact message-number navigation."))
                    .font(.callout).padding().frame(width: 300)
                }
            }
            Text(verbatim: localization.chatCount(messages.count, one: "{count} message · entire history", other: "{count} messages · entire history"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            LazyVGrid(
                columns: [
                    GridItem(.flexible(minimum: 0), alignment: .leading),
                    GridItem(.flexible(minimum: 0), alignment: .leading),
                ], alignment: .leading, spacing: 5
            ) {
                ForEach(MessageRole.allCases, id: \.self) { role in
                    HStack(spacing: 4) {
                        Circle().fill(role.minimapColor).frame(width: 6, height: 6)
                        Text(verbatim: localization.role(role)).lineLimit(1).minimumScaleFactor(0.6)
                    }
                    .font(.caption2)
                }
            }
            if messages.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.bubble").font(.title2)
                    Text(emptyText).font(.callout).multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                map
                Text(viewportDescription).font(.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("minimap.viewport")
                preview.frame(height: 56, alignment: .topLeading)
            }
            Button {
                showsMessages = true
            } label: {
                Label(localization.chat("All messages…"), systemImage: "list.bullet")
                    .font(.caption).lineLimit(1).minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity)
            }
            .disabled(messages.isEmpty)
            .help(localization.chat("Browse every message or jump to an exact message number"))
        }
        .padding(10)
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .background(.background.secondary)
        .onChange(of: navigation.scrollRequest?.id) { _, _ in
            guard let target = navigation.scrollRequest?.messageID, layout.index(for: target) != nil else { return }
            cursorID = target
        }
        .sheet(isPresented: $showsMessages) {
            MinimapMessageList(messages: messages, navigation: navigation)
        }
    }

    private var viewportDescription: String {
        guard let range = layout.visibleIndices(navigation.viewport) else { return localization.chat("Visible range unavailable") }
        return localization.chat("Viewing {first}–{last} of {total}", [
            "first": .integer(range.lowerBound + 1), "last": .integer(range.upperBound + 1),
            "total": .integer(messages.count),
        ])
    }

    private var preview: some View {
        Group {
            if let index = layout.index(for: hoveredID ?? activeID) {
                let message = messages[index]
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        localization.chat("{number} · {role} · {status}", [
                            "number": .integer(index + 1), "role": .string(localization.role(message.role)),
                            "status": .string(localization.status(message.status)),
                        ])
                    )
                    .font(.caption.weight(.semibold)).lineLimit(1)
                    Text(message.content.isEmpty ? localization.chat("Empty message") : String(message.content.prefix(160)))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            } else {
                Text(localization.chat("Hover to preview. Click to jump.\n↑ ↓ navigate · Home / End"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("minimap.preview")
    }

    private var map: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Canvas { context, canvasSize in
                for index in layout.nodes.indices {
                    let node = layout.nodes[index]
                    let rect = layout.rect(for: index, size: canvasSize)
                    context.fill(Path(rect), with: .color(node.role.minimapColor.opacity(0.8)))
                    if node.status == .streaming {
                        context.fill(
                            Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(2, rect.height))),
                            with: .color(.primary))
                    }
                }
                if let viewport = layout.viewportRect(navigation.viewport, size: canvasSize) {
                    let inset = min(1, min(viewport.width, viewport.height) / 2)
                    context.fill(Path(viewport), with: .color(.accentColor.opacity(0.12)))
                    context.stroke(
                        Path(viewport.insetBy(dx: inset, dy: inset)), with: .color(.primary), lineWidth: 2 * inset)
                }
                if keyboardFocused, let index = layout.index(for: activeID) {
                    let y = min(
                        max(1, (layout.nodes[index].start + layout.nodes[index].end) / 2 * canvasSize.height),
                        max(1, canvasSize.height - 1))
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: y))
                    line.addLine(to: CGPoint(x: canvasSize.width, y: y))
                    context.stroke(line, with: .color(.primary), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
            }
            .accessibilityHidden(true)
            MinimapInputSurface(
                layout: layout, navigation: navigation, activeID: activeID,
                onTarget: { cursorID = $0 }, onHover: { hoveredID = $0 },
                onFocus: { keyboardFocused = $0 }, onOpenList: { showsMessages = true }
            )
            .frame(width: size.width, height: size.height)
        }
        .frame(minHeight: 24)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(
                    keyboardFocused ? Color.accentColor : Color.secondary.opacity(0.25),
                    lineWidth: keyboardFocused ? 2 : 1
                )
                .allowsHitTesting(false)
        }
    }
}

extension MessageRole {
    fileprivate var minimapColor: Color {
        switch self {
        case .system: .secondary
        case .user: .accentColor
        case .assistant: .green
        case .tool: .orange
        }
    }
}

/// One native keyboard/AX target regardless of history size. The explicit List below supplies
/// per-message elements without constructing thousands of SwiftUI controls over the Canvas.
@MainActor
private struct MinimapInputSurface: NSViewRepresentable {
    @ChatLocalization private var localization
    let layout: MinimapLayout
    let navigation: TranscriptNavigation
    let activeID: MessageID?
    let onTarget: (MessageID) -> Void
    let onHover: (MessageID?) -> Void
    let onFocus: (Bool) -> Void
    let onOpenList: () -> Void

    func makeNSView(context: Context) -> MinimapInputView { MinimapInputView() }

    func updateNSView(_ view: MinimapInputView, context: Context) {
        view.localizer = localization
        view.layout = layout
        view.navigation = navigation
        view.activeID = activeID
        view.onTarget = onTarget
        view.onHover = onHover
        view.onFocus = onFocus
        view.onOpenList = onOpenList
        view.updateAccessibility()
    }
}

@MainActor
final class MinimapInputView: NSView {
    var localizer = Localizer(language: .english)
    var layout = MinimapLayout(messages: [])
    var navigation: TranscriptNavigation?
    var activeID: MessageID?
    var onTarget: (MessageID) -> Void = { _ in }
    var onHover: (MessageID?) -> Void = { _ in }
    var onFocus: (Bool) -> Void = { _ in }
    var onOpenList: () -> Void = {}
    private var hoverID: MessageID?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { !layout.nodes.isEmpty }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityIdentifier("minimap.navigation")
        updateAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func becomeFirstResponder() -> Bool {
        onFocus(true)
        return true
    }
    override func resignFirstResponder() -> Bool {
        onFocus(false)
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), bounds.height > 0,
            let index = layout.index(at: (point.y - bounds.minY) / bounds.height)
        else { return }
        activate(index)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index =
            bounds.height > 0 && bounds.contains(point)
            ? layout.index(at: (point.y - bounds.minY) / bounds.height) : nil
        let id = index.map { layout.nodes[$0].id }
        if hoverID != id {
            hoverID = id
            onHover(id)
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoverID = nil
        onHover(nil)
    }

    override func keyDown(with event: NSEvent) {
        // Preserve system/menu shortcuts. Tab remains normal key-view traversal.
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 126: move(-1)  // Up
        case 125: move(1)  // Down
        case 116: move(-10)  // Page Up
        case 121: move(10)  // Page Down
        case 115: activate(0)  // Home
        case 119: activate(layout.nodes.count - 1)  // End
        case 36, 76, 49:
            activate(layout.index(for: activeID) ?? layout.index(for: navigation?.viewport.firstVisibleMessageID) ?? 0)
        case 48:
            if event.modifierFlags.contains(.shift) {
                window?.selectPreviousKeyView(self)
            } else {
                window?.selectNextKeyView(self)
            }
        default: super.keyDown(with: event)
        }
    }

    private func move(_ distance: Int) {
        let current = layout.index(for: activeID) ?? layout.index(for: navigation?.viewport.firstVisibleMessageID) ?? 0
        activate(min(max(0, current + distance), layout.nodes.count - 1))
    }

    private func activate(_ index: Int) {
        guard layout.nodes.indices.contains(index) else { return }
        let id = layout.nodes[index].id
        activeID = id
        onTarget(id)
        navigation?.jump(to: id)
        updateAccessibility()
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    func updateAccessibility() {
        setAccessibilityLabel(localizer.chat("Conversation map"))
        setAccessibilityHelp(localizer.chat("Up and Down navigate every message. Home and End jump to the ends. Return repeats a jump. Use All messages for individual messages and exact message numbers."))
        if let index = layout.index(for: activeID) ?? layout.index(for: navigation?.viewport.firstVisibleMessageID) {
            let node = layout.nodes[index]
            setAccessibilityValue(
                localizer.chat("Message {current} of {total}, {role}, {bytes} UTF-8 bytes, {status}", [
                    "current": .integer(index + 1), "total": .integer(layout.nodes.count),
                    "role": .string(localizer.role(node.role)), "bytes": .integer(node.byteCount),
                    "status": .string(localizer.status(node.status)),
                ])
            )
        } else {
            setAccessibilityValue(localizer.chatCount(layout.nodes.count, one: "{count} message. Visible range unavailable.", other: "{count} messages. Visible range unavailable."))
        }
    }

    override func accessibilityPerformIncrement() -> Bool {
        guard !layout.nodes.isEmpty else { return false }
        move(1)
        return true
    }
    override func accessibilityPerformDecrement() -> Bool {
        guard !layout.nodes.isEmpty else { return false }
        move(-1)
        return true
    }
    override func accessibilityPerformPress() -> Bool {
        guard !layout.nodes.isEmpty else { return false }
        activate(layout.index(for: activeID) ?? layout.index(for: navigation?.viewport.firstVisibleMessageID) ?? 0)
        return true
    }
    override func accessibilityPerformShowMenu() -> Bool {
        onOpenList()
        return true
    }
}

@MainActor
private struct MinimapMessageList: View {
    @ChatLocalization private var localization
    let messages: [ChatMessage]
    let navigation: TranscriptNavigation
    @Environment(\.dismiss) private var dismiss
    @MinimapState private var messageNumber = ""

    private var targetIndex: Int? {
        guard let value = Int(messageNumber), value > 0, value <= messages.count else { return nil }
        return value - 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(verbatim: localization.chatCount(messages.count, one: "{count} message in total", other: "All {count} messages")).font(.headline)
                Spacer()
                Button(localization.chat("Done")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                TextField(localization.chat("Message number (1–{count})", ["count": .integer(messages.count)]), text: $messageNumber)
                    .accessibilityLabel(localization.chat("Message number"))
                    .onSubmit { if let index = targetIndex { jump(index) } }
                Button(localization.chat("Go")) { if let index = targetIndex { jump(index) } }
                    .disabled(targetIndex == nil)
            }
            ScrollViewReader { proxy in
                List(Array(messages.enumerated()), id: \.element.id) { entry in
                    let index = entry.offset
                    let message = entry.element
                    Button {
                        jump(index)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(
                                localization.chat("{number} · {role} · {bytes} bytes · {status}", [
                                    "number": .integer(index + 1), "role": .string(localization.role(message.role)),
                                    "bytes": .integer(message.content.utf8.count),
                                    "status": .string(localization.status(message.status)),
                                ])
                            )
                            .font(.caption.weight(.semibold))
                            Text(message.content.isEmpty ? localization.chat("Empty message") : String(message.content.prefix(180)))
                                .lineLimit(2).font(.callout).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        localization.chat("Message {number}, {role}, {bytes} UTF-8 bytes, {status}. {preview}", [
                            "number": .integer(index + 1), "role": .string(localization.role(message.role)),
                            "bytes": .integer(message.content.utf8.count),
                            "status": .string(localization.status(message.status)),
                            "preview": .string(String(message.content.prefix(180))),
                        ])
                    )
                }
                .onAppear {
                    if let id = navigation.viewport.firstVisibleMessageID { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .padding(20).frame(minWidth: 360, idealWidth: 480, minHeight: 320, idealHeight: 520)
    }

    private func jump(_ index: Int) {
        guard messages.indices.contains(index) else { return }
        navigation.jump(to: messages[index].id)
        dismiss()
    }
}
