import AppKit
import ChatCore
import SwiftUI

// Select the property wrapper explicitly: newer SDKs also export an @State macro whose
// SwiftUIMacros plugin is not bundled with the supported Command Line Tools toolchain.
private typealias MinimapState<Value> = SwiftUI.State<Value>

/// A complete, compressed conversation overview for the workspace's `(store, navigation)` slot.
/// The transcript owns geometry: the solid viewport always uses `navigation.viewport`.
@MainActor
public struct ConversationMinimap: View {
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
                ? "Select a conversation"
                : (store.selectedConversation == nil ? "Loading messages…" : "No messages yet"),
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
                Text("Conversation map").font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Button {
                    showsHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.plain).accessibilityLabel("Conversation map help")
                .popover(isPresented: $showsHelp) {
                    Text(
                        "Every message is included, from top (oldest) to bottom (newest). The four lanes show System, User, Assistant, and Tool messages. Height and width encode compressed UTF-8 text length, not measured transcript height. Very dense messages occupy subpixels.\n\nThe outlined band is the transcript’s visible range. The dotted line is the keyboard target; it can differ while a jump is pending. Click to jump. Up/Down, Page Up/Down, and Home/End jump through messages. Return or Space repeats a jump. Tab leaves the map. Open All messages for an accessible list and exact message-number navigation."
                    )
                    .font(.callout).padding().frame(width: 300)
                }
            }
            Text("\(messages.count.formatted()) messages · entire history")
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
                        Text(role.minimapName).lineLimit(1).minimumScaleFactor(0.6)
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
                Label("All messages…", systemImage: "list.bullet")
                    .font(.caption).lineLimit(1).minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity)
            }
            .disabled(messages.isEmpty)
            .help("Browse every message or jump to an exact message number")
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
        guard let range = layout.visibleIndices(navigation.viewport) else { return "Visible range unavailable" }
        return "Viewing \(range.lowerBound + 1)–\(range.upperBound + 1) of \(messages.count)"
    }

    private var preview: some View {
        Group {
            if let index = layout.index(for: hoveredID ?? activeID) {
                let message = messages[index]
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        "\(index + 1) · \(message.role.minimapName)\(message.status == .streaming ? " · streaming" : "")"
                    )
                    .font(.caption.weight(.semibold)).lineLimit(1)
                    Text(message.content.isEmpty ? "Empty message" : String(message.content.prefix(160)))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            } else {
                Text("Hover to preview. Click to jump.\n↑ ↓ navigate · Home / End")
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
    fileprivate var minimapName: String { rawValue.capitalized }
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
    let layout: MinimapLayout
    let navigation: TranscriptNavigation
    let activeID: MessageID?
    let onTarget: (MessageID) -> Void
    let onHover: (MessageID?) -> Void
    let onFocus: (Bool) -> Void
    let onOpenList: () -> Void

    func makeNSView(context: Context) -> MinimapInputView { MinimapInputView() }

    func updateNSView(_ view: MinimapInputView, context: Context) {
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
        setAccessibilityLabel("Conversation map")
        setAccessibilityIdentifier("minimap.navigation")
        setAccessibilityHelp(
            "Up and Down navigate every message. Home and End jump to the ends. Return repeats a jump. Use All messages for individual messages and exact message numbers."
        )
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
        if let index = layout.index(for: activeID) ?? layout.index(for: navigation?.viewport.firstVisibleMessageID) {
            let node = layout.nodes[index]
            setAccessibilityValue(
                "Message \(index + 1) of \(layout.nodes.count), \(node.role.rawValue), \(node.byteCount) UTF-8 bytes, \(node.status.rawValue)"
            )
        } else {
            setAccessibilityValue("\(layout.nodes.count) messages. Visible range unavailable.")
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
                Text("All \(messages.count.formatted()) messages").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                TextField("Message number (1–\(messages.count))", text: $messageNumber)
                    .accessibilityLabel("Message number")
                    .onSubmit { if let index = targetIndex { jump(index) } }
                Button("Go") { if let index = targetIndex { jump(index) } }
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
                                "\(index + 1) · \(message.role.minimapName) · \(message.content.utf8.count) bytes · \(message.status.rawValue)"
                            )
                            .font(.caption.weight(.semibold))
                            Text(message.content.isEmpty ? "Empty message" : String(message.content.prefix(180)))
                                .lineLimit(2).font(.callout).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        "Message \(index + 1), \(message.role.minimapName), \(message.content.utf8.count) UTF-8 bytes, \(message.status.rawValue). \(message.content.prefix(180))"
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
