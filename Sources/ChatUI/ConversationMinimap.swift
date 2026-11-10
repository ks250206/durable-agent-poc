import ChatCore
import SwiftUI

/// Compatibility entry point. The former role map is now the standalone trajectory.
/// Application tab composition belongs to #38; the thin chat-edge navigator is PromptRail.
@MainActor public struct ConversationMinimap: View {
    private let store: ChatStore
    private let navigation: TranscriptNavigation

    public init(store: ChatStore, navigation: TranscriptNavigation) {
        self.store = store
        self.navigation = navigation
    }

    public var body: some View { ConversationTrajectory(store: store, navigation: navigation) }
}
