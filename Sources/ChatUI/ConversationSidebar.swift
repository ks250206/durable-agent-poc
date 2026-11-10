import AppLocalization
import ChatCore
import Observation
import SwiftUI

private typealias StoredState<Value> = SwiftUI.State<Value>

/// Searches titles without reordering the backend's authoritative conversation list.
enum ConversationFilter {
    static func matching(_ conversations: [ConversationSummary], query: String, localizer: Localizer = Localizer(language: .english)) -> [ConversationSummary] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return conversations.filter { conversation in
            terms.allSatisfy { term in
                title(conversation, localizer: localizer).range(of: term, options: [.caseInsensitive, .diacriticInsensitive], locale: localizer.locale) != nil
            }
        }
    }

    static func title(_ summary: ConversationSummary, localizer: Localizer = Localizer(language: .english)) -> String {
        summary.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? localizer.chat("Untitled conversation") : summary.title
    }
}

/// Serializes sidebar commands without optimistically changing backend-owned selection.
@MainActor @Observable
final class ConversationSidebarActions {
    let store: ChatStore
    var query = ""
    private(set) var isCreating = false
    private(set) var isSelecting = false
    var filtered: [ConversationSummary] { ConversationFilter.matching(store.conversations, query: query) }
    var isBusy: Bool { isCreating || isSelecting }

    init(store: ChatStore) { self.store = store }

    func create() async {
        guard store.connection.canSend, !isBusy else { return }
        isCreating = true
        defer { isCreating = false }
        if await store.createConversation() != nil { query = "" }
    }

    func select(_ id: ConversationID) async {
        guard !isBusy else { return }
        isSelecting = true
        defer { isSelecting = false }
        if store.lastFailure?.operation == "select" { store.clearFailure() }
        await store.selectConversation(id)
    }
}

/// Native buttons retain keyboard activation; custom chrome only changes their presentation.
struct WorkspaceButtonStyle: ButtonStyle {
    @ChatAppearance private var appearance
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @StoredState private var hovered = false
    var selected = false
    var raised = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? appearance.palette.primaryText.color : appearance.palette.mutedText.color)
            .background(surface(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: ChatTheme.Radii.code))
            .overlay {
                RoundedRectangle(cornerRadius: ChatTheme.Radii.code)
                    .strokeBorder(focused ? appearance.palette.focus.color : appearance.palette.stroke.color.opacity(raised || selected ? (appearance.contrast == .increased ? 1 : 0.55) : 0),
                                  lineWidth: focused ? appearance.focusWidth : appearance.strokeWidth)
            }
            .opacity(enabled ? 1 : 0.6)
            .onHover { hovered = $0 }
            .animation(appearance.feedbackAnimation, value: hovered)
            .animation(appearance.feedbackAnimation, value: selected)
    }

    private func surface(pressed: Bool) -> Color {
        if selected { return appearance.palette.active.color }
        if enabled && (hovered || pressed) { return appearance.palette.hover.color }
        return raised ? appearance.palette.raised.color : .clear
    }
}

@MainActor
public struct ConversationSidebar: View {
    @ChatLocalization private var localization
    @ChatAppearance private var appearance
    @Environment(\.chatDiagnosticTemplates) private var diagnosticTemplates
    private let store: ChatStore
    private let onSelection: () -> Void
    @StoredState private var actions: ConversationSidebarActions
    @FocusState private var searchFocused: Bool

    public init(store: ChatStore, onSelection: @escaping () -> Void = {}) {
        self.store = store
        self.onSelection = onSelection
        _actions = StoredState(initialValue: ConversationSidebarActions(store: store))
    }

    private var filtered: [ConversationSummary] { ConversationFilter.matching(store.conversations, query: actions.query, localizer: localization) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 19, weight: .medium)).foregroundStyle(appearance.palette.accent.color)
                    .accessibilityHidden(true)
                Text("DurableChat").font(ChatTheme.Typography.heading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 24)

            Button {
                Task { await actions.create() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.pencil").accessibilityHidden(true)
                    Text(actions.isCreating ? localization.chat("Creating…") : localization.chat("New conversation"))
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(ChatTheme.Typography.secondary.weight(.semibold))
                .padding(.horizontal, 12).frame(minHeight: 40)
            }
            .buttonStyle(WorkspaceButtonStyle(raised: true))
            .shadow(color: appearance.palette.shadow.color, radius: ChatTheme.Shadows.popoverRadius, y: ChatTheme.Shadows.popoverY)
            .disabled(!store.connection.canSend || actions.isBusy)
            .keyboardShortcut("n", modifiers: .command)
            .accessibilityLabel(localization.chat("New conversation"))
            .accessibilityIdentifier("chat.sidebar.create")
            .help(localization.chat("Create and select a new conversation"))
            .padding(.horizontal, 12)

            searchControl.padding(.horizontal, 12).padding(.top, 12)
            Text(localization.chat("Conversations"))
                .font(ChatTheme.Typography.caption.weight(.semibold))
                .foregroundStyle(appearance.palette.mutedText.color)
                .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 10)

            if let failure = store.lastFailure, failure.operation == "select" {
                HStack(alignment: .top, spacing: 8) {
                    Label(localization.diagnostic(failure.message, templates: diagnosticTemplates), systemImage: "exclamationmark.triangle")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { store.clearFailure() } label: { Image(systemName: "xmark").padding(6) }
                        .buttonStyle(WorkspaceButtonStyle())
                        .accessibilityLabel(localization.chat("Dismiss selection error"))
                }
                .font(ChatTheme.Typography.secondary).foregroundStyle(appearance.palette.error.color)
                .padding(12).background(appearance.palette.raised.color, in: RoundedRectangle(cornerRadius: ChatTheme.Radii.code))
                .padding(.horizontal, 12).padding(.bottom, 8)
            }

            if filtered.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(actions.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? localization.chat("No conversations yet") : localization.chat("No matches"))
                        .font(ChatTheme.Typography.secondary.weight(.medium))
                    Text(actions.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? localization.chat("Your conversations will appear here.") : localization.chat("Try another conversation title."))
                        .font(ChatTheme.Typography.secondary).foregroundStyle(appearance.palette.mutedText.color)
                }
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 20).padding(.top, 8)
                Spacer(minLength: 16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filtered) { summary in conversationButton(summary) }
                    }.padding(.horizontal, 8).padding(.bottom, 16)
                }
                .accessibilityLabel(localization.chat("Conversations"))
            }
        }
        .font(ChatTheme.Typography.secondary)
        .foregroundStyle(appearance.palette.primaryText.color)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(appearance.palette.sidebar.color)
        .onChange(of: store.selectedConversationID) { _, _ in onSelection() }
    }

    private var searchControl: some View {
        @Bindable var actions = actions
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(appearance.palette.mutedText.color).accessibilityHidden(true)
            TextField(localization.chat("Search conversations"), text: $actions.query)
                .textFieldStyle(.plain).focused($searchFocused)
                .accessibilityLabel(localization.chat("Search conversations"))
                .accessibilityIdentifier("chat.sidebar.search")
                .onExitCommand { actions.query = "" }
            if !actions.query.isEmpty {
                Button { actions.query = "" } label: { Image(systemName: "xmark.circle.fill").padding(3) }
                    .buttonStyle(WorkspaceButtonStyle())
                    .foregroundStyle(appearance.palette.mutedText.color)
                    .accessibilityLabel(localization.chat("Clear conversation search"))
            }
        }
        .padding(.horizontal, 10).frame(height: ChatTheme.Dimensions.controlHeight + 4)
        .background(appearance.palette.mainCanvas.color.opacity(0.5), in: RoundedRectangle(cornerRadius: ChatTheme.Radii.code))
        .overlay {
            RoundedRectangle(cornerRadius: ChatTheme.Radii.code)
                .strokeBorder(searchFocused ? appearance.palette.focus.color : appearance.palette.stroke.color.opacity(appearance.contrast == .increased ? 1 : 0.45),
                              lineWidth: searchFocused ? appearance.focusWidth : appearance.strokeWidth)
        }
    }

    private func conversationButton(_ summary: ConversationSummary) -> some View {
        let selected = store.selectedConversationID == summary.id
        return Button {
            if selected { onSelection(); return }
            Task { await actions.select(summary.id) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(selected ? appearance.palette.accent.color : .clear)
                    .frame(width: 3, height: 16).padding(.top, 1).accessibilityHidden(true)
                Text(ConversationFilter.title(summary, localizer: localization))
                    .font(ChatTheme.Typography.secondary.weight(selected ? .medium : .regular))
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if store.loadedConversations[summary.id]?.activity.isBusy == true {
                    Image(systemName: "ellipsis").foregroundStyle(appearance.palette.accent.color)
                        .accessibilityLabel(localization.chat("Response in progress"))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: ChatTheme.Radii.code))
        }
        .buttonStyle(WorkspaceButtonStyle(selected: selected))
        .disabled(actions.isBusy)
        .accessibilityIdentifier("chat.sidebar.row.\(summary.id.rawValue)")
        .accessibilityLabel(ConversationFilter.title(summary, localizer: localization))
        .accessibilityValue(store.loadedConversations[summary.id]?.activity.isBusy == true ? localization.chat("Response in progress") : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(summary.title)
    }
}
