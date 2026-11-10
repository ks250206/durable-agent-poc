import ChatCore
import SwiftUI

private typealias StoredState<Value> = SwiftUI.State<Value>

/// The owner retains store/navigation and runs `store.start()` once for its lifetime.
/// Slots match ChatShellView; no composer, minimap, provider settings, or runtime is created here.
@MainActor
public struct ChatWorkspaceView<Composer: View, Minimap: View>: View {
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
                                .accessibilityLabel("Transcript overview")
                        }
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(ChatTheme.background)
            .sheet(isPresented: $sidebarPresented) {
                VStack(spacing: 0) {
                    HStack { Spacer(); Button("Done") { sidebarPresented = false }.keyboardShortcut(.cancelAction) }.padding(12)
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
            .buttonStyle(.borderless).accessibilityLabel("Toggle conversations sidebar")
            .help("Show or hide conversations")

            VStack(alignment: .leading, spacing: 3) {
                Text(store.conversations.first(where: { $0.id == store.selectedConversationID }).map(ConversationFilter.title) ?? "New conversation")
                    .font(.headline).lineLimit(1)
                Text(store.modelSelection.map { "\($0.modelID) · \($0.account.providerID)" } ?? "No model selected")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityLabel("Selected model")
                    .accessibilityValue(store.modelSelection?.modelID ?? "None")
            }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            let connection = ConnectionPresentation(store.connection)
            Image(systemName: connection.symbol)
                .foregroundStyle(store.connection.canSend ? Color.secondary : Color.primary)
                .accessibilityLabel(connection.title).help(connection.title)
            if !layout.inlineMinimap && Minimap.self != EmptyView.self {
                Button { minimapPresented.toggle() } label: { Image(systemName: "rectangle.trailingthird.inset.filled") }
                    .buttonStyle(.borderless).accessibilityLabel("Show transcript overview")
                    .popover(isPresented: $minimapPresented) {
                        minimap.frame(width: 240, height: 420).padding(12)
                    }
            }
        }.padding(.horizontal, 16).padding(.vertical, 14)
    }

    @ViewBuilder private var activityBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            let connection = ConnectionPresentation(store.connection)
            if let detail = connection.detail {
                Label {
                    Text("\(connection.title). \(detail)").fixedSize(horizontal: false, vertical: true)
                } icon: { Image(systemName: connection.symbol) }
                .foregroundStyle(.secondary)
            }
            if let failure = store.visibleFailure {
                HStack(alignment: .top) {
                    Label(failure.message, systemImage: "exclamationmark.triangle")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button { store.clearFailure() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).accessibilityLabel("Dismiss error")
                }.foregroundStyle(.red)
            } else if case .failed(let message) = store.selectedConversation?.activity {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
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
                    } label: { Label("Stop", systemImage: "stop.fill") }
                    .disabled(stopPending || store.selectedConversation?.activity == .stopping)
                    .accessibilityLabel("Stop response")
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: ChatTheme.transcriptWidth, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var activityLabel: String {
        if stopPending || store.selectedConversation?.activity == .stopping { return "Stopping…" }
        return store.selectedConversation?.activity == .streaming ? "Responding…" : "Sending…"
    }
}

extension ChatWorkspaceView where Composer == EmptyView, Minimap == EmptyView {
    public init(store: ChatStore, navigation: TranscriptNavigation) {
        self.init(store: store, navigation: navigation, composer: { _ in EmptyView() }, minimap: { _, _ in EmptyView() })
    }
}
