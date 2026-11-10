# Cursor runtime (#8)

`CursorChatBackend` implements `ChatBackend`; `CursorProviderSettingsService` implements
`ProviderSettingsService` for `(.cursor, "cursor")`. Routing, Pi settings, and app wiring
belong to #9. Both initializers throw on inaccessible/corrupt storage. Supply the same
**app-owned** storage root (default: Application Support/DurableChat/Cursor) to both:

```swift
let settings = try CursorProviderSettingsService()
let backend = try CursorChatBackend(settings: settings)
// Settings UI calls update/login/logout; copy its explicit model selection into ChatStore.
try await backend.refreshConnection() // refresh again after authentication/settings changes
```

`CursorProcess.discover(executablePath:searchPath:)` accepts an absolute executable override,
otherwise finds `agent`/`cursor-agent` on PATH and standard install paths. The service probes
`--help`, requires the read-only print/resume protocol, runs `status --format json`, and
reads available choices from `models`. Unsupported versions/formats fail closed. No model
is selected implicitly. `loginInstructions` provides official Terminal instructions;
`login(to:)` launches the official browser flow, and task cancellation or `cancelLogin(to:)`
terminates that invocation. Logout calls the official CLI. Login URLs/output and account
information are not published, logged, or persisted. API-key operations are rejected.
Credentials remain entirely inside Cursor's own CLI store. The process environment keeps
HOME/PATH/locale/temp/XDG location variables, excluding injected API keys/endpoints/tokens.

Every generation uses an argv array, stdin, `--print --mode ask --trust --output-format stream-json
--stream-partial-output --model <explicit-model> --workspace <app-root>/workspace`. It never
uses a shell, `--force`, `--yolo`, added roots, or automatic MCP approval.
The working directory is the app's isolated `workspace` subdirectory, never the source
checkout. Workspace trust is limited to this private app-owned directory so noninteractive CLI startup succeeds. Ask mode remains Cursor's read-only conversational mode; this is a CLI permission
boundary, not an OS sandbox against a malicious executable or user-configured extensions.
Only override the executable with a trusted Cursor installation.

The NDJSON adapter appends only assistant deltas with `timestamp_ms` and no `model_call_id`,
skips duplicate buffered/final flushes, and replaces text from the success result. Missing
terminal result, malformed JSON, error result, unknown framing, timeout, or nonzero exit
fails the turn while retaining partial output. stderr is drained and discarded; UI failures
use fixed messages. Lines are bounded to 2 MiB, prompts/output text to 8 MiB; oversized
responses fail explicitly. stdin is a private, immediately unlinked file, so large prompts
cannot block pipe writing or generate SIGPIPE. Process cancellation kills only its verified
new macOS process group, including ordinary children; escaped sessions are outside that
group. Commands time out after 30 seconds, login after 5 minutes, generation after 10 minutes.

Conversation IDs use `cursor:conversation:` and assistant IDs `cursor:assistant:`; user IDs
are the client's durable idempotency keys. Reusing an accepted ID with identical conversation,
text, and model is a no-op, including after reopen; conflicting reuse is rejected. Acceptance
is atomically persisted and published with a busy state before `send` returns. Subscribers
get an atomic full initial snapshot, and canceling one only removes that observer. Stopping during credential/model preflight cancels the pending CLI checks and prevents a delayed generation from starting. Stop
preserves the assistant ID/text as stopped, makes the target idle, and leaves selection alone.
Dropping the backend cancels its active processes.

`conversations.json` stores ordered transcripts, selection, accepted request/model mappings,
and CLI session IDs; `preferences.json` stores only nonsecret provider preferences. Files
use atomic replacement and POSIX 0600, without macOS-incompatible Data Protection options; a nonblocking exclusive lock prevents two backends
writing the same archive. Conversation text can itself be sensitive: these are local
transcripts, not an encrypted credential vault. Do not put a repository or shared directory
in place of the app storage root. Successful sessions continue with `--resume <id>`; interrupted,
stopped, or failed sessions are cleared and subsequent input includes the complete local
history as JSON. A reopened busy turn becomes stopped/idle with the same IDs. Expired native
sessions fail visibly; no automatic paid retry is attempted. Reusing an accepted ID after a
failed/stopped turn does not regenerate it; a new user submission needs a new ID.

Verified 2026-11-10 with installed `agent`/`cursor-agent` version `2026.11.05-86047df`:
`--help`, login/status/models help, sanitized JSON status schema, and model-list format.
No real print/model request, login, logout, token inspection, or credential extraction was
performed. Subscription entitlement, billing limits, actual model streaming, and real browser
login remain provider-side behavior, not fixture-proven integration claims.

Official references: [headless](https://cursor.com/docs/cli/headless),
[authentication](https://cursor.com/docs/cli/reference/authentication),
[output format](https://cursor.com/docs/cli/reference/output-format),
[parameters](https://cursor.com/docs/cli/reference/parameters).
Fixtures in `Tests/AgentRuntimeTests/CursorTests.swift` launch actual local executables and
cover argv/stdin, framing/errors, child cancellation/timeout, reopen/recovery/idempotency,
concurrent acceptance, and subscriber lifecycle without contacting a model.
