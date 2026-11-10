import AppLocalization
import ChatCore
import SwiftUI

private typealias StoredState<Value> = SwiftUI.State<Value>

/// The owner retains store/navigation and runs `store.start()` once for its lifetime.
/// Slots match ChatShellView; no composer, minimap, provider settings, or runtime is created here.
@MainActor
public struct ChatWorkspaceView<Composer: View, Minimap: View>: View {
    @ChatLocalization private var localization
    @ChatAppearance private var appearance
    @Environment(\.chatDiagnosticTemplates) private var diagnosticTemplates
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
                    ConversationSidebar(store: store).frame(width: ChatTheme.Dimensions.sidebarWidth)
                    Rectangle().fill(appearance.palette.stroke.color.opacity(appearance.contrast == .increased ? 1 : 0.4)).frame(width: appearance.strokeWidth)
                }
                VStack(spacing: 0) {
                    header(layout)
                    separator
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            TranscriptView(store: store, navigation: navigation)
                            activityBar
                            composer
                                .frame(maxWidth: ChatTheme.Dimensions.readableWidth)
                                .padding(.horizontal, ChatTheme.Spacing.large).padding(.bottom, ChatTheme.Spacing.large)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        if layout.inlineMinimap && Minimap.self != EmptyView.self {
                            Rectangle().fill(appearance.palette.stroke.color.opacity(appearance.contrast == .increased ? 1 : 0.4)).frame(width: appearance.strokeWidth)
                            minimap.frame(width: WorkspaceLayout.minimapWidth).clipped()
                                .accessibilityElement(children: .contain)
                                .accessibilityLabel(localization.chat("Transcript overview"))
                        }
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            }
            .foregroundStyle(appearance.palette.primaryText.color)
            .background(appearance.palette.mainCanvas.color)
            .sheet(isPresented: $sidebarPresented) {
                VStack(spacing: 0) {
                    HStack { Spacer(); Button { sidebarPresented = false } label: {
                            Text(localization.chat("Done")).padding(.horizontal, 12).frame(minHeight: ChatTheme.Dimensions.controlHeight)
                        }
                            .buttonStyle(WorkspaceButtonStyle(raised: true)).keyboardShortcut(.cancelAction)
                    }.padding(12)
                    ConversationSidebar(store: store, onSelection: { sidebarPresented = false })
                }
                .frame(width: min(ChatTheme.Dimensions.popoverWidth, max(260, geometry.size.width - 32)), height: min(620, max(360, geometry.size.height - 48)))
                .background(appearance.palette.sidebar.color)
                .environment(\.locale, localization.locale)
                .environment(\.chatDiagnosticTemplates, diagnosticTemplates)
                .preferredColorScheme(appearance.colorScheme)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.workspace")
    }

    private var separator: some View {
        Rectangle().fill(appearance.palette.stroke.color.opacity(appearance.contrast == .increased ? 1 : 0.4))
            .frame(height: appearance.strokeWidth).accessibilityHidden(true)
    }

    private var conversationTitle: String {
        store.conversations.first(where: { $0.id == store.selectedConversationID })
            .map { ConversationFilter.title($0, localizer: localization) } ?? localization.chat("New conversation")
    }

    private func header(_ layout: WorkspaceLayout) -> some View {
        HStack(alignment: .center, spacing: ChatTheme.Spacing.medium) {
            Button {
                if layout.inlineSidebar { sidebarVisible.toggle() } else { sidebarPresented = true }
            } label: {
                Image(systemName: "sidebar.left").font(.system(size: 15))
                    .frame(width: ChatTheme.Dimensions.controlHeight, height: ChatTheme.Dimensions.controlHeight)
            }
            .buttonStyle(WorkspaceButtonStyle())
            .accessibilityIdentifier("chat.workspace.sidebar")
            .accessibilityLabel(localization.chat("Toggle conversations sidebar"))
            .help(localization.chat("Show or hide conversations"))

            VStack(alignment: .leading, spacing: 4) {
                Text(conversationTitle)
                    .font(ChatTheme.Typography.heading).lineLimit(1).truncationMode(.tail)
                    .help(conversationTitle)
                Text(store.modelSelection.map { "\($0.modelID) · \($0.account.providerID)" } ?? localization.chat("No model selected"))
                    .font(ChatTheme.Typography.caption).foregroundStyle(appearance.palette.secondaryText.color).lineLimit(1)
                    .accessibilityLabel(localization.chat("Selected model"))
                    .accessibilityValue(store.modelSelection.map { "\($0.modelID) · \($0.account.providerID)" } ?? localization.chat("None"))
                    .help(store.modelSelection.map { "\($0.modelID) · \($0.account.providerID)" } ?? localization.chat("No model selected"))
            }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            let connection = ConnectionPresentation(store.connection, localizer: localization, diagnosticTemplates: diagnosticTemplates)
            HStack(spacing: 6) {
                Image(systemName: connection.symbol)
                if layout.inlineSidebar { Text(connection.title).lineLimit(1) }
            }
            .font(ChatTheme.Typography.caption.weight(.medium))
            .foregroundStyle(connectionColor)
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(appearance.palette.raised.color, in: Capsule())
            .overlay(Capsule().strokeBorder(appearance.palette.stroke.color.opacity(appearance.contrast == .increased ? 1 : 0.45), lineWidth: appearance.strokeWidth))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(connection.title).help(connection.title)

            if !layout.inlineMinimap && Minimap.self != EmptyView.self {
                Button { minimapPresented.toggle() } label: {
                    Image(systemName: "rectangle.trailingthird.inset.filled")
                        .frame(width: ChatTheme.Dimensions.controlHeight, height: ChatTheme.Dimensions.controlHeight)
                }
                .buttonStyle(WorkspaceButtonStyle())
                .accessibilityLabel(localization.chat("Show transcript overview"))
                .popover(isPresented: $minimapPresented) {
                    minimap.frame(width: 240, height: 420).padding(12)
                        .background(appearance.palette.raised.color)
                        .environment(\.locale, localization.locale)
                        .environment(\.chatDiagnosticTemplates, diagnosticTemplates)
                        .preferredColorScheme(appearance.colorScheme)
                }
            }
        }
        .padding(.horizontal, ChatTheme.Spacing.large).padding(.vertical, ChatTheme.Spacing.medium)
        .frame(minHeight: ChatTheme.Dimensions.headerHeight)
        .background(appearance.palette.mainCanvas.color)
    }

    private var connectionColor: Color {
        switch store.connection {
        case .connected: appearance.palette.success.color
        case .failed: appearance.palette.error.color
        case .demo, .disconnected, .connecting: appearance.palette.secondaryText.color
        }
    }

    @ViewBuilder private var activityBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            let connection = ConnectionPresentation(store.connection, localizer: localization, diagnosticTemplates: diagnosticTemplates)
            if let detail = connection.detail {
                Label {
                    Text(verbatim: localization.chat("{title}. {detail}", [
                        "title": .string(connection.title), "detail": .string(detail),
                    ])).fixedSize(horizontal: false, vertical: true)
                } icon: { Image(systemName: connection.symbol) }
                .foregroundStyle(appearance.palette.secondaryText.color)
            }
            if let failure = store.visibleFailure {
                HStack(alignment: .top) {
                    Label(localization.diagnostic(failure.message, templates: diagnosticTemplates), systemImage: "exclamationmark.triangle")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button { store.clearFailure() } label: { Image(systemName: "xmark").padding(6) }
                        .buttonStyle(WorkspaceButtonStyle()).accessibilityLabel(localization.chat("Dismiss error"))
                }.foregroundStyle(appearance.palette.error.color)
            } else if case .failed(let message) = store.selectedConversation?.activity {
                Label(localization.diagnostic(message, templates: diagnosticTemplates), systemImage: "exclamationmark.triangle").foregroundStyle(appearance.palette.error.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.isSending {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).accessibilityLabel(activityLabel)
                    Text(activityLabel).foregroundStyle(appearance.palette.secondaryText.color)
                    Spacer(minLength: 4)
                    Button {
                        let id = store.selectedConversationID
                        stopPendingFor = id
                        Task { @MainActor in
                            defer { if stopPendingFor == id { stopPendingFor = nil } }
                            await store.stop(conversationID: id)
                        }
                    } label: {
                        Label(localization.chat("Stop"), systemImage: "stop.fill")
                            .padding(.horizontal, 10).padding(.vertical, 7)
                    }
                    .buttonStyle(WorkspaceButtonStyle(raised: true))
                    .accessibilityIdentifier("chat.workspace.stop")
                    .disabled(stopPending || store.selectedConversation?.activity == .stopping)
                    .accessibilityLabel(localization.chat("Stop response"))
                }
            }
        }
        .font(ChatTheme.Typography.secondary)
        .frame(maxWidth: ChatTheme.transcriptWidth, alignment: .leading)
        .padding(.horizontal, ChatTheme.Spacing.large)
        .padding(.vertical, hasActivity ? ChatTheme.Spacing.small : 0)
    }

    private var hasActivity: Bool {
        if ConnectionPresentation(store.connection, localizer: localization, diagnosticTemplates: diagnosticTemplates).detail != nil { return true }
        if store.visibleFailure != nil || store.isSending { return true }
        if case .failed = store.selectedConversation?.activity { return true }
        return false
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
