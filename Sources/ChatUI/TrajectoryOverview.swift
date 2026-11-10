import AppKit
import AppLocalization
import ChatCore

/// Projection of the existing complete-history layout onto horizontal order and role lanes.
/// Each lane has the same text-weighted order axis. It is never an elapsed-time chart.
@MainActor final class TrajectoryOverview: NSView {
    private(set) var layout = MinimapLayout(messages: [])
    private var viewport = TranscriptViewport()
    private var localizer = Localizer(language: .english)
    private var resolved = ResolvedAppearance(colorScheme: .light)
    private var navigation: TranscriptNavigation?
    var activeID: MessageID? { didSet { needsDisplay = true } }
    var hoverID: MessageID? {
        didSet { toolTip = layout.index(for: hoverID).map { value($0) }; needsDisplay = true }
    }
    var onTarget: (MessageID) -> Void = { _ in }
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { !layout.nodes.isEmpty }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var plot: CGRect { CGRect(x: min(142, bounds.width * 0.39), y: 4, width: max(0, bounds.width - min(142, bounds.width * 0.39) - 8), height: 78) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityIdentifier("trajectory.overview")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(layout: MinimapLayout, viewport: TranscriptViewport, localizer: Localizer,
                   resolved: ResolvedAppearance, navigation: TranscriptNavigation) {
        self.layout = layout
        self.viewport = viewport
        self.localizer = localizer
        self.resolved = resolved
        self.navigation = navigation
        appearance = resolved.nsAppearance
        if layout.index(for: activeID) == nil { activeID = nil }
        if layout.index(for: hoverID) == nil { hoverID = nil }
        updateAX()
        toolTip = layout.index(for: hoverID).map { value($0) }
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let p = resolved.palette
        p.sidebar.nsColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: ChatTheme.Radii.control, yRadius: ChatTheme.Radii.control).fill()
        let labels = [localizer.chat("Input / User"), localizer.chat("Assistant / Model"), localizer.chat("Tool / System")]
        for lane in 0..<3 {
            let y = plot.minY + CGFloat(lane) * 26
            let color = roleColor(lane)
            color.setFill()
            let badge = CGRect(x: 8, y: y + 8, width: 6, height: 6)
            if lane == 0 { NSBezierPath(ovalIn: badge).fill() }
            else if lane == 1 { NSBezierPath(rect: badge).fill() }
            else {
                let path = NSBezierPath()
                path.move(to: CGPoint(x: badge.midX, y: badge.minY))
                path.line(to: CGPoint(x: badge.maxX, y: badge.midY))
                path.line(to: CGPoint(x: badge.midX, y: badge.maxY))
                path.line(to: CGPoint(x: badge.minX, y: badge.midY))
                path.close(); path.fill()
            }
            drawText(labels[lane], rect: CGRect(x: 20, y: y + 3, width: max(0, plot.minX - 26), height: 20), color: p.primaryText.nsColor)
            p.stroke.nsColor.setStroke()
            let baseline = NSBezierPath()
            baseline.move(to: CGPoint(x: plot.minX, y: y + 22))
            baseline.line(to: CGPoint(x: plot.maxX, y: y + 22))
            baseline.lineWidth = 0.5
            baseline.stroke()
            if !layout.nodes.contains(where: { MinimapLayout.trajectoryLane($0.role) == lane }) {
                drawText(localizer.chat("No messages for this role"), rect: CGRect(x: plot.minX + 3, y: y + 3, width: plot.width - 6, height: 20), color: p.mutedText.nsColor)
            }
        }
        for index in layout.nodes.indices {
            let rect = layout.trajectoryRect(for: index, plot: plot)
            roleColor(MinimapLayout.trajectoryLane(layout.nodes[index].role)).setFill()
            NSBezierPath(rect: rect).fill()
            if layout.nodes[index].status != .complete, rect.width >= 4 {
                p.primaryText.nsColor.setStroke()
                let outline = NSBezierPath(rect: rect)
                outline.lineWidth = 1
                outline.stroke()
            }
        }
        if let band = layout.trajectoryViewportRect(viewport, plot: plot) {
            p.primaryText.nsColor.setStroke()
            let path = NSBezierPath(rect: band.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = resolved.strokeWidth
            path.stroke()
        }
        for (id, dashed) in [(hoverID, false), (activeID, true)] {
            if let index = layout.index(for: id) {
                let rect = layout.trajectoryRect(for: index, plot: plot)
                p.focus.nsColor.setStroke()
                let path = NSBezierPath()
                path.move(to: CGPoint(x: rect.midX, y: plot.minY))
                path.line(to: CGPoint(x: rect.midX, y: plot.maxY))
                if dashed { path.setLineDash([3, 2], count: 2, phase: 0) }
                path.lineWidth = 2
                path.stroke()
            }
        }
        drawText(localizer.chat("Earlier → Later · text-weighted order"), rect: CGRect(x: 8, y: 88, width: bounds.width - 16, height: 20), color: p.secondaryText.nsColor)
        if window?.firstResponder === self {
            p.focus.nsColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: ChatTheme.Radii.control, yRadius: ChatTheme.Radii.control)
            ring.lineWidth = resolved.focusWidth
            ring.stroke()
        }
    }
    func roleColor(_ lane: Int) -> NSColor {
        switch lane {
        case 0: resolved.palette.accent.nsColor
        case 1: ThemeColor(hex: resolved.colorScheme == .dark ? 0xc4b0ed : 0x68418f).nsColor
        default: resolved.palette.warning.nsColor
        }
    }
    private func drawText(_ text: String, rect: CGRect, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: color, .paragraphStyle: paragraph])
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        tracking = area
        addTrackingArea(area)
    }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resetCursorRects() { addCursorRect(plot, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if let index = layout.trajectoryIndex(at: convert(event.locationInWindow, from: nil), plot: plot) { activate(index) }
    }
    override func mouseMoved(with event: NSEvent) {
        let index = layout.trajectoryIndex(at: convert(event.locationInWindow, from: nil), plot: plot)
        hoverID = index.map { layout.nodes[$0].id }
        toolTip = index.map { value($0) }
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) { hoverID = nil; toolTip = nil; needsDisplay = true }
    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 123, 126: move(-1)
        case 124, 125: move(1)
        case 116: move(-10)
        case 121: move(10)
        case 115: activate(0)
        case 119: activate(layout.nodes.count - 1)
        case 36, 76, 49: activate(currentIndex)
        case 48:
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
        default: super.keyDown(with: event)
        }
    }
    private var currentIndex: Int { layout.index(for: activeID) ?? layout.index(for: viewport.centerVisibleMessageID) ?? layout.index(for: viewport.firstVisibleMessageID) ?? 0 }
    private func move(_ distance: Int) { activate(min(max(0, currentIndex + distance), layout.nodes.count - 1)) }
    private func activate(_ index: Int) {
        guard layout.nodes.indices.contains(index) else { return }
        let id = layout.nodes[index].id
        activeID = id
        onTarget(id)
        navigation?.jump(to: id)
        updateAX()
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .valueChanged)
    }
    private func value(_ index: Int) -> String {
        let node = layout.nodes[index]
        return localizer.chat("Message {current} of {total}, {role}, {bytes} UTF-8 bytes, {status}", [
            "current": .integer(index + 1), "total": .integer(layout.nodes.count), "role": .string(localizer.role(node.role)),
            "bytes": .integer(node.byteCount), "status": .string(localizer.status(node.status))])
    }
    func updateAX() {
        setAccessibilityLabel(localizer.chat("Full-history role overview"))
        setAccessibilityHelp(localizer.chat("Left/Right or Up/Down navigate every message. Home/End reach the ends. Return repeats a jump. The solid outline is the actual chat viewport; the dashed line is your target. Tab leaves the overview."))
        setAccessibilityValue(layout.nodes.indices.contains(currentIndex) ? value(currentIndex) : localizer.chat("No messages yet"))
    }
    override func accessibilityPerformIncrement() -> Bool { guard !layout.nodes.isEmpty else { return false }; move(1); return true }
    override func accessibilityPerformDecrement() -> Bool { guard !layout.nodes.isEmpty else { return false }; move(-1); return true }
    override func accessibilityPerformPress() -> Bool { guard !layout.nodes.isEmpty else { return false }; activate(currentIndex); return true }
}

// Internal source compatibility for the existing native integration fixtures.
typealias MinimapInputView = TrajectoryOverview
