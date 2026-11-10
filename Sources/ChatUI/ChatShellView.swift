import ChatCore
import SwiftUI

/// Deliberately minimal shell, replaced by #4's ChatWorkspaceView at #9 integration.
/// Composer (#5) and minimap (#6) enter as typed ViewBuilder slots; settings enter the App's Settings scene.
@MainActor
public struct ChatShellView<Composer: View, Minimap: View>: View {
    private let store: ChatStore
    private let composer: Composer
    private let minimap: Minimap

    public init(
        store: ChatStore, navigation: TranscriptNavigation,
        @ViewBuilder composer: (ChatStore) -> Composer,
        @ViewBuilder minimap: (ChatStore, TranscriptNavigation) -> Minimap
    ) {
        self.store = store
        self.composer = composer(store)
        self.minimap = minimap(store, navigation)
    }

    public var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 16) {
                Text("DurableChat").font(.title)
                if store.connection == .demo {
                    Text("DEMO — read-only sample data").font(.headline)
                    Text("\(store.conversations.count) sample conversation; \(store.messages.count) sample messages.")
                } else {
                    Text("No backend connected")
                    Text("Choose and configure a provider when runtime integration is installed.")
                        .foregroundStyle(.secondary)
                }
                composer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            minimap
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 320)
        .accessibilityLabel("DurableChat application shell")
    }
}

extension ChatShellView where Composer == EmptyView, Minimap == EmptyView {
    public init(store: ChatStore, navigation: TranscriptNavigation) {
        self.init(store: store, navigation: navigation, composer: { _ in EmptyView() }, minimap: { _, _ in EmptyView() })
    }
}
