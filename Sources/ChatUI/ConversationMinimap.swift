import ChatCore
import SwiftUI

/// Compact compatibility entry point for the existing sidebar/popover slot.
/// The full ConversationTrajectory is mounted separately as an application tab in #38.
@MainActor public struct ConversationMinimap: View {
    private let store: ChatStore
    private let navigation: TranscriptNavigation

    public init(store: ChatStore, navigation: TranscriptNavigation) {
        self.store = store
        self.navigation = navigation
    }

    public var body: some View { PromptRail(store: store, navigation: navigation) }
}
