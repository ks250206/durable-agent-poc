import ChatCore
import Foundation
import Testing

@Test func stableIDsAndStreamingMessagesRoundTrip() throws {
    let conversation = ConversationID("pi:conversation:42")
    var message = ChatMessage(id: MessageID("pi:entry:99:0"), conversationID: conversation,
                              role: .assistant, content: "first", status: .streaming)
    let originalID = message.id
    message.content += " second"
    message.status = .complete
    let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
    #expect(decoded == message)
    #expect(decoded.id == originalID)
    #expect(decoded.conversationID == conversation)
    #expect(try JSONDecoder().decode(ConversationID.self, from: Data("\"pi:conversation:42\"".utf8)) == conversation)
}

@Test func providerRoutesAndModelIdentityRemainDistinct() throws {
    let api = ProviderAccount(option: .apiKey, providerID: "openai")
    let subscription = ProviderAccount(option: .chatGPT, providerID: "openai-codex")
    let codex = ProviderAccount(option: .codexCLI, providerID: "codex-cli")
    let cursor = ProviderAccount(option: .cursor, providerID: "cursor")
    #expect(Set([api, subscription, cursor, codex]).count == 4)
    #expect(ModelSelection(account: api, modelID: "same") != ModelSelection(account: subscription, modelID: "same"))
    let config = ProviderConfiguration(account: cursor, selectedModelID: "auto", executablePath: "/tmp/agent")
    #expect(try JSONDecoder().decode(ProviderConfiguration.self, from: JSONEncoder().encode(config)) == config)
    #expect(ProviderOption.allCases == [.apiKey, .chatGPT, .cursor, .codexCLI])
}

@Test func busyStatesAndEmptyDefaultsHaveExpectedMeaning() {
    #expect(ConversationActivity.sending.isBusy)
    #expect(ConversationActivity.streaming.isBusy)
    #expect(ConversationActivity.stopping.isBusy)
    #expect(!ConversationActivity.idle.isBusy)
    #expect(!ConversationActivity.failed("failed").isBusy)
    #expect(ChatSnapshot().connection == .disconnected)
    #expect(ChatSnapshot().conversations.isEmpty)
    #expect(!ConnectionState.demo.canSend)
    #expect(ConnectionState.connected.canSend)
}
