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

@MainActor
public struct ConversationSidebar: View {
    @ChatLocalization private var localization
    @Environment(\.chatDiagnosticTemplates) private var diagnosticTemplates
    private let store: ChatStore
    private let onSelection: () -> Void
    @StoredState private var actions: ConversationSidebarActions

    public init(store: ChatStore, onSelection: @escaping () -> Void = {}) {
        self.store = store
        self.onSelection = onSelection
        _actions = StoredState(initialValue: ConversationSidebarActions(store: store))
    }

    private var filtered: [ConversationSummary] { ConversationFilter.matching(store.conversations, query: actions.query, localizer: localization) }

    public var body: some View {
        @Bindable var actions = actions
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "bubble.left.and.bubble.right").accessibilityHidden(true)
                Text("DurableChat").font(.headline)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.top, 20)

            Button {
                Task { await actions.create() }
            } label: {
                Label(actions.isCreating ? localization.chat("Creating…") : localization.chat("New conversation"), systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            }
            .disabled(!store.connection.canSend || actions.isBusy)
            .keyboardShortcut("n", modifiers: .command)
            .accessibilityLabel(localization.chat("New conversation"))
            .help(localization.chat("Create and select a new conversation"))
            .padding(.horizontal, 12)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField(localization.chat("Search conversations"), text: $actions.query)
                    .textFieldStyle(.plain).accessibilityLabel(localization.chat("Search conversations"))
                if !actions.query.isEmpty {
                    Button { actions.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(localization.chat("Clear conversation search"))
                }
            }
            .padding(8).background(ChatTheme.inset, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)

            if let failure = store.lastFailure, failure.operation == "select" {
                HStack(alignment: .top) {
                    Label(localization.diagnostic(failure.message, templates: diagnosticTemplates), systemImage: "exclamationmark.triangle")
                        .fixedSize(horizontal: false, vertical: true)
                    Button { store.clearFailure() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).accessibilityLabel(localization.chat("Dismiss selection error"))
                }.font(.caption).foregroundStyle(.red).padding(.horizontal, 12)
            }

            if filtered.isEmpty {
                ContentUnavailableView(
                    actions.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? localization.chat("No conversations yet") : localization.chat("No matches"),
                    systemImage: "bubble.left",
                    description: Text(actions.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? localization.chat("Your conversations will appear here.") : localization.chat("Try another conversation title."))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filtered) { summary in
                            conversationButton(summary)
                        }
                    }.padding(.horizontal, 8).padding(.bottom, 12)
                }
                .accessibilityLabel(localization.chat("Conversations"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ChatTheme.sidebar)
        .onChange(of: store.selectedConversationID) { _, _ in onSelection() }
    }

    private func conversationButton(_ summary: ConversationSummary) -> some View {
        let selected = store.selectedConversationID == summary.id
        return Button {
            if selected { onSelection(); return }
            Task { await actions.select(summary.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left").accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ConversationFilter.title(summary, localizer: localization)).lineLimit(2).multilineTextAlignment(.leading)
                    if summary.id.rawValue.hasPrefix("pi:conversation:") {
                        Text("Pi").font(.caption).foregroundStyle(.secondary)
                    } else if summary.id.rawValue.hasPrefix("cursor:conversation:") {
                        Text("Cursor").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if store.loadedConversations[summary.id]?.activity.isBusy == true {
                    Image(systemName: "ellipsis").accessibilityLabel(localization.chat("Response in progress"))
                }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(actions.isBusy)
        .accessibilityLabel(ConversationFilter.title(summary, localizer: localization))
        .accessibilityValue(store.loadedConversations[summary.id]?.activity.isBusy == true ? localization.chat("Response in progress") : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(summary.title)
    }
}
