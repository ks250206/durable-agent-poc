import ChatCore
import ChatUI
import Testing

@Test @MainActor func repeatedJumpAndConversationResetRetainStableMessageIdentity() {
    let navigation = TranscriptNavigation()
    let message = MessageID("pi:entry:9:0")
    navigation.jump(to: message)
    let firstRequest = navigation.scrollRequest
    navigation.jump(to: message)
    #expect(navigation.scrollRequest?.messageID == message)
    #expect(navigation.scrollRequest?.id != firstRequest?.id)
    navigation.viewport = TranscriptViewport(firstVisibleMessageID: message, lastVisibleMessageID: message)
    navigation.reset()
    #expect(navigation.scrollRequest == nil)
    #expect(navigation.viewport == TranscriptViewport())
}
