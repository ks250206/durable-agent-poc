> Historical foundation/API handoff below. Current application composition, Codex route and
> four-language behavior are documented in [Integration.md](Integration.md),
> [CodexRuntime.md](CodexRuntime.md) and [Localization.md](Localization.md). Statements that a
> feature was not yet implemented describe the original #3 boundary, not the final app.

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
same submission. ChatStore currently exposes new submissions only; an explicit retry UI is deferred.
Publish acceptance including the client user-message ID before returning from send, then publish
streaming/completion via events. Event delivery can lag command completion; ChatStore keeps sending
disabled until the accepted message or busy state is observed. Reject
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
`sendDraft` clears the draft only after acceptance and only if the draft is unchanged.
Draft is a single UI buffer, not persistent per-conversation history. Accepted text is cleared if unchanged even after switching conversations, so it cannot be accidentally resubmitted in the new conversation. Backends own persistent transcripts.

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

## Issue #36 standalone prompt rail handoff (application wiring: #38)

`@MainActor public PromptRail(store: ChatStore, navigation: TranscriptNavigation): View` is a new
standalone component. Supply the **same instances** as `TranscriptView`; the owner still starts
`store.start()` once. It does not replace or modify `ConversationMinimap`, install a workspace,
or alter the composer, message rows, appearance settings or runtime. It uses semantic native label
colors and the standard accent for keyboard focus, without a dependency on future #32 tokens.

The rail has a default fixed **40 pt width**, transparent background, 12 pt vertical input cells,
and neutral horizontal bars of 10 pt (ordinary), 22 pt (current) and 28 pt (hover). A trailing overlay
is supported; #38 must reserve trailing reading space so the fixed hit strip does not cover text,
and keep Latest/other controls outside that strip. Animated widths do not change hit cells, borders,
bar anchors or transcript layout. Reduce Motion suppresses/removes width animations.

`TranscriptViewport` adds mutable `centerVisibleMessageID: MessageID?` as the final initializer
argument, **default nil**. Existing `TranscriptViewport()`, two-argument initializers, public first/last
properties, `jump(to:)`, repeated jump requests and `reset()` remain source compatible. TranscriptView
reports the measured row interval containing the actual viewport midpoint, including a row larger
than the viewport; in a spacing gap it selects the nearest visible row (earlier on ties). The rail
uses the preceding-or-equal user input in complete transcript order. It never estimates center from
first/last indices or content length. A nil/missing center or a center before the first user has no
current bar. Standalone consumers that manually set viewport must supply the new center for highlighting.

Every user input and every message-to-preceding-user association is retained by stable ID. Dense
histories use an explicit scrollable **window of full-sized cells**, never silent truncation or
unselectable subpixels. Top/bottom chevrons page that window; wheel scrolling over the rail browses
it without moving the transcript. AX help announces the exact shown range/total. Up/Down, Page
Up/Down, Home/End and AX increment/decrement reach every input and jump to its exact user ID;
Return/Space/AX press repeat a jump. Tab/Shift-Tab leave the single native roving focus participant.
Its AX value includes the ordinal, total and **entire original input text**. The keyboard cursor and
hover are independent of the measured current turn; only actual transcript measurement changes that
highlight. Manual transcript scrolling returns keyboard navigation to the measured turn and reveals
it in the rail. Streaming updates never issue a jump or change the reader's scroll position.

Hover uses a bounded native popover containing selectable, scrollable, read-only plain text, verbatim
including whitespace/Markdown-looking content. AppKit positions it against screen edges; it is a
separate window and does not enlarge the rail or overlap its hit strip. Exiting a cell clears only
hover immediately. A short dismissal grace allows entering/scrolling/selecting the popover; leaving
both dismisses it. Escape dismisses it too. Conversation changes clear local hover/cursor/window
and stale requests; a sibling's already-valid new center report is retained. Removing IDs clears
their stale state. Language/appearance updates keep the same native key-view participant and do not
remount store, navigation, transcript or editors. Five new ChatUI keys belong only to #36, in all four
locales and both audited inventories; #32 retains ownership of Appearance resources.

Local verification on 2026-11-10 after incorporating main `dbc753e`: **147 tests passed**, including
8 new rail tests (all 5 native rail tests use the existing serialized suite). Coverage includes 0/1/10,000 inputs and
every AX step, fixed hover hit cells, multiline raw-text popovers/AX/Escape, huge assistant rows,
manual scrolling/streaming/reset/missing IDs, unchanged native identity/focus across four languages
and appearance changes, Reduce Motion, and at least 3:1 native bar contrast in Light/Dark and
increased contrast. Real transcript + rail hosts were rendered at 400/1200 pt in all four languages
and Light/Dark; component PNGs/logs are opt-in under ignored `dist/qa/issue-36/`. The full command
was bounded to 270 seconds and finished normally. Existing IME/undo/native tests remain intact.
Source and packaged resource audits passed with ChatUI 109 keys in all four locales, including exact
Foundation lookups; release packaging and deep/strict ad-hoc signature verification passed.
This is synthetic native hosting evidence; physical VoiceOver/IME and final app wiring remain
outside this component change. Remote CI and independent review must be read separately.

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

## Issue 9 application routing extension

`ChatSnapshot.modelContext: ChatModelContext?` defaults to nil so standalone backends and existing clients
retain their behavior. The composite router supplies `ChatModelContext(selection: ModelSelection?, notice: String?)`;
ChatStore applies the choice/notice atomically with selection and transcript, exposing `routingNotice` for app UX.
The model remains UI-writable for standalone clients; integrated app settings use `ChatBackendRouter.useModel`.
`ChatStore.stop(conversationID: ConversationID?)` additionally permits pre-Task origin capture; `stop()` remains.
See [Integration.md](Integration.md) for composite subscription, persisted account bindings and shutdown ownership.

## Issue #23 localization presentation seam

AppSession retains one `LocalizationSettings` and passes it plus its locale to both scenes and
roots. `LanguagePickerView(localization:)` is reused from #20. Runtime/App tables belong to #23;
Common/ChatUI remain with #20/#22. `RuntimePresentation.diagnostic(_:localizer:)` and its two
`diagnosticTemplates` are presentation adapters over canonical English source strings, never a
backend mutation or transcript transform. ChatUI's optional `EnvironmentValues.chatDiagnosticTemplates`
(default `[]`) forwards only that explicit runtime allowlist at diagnostic display sites. This small
adapter is needed for open interpolated failures; ChatUI does not import AgentRuntime and ChatCore
still does not import AppLocalization. #24 should audit this seam and inventories without absorbing
provider behavior, changing account/model routing, or replacing persisted source diagnostics.

## Issue #32 appearance and design handoff (`import ChatUI`)

This is the shared foundation for #33–#37. AppSession, scenes, workspace, transcript, composer,
sidebar and navigation are **not wired here**. Existing ChatTheme and ConnectionPresentation
consumers remain source-compatible. ChatCore has no SwiftUI/AppKit/AppLocalization dependency;
no package dependency or provider behavior changes.

### Ownership and persistence (#33)

`AppearanceChoice: String, CaseIterable, Identifiable, Sendable` is ordered `.system`, `.light`,
`.dark` with canonical stored identifiers `system`, `light`, `dark`. Public `init(persistedValue:)`
accepts only exact identifiers; missing, invalid, translated, wrong-case and non-string defaults
fall back to System. `nameKey` is a key in **Appearance**, not Common or ChatUI.
`preferredColorScheme: ColorScheme?` returns nil/light/dark.

`@MainActor @Observable public final class AppearanceSettings` has:

```swift
init(defaults: UserDefaults, storageKey: String = AppearanceSettings.defaultStorageKey)
var choice: AppearanceChoice { get set }
var preferredColorScheme: ColorScheme? { get }
func resetToSystem()
func resolve(systemColorScheme: ColorScheme, contrast: ColorSchemeContrast = .standard,
             reduceMotion: Bool = false) -> ResolvedAppearance
```

`defaults` is **required**; the library never selects `.standard`. Production #33 can explicitly
pass its defaults; demo/test modes must pass disposable suites, as language already does.
`defaultStorageKey` is `DurableChat.appearanceOverride`. Only explicit light/dark is persisted.
System/reset removes that key; initialization repairs invalid storage. No language, OS preference,
credential, model or account value is read or changed. Reopen recreates the owner with the same suite.
Observation invalidates choice-derived body reads synchronously, without a task or reinitialization.

Own one instance, pass the same reference into every Window/Settings/popover presentation and
apply the preference at **each presentation root** (SwiftUI uses the nearest enclosing presentation):

```swift
// Example for #33 only; no app scene is modified in #32.
ContentView()
    .environment(appearanceSettings)
    .preferredColorScheme(appearanceSettings.preferredColorScheme)
// In a consuming SwiftUI view:
@ChatAppearance private var appearance
// Inside body: appearance.palette.mainCanvas.color; appearance.feedbackAnimation
// Existing localization owner remains independent:
AppearancePickerView(settings: appearanceSettings, localizer: localization.localizer)
```

`AppearancePickerView` has public `init(settings: AppearanceSettings, localizer: Localizer)`.
It supplies a localized System/Light/Dark picker, explanatory help, and Reset to System. It does not
own windows/defaults, cache language globally, or install lifecycle observers. Pass the live localizer
from body. `LocalizationTable.appearance` declares its six keys in en/ja/zh-Hans/ko. #33 should reuse
these resources, not add a duplicate set to App/Common. See Localization.md for inventory ownership.

### Resolution and native controls (#34/#35/#36/#37)

`@ChatAppearance: DynamicProperty` is public, with `init()` and `wrappedValue: ResolvedAppearance`.
It reads optional typed `AppearanceSettings` injection, SwiftUI `colorScheme`, `colorSchemeContrast`,
and `accessibilityReduceMotion`. Without an owner it uses the environment and never loads defaults.
Explicit Light/Dark wins over the environment's scheme; System resolves on **every environment update**.
Use nil `preferredColorScheme` to release the override. Do not cache a launch-time NSApp appearance,
observe/mutate AppleInterfaceStyle, set NSApp.appearance, or freeze a System scheme in defaults.

`ResolvedAppearance: Equatable, Sendable` exposes public immutable `colorScheme`, `contrast`,
`reduceMotion`, and `init(colorScheme:contrast:reduceMotion:)` (standard/false defaults). Derived fields:

- `palette: ChatPalette`; `strokeWidth` 1/1.5 pt and `focusWidth` 2/3 pt for standard/increased contrast.
- `feedbackAnimation: Animation?`: 140 ms ease-out or nil with Reduce Motion. Consumers must also
  avoid spatial/scroll animation when reduced; nil is not permission to start an implicit animation.
- `@MainActor nsAppearance: NSAppearance`: assignable Aqua/Dark Aqua, even if macOS currently uses
  the opposite scheme. AppKit applies the OS Increase Contrast preference to native controls.
  Accessibility high-contrast names are **matching-only**, not assignable overrides. Custom chrome
  always uses the snapshot's explicit contrast palette, including in deterministic tests.
- `@MainActor resolveAppKitColor(_ color: NSColor) -> NSColor?`: resolves system/selection colors
  inside that concrete drawing appearance into sRGB; callers handle an unconvertible color.

For an NSViewRepresentable, read `@ChatAppearance` during update and set **the existing** native
view's `appearance = appearance.nsAppearance`. Use `appearance.palette.<role>.nsColor` for text,
background, insertion point and custom chrome; use `resolveAppKitColor` for system selection colors.
Assigning a plain ambient fixed NSColor once in makeNSView is insufficient under forced Light/Dark.
Do not replace the native editor, coordinator, binding or attributed text on a presentation change.
Update presentation properties in place; retain marked text, selection, first responder, undo, draft,
ChatStore, navigation, subscription and generation. Never add `.id(choice)` or conditional root types.
Production composer adoption and real physical IME QA belong to #35/#38, not this foundation.

### Token names and compatibility

`ThemeColor: Equatable, Sendable` exposes immutable `red/green/blue/opacity: Double`,
`init(hex: UInt32, opacity: Double = 1)` and concrete `color: Color` / `nsColor: NSColor`.
`ChatPalette: Equatable, Sendable` has `init(colorScheme: ColorScheme,
contrast: ColorSchemeContrast = .standard)` and immutable ThemeColor fields:

- surfaces `mainCanvas`, `sidebar`, `raised` (popover/tooltip), `composer`, `code`, `userBubble`;
- interaction `active` (selected navigation), `hover`, `stroke`, `focus`;
- text `primaryText`, `secondaryText`, `mutedText`, `textOnAccent`;
- status `accent`, `success`, `warning`, `error`, and `shadow`.

Dark uses restrained charcoal (#151515 canvas, #242426 sidebar, #2e2e30 composer), fine borders,
and a muted blue accent. Light uses warm neutral distinct surfaces. Normal readable text/status roles
are tested at >=4.5:1 on every content/interaction surface; focus >=3:1. Increased Contrast strengthens
text, focus and borders (stroke >=3:1) and removes shadows; selection/focus must remain distinguished
by shape/border as well as color. A fine standard decorative separator is not a sufficient focus ring.
Do not use status color alone to communicate a status.

`public enum ChatTheme` provides `palette(colorScheme:contrast:)`. Existing static `background`,
`sidebar`, `inset`, `separator`, `transcriptWidth` remain available; the four colors dynamically resolve
against their supplied AppKit drawing appearance. New consumers should use the explicit resolved palette.
`WorkspaceLayout` thresholds and `ConnectionPresentation` title/symbol/detail/localization are unchanged.
Public nested token namespaces:

- `Spacing`: `xSmall=4`, `small=8`, `medium=12`, `large=16`, `xLarge=24`, `section=32` (CGFloat).
- `Radii`: `control=6`, `code=8`, `message=16`, `composer=20` (CGFloat).
- `Dimensions`: `readableWidth=760`, `sidebarWidth=248`, `headerHeight=52`, `controlHeight=32`,
  `composerMinHeight=80`, `composerMaxHeight=180`, `promptRailWidth=28`, `popoverWidth=320` (CGFloat).
  Readable width is a maximum; owners adapt padding and auxiliary panes to available width.
- `Shadows`: `composerRadius=16`, `composerY=4`, `popoverRadius=12`, `popoverY=3` (CGFloat),
  paired with the resolved `palette.shadow`, whose opacity is zero in Increased Contrast.
- `Typography`: system `title` 22 semibold, `heading` 17 semibold, `body` 15,
  `secondary` 13, `caption` 11, `code` 13 monospaced (Font); main-actor `editor` (NSFont 15)
  and `nativeCode` (NSFont 13 monospaced). Use system fallback fonts for multilingual glyphs.

Apple documents [preferredColorScheme presentation scope](https://developer.apple.com/documentation/swiftui/view/preferredcolorscheme(_:))
and the [matching-only high-contrast appearance contract](https://developer.apple.com/documentation/appkit/nsappearance/name-swift.struct/accessibilityhighcontrastaqua).

Native tests join the existing serialized `NativeUITests`. They exercise concrete AppKit resolution,
compatibility colors, live override/System changes, and injected accessibility resolution. The
**existing** CompositionTextView retains marked text, selection, focus and draft in one host. A test-only native swatch consumes the
resolved appearance; it does not claim the future production editor/window wiring is implemented.
Any saved PNG is rendered from this synthetic host. User reference images are never copied or used
as test fixtures/artifacts. Tests use fresh disposable defaults and no provider/network/account calls.
