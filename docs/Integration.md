# Application integration (#9, #21)

## Composition and lifecycle API

`AppSession` (main actor, Observable) owns one `ChatStore`, `TranscriptNavigation`, composite settings
service and `ChatBackendRouter`. `start()` opens storage and subscribes once. `NativeWorkspaceView`
uses `ChatWorkspaceView` with `ComposerView(store:)` and `ConversationMinimap(store:navigation:)`;
`NativeSettingsView` injects the shared service and applies only explicit selection callbacks.
`AppDelegate.applicationShouldTerminate` returns terminateLater, awaits `AppSession.shutdown()`, and replies.
Startup is owned/cancellable too, including a quit during initial status discovery.

`ChatBackendRouter.open(pi:cursor:codex:preferencesURL:)` observes each backend's `events()` atomic initial
snapshot and ordered updates. It does not observe with snapshot-then-events. Its own subscribers receive
one atomic initial combined snapshot; every subsequent snapshot combines list, loaded cache, selection,
connection and `ChatModelContext`. Child selection is ignored after subscription; commands serialize
create/select/model changes. Creation waits for its authoritative event. Pi ordering precedes Cursor, then Codex ordering,
and each backend's list order is preserved. IDs are unchanged, with `pi:conversation:`, `cursor:conversation:` and `codex:conversation:`
namespaces. Per-backend stream failures disable only that selected route and preserve all cached history.

`useModel(_:)` applies/persists the explicit choice and clears incompatible selection. No default model is
chosen. `updateProviderStatuses(_:)` changes availability only. New conversations bind to the captured
explicit account; send validates conversation/account route independently of current UI selection.
API key versus ChatGPT OAuth remains distinct even though both use Pi. Codex CLI uses exactly
`(.codexCLI, "codex-cli")`, separately from Pi `(.chatGPT, "openai-codex")` and Cursor. Old Pi/Codex histories without binding
metadata remain browsable/read-only. The router never guesses their account or rewrites their history.
Preferences are atomic, nonsecret JSON (0600). A corrupt routing file fails visibly without resetting it.

`ChatSnapshot.modelContext` is optional for existing standalone backends. When provided, ChatStore applies
its model and notice in the same main-actor turn as selection/cache/connection. This avoids an asynchronous
view onChange briefly displaying another route's model. Nil context preserves the pre-integration store API.
`ChatStore.stop(conversationID:)` lets UI tasks capture the origin before a Task hop; existing `stop()` remains.
Pi checks task cancellation after credential preflight and immediately before admission so a queued stop
cannot silently become a delayed provider call. The router owns cancellable preflight send tasks; Stop
cancels the origin and calls that backend's Stop, even if workspace selection already changed.

`CompositeProviderSettingsService` routes exact accounts to Pi/Cursor/Codex; snapshot updates router availability,
never the chosen model. It tracks/cancels pending CLI probes and auth/control operations in `shutdown()`.
The settings view refreshes discovered models and has explicit Use selected model, key save/remove,
ChatGPT OAuth, Cursor path/login/cancel/logout controls. Codex has its own executable override,
existing ChatGPT login detection, explicit login/catalog refresh, and instructions for user-run `codex login`
/ `codex logout` in Terminal. It has no app login/logout/key controls. API-key CLI authentication is
unsupported; quota/remaining usage and real model entitlement are unknown. No credentials are extracted. Dismissal cancels view-owned login/control tasks.

Router `shutdown()` cancels observation and pending admissions, stops every known origin (including inactive
conversations), awaits pending send completion, calls `PiChatBackend.close()`, finishes subscribers and drops
all backend owners. It also awaits `CodexChatBackend.shutdown()` to terminate every owned process
and release its lock while references remain alive; concurrent shutdown callers await the same boundary. Cursor's own deinit/process-group cancellation remains a second cleanup boundary.
Settings shutdown also cancels CLI control invocations and calls `CodexProviderSettingsService.shutdown()`; there is no invented Cursor close API.

## Issue #21 verification (2026-11-10)

The #19 Codex adapter/process/settings implementation is reused without protocol or credential changes.
The app composes its third backend under `Application Support/DurableChat/Codex`. Construction starts no
process; app/settings availability refresh uses account/read with refreshToken:false and model/list.
No default model or inferred account is introduced. Existing routing.json stays version 1 with identical
keys and existing Pi/Cursor archives are untouched. Opening or refreshing does not rewrite routing.json.
Codex history without a recorded account remains read-only. Explicit model choices survive refresh and
reopen, including an unavailable choice; availability never chooses another model.

AppSession retains partial-startup owners until cleanup. Startup failure, quit during opening, and normal
shutdown await Codex backend/settings cleanup. Existing Pi SQLite close and Cursor origin Stop remain.
Fixture mode pins every Codex probe/preflight/generation to an app-generated Python executable before
any snapshot. It does not discover an installed Codex, read personal account state, invoke login/logout,
or contact a model/network. The existing simulated Pi scratch selection is fixture data; Codex begins
without a selected model. Its mock response streams until Stop; `fixture-complete` completes locally.

Scope-required ancillary changes: CodexProviderSettingsService accepts an optional isolatedExecutable
constraint, used only by fixture mode, so saving another path or clearing it cannot invoke a personal CLI.
The obsolete #19 assertion expecting an unsupported router account now expects the connected Codex route.
The test-only internal AppSession isolatedDirectory injection permits
reopening a copied temporary workspace (not exposed in launch arguments); fixture preparation preserves
existing sample archives. NativeWorkspaceView displays the active Codex route and unknown-limit notice.
ChatUI source/resource tables and language wiring (#22/#23) are untouched. Existing serialized NativeUITests
and serialized app hosting remain intact; no new independent native host suite is introduced.

Automated evidence:

- Router/composite tests cover all three backend selections/sends, four distinct accounts (including Pi
  OAuth), wrong-account/model rejection, late origin events, selected-route availability, legacy v1
  preservation, explicit model restore, and origin Stop during preflight after switching providers.
- The real #19 executable fixture is exercised through router/composite: API-key rejection, no global
  login/logout, cancellable control probes, Stop, concurrent router shutdown, process exit, and lock
  reacquisition while the old router/backend references still exist.
- NativeAppTests adds actual NSHostingView settings/composer/send/Stop, Codex-to-Cursor switch, late-event
  rejection, copied temporary-history reopen with stable messages/model/thread resume, 400 pt rendering,
  startup failure with zero Codex probes and lock release, and early settings-probe cancellation.
  Existing Pi/Cursor composition, marked-text, minimap, light/dark and demo regressions remain required.
- All checks use fixtures and temporary storage. Real Codex CLI account authentication, entitlement,
  quota, streaming and official-thread continuation remain unverified. Synthetic AppKit Return/IME
  tests do not establish physical input-method/candidate-window behavior.

Local CLT verification: all **120 tests passed** (ChatUI 34, ChatCore 14, AppLocalization 11,
app integration 7, AgentRuntime 54). `scripts/build-app.sh` produced the release app and
`codesign --verify --deep --strict dist/DurableChat.app` passed. Existing CLT linker search-path
warnings are nonfatal. Full-suite/package logs and hosting PNGs are under ignored `dist/qa/`.

Packaged native GUI QA uses only `--test-runtime`. CUA observed the separate Codex account, executable
path, detected existing mock login, user-run login/logout instructions, unknown-limit notice, and
initially unselected model with Use disabled. It refreshed the mock login/catalog, explicitly chose
SIMULATED Codex CLI and Use selected model, created a conversation, typed/sent a message, observed
SIMULATED Codex streaming, clicked Stop and observed Response stopped. Switching to the seeded Cursor
history disabled sending without inferring a model; returning to Codex restored its explicit model and
stopped text. Reopening Settings retained the chosen model, and Command-Q completed async shutdown.
CUA's initial inventory timed out; some popup attempts were rejected as changed/offscreen state.
After refreshing the state and bringing the picker into the visible scroll area, selection succeeded.
Temporary diagnostic prints confirmed the view action and were removed from the final release package.
The final release package was then exercised again for refresh, explicit selection, send/Stop, settings
reopen and normal quit; its temporary root was removed and its deep/strict signature remained valid.
No production login/account/model call was used for this QA. Durable process-reopen proof is supplied
by native hosting with a copied temporary archive; the normal interactive fixture intentionally deletes
its temporary workspace on quit.

CI and independent Cursor review remain separate parent-owned gates. No merge or watch is performed here.

## Historical issue #9 verification record (2026-11-10)

All QA uses fixtures and temp storage, without personal credentials, sign-in, or paid calls.
The pinned upstream revision and `scripts/build-app.sh --build-system swiftbuild` choice are preserved.

- Local compiler/SDK: CLT Swift 6.4.2, macOS 27.2 SDK, deployment macOS 14.
- Automated native hosting: `NativeAppTests` hosts the actual complete app root and settings in NSHostingView,
  finds the real AppKit composer, sends a synthetic Return to it, observes Faux streaming, switches to full
  Cursor history, stops the Pi origin, jumps through the live transcript navigation, and checks viewport IDs.
  It applies a Cursor model, opens/closes settings without losing the active model, sends/stops the actual
  local CLI fixture, restores Pi selection, shuts down and verifies temp storage removal. Desktop/400 pt,
  light/dark, demo and quit-during-opening are included. PNGs use `CHAT_UI_ARTIFACTS_DIR`.
- Router tests use injected backends to exercise atomic combined initial snapshots without snapshot reads,
  both backend/account mismatch rejection, selected-route connection state, late snapshots/failures,
  persisted choices/bindings, correct creation route, no implicit model and preflight cancellation after switch.
- AppKit synthetic IME tests: existing native marked-text/confirmation Enter and newline tests run unchanged.
  They do not prove real input-source/candidate-window/hardware behavior.
- Real-account verification: not performed. No production key access, secure OAuth completion, Cursor login,
  logout, paid/model request, account entitlement or actual-provider streaming is certified by fixture tests.
- Local build/test/package: all 88 tests passed (ChatUI 34, ChatCore 14, app integration 4, runtime 36).
  `scripts/build-app.sh` produced `dist/DurableChat.app` and codesign deep/strict verification passed.
  Logs and native hosting PNGs are under ignored `dist/qa/` in the implementation worktree.
- Actual packaged native GUI: launched with `open -n dist/DurableChat.app --args --test-runtime`.
  CUA observed the isolated-mode banner and connected faux-1 selection, typed and sent a local message,
  observed SIMULATED Pi streaming, clicked Stop and observed Response stopped. It opened Settings,
  browsed Cursor (path/login/logout/discovered model controls visible), closed Settings and verified faux-1
  remained active. It created a Pi conversation, switched to the 48-message Cursor history with no implicit
  model, opened the minimap, used All messages / Message number 1 / Go, and observed Message 1 of 48 and
  Viewing 1–2 of 48. This is running-app GUI evidence, separate from off-screen native hosting PNGs.
  A direct click/Home attempt did not establish minimap keyboard focus; the exact-number navigation path
  was then verified. Physical keyboard minimap focus/IME timing remains for independent GUI QA.
- The actual app is left running in isolated test mode for parent CUA QA. Normal production credential
  startup has not been interactively exercised, to avoid reading personal credentials for QA.
  Parent owns final independent CUA QA, cross-model review and CI waiting. No review or merge was run here.
  PR checks are reported from one exact-head query at handoff; local tests do not certify remote CI.

## Reproduce safe interactive QA

Package, then `open -n dist/DurableChat.app --args --test-runtime`. Check the simulated-mode banner.
Send in the Pi scratch conversation, stop it, create/switch conversations, and browse the seeded Cursor
history. The Minimap can jump to every message and outlines the current viewport. In Settings, browse
Cursor, select simulated-cursor and Use selected model. Switching providers clears incompatible selection;
create a compatible conversation. Test send/stop there. Close/open Settings and verify the active choice
persists. Command-Q exercises async shutdown and deletes this run's temp data. Use `--demo` separately to
check the read-only mode. For Codex, choose Codex CLI · codex-cli in Settings, scroll to the model picker,
choose SIMULATED Codex CLI (no AI), click Use selected model, create a conversation and send/Stop.
Refresh, close/reopen Settings, and switch away/back to its history to verify the explicit choice.
Codex login/logout is instructions-only, and fixture mode rejects clearing/changing its executable to
another CLI. Do not enter a real API key or attempt real account sign-in for this QA.
