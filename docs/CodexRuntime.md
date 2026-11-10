# Codex CLI runtime (#19)

This standalone AgentRuntime adapter reuses **the existing official Codex CLI ChatGPT login**.
It is a separate route from PiDurableKit ChatGPT OAuth. Application/router/settings-view composition is now connected by #21; see [Integration.md](Integration.md).
The adapter remains independently usable through the handoff below.
The runtime target and pinned dependencies remain unchanged. #24 adds a separate localization-audit
executable and final integration checks; see [the current QA matrix](Integration.md).

## Public handoff for #21

```swift
import AgentRuntime
import ChatCore

let root = CodexProcess.defaultStorageDirectory // Application Support/DurableChat/Codex
let settings = try CodexProviderSettingsService(storageDirectory: root, requestTimeout: 20)
let backend = try CodexChatBackend(
    storageDirectory: root, settings: settings, requestTimeout: 20, turnTimeout: 600
)
// No process or credential read happens in these constructors.
let statuses = try await settings.snapshot() // explicit account/catalog refresh
try await backend.refreshConnection()       // publish refreshed standalone connection state
// Consume backend.events() for its atomic initial snapshot and ordered changes.
// Route commands with captured conversation/model, never the current UI selection.

// At application shutdown, including inactive conversations and pending preflight:
await backend.shutdown()
await settings.shutdown()
```

- `ProviderOption.codexCLI` displays as `Codex CLI`.
- `CodexProviderSettingsService.account` is exactly `(.codexCLI, "codex-cli")`.
- Conversation IDs use `codex:conversation:`; accepted client user-message IDs are preserved verbatim.
- `CodexProcess.discover(executablePath:searchPath:) -> URL` accepts an absolute executable override
  or discovers `codex` on absolute PATH entries and common install locations. A configured executable
  is trusted code; paths are not passed to a shell.
- `CodexProviderSettingsService` implements the existing `ProviderSettingsService` protocol.
  `update(_:)` persists only `ProviderConfiguration` (account, selected model, optional executable path).
  `snapshot()` re-reads auth and the complete paged model catalog without selecting a model.
  `loginInstructions` tells the user to operate `codex login` / `codex logout` in Terminal themselves,
  then refresh. `login`, `logout`, and `setAPIKey` throw safe unsupported/instruction errors;
  `cancelLogin` is a no-op because this service never starts login. They never mutate the CLI session.
  `shutdown()` cancels and awaits active probes. Do not invoke a real probe merely for QA.
  #21 adds an optional `isolatedExecutable` constructor constraint used by the app fixture: it pins discovery
  and rejects changing/clearing the executable path, without starting a process. Normal callers omit it.
- `CodexChatBackend` implements every `ChatBackend` method. `refreshConnection()` is an explicit
  status refresh, useful after a settings change. Constructors and local history browsing work offline.
  `shutdown()` is required: it cancels pending admissions, interrupts known turns, kills/awaits owned
  processes/readers/writers, finishes subscribers, and releases the storage lock while the object lives.
  Repeated/concurrent backend shutdown calls await the same cleanup boundary.
- The lower-level `CodexProcess(executable:workingDirectory:requestTimeout:)` owns one stdio connection;
  `shutdown()` is public. JSON-RPC and notification methods are internal implementation details.

Use an **app-owned** storage root, not a source checkout or the CLI's state directory. The root contains
private `control/` and `workspace/` directories, preferences, conversations, and `runtime.lock`.
The backend enforces exclusive ownership with flock. Explicit shutdown unlocks before closing its descriptor, so a duplicate temporarily inherited during another process launch cannot retain ownership after shutdown. Constructors fail on corrupt/foreign archives;
they never silently reset history. Files are replaced via a new 0600 temporary file, fsync, then rename;
directories are 0700. Reads and writes share a 128 MiB encoded-file limit. Oversized updates fail before
creating/replacing any file; the prior readable archive remains intact. No history is silently truncated. Direct symlink storage files/roots are rejected. CLI authentication never enters
these files; user/assistant conversation text is intentionally persisted, without truncating history.

## Wire protocol and ownership

The source of truth is [official Codex App Server documentation](https://learn.chatgpt.com/docs/app-server)
and schemas generated offline with installed **codex-cli 0.167.0**:

```sh
codex app-server generate-json-schema --out /tmp/durable-chat-issue19-schema
```

This schema operation requires no account/login/model invocation. Tests embed the generated schema
constraints in `CodexSchemaFixtures.swift`, removing descriptive/default/format annotations and
sharing identical definitions. The fixture validates outgoing requests and representative responses
and notifications; production decoding consumes required fields while allowing additive fields.
The adapter uses stable API capabilities (`experimentalApi: false`), never experimental token injection.

Each connection starts with `initialize` / `initialized`. A settings probe calls
`account/read` with **`refreshToken: false`**. Only `account.type == "chatgpt"` is configured;
API-key auth is distinctly unsupported, null is signed out, and other/future kinds are unsupported.
Neither email nor raw account payload is persisted or exposed. No paid-plan allowlist is used:
free/future plans, actual model access, entitlements, and rate/usage limits remain provider-controlled.
Configured accounts enumerate `model/list` until `nextCursor` is null, preserving provider order and
deduplicating model identifiers. Repeated cursors, oversized catalogs, or invalid pages fail the entire
probe visibly instead of returning a partial catalog.

Send first performs cancellable account/model preflight. Acceptance atomically persists the user
message with its client ID, model/idempotency record, and busy state, publishes that event, installs the
owned generation task, then returns. Retrying an accepted ID is a no-op only when conversation, original
text, and model all match. Conflicting reuse is rejected, including concurrent cross-conversation sends.
Canceling preflight or stopping that origin prevents later admission and provider turn creation.

A generation owns a separate app-server connection. It checks ChatGPT auth again, starts or resumes
its saved official thread ID, persists the ID **before** `turn/start`, then submits the original text with
`clientUserMessageId`. Every thread/start/resume sets the app workspace, OpenAI provider,
`approvalPolicy: never`, `approvalsReviewer: user`, and `sandbox: read-only`. The returned effective
policy/workspace/provider must agree. Every turn/start additionally sets
`sandboxPolicy: {type: readOnly, networkAccess: false}`. CLI launch also overrides sandbox/approval/provider
config. The child receives only HOME/USER/LOGNAME/PATH/TMPDIR/LANG/LC_ALL; inherited API keys,
CODEX_* overrides, and loader/injection variables are excluded. Credentials and official session files
remain CLI-owned. The sandbox is the CLI's sandbox, not an independent macOS application sandbox.

Notifications may precede the turn/start response; a bounded queue retains wire order until the turn ID
is known. Only matching thread/turn events apply. Agent-message item IDs map to stable local IDs;
item completion replaces incremental text, duplicate completions are idempotent, post-completion deltas
are ignored, and the final turn reconciles authoritative item text/order. Identical deltas cannot be
recognized as retransmissions without protocol sequence IDs: they append during streaming and final
item text corrects them. Every assistant text item is retained. This is a text-chat adapter; reasoning,
command/tool progress and nontext outputs are not transcript messages. Server-initiated approval,
dynamic tool, user-input, token-refresh and future requests always receive JSON-RPC `-32601`:
no tools or permissions are autoapproved.

Stop targets its captured conversation, invalidates late events, preserves partial text as stopped,
issues `turn/interrupt` only when both IDs are known, and awaits process-group cleanup before returning.
New admission for that origin remains busy during cleanup. Before a turn ID exists, cancellation kills
the owned connection. Subscriber cancellation releases observation only. Shutdown retains stopped
partial output. Interrupted archives recover streaming messages as stopped/idle while keeping thread IDs;
accepted submissions are never automatically replayed. Reopen continues the saved thread, retaining the
complete local text history and IDs. If the official CLI thread is missing/incompatible, continuation
fails visibly; the adapter never silently starts a different thread or resubmits history.

RPC deadlines default to 20 seconds, generation lifetime to 600 seconds, and interrupt waits to at most
2 seconds. Normal completion, interruption, timeout, malformed JSON, process exit and explicit shutdown
kill only the newly launched, verified process group (including descendants that stay in that group).
stdout frames are limited to 2 MiB, connection output to 32 MiB, queued notifications to 512, stderr to
8 MiB, and an assistant item to 8 MiB. Overflow fails visibly. stderr and server error text are discarded;
UI failures use fixed safe messages. Caller-provided conversation text is naturally user-visible.

## Verification boundary

`CodexRuntimeTests` creates its own executable Python JSON-RPC server, generated-schema fixtures,
auth-state sentinel and temporary storage. It tests auth kinds, paging, handshake sequencing, actual
process launch, early/duplicate/out-of-order/foreign events, durable acceptance, idempotency conflicts,
stable IDs and full history reopen, interruption, preflight/caller cancellation, late-event rejection,
server request denial, environment filtering, exclusive locks, permissions, malformed/oversized output,
timeouts (including a blocked stdin writer), parent exit with a live child, cleanup, and shutdown while the old object remains alive.

Run with the repository's CLT toolchain:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
PATH=/Library/Developer/CommandLineTools/usr/bin:$PATH \
swift test -Xswiftc -plugin-path \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

No personal account read, real app-server login/logout/model/catalog/turn request, OAuth token extraction,
or production credential access is used for tests. Live CLI account entitlement and real model streaming
are not certified by executable fixtures; #21 native UI/router verification is recorded separately in
Integration.md. Existing Pi/Cursor contracts and routes remain independently exercised by their existing test suites.

CI harness note: native AppKit host suites share a serialized parent because focus/key-window state
is process-global. Their bounded waits service the event loop. Fixture RPC budgets are 5 seconds
(production defaults remain 20); explicit hung-process/blocked-stdin/turn-deadline assertions remain.

Historical #19 CLT verification snapshot (not the current aggregate total): all **101 tests passed** (ChatUI 34, ChatCore 14, app integration 4,
runtime 48 including 12 Codex executable-fixture tests). Existing CLT linker search-path warnings
are nonfatal. CI and independent Cursor Agent review are separate parent-owned gates.
