import AppKit
import AppLocalization
import ChatCore
import SwiftUI

/// Slim, overlay-compatible user-input navigation. The owner supplies the same store
/// and navigation as TranscriptView. This component never starts observation or generation.
@MainActor
public struct PromptRail: View {
    @ChatLocalization private var localization
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    private let store: ChatStore
    private let navigation: TranscriptNavigation

    public init(store: ChatStore, navigation: TranscriptNavigation) {
        self.store = store
        self.navigation = navigation
    }

    public var body: some View {
        let model = PromptRailModel(messages: store.messages)
        PromptRailSurface(model: model, conversationID: store.selectedConversationID,
                          navigation: navigation, viewport: navigation.viewport,
                          localizer: localization, reduceMotion: reduceMotion,
                          increasedContrast: contrast == .increased)
            .frame(width: PromptRailGeometry.width)
            .frame(maxHeight: .infinity)
            .onChange(of: store.selectedConversationID) { _, _ in
                // A sibling transcript may already have measured the new conversation.
                // Preserve that report, but always discard the previous jump request.
                let viewport = navigation.viewport
                navigation.reset()
                if let center = viewport.centerVisibleMessageID,
                   store.messages.contains(where: { $0.id == center }) {
                    navigation.viewport = viewport
                }
            }
    }
}

@MainActor
private struct PromptRailSurface: NSViewRepresentable {
    let model: PromptRailModel
    let conversationID: ConversationID?
    let navigation: TranscriptNavigation
    let viewport: TranscriptViewport
    let localizer: Localizer
    let reduceMotion: Bool
    let increasedContrast: Bool

    func makeNSView(context: Context) -> PromptRailInputView { PromptRailInputView(frame: .zero) }
    func updateNSView(_ view: PromptRailInputView, context: Context) {
        view.configure(model: model, conversationID: conversationID, navigation: navigation,
                       viewport: viewport, localizer: localizer, reduceMotion: reduceMotion,
                       increasedContrast: increasedContrast)
    }
}

/// A single roving native key/AX participant reaches every retained input. Only
/// visible bars have layers; no input is discarded when the rail window changes.
@MainActor
final class PromptRailInputView: NSView {
    private(set) var model = PromptRailModel(messages: [])
    private(set) var currentID: MessageID?
    private(set) var hoveredID: MessageID?
    private(set) var cursorID: MessageID?
    private(set) var windowStart = 0
    private var conversationID: ConversationID?
    private var configured = false
    private var navigation: TranscriptNavigation?
    private var localizer = Localizer(language: .english)
    private var reduceMotion = false
    private var increasedContrast = false
    private var keyboardFocused = false
    private var previousSize = CGSize.zero
    private var tracking: NSTrackingArea?
    private var bars: [MessageID: CALayer] = [:]
    private let earlierLayer = CATextLayer()
    private let laterLayer = CATextLayer()
    private var popover: NSPopover?
    private(set) var previewText: String?
    private var previewID: MessageID?
    private weak var previewTextView: NSTextView?
    private var previewPointer = false
    private var closePreviewTask: Task<Void, Never>?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { !model.inputs.isEmpty }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var geometry: PromptRailGeometry {
        PromptRailGeometry(size: bounds.size, count: model.inputs.count, proposedStart: windowStart)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityIdentifier("promptRail.navigation")
        for arrow in [earlierLayer, laterLayer] {
            arrow.fontSize = 11
            arrow.alignmentMode = .center
            arrow.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            layer?.addSublayer(arrow)
        }
        earlierLayer.string = "⌃"
        laterLayer.string = "⌄"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(model: PromptRailModel, conversationID: ConversationID?, navigation: TranscriptNavigation,
                   viewport: TranscriptViewport, localizer: Localizer, reduceMotion: Bool,
                   increasedContrast: Bool) {
        let changedConversation = configured && self.conversationID != conversationID
        configured = true
        self.conversationID = conversationID
        self.navigation = navigation
        self.localizer = localizer
        self.reduceMotion = reduceMotion
        self.increasedContrast = increasedContrast
        self.model = model
        if changedConversation {
            cursorID = nil
            hoveredID = nil
            windowStart = 0
            closePreview()
        }
        let measuredCurrent = model.currentInput(in: viewport)
        if currentID != measuredCurrent || changedConversation {
            currentID = measuredCurrent
            cursorID = nil // manual scroll returns keyboard navigation to the measured turn
            setHover(nil)
            closePreview()
            if let index = model.index(for: currentID) { reveal(index) }
        }
        if model.index(for: cursorID) == nil { cursorID = nil }
        if model.index(for: hoveredID) == nil { setHover(nil) }
        if let id = previewID {
            if let index = model.index(for: id) {
                let content = model.inputs[index].content
                if previewText != content { showPreview(index) }
                // Updating translated labels never recreates the native navigation view.
                popover?.contentViewController?.view.setAccessibilityLabel(inputDescription(index))
                previewTextView?.setAccessibilityLabel(inputDescription(index))
            } else { closePreview() }
        }
        windowStart = geometry.start
        updateLayers(animated: false)
        updateAccessibility()
    }

    override func layout() {
        super.layout()
        windowStart = geometry.start
        // Resizing has its own geometry pass; hovering never changes the cells or bounds.
        if bounds.size != previousSize, let index = model.index(for: cursorID ?? currentID) { reveal(index) }
        previousSize = bounds.size
        updateLayers(animated: false)
        updateAccessibility()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayers(animated: false)
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { closePreview() }
        super.viewWillMove(toWindow: newWindow)
    }
    override func becomeFirstResponder() -> Bool {
        keyboardFocused = true
        cursorID = cursorID ?? currentID ?? model.inputs.first?.id
        updateLayers(animated: false)
        updateAccessibility()
        return true
    }
    override func resignFirstResponder() -> Bool {
        keyboardFocused = false
        cursorID = nil
        updateLayers(animated: false)
        return true
    }

    private func reveal(_ index: Int) { windowStart = geometry.start(revealing: index) }

    /// The right anchor stays fixed; only CALayer bounds animate. Input geometry never
    /// reads presentation layers, so pointer movement cannot trigger a layout feedback loop.
    private func updateLayers(animated: Bool) {
        guard let root = layer else { return }
        let geometry = geometry
        let visibleIDs = Set(geometry.visible.map { model.inputs[$0].id })
        for id in Array(bars.keys) where !visibleIDs.contains(id) {
            bars.removeValue(forKey: id)?.removeFromSuperlayer()
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(!animated || reduceMotion)
            CATransaction.setAnimationDuration(0.14)
            for index in geometry.visible {
                let id = model.inputs[index].id
                let bar: CALayer
                if let existing = bars[id] { bar = existing }
                else {
                    bar = CALayer()
                    bar.anchorPoint = CGPoint(x: 1, y: 0.5)
                    bar.cornerRadius = 1.25
                    root.addSublayer(bar)
                    bars[id] = bar
                }
                let current = id == currentID
                let hovered = id == hoveredID
                let cell = geometry.cell(for: index)
                bar.bounds = CGRect(x: 0, y: 0, width: geometry.barWidth(current: current, hovered: hovered), height: 2.5)
                bar.position = CGPoint(x: max(0, bounds.width - 6), y: cell.midY)
                let alpha: CGFloat = current ? 0.95 : (hovered ? 0.75 : (increasedContrast ? 0.7 : 0.46))
                bar.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
                if reduceMotion { bar.removeAllAnimations() }
                let focused = keyboardFocused && id == (cursorID ?? currentID)
                bar.borderWidth = focused ? 1 : 0
                bar.borderColor = NSColor.controlAccentColor.cgColor
            }
            earlierLayer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: PromptRailGeometry.controlHeight)
            laterLayer.frame = CGRect(x: 0, y: max(0, bounds.height - PromptRailGeometry.controlHeight),
                                      width: bounds.width, height: PromptRailGeometry.controlHeight)
            earlierLayer.isHidden = !geometry.isWindowed || !geometry.hasEarlier
            laterLayer.isHidden = !geometry.isWindowed || !geometry.hasLater
            for arrow in [earlierLayer, laterLayer] { arrow.foregroundColor = NSColor.secondaryLabelColor.cgColor }
            CATransaction.commit()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func resetCursorRects() { if !model.inputs.isEmpty { addCursorRect(bounds, cursor: .pointingHand) } }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) {
        let index = geometry.index(at: convert(event.locationInWindow, from: nil))
        let id = index.map { model.inputs[$0].id }
        guard id != hoveredID else { return }
        setHover(id)
        if let index { showPreview(index) } else { schedulePreviewClose() }
    }
    override func mouseExited(with event: NSEvent) {
        setHover(nil)
        schedulePreviewClose() // permits entering/selecting/scrolling the native popover
    }
    private func setHover(_ id: MessageID?) {
        guard hoveredID != id else { return }
        hoveredID = id
        updateLayers(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        window?.makeFirstResponder(self)
        if let index = geometry.index(at: point) { activate(index) }
        else if geometry.isWindowed {
            if point.y < geometry.topInset { shiftWindow(-max(1, geometry.capacity)) }
            else if point.y >= bounds.height - PromptRailGeometry.controlHeight { shiftWindow(max(1, geometry.capacity)) }
        }
    }
    override func scrollWheel(with event: NSEvent) {
        guard geometry.isWindowed else { super.scrollWheel(with: event); return }
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        shiftWindow(delta > 0 ? -max(1, Int(abs(delta) / 3)) : max(1, Int(abs(delta) / 3)))
    }
    private func shiftWindow(_ distance: Int) {
        windowStart = PromptRailGeometry(size: bounds.size, count: model.inputs.count,
                                        proposedStart: windowStart + distance).start
        setHover(nil)
        closePreview()
        updateLayers(animated: false)
        updateAccessibility()
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 126: move(-1)
        case 125: move(1)
        case 115: activate(0)
        case 119: activate(model.inputs.count - 1)
        case 116: move(-max(1, geometry.capacity))
        case 121: move(max(1, geometry.capacity))
        case 36, 76, 49: activate(model.index(for: cursorID ?? currentID) ?? 0)
        case 53: setHover(nil); closePreview()
        case 48:
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
        default: super.keyDown(with: event)
        }
    }
    private func move(_ distance: Int) {
        let index = model.index(for: cursorID ?? currentID)
        // With no viewport/cursor, the first action targets the first/last input.
        activate(index.map { min(max(0, $0 + distance), model.inputs.count - 1) }
                 ?? (distance < 0 ? model.inputs.count - 1 : 0))
    }
    private func activate(_ index: Int) {
        guard model.inputs.indices.contains(index) else { return }
        cursorID = model.inputs[index].id
        reveal(index)
        setHover(nil)
        closePreview()
        navigation?.jump(to: model.inputs[index].id)
        updateLayers(animated: false)
        updateAccessibility()
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    private func inputDescription(_ index: Int) -> String {
        localizer.chat("User input {current} of {total}", ["current": .integer(index + 1), "total": .integer(model.inputs.count)])
    }
    private func updateAccessibility() {
        setAccessibilityLabel(localizer.chat("User input navigation"))
        var help = localizer.chat("Each bar is a user input. The bright bar follows the transcript center. Hover previews the original input. Click, Up/Down, Home/End or Return jumps to an input. Tab leaves navigation.")
        if geometry.isWindowed {
            help += " " + localizer.chat("Showing inputs {first}–{last} of {total}. Scroll here or use Page Up/Down to browse every input.", [
                "first": .integer(geometry.visible.isEmpty ? 0 : geometry.visible.lowerBound + 1),
                "last": .integer(geometry.visible.upperBound), "total": .integer(model.inputs.count),
            ])
        }
        setAccessibilityHelp(help)
        if let index = model.index(for: cursorID ?? currentID) {
            // Entire original plain text, including whitespace and empty content; no preview truncation.
            setAccessibilityValue(inputDescription(index) + "\n" + model.inputs[index].content)
        } else { setAccessibilityValue(localizer.chat("{count} user inputs. Transcript center unavailable.", ["count": .integer(model.inputs.count)])) }
        setAccessibilityEnabled(!model.inputs.isEmpty)
    }
    override func accessibilityPerformIncrement() -> Bool {
        guard !model.inputs.isEmpty else { return false }
        move(1); return true
    }
    override func accessibilityPerformDecrement() -> Bool {
        guard !model.inputs.isEmpty else { return false }
        move(-1); return true
    }
    override func accessibilityPerformPress() -> Bool {
        guard !model.inputs.isEmpty else { return false }
        activate(model.index(for: cursorID ?? currentID) ?? 0); return true
    }

    private func showPreview(_ index: Int) {
        guard model.inputs.indices.contains(index), window != nil else { return }
        closePreview()
        let message = model.inputs[index]
        previewID = message.id
        previewText = message.content
        let controller = NSViewController()
        let container = PromptRailPreviewView(frame: CGRect(x: 0, y: 0, width: 320, height: 260))
        container.onPointer = { [weak self] inside in
            self?.previewPointer = inside
            if inside { self?.closePreviewTask?.cancel() } else { self?.schedulePreviewClose() }
        }
        container.setAccessibilityLabel(inputDescription(index))
        let scroll = NSScrollView(frame: container.bounds.insetBy(dx: 14, dy: 14))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        let text = PromptRailPreviewTextView(frame: CGRect(origin: .zero, size: scroll.contentSize))
        text.onDismiss = { [weak self] in self?.setHover(nil); self?.closePreview() }
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.string = message.content
        text.font = .systemFont(ofSize: 13)
        text.textColor = .textColor
        text.backgroundColor = .textBackgroundColor
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = CGSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        text.setAccessibilityLabel(inputDescription(index))
        text.setAccessibilityValue(message.content)
        scroll.documentView = text
        previewTextView = text
        container.addSubview(scroll)
        controller.view = container
        let popup = NSPopover()
        popup.contentViewController = controller
        popup.behavior = .applicationDefined
        popup.animates = false
        popup.contentSize = container.bounds.size
        popover = popup
        // AppKit keeps this separate window onscreen at both vertical edges and narrow hosts.
        popup.show(relativeTo: geometry.cell(for: index), of: self, preferredEdge: .minX)
    }
    private func schedulePreviewClose() {
        closePreviewTask?.cancel()
        closePreviewTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard let self, !previewPointer else { return }
            closePreview()
        }
    }
    private func closePreview() {
        closePreviewTask?.cancel()
        closePreviewTask = nil
        popover?.close()
        popover = nil
        previewID = nil
        previewText = nil
        previewTextView = nil
        previewPointer = false
    }
}

@MainActor
private final class PromptRailPreviewView: NSView {
    var onPointer: (Bool) -> Void = { _ in }
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { onPointer(true) }
    override func mouseExited(with event: NSEvent) { onPointer(false) }
}

@MainActor
private final class PromptRailPreviewTextView: NSTextView {
    var onDismiss: () -> Void = {}
    override func cancelOperation(_ sender: Any?) { onDismiss() }
}
