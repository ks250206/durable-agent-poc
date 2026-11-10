# Pi runtime and native settings (#7)

This component uses the actual Swift API of PiDurableKit at
`4e1120bbdc7c5329a2f3c05a22bec4b9c9a076bb`. It does not change ChatCore, ChatUI,
the app entrypoint, or the Cursor backend. #9 owns the composite router and app wiring.

## Public component API and injection

```swift
import AgentRuntime
import ChatCore

// Explicit production startup; this is the point at which Keychain may be accessed.
let settings = try PiProviderSettingsService.open() // @MainActor
let backend = try await PiChatBackend.open(settings: settings)
let store = ChatStore(backend: backend)             // @MainActor

// In the app's Settings scene (#9), not in ChatUI:
ProviderSettingsView(service: settings, initialAccount: store.modelSelection?.account) {
    store.modelSelection = $0
}
```

`PiProviderSettingsService` conforms to `ProviderSettingsService` and implements
`snapshot`, `update`, `setAPIKey`, `login`, `cancelLogin`, and `logout`.
`PiChatBackend` conforms to `ChatBackend` and adds `open(settings:databaseURL:)`,
`applicationSupportDirectory()`, and explicit async `close()`.
`ProviderSettingsView(service:initialAccount:onSelection:)` is in AgentRuntime,
which imports SwiftUI; ChatUI does not depend on AgentRuntime.

No provider or model is chosen implicitly. The settings view starts with the supplied
account (or an explicit “Choose a provider” item), persists each provider's selected
model with `update`, and calls `onSelection` with a configured, catalog-valid selection,
or nil only via the explicit Disable sending action. Status refresh does not invoke the selection callback. The caller owns the active account across settings-window lifetimes. Browsing another account does not change it; the explicit Use selected model button applies the choice.
For a headless integration, read `snapshot()`, choose a `ProviderStatus`, persist
`ProviderConfiguration(account:selectedModelID:)`, and copy its explicit `ModelSelection`
into `ChatStore.modelSelection`. Setting a model does not authenticate or send anything.
The concrete backend observes credential changes and updates its connection events.
The shared settings protocol intentionally has no event API; other callers refresh its
snapshot after operations. Cursor account composition is deferred to #9.

## Storage and lifecycle

Production defaults:

- `~/Library/Application Support/DurableChat/conversations.sqlite` (Pi SQLite/WAL).
- `~/Library/Application Support/DurableChat/providers.json` (nonsecret preferences).
- `Models(credentials: .keychain, catalog: nil)` for provider credentials. Production
  uses a dedicated Runtime with console logging discarded. No catalog HTTP refresh runs.

Keep one backend owner per database URL. Await `close()` before reopening the file;
releasing a Swift reference is not a shutdown operation. Credential/model lookup failures are isolated to the provider status; they do not prevent saved history from opening.
Close stops observations,
aborts each conversation, preserves committed partial output as stopped, finishes event
subscribers, and closes the harness/storage. It is idempotent. An abort/read failure
still attempts harness close and reports a sanitized error.

Open uses `Harness.open(..., resume: false)`, restores **all** conversation pages and
**all** history pages, and aborts interrupted runs/inbox inputs before exposing the
backend. It never calls `resume()` automatically. A new explicit authenticated send
starts Pi's scheduler. This deliberately stops interrupted work, rather than issuing
an unprompted provider request after a restart. Previously committed partials and all
completed messages survive. Graceful close and interrupted-harness reopen are tested.

Conversation IDs are `pi:conversation:<durable ID>`. User IDs are the exact client
`SendRequest.messageID`. Pi's conversation-scoped `requestId` supplies durable
idempotency. A candidate user input is recorded in an app document before submit;
it is restored only when Pi has the matching committed submission. Thus a crash before
admission cannot invent an accepted message, and aborting an accepted inbox input does
not erase it. Its text/date also survive retries; reusing an accepted ID with different text is rejected. Reusing a key acknowledges its original
submission and never queues a second generation; keys must identify the same submission.

Assistant IDs are `pi:reply:<client user ID>:<reply ordinal>`, shared between committed
partials and settled entries; other entry submessages use `pi:entry:<entry ID>:<ordinal>`.
Pi's immutable entries remain authoritative. Snapshots retain full history across resets;
there is no 50/100-entry or conversation truncation. Every event replaces the entire
conversation transcript. Mutations are serialized across async Pi calls. Each subscriber
is registered and receives its initial cached snapshot in one actor turn. Successful
send publishes the accepted user message plus busy state before returning, then runtime
observations publish streaming and completion. Stopping uses the requested conversation
handle, independently of selection. Canceling a subscriber does not abort generation.

## Authentication and safe configuration

The service discovers providers and model catalogs using `Models.providers/models`.
It checks `Models.isConfigured` plus credential kind, never substitutes a cached boolean.
OpenAI API is `(.apiKey, "openai")`; ChatGPT subscription OAuth is
`(.chatGPT, "openai-codex")`. Other API-key-capable Pi providers are discovered too.
Unsupported route/provider combinations and Cursor are rejected. No execution environment,
extensions, shell tools, or file tools are granted to the agent.

`setAPIKey(nil, for:)` removes a key. `login` calls
`Models.login(to: "openai-codex", interaction: .webAuthenticationSession())` through the
injected interaction factory. Subscription authentication requires real user interaction
in the secure browser session. The view owns the login Task; dismissal, task cancellation,
and `cancelLogin` cancel Pi's operation and dismiss authentication. Logout waits for login
cancellation before removing that route's credential, without holding the settings operation lock. New sign-ins remain blocked until logout finishes. API-key and subscription slots
remain separate. Nonsecret selected models persist after logout. The composite router disables sending from provider status while retaining the explicit active preference; browsing or refreshing settings does not invoke the selection callback. Raw keys/tokens, OAuth URLs/codes, and upstream error detail
never enter settings/chat snapshots, app preferences, or app logging callbacks. UI errors
are fixed sanitized messages; the provider's actual errorMessage is not rendered.

## Validation and toolchain

Tests inject `Models(credentials: InMemoryCredentialStore(), catalog: nil, runtime: ...)`,
register an actual `FauxProvider`, use temporary SQLite files, and deny runtime HTTP with a
URLProtocol (and assert that no HTTP request was attempted). This exercises Pi's JavaScriptCore scheduler/storage/streaming rather than
mocking the core. Settings tests use synthetic in-memory credentials; OAuth cancellation
uses Pi's actual `Models.login` with a local custom OAuth definition and an injected
interaction that never opens a browser or exchanges tokens, plus an explicit installation
UUID so test login never accesses production installation preferences. Production Keychain and
ASWebAuthenticationSession are compiled but never invoked in tests.

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
PATH=/Library/Developer/CommandLineTools/usr/bin:$PATH \
swift test -Xswiftc -plugin-path \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

Pinned upstream requires the Swift 6.4.2 / macOS 27.2 SDK pair (deployment target macOS 14).
The view uses the same explicit State property-wrapper alias as the foundation app for
SDKs that also expose a State macro unavailable in Command Line Tools. Local tests do not
verify paid provider calls, actual user OAuth completion, production Keychain entitlements,
or native settings-window interaction. App/router integration is #9; Cursor is #8.
