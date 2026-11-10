import AgentRuntime
import ChatCore
import Testing

@Test func launchRequiresExplicitDemoFlag() {
    #expect(ShellLaunchMode(arguments: ["DurableChat"]) == .empty)
    #expect(ShellLaunchMode(arguments: ["DurableChat", "demo"]) == .empty)
    #expect(ShellLaunchMode(arguments: ["DurableChat", "--demo"]) == .demo)
}

@Test func normalLaunchIsEmptyDisconnectedAndRejectsMutation() async throws {
    let backend = ShellChatBackend()
    #expect(try await backend.snapshot() == ChatSnapshot())
    var iterator = await backend.events().makeAsyncIterator()
    #expect(try await iterator.next() == .snapshot(ChatSnapshot()))
    await #expect(throws: ChatBackendError.disconnected) { try await backend.createConversation(title: nil) }
}

@Test func demoIsExplicitDeterministicAndReadOnly() async throws {
    let first = ShellChatBackend(mode: .demo)
    let second = ShellChatBackend(mode: .demo)
    let snapshot = try await first.snapshot()
    #expect(snapshot == (try await second.snapshot()))
    #expect(snapshot.connection == .demo)
    #expect(snapshot.conversations.count == 1)
    #expect(snapshot.loadedConversations.first?.messages.count == 2)
    #expect(snapshot.conversations.first?.title.contains("Demo") == true)
    await #expect(throws: ChatBackendError.demoReadOnly) { try await first.createConversation(title: nil) }
}
