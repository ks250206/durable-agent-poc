import AppLocalization
import ChatCore
import SwiftUI

private typealias StoredState<Value> = SwiftUI.State<Value>

/// The owner retains store/navigation and runs `store.start()` once for its lifetime.
/// Slots match ChatShellView; no composer, minimap, provider settings, or runtime is created here.
@MainActor
public struct ChatWorkspaceView<Composer: View, Minimap: View>: View {
    @ChatLocalization private var localization
    private let store: ChatStore
    private let navigation: TranscriptNavigation
    private let composer: Composer
    private let minimap: Minimap
    @StoredState private var sidebarVisible = true
    @StoredState private var sidebarPresented = false
    @StoredState private var minimapPresented = false
    @StoredState private var stopPendingFor: ConversationID?
    private var stopPending: Bool { stopPendingFor != nil && stopPendingFor == store.selectedConversationID }

    public init(
        store: ChatStore, navigation: TranscriptNavigation,
        @ViewBuilder composer: (ChatStore) -> Composer,
        @ViewBuilder minimap: (ChatStore, TranscriptNavigation) -> Minimap
    ) {
        self.store = store
        self.navigation = navigation
        self.composer = composer(store)
        self.minimap = minimap(store, navigation)
    }

    public var body: some View {
        GeometryReader { geometry in
            let layout = WorkspaceLayout(width: geometry.size.width)
            HStack(spacing: 0) {
                if layout.inlineSidebar && sidebarVisible {
                    ConversationSidebar(store: store).frame(width: WorkspaceLayout.sidebarWidth)
                    Divider()
                }
                VStack(spacing: 0) {
                    header(layout)
                    Divider()
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            TranscriptView(store: store, navigation: navigation)
                            activityBar
                            composer
                                .frame(maxWidth: ChatTheme.transcriptWidth)
                                .padding(.horizontal, 16).padding(.bottom, 12)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        if layout.inlineMinimap && Minimap.self != EmptyView.self {
                            Divider()
                            minimap.frame(width: WorkspaceLayout.minimapWidth).clipped()
                                .accessibilityElement(children: .contain)
                                .accessibilityLabel(localization.chat("Transcript overview"))
                        }
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(ChatTheme.background)
            .sheet(isPresented: $sidebarPresented) {
                VStack(spacing: 0) {
                    HStack { Spacer(); Button(localization.chat("Done")) { sidebarPresented = false }.keyboardShortcut(.cancelAction) }.padding(12)
                    ConversationSidebar(store: store, onSelection: { sidebarPresented = false })
                }.frame(minWidth: 260, idealWidth: 320, minHeight: 360, idealHeight: 520)
            }
        }
        .accessibilityIdentifier("chat.workspace")
    }

    private func header(_ layout: WorkspaceLayout) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                if layout.inlineSidebar { sidebarVisible.toggle() } else { sidebarPresented = true }
            } label: { Image(systemName: "sidebar.left") }
            .buttonStyle(.borderless).accessibilityLabel(localization.chat("Toggle conversations sidebar"))
            .help(localization.chat("Show or hide conversations"))

            VStack(alignment: .leading, spacing: 3) {
                Text(store.conversations.first(where: { $0.id == store.selectedConversationID }).map { ConversationFilter.title($0, localizer: localization) } ?? localization.chat("New conversation"))
                    .font(.headline).lineLimit(1)
                Text(store.modelSelection.map { "\($0.modelID) · \($0.account.providerID)" } ?? localization.chat("No model selected"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityLabel(localization.chat("Selected model"))
                    .accessibilityValue(store.modelSelection?.modelID ?? localization.chat("None"))
            }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            let connection = ConnectionPresentation(store.connection, localizer: localization)
            Image(systemName: connection.symbol)
                .foregroundStyle(store.connection.canSend ? Color.secondary : Color.primary)
                .accessibilityLabel(connection.title).help(connection.title)
            if !layout.inlineMinimap && Minimap.self != EmptyView.self {
                Button { minimapPresented.toggle() } label: { Image(systemName: "rectangle.trailingthird.inset.filled") }
                    .buttonStyle(.borderless).accessibilityLabel(localization.chat("Show transcript overview"))
                    .popover(isPresented: $minimapPresented) {
                        minimap.frame(width: 240, height: 420).padding(12)
                    }
            }
        }.padding(.horizontal, 16).padding(.vertical, 14)
    }

    @ViewBuilder private var activityBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            let connection = ConnectionPresentation(store.connection, localizer: localization)
            if let detail = connection.detail {
                Label {
                    Text(verbatim: localization.chat("{title}. {detail}", [
                        "title": .string(connection.title), "detail": .string(detail),
                    ])).fixedSize(horizontal: false, vertical: true)
                } icon: { Image(systemName: connection.symbol) }
                .foregroundStyle(.secondary)
            }
            if let failure = store.visibleFailure {
                HStack(alignment: .top) {
                    Label(localization.diagnostic(failure.message), systemImage: "exclamationmark.triangle")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button { store.clearFailure() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).accessibilityLabel(localization.chat("Dismiss error"))
                }.foregroundStyle(.red)
            } else if case .failed(let message) = store.selectedConversation?.activity {
                Label(localization.diagnostic(message), systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.isSending {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).accessibilityLabel(activityLabel)
                    Text(activityLabel).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button {
                        let id = store.selectedConversationID
                        stopPendingFor = id
                        Task { @MainActor in
                            defer { if stopPendingFor == id { stopPendingFor = nil } }
                            await store.stop(conversationID: id)
                        }
                    } label: { Label(localization.chat("Stop"), systemImage: "stop.fill") }
                    .disabled(stopPending || store.selectedConversation?.activity == .stopping)
                    .accessibilityLabel(localization.chat("Stop response"))
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: ChatTheme.transcriptWidth, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var activityLabel: String {
        if stopPending || store.selectedConversation?.activity == .stopping { return localization.chat("Stopping…") }
        return store.selectedConversation?.activity == .streaming ? localization.chat("Responding…") : localization.chat("Sending…")
    }
}

extension ChatWorkspaceView where Composer == EmptyView, Minimap == EmptyView {
    public init(store: ChatStore, navigation: TranscriptNavigation) {
        self.init(store: store, navigation: navigation, composer: { _ in EmptyView() }, minimap: { _, _ in EmptyView() })
    }
}
