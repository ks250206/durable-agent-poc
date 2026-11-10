# Issue #3 shared API handoff

These are public application contracts. `ChatCore` imports only Foundation and Observation;
it does not expose PiDurableKit types. All value models are `Sendable`; IDs are opaque strings.
No runtime authentication, provider discovery, persistence, composer, transcript renderer,
or minimap layout is implemented here. Issue numbers have been checked against GitHub.

## IDs and transcript models (`import ChatCore`)

- `StableID<Tag>`: `RawRepresentable<String>`, `Hashable`, `Codable` (single string),
  `Sendable`, `CustomStringConvertible`; `init(_:)`, `init(rawValue:)`, immutable `rawValue`.
- `ConversationID = StableID<ConversationIDTag>` and `MessageID = StableID<MessageIDTag>`.
  Namespace IDs by backend and persist them. Pi mappings should be deterministic, for example
  `pi:conversation:1`, `pi:entry:42:0`. Do not regenerate a message ID as its streaming text changes;
  reuse it when the message settles. Entry submessage ordinals must also be stable. A runtime can
  persist a streaming-to-committed ID mapping when its upstream IDs differ.
- `MessageRole: String`: `.system`, `.user`, `.assistant`, `.tool`.
- `MessageStatus: String`: `.complete`, `.streaming`, `.stopped`, `.failed`.
- `ChatMessage: Identifiable, Equatable, Codable`: immutable `id: MessageID`,
  `conversationID: ConversationID`, `role: MessageRole`, `createdAt: Date`;
  mutable `content: String`, `status: MessageStatus`.
  `init(id:conversationID:role:content:createdAt:status:)` (date now; status complete by default).
- `ConversationSummary: Identifiable, Equatable, Codable`: immutable `id: ConversationID`,
  `createdAt: Date`; mutable `title: String`, `updatedAt: Date`.
  `init(id:title:createdAt:updatedAt:)` (dates default to now).
- `ConversationActivity: Equatable, Codable`: `.idle`, `.sending`, `.streaming`, `.stopping`,
  `.failed(String)`; `isBusy` is true only for sending/streaming/stopping.
- `ConversationSnapshot: Identifiable, Equatable, Codable`: mutable `summary: ConversationSummary`,
  `messages: [ChatMessage]` (ordered complete transcript), `activity: ConversationActivity`;
  computed `id = summary.id`. `init(summary:messages:activity:)` (empty/idle defaults).
  Every message must belong to this conversation. No truncation is implied by this contract.
- `ConnectionState: Equatable, Codable`: `.disconnected`, `.connecting`, `.connected`, `.demo`,
  `.failed(String)`; `canSend` is true only when connected. Demo is always read-only.
- `ChatSnapshot: Equatable, Codable`: mutable `connection: ConnectionState`,
  `conversations: [ConversationSummary]`, `selectedConversationID: ConversationID?`,
  `loadedConversations: [ConversationSnapshot]`.
  `init(connection:conversations:selectedConversationID:loadedConversations:)` defaults to empty/disconnected.
  This is a full replacement of list, selection, connection, and loaded transcript cache. Include the
  selected transcript. Unloaded transcripts can be omitted, but their summaries remain in the list.
  A snapshot with a removed conversation drops its cached messages too. IDs must be unique.

## Backend and events (`import ChatCore`; #7 and #8 implement)

```swift
public protocol ChatBackend: Sendable {
    func snapshot() async throws -> ChatSnapshot
    func events() async -> AsyncThrowingStream<ChatEvent, any Error>
    func createConversation(title: String?) async throws -> ConversationID
    func selectConversation(_ id: ConversationID?) async throws
    func send(_ request: SendRequest) async throws
    func stop(conversationID: ConversationID) async throws
}

public enum ChatEvent: Equatable, Sendable {
    case snapshot(ChatSnapshot)
    case conversationUpdated(ConversationSnapshot)
}
```

Each event subscriber receives an **atomic initial snapshot**, followed by ordered events without a
subscription gap. Serialize mutations; create/select emit an authoritative snapshot before returning.
`createConversation` creates **and selects**. Selecting `nil` clears selection. A conversation update
replaces its entire transcript and upserts its summary, **without changing selection**. Preserve backend
list ordering; the UI may derive filtered or sorted summaries. Do not use `snapshot()` followed by
`events()` to observe (that would create a race); `snapshot()` is an independent point-in-time read.

`SendRequest: Equatable, Sendable` has immutable `conversationID`, `messageID: MessageID`, `text: String`,
`model: ModelSelection`; `init(conversationID:messageID:text:model:)` creates a UUID message ID by default.
The client message ID is an idempotency key: persist/reuse it for the user message and when retrying the
same submission. Return from send on acceptance, then publish streaming/completion via events. Reject
empty/busy/unconfigured requests in the backend too. Never route a submission by the *current* UI selection.
`stop` targets only its given conversation, preserves partial output with `.stopped` message status, and
publishes an idle conversation. Canceling an event subscriber releases that subscriber's resources and
must not abort generation. Error strings exposed to the UI must not contain secrets.

`ChatBackendError: Error, Equatable, LocalizedError` cases: `.disconnected`, `.demoReadOnly`,
`.emptyMessage`, `.noConversation`, `.noModel`, `.busy`, `.unavailable(String)`.
`ChatFailure: Equatable, Sendable` has immutable `operation: String`, `message: String`,
`conversationID: ConversationID?`; `init(operation:message:conversationID:)` (nil default).

## Observable store (`import ChatCore`; #4 consumes)

```swift
@MainActor @Observable public final class ChatStore {
    public init(backend: any ChatBackend)
    // Read-only to callers:
    public private(set) var connection: ConnectionState
    public private(set) var conversations: [ConversationSummary]
    public private(set) var selectedConversationID: ConversationID?
    public private(set) var loadedConversations: [ConversationID: ConversationSnapshot]
    public private(set) var lastFailure: ChatFailure?
    public private(set) var isObserving: Bool
    // UI/settings writable:
    public var draft: String
    public var modelSelection: ModelSelection?
    // Derived read-only:
    public var selectedConversation: ConversationSnapshot? { get }
    public var messages: [ChatMessage] { get }
    public var isSending: Bool { get }
    public var canSend: Bool { get }
    public var visibleFailure: ChatFailure? { get }
    public func start() async
    public func clearFailure()
    public func createConversation(title: String? = nil) async -> ConversationID?
    public func selectConversation(_ id: ConversationID?) async
    public func send(_ text: String) async -> Bool
    public func sendDraft() async
    public func stop() async
}
```

Own the store in SwiftUI `@State`; pass it to child views (or use typed environment injection).
Run `await store.start()` in **one owner's** `.task`. This suspends for the subscription lifetime;
cancel on owner teardown. A second concurrent start is a no-op; it can restart after termination.
Cancellation disconnects observation without calling backend stop. Stream failure/unexpected end
marks the connection failed and disables sending; call start again to reconnect.

Commands catch failures and publish `lastFailure`; the UI displays `visibleFailure` to avoid showing
a delayed conversation-A error in B. Clear with `clearFailure()`. `isSending` includes a pending send
command and selected conversation activity. `canSend` requires connected, loaded selection, model,
and nonbusy state; the composer must additionally reject whitespace and marked-text submission.
`send` validates and captures conversation/model before suspension and preserves original whitespace.
`sendDraft` clears the draft only after acceptance and only if the draft and selection are unchanged.
Draft is a single UI buffer, not persistent per-conversation history. Backends own persistent transcripts.

## Provider, model, and credential boundary (`import ChatCore`; #7/#8 implement)

All following values are `Equatable`, `Codable`, `Sendable`; account/selection are also `Hashable`.

- `ProviderOption: String, CaseIterable, Identifiable`: `.apiKey`, `.chatGPT`, `.cursor`;
  computed `id: Self`, `displayName: String`.
- `ProviderAccount(option: ProviderOption, providerID: String)`: both mutable.
  Separate routes: `(.apiKey, "openai")`, `(.chatGPT, "openai-codex")`, `(.cursor, "cursor")`.
  API-key route supports other Pi provider IDs as well. Do not treat ChatGPT OAuth as an OpenAI API key.
- `ModelSelection(account: ProviderAccount, modelID: String)`: both mutable.
- `ChatModel(id: ModelSelection, displayName: String)`: both mutable; `Identifiable`.
- `ProviderConfiguration(account:selectedModelID:executablePath:)`: mutable `account: ProviderAccount`,
  `selectedModelID: String? = nil`, `executablePath: String? = nil` (Cursor executable override).
  Only nonsecret preferences belong here.
- `AuthenticationState`: `.unconfigured`, `.signedOut`, `.signingIn`, `.configured`,
  `.unavailable(String)`, `.failed(String)`.
- `ProviderStatus(configuration:authentication:models:)`: mutable `configuration: ProviderConfiguration`,
  `authentication: AuthenticationState`, `models: [ChatModel] = []`.

```swift
public protocol ProviderSettingsService: Sendable {
    func snapshot() async throws -> [ProviderStatus]
    func update(_ configuration: ProviderConfiguration) async throws
    func setAPIKey(_ key: String?, for account: ProviderAccount) async throws
    func login(to account: ProviderAccount) async throws
    func cancelLogin(to account: ProviderAccount) async
    func logout(from account: ProviderAccount) async throws
}
```

The settings view refreshes snapshot after operations, owns the login Task, and uses cancellation or
`cancelLogin` to dismiss authentication. Service implementations reject unsupported combinations.
A nil API key removes it. Pi keys/OAuth live in Keychain; Cursor credentials stay in its official CLI
store and are never extracted. No raw OAuth token appears in this API. `update` persists only nonsecret
configuration; service `snapshot` supplies provider-discovered models/authentication state. Integration
copies the chosen account/model into `store.modelSelection`; there is no implicit/default model or login.
A composite service/backend router, if needed, belongs to #9.

## UI insertion points (`import ChatUI`; #4/#5/#6)

- `ChatShellView<Composer: View, Minimap: View>` is the #3 placeholder. Public initializer:
  `init(store:navigation:composer:minimap:)`, where the ViewBuilder slots have types
  `(ChatStore) -> Composer` and `(ChatStore, TranscriptNavigation) -> Minimap`.
  `init(store:navigation:)` supplies empty slots. #9 replaces this shell with #4's workspace;
  the real Composer/Minimap views are not defined or mocked here.
- `@MainActor @Observable TranscriptNavigation`: `init()`, mutable `viewport: TranscriptViewport`,
  read-only `scrollRequest: MessageScrollRequest?`, `jump(to: MessageID)`, `reset()`.
- `TranscriptViewport: Equatable, Sendable` has mutable `firstVisibleMessageID: MessageID?`,
  `lastVisibleMessageID: MessageID?`; matching initializer defaults to nil/nil.
- `MessageScrollRequest: Identifiable, Equatable, Sendable`: immutable `id: UUID`, `messageID: MessageID`;
  `init(messageID:)` generates a fresh request ID, so repeated jumps to the same message still fire.

#4 owns ScrollViewReader, observes request ID, and reports viewport IDs. #6 uses all current conversation
messages to derive layout, calls `jump`, and draws viewport from these IDs. Reset navigation on conversation
switch and ignore jump IDs missing from that transcript. #5 binds its text to `$store.draft`, receives
`isSending`/`canSend`, and calls `sendDraft()` only after IME validation; stop uses `store.stop()`.
No IME behavior or minimap layout has been implemented by #3.

## Runtime/app composition (`import AgentRuntime`; #9 replaces)

`ShellLaunchMode: Equatable, Sendable` cases `.empty`, `.demo`; `init(arguments: [String])` checks only
`--demo`. `ShellChatBackend: actor, ChatBackend` has `init(mode: ShellLaunchMode = .empty)` and the
protocol methods above. It never initializes Pi, reads credentials, discovers Cursor, or calls a provider.
Normal snapshot is empty/disconnected; demo is deterministic/read-only and visibly labeled. Every
mutation throws `.disconnected` or `.demoReadOnly`. No fallback-to-demo behavior is allowed.

App owns store/navigation in a single main Window. The Settings scene is a placeholder for #7's
ProviderSettingsView; #9 injects the runtime/service and connects the real workspace/composer/minimap.
Package target dependencies are already wired: ChatUI -> ChatCore; AgentRuntime -> ChatCore + pinned
PiDurableKit; DurableChatApp -> all three. All three libraries have test targets.
