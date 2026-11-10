import AppLocalization
import ChatCore
import SwiftUI

private typealias StoredState<Value> = SwiftUI.State<Value>

struct TranscriptMeasurements: Equatable {
    var frames: [MessageID: CGRect] = [:]
    var top: CGFloat?
    var bottom: CGFloat?

    func viewport(orderedIDs: [MessageID], height: CGFloat) -> TranscriptViewport {
        guard height.isFinite, height > 0 else { return TranscriptViewport() }
        let visible = orderedIDs.filter { id in
            guard let frame = frames[id], !frame.isInfinite, !frame.isNull,
                  frame.minY.isFinite, frame.maxY.isFinite, frame.height > 0 else { return false }
            return frame.maxY > 0 && frame.minY < height
        }
        // Distance to the *row interval*, not its midpoint: a huge assistant row can
        // contain the viewport center even when its own center is far offscreen.
        // In inter-row spacing choose the nearest visible interval (earlier on ties).
        let centerY = height / 2
        let center = visible.min { left, right in
            func distance(_ id: MessageID) -> CGFloat {
                guard let frame = frames[id] else { return .infinity }
                return max(frame.minY - centerY, centerY - frame.maxY, 0)
            }
            return distance(left) < distance(right)
        }
        return TranscriptViewport(firstVisibleMessageID: visible.first, lastVisibleMessageID: visible.last,
                                  centerVisibleMessageID: center)
    }
}

private struct TranscriptFramesKey: PreferenceKey {
    static let defaultValue = TranscriptMeasurements()
    static func reduce(value: inout TranscriptMeasurements, nextValue: () -> TranscriptMeasurements) {
        let next = nextValue()
        value.frames.merge(next.frames, uniquingKeysWith: { _, new in new })
        if let top = next.top { value.top = top }
        if let bottom = next.bottom { value.bottom = bottom }
    }
}

/// Content growth changes bottom but not top. A positive top delta away from the bottom
/// means the reader scrolled upwards; streaming must no longer move their reading position.
struct TranscriptScrollState {
    private(set) var followsLatest = true
    private var previousTop: CGFloat?
    private var awaitingJumpMovement = false

    mutating func update(_ geometry: TranscriptMeasurements, height: CGFloat) {
        guard let top = geometry.top, let bottom = geometry.bottom, height > 0 else { return }
        let atBottom = bottom <= height + 32
        if awaitingJumpMovement {
            if let previousTop, abs(top - previousTop) > 1 {
                awaitingJumpMovement = false
                followsLatest = atBottom
            }
            previousTop = top
            return
        }
        if atBottom { followsLatest = true }
        else if let previousTop, top > previousTop + 1 { followsLatest = false }
        previousTop = top
    }
    mutating func jump() { followsLatest = false; awaitingJumpMovement = true }
    mutating func resume() { followsLatest = true; awaitingJumpMovement = false }
}

/// Uses stable message IDs for jumps and reports actual intersecting row frames, including
/// a row taller than the viewport. Navigation is reset when the selected conversation changes.
@MainActor
public struct TranscriptView: View {
    @ChatLocalization private var localization
    private let store: ChatStore
    private let navigation: TranscriptNavigation

    public init(store: ChatStore, navigation: TranscriptNavigation) {
        self.store = store
        self.navigation = navigation
    }

    public var body: some View {
        Group {
            if let id = store.selectedConversationID, store.selectedConversation == nil {
                ContentUnavailableView(localization.chat("Conversation not loaded"), systemImage: "bubble.left",
                                       description: Text(localization.chat("Waiting for the backend to load this conversation.")))
                    .id(id)
            } else if store.messages.isEmpty {
                ContentUnavailableView {
                    Label(store.selectedConversationID == nil ? localization.chat("How can I help?") : localization.chat("Start a conversation"), systemImage: "sparkles")
                } description: {
                    Text(store.selectedConversationID == nil
                         ? localization.chat("Select a conversation or create a new one to get started.")
                         : localization.chat("Write a message below when your provider and model are ready."))
                }
            } else {
                TranscriptContent(conversationID: store.selectedConversationID, messages: store.messages, navigation: navigation)
                    .id(store.selectedConversationID)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: store.selectedConversationID, initial: true) { _, _ in navigation.reset() }
        .onChange(of: store.messages.isEmpty) { _, empty in
            if empty { navigation.viewport = TranscriptViewport() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localization.chat("Conversation transcript"))
    }
}

@MainActor
private struct TranscriptContent: View {
    @ChatLocalization private var localization
    let conversationID: ConversationID?
    let messages: [ChatMessage]
    let navigation: TranscriptNavigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StoredState private var scrollState = TranscriptScrollState()
    @StoredState private var measurements = TranscriptMeasurements()
    private enum Anchor: Hashable { case top, bottom }
    private var coordinateSpace: String { "transcript.\(conversationID?.rawValue ?? "none")" }

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 20) {
                        marker(top: true).id(Anchor.top)
                        ForEach(messages) { message in
                            MessageRow(message: message)
                                .frame(maxWidth: ChatTheme.transcriptWidth)
                                .id(message.id)
                                .background {
                                    GeometryReader { row in
                                        Color.clear.preference(key: TranscriptFramesKey.self,
                                                               value: TranscriptMeasurements(frames: [message.id: row.frame(in: .named(coordinateSpace))]))
                                    }
                                }
                        }
                        marker(top: false).id(Anchor.bottom)
                    }
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity)
                }
                .coordinateSpace(name: coordinateSpace)
                .onPreferenceChange(TranscriptFramesKey.self) { value in
                    measurements = value
                    report(value, height: viewport.size.height)
                    if scrollState.followsLatest, let bottom = value.bottom, bottom > viewport.size.height + 1 {
                        proxy.scrollTo(Anchor.bottom, anchor: .bottom)
                    }
                }
                .onChange(of: viewport.size.height) { _, height in
                    let wasFollowing = scrollState.followsLatest
                    report(measurements, height: height)
                    if wasFollowing { proxy.scrollTo(Anchor.bottom, anchor: .bottom) }
                }
                .onChange(of: navigation.scrollRequest?.id) { _, _ in
                    guard let request = navigation.scrollRequest, messages.contains(where: { $0.id == request.messageID }) else { return }
                    scrollState.jump()
                    // An immediate jump avoids intermediate animation frames being mistaken
                    // for a reader returning to the bottom during a minimap jump.
                    proxy.scrollTo(request.messageID, anchor: .top)
                }
                .overlay(alignment: .bottomTrailing) {
                    if !scrollState.followsLatest {
                        Button {
                            scrollState.resume()
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                                proxy.scrollTo(Anchor.bottom, anchor: .bottom)
                            }
                        } label: { Label(localization.chat("Latest"), systemImage: "arrow.down") }
                        .buttonStyle(.bordered).background(.regularMaterial, in: Capsule())
                        .accessibilityLabel(localization.chat("Jump to latest message")).padding(16)
                    }
                }
            }
        }
    }

    private func marker(top: Bool) -> some View {
        Color.clear.frame(height: 1).accessibilityHidden(true).background {
            GeometryReader { geometry in
                let frame = geometry.frame(in: .named(coordinateSpace))
                Color.clear.preference(key: TranscriptFramesKey.self,
                                       value: TranscriptMeasurements(top: top ? frame.minY : nil, bottom: top ? nil : frame.maxY))
            }
        }
    }

    private func report(_ value: TranscriptMeasurements, height: CGFloat) {
        let visible = value.viewport(orderedIDs: messages.map(\.id), height: height)
        if navigation.viewport != visible { navigation.viewport = visible }
        scrollState.update(value, height: height)
    }
}
