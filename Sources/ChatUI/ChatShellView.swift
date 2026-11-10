import AppLocalization
import ChatCore
import SwiftUI

/// Source-compatible entry point sharing the workspace's live appearance and real chat behavior.
/// The caller still owns observation, provider configuration, composer and minimap content.
@MainActor
public struct ChatShellView<Composer: View, Minimap: View>: View {
    @ChatLocalization private var localization
    private let workspace: ChatWorkspaceView<Composer, Minimap>

    public init(
        store: ChatStore, navigation: TranscriptNavigation,
        @ViewBuilder composer: (ChatStore) -> Composer,
        @ViewBuilder minimap: (ChatStore, TranscriptNavigation) -> Minimap
    ) {
        workspace = ChatWorkspaceView(store: store, navigation: navigation, composer: composer, minimap: minimap)
    }

    public var body: some View {
        workspace.accessibilityLabel(localization.chat("DurableChat application shell"))
    }
}

extension ChatShellView where Composer == EmptyView, Minimap == EmptyView {
    public init(store: ChatStore, navigation: TranscriptNavigation) {
        self.init(store: store, navigation: navigation, composer: { _ in EmptyView() }, minimap: { _, _ in EmptyView() })
    }
}
