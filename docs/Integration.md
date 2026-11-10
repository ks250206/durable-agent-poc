# Application integration and final QA (#24)

## Final #24 verification and parent handoff (2026-11-10)

Local final result: **139 Swift tests passed** (ChatUI 42, ChatCore 14, AppLocalization 11,
AppIntegration 17, AgentRuntime 55), plus **2 Python audit tests**. CLT Swift 6.4.2 / SDK 27.2.
Existing CLT missing Developer library/framework search-path warnings and AX compatibility API
deprecations remain nonfatal.

The final integration adds the source/resource audit, CI gates and aggregate tests. It reuses the
#19–#23 runtime/localization implementations without changing backend behavior or translating data.
The manifest strictly accounts for Common 10 / ChatUI 104 / Runtime 108 / App 13 keys in each locale,
plus all string sites in 42 Swift source files. Table/language iteration derives from the owning enums;
future UI resources can extend those contracts and the audited manifest together. There is no fixed
key-count or four-table ceiling. Unregistered resource tables/locales and source strings still fail.

| Surface | Current local evidence | Limits |
| --- | --- | --- |
| Translation inventory/format | Source audit; exact key sets, empty/malformed/mismatched templates, missing/extra keys, actual Foundation lookup in every source and packaged table; mutation and manifest-growth tests | Coverage/parity does not prove linguistic quality; source inventory is an audited string-site boundary, not general Swift data-flow analysis |
| Workspace/settings/providers/errors/AX/minimap | Complete native NSHostingView suites rerun in en/ja/zh-Hans/ko at 400/1200 pt, light/dark; fresh PNGs and AX assertions | Native hosting is distinct from the running packaged app and VoiceOver |
| Language/editor lifecycle | Immediate change, injected defaults reopen/invalid fallback/System reset and activation/locale notifications; real composer marked text, selection, focus, draft, navigation and owners preserved during actual fixture streaming | Marked text is synthetic AppKit, not a physical Japanese IME/candidate-window pass |
| Final four-language aggregate | Codex fixture account → explicit model → send; switch to Cursor's 48-message history; localized minimap Page Up and preserved focus/target; Stop captured Codex origin; reject late text; copied archive reopens language/model/messages; owned processes/temp roots removed | Copied temporary archive proves process/session reopen without personal settings; interactive fixture intentionally deletes storage/preferences at Quit |
| Actual packaged GUI via CUA | English/Japanese/Chinese/Korean settings/workspace/AX, mock Codex login/help/quota and explicit model selection; send/stream; Japanese then Chinese then System-English while busy; exact Unicode draft retained; Stop; Cursor account isolation; minimap exact message 8 of 48; reopen stopped Codex history and Settings with model retained | Desktop/system-dark CUA run; exact 400/1200 and both appearances are native-host evidence, not a claimed packaged GUI matrix |
| Existing packaged settings error | Rejected a nonfixture executable path without launching it; open error retranslated in all four languages, active Codex route retained | Fixture-safe rejection only; no real CLI/authentication failure was requested |
| App-owned commands | CUA observed live Settings/Quit labels in Japanese, Chinese and Korean; Reset to System restored English workspace; localized Quit completed cleanup | Stock macOS/SwiftUI commands follow OS locale; the stock English Settings entry was also visible beside the custom localized command |
| Build/distribution | Release app, all actual packaged table lookups, strict/deep ad-hoc codesign; signature/resource checks repeated after zip extraction | No Developer ID, notarization, hardened-runtime distribution or production entitlement certification |
| CI/independent review/merge | Workflow retains SHA pins, read-only permissions, Xcode/SDK 27.2 and all native tests; source, package and extracted-archive audits are required | Remote checks, independent review and merge are parent-owned, not certified by local results |

The CUA model-popup attempt initially hit “The user changed … Re-query the latest state …”.
Fresh full snapshots, visible scroll position and normal UI retries eventually selected the model;
no stale guard was bypassed. The language popup also needed a fresh snapshot once. Some clicks
returned AXError.failure while their action completed; the following full snapshot, not the error
or attempted click, established the result. A standalone screenshot call was unavailable; combined
AX/screenshot observations worked. These are recorded as tooling events, not application passes.
The final packaged temporary root was removed by normal localized Quit and all nine recorded fixture
process PIDs were absent afterward. The three added integration tests cover resource mutations,
strict manifest growth, and the four-language native Codex/history/minimap aggregate.

Real accounts, credential/token reads, installed CLI account/catalog/model requests, provider network
calls and paid generation were not used. Physical Japanese IME/candidate windows, VoiceOver operation,
live authentication/account entitlement and distribution signing remain **unverified**.

Reproduce from this checkout (and rebuild again in the parent's checkout from merged main):

```sh
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
export PATH="$DEVELOPER_DIR/usr/bin:$PATH"
mkdir -p dist/qa/issue-24
scripts/validate-localization.sh
swift build --build-system swiftbuild
CHAT_UI_ARTIFACTS_DIR="$PWD/dist/qa/issue-24/native" \
swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
scripts/build-app.sh
scripts/validate-localization.sh dist/DurableChat.app
codesign --verify --deep --strict dist/DurableChat.app
ditto -c -k --sequesterRsrc --keepParent dist/DurableChat.app dist/DurableChat-macOS.zip
archive_root="$(mktemp -d "$TMPDIR/DurableChat-archive.XXXXXX")"
ditto -x -k dist/DurableChat-macOS.zip "$archive_root"
codesign --verify --deep --strict "$archive_root/DurableChat.app"
scripts/validate-localization.sh "$archive_root/DurableChat.app"
rm -r "$archive_root"
open -n dist/DurableChat.app --args --test-runtime
```

Interactive sequence: choose each language and reopen Settings; browse the Codex account, scroll to
Model, explicitly choose SIMULATED Codex CLI (no AI), Use selected model, create a conversation,
send/Stop and switch history. Paste a disposable Unicode draft to verify retention while streaming
and switching languages. Use All messages → number → Go in Cursor history. Test invalid fixture
path save for the nonsecret settings error; refresh restores the pinned fixture configuration.
Quit normally and verify the exact temporary root/processes recorded during the run are gone.
Do not use production preferences or accounts to expand QA coverage.

Ignored local handoff artifacts: `dist/DurableChat.app`, `dist/DurableChat-macOS.zip`,
`dist/qa/issue-24/` (command logs, fresh native PNGs, fixture-only process/call evidence and GUI notes).
PNG names beginning `issue23-` are rerun by the final suite; they are **fresh #24 run evidence** from
reused tests, not copied prior artifacts. Earlier issue records below retain their historical counts
and original QA limits. Do not retain this worktree as a release source: T3 may delete it after merge.

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

## Historical issue #21 verification (2026-11-10)

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
- At the historical #9 handoff, the app was left running in isolated test mode for parent CUA QA. Normal production credential
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

## Issue #33 appearance composition and #38 handoff

`AppSession.appearance` is the one `AppearanceSettings` owner. The session accepts injected
`UserDefaults`; production explicitly selects `.standard`, while demo/test-runtime create one unique
disposable preference suite shared by the independent appearance and language owners. Shutdown
removes only a session-owned suite, including early shutdown/startup failure. A caller injecting a
suite owns its cleanup and can reopen it to test persistence. No OS preference or app-global
appearance is written. The appearance foundation's canonical storage, invalid-value repair and
System key removal remain unchanged.

Window and Settings scenes inject the same owner. `NativeWorkspaceView` and `NativeSettingsView`
apply the app-target `View.appAppearance(session.appearance)` presentation-root seam, including
opening/failure/demo states. It injects the reference, uses public `@ChatAppearance` /
`ResolvedAppearance`, applies `preferredColorScheme` and updates the **existing owning NSWindow**
through a non-interactive native anchor. Explicit choices assign Aqua/Dark Aqua; System assigns nil
to release the window override and follow live AppKit inheritance. No window/store/editor/navigation
identity is keyed by the choice and there is no lifecycle observer or cached System scheme.
Each anchor fills its owning presentation for its lifetime; do not move/remove it while retaining the
same window with a different appearance owner without first releasing that window override.

The Settings root reuses `AppearancePickerView(settings:localizer:)` with the current language
owner's live localizer. Its six existing Appearance-table keys are reused without new labels or
duplicate translations. Language reset and appearance reset operate independently.

For #38: keep this session and both root modifiers when wiring tabs and the prompt rail. Apply
`.appAppearance(session.appearance)` at every **new app-owned sheet/popover root**, using the same
reference. The owner environment wraps the appearance modifier, so the modifier itself resolves explicit
choices from that owner even in a bare hosting root with an opposite ambient color scheme. A newly
created native hosting controller is a presentation boundary too. Within ChatUI,
use the public foundation `@ChatAppearance`, `ResolvedAppearance`, and `ChatTheme` contracts; do not
import the executable target or create another preferences owner. Existing native descendants inherit
their window appearance. Custom production editor text/background/insertion/selection palette and
font adoption still belongs to #35. Window/native appearance inheritance does not certify that future
custom palette work, final tab/rail integration, or physical IME/candidate-window interaction.

API references: [SwiftUI presentation color preference](https://developer.apple.com/documentation/swiftui/view/preferredcolorscheme(_:))
and [AppKit appearance inheritance](https://developer.apple.com/documentation/appkit/nsappearancecustomization/appearance).

Local #33 verification (2026-11-10): **147 tests passed** (48 ChatUI, 14 ChatCore, 11
AppLocalization, 19 app integration, 55 AgentRuntime) using the prescribed CLT/plugin command,
bounded to 300 seconds; the final run completed in 87.9 seconds. The serialized native app suite
checks four locales × 400/1200 pt × all three choices at both roots, overriding an initially opposite
native window appearance. The actual production editor inherits the expected effective appearance;
an actual NSPopover switches in place and releases its override on System. System popovers legitimately
inherit VibrantLight/VibrantDark, so assertions compare their canonical Aqua/Dark Aqua best match.
The existing foundation also exercises injected live System-scheme changes. The real local Codex
fixture test changes language and appearance while streaming and retaining marked text, selection,
first responder, draft, undo manager/availability, store/navigation/conversation/model and canonical
failure; no extra CLI probes occur. Stop still targets the original turn after switching to Cursor.
Persistence/reopen/invalid repair, independent resets, unrelated preference sentinels, normal shutdown,
startup failure and quit-during-opening suite cleanup pass without personal preference domains.

The unchanged release packaging script and deep/strict ad-hoc signature verification pass. Strict
source and source/packaged resource audits pass for all five tables in all four locales, including
the six Appearance keys with exact Foundation lookup. Logs and
48 new app-owned native root PNGs are under ignored `dist/qa/issue-33/`; reference images are not
stored or packaged. Evidence is synthetic native hosting and isolated executable fixtures. Physical
IME/candidate windows, interactive packaged GUI and live OS-wide appearance-setting changes were not
performed for #33. No real login/account/catalog/model/network request is certified. CI and the
parent-owned Claude provider Opus 5.5 Medium review remain separate gates; no review/merge/watch is
started by this implementation.

## Issue #23 language integration and historical verification

AppSession now owns one injectable LocalizationSettings, shared by the scenes, workspace, settings
and commands. NativeSettingsView places the existing System/日本語/English/简体中文/한국어 picker and
Reset to System above provider settings, including opening/failure/demo states. Overrides apply
immediately and persist through the foundation's key; activation/locale notifications refresh only
System. Demo/test-runtime language defaults are isolated suites cleaned at shutdown, so QA never
reads or changes personal language preferences. Provider/account IDs, explicit model-application
callbacks, runtime startup/cleanup, origin Stop and Codex locks are unchanged.

Runtime/App resources translate settings/auth help/status/errors, app badges/startup errors and
app-owned Settings/Quit commands in four languages. Canonical source strings remain English in
runtime/store state; already open errors/notices resolve again on language change. Only exact
app-owned keys and the two RuntimePresentation templates are eligible. External text and all
conversation/model/path data stay verbatim. See Localization.md for the adapter and #24 handoff.

Verification uses the existing serialized NativeAppTests parent and the original separately
serialized ChatUI native suites. It includes four-language settings/provider screens at 400/1200,
light/dark; every authentication-state branch; existing open startup/settings/status failures and
routing notices; unchanged external status text; injected persistence/reopen/fallback/System reset
and lifecycle refresh; and actual isolated Codex streaming plus native marked-text, selection,
focus, draft, store/navigation/model/conversation identity and original busy-error preservation.
The #21 early-exit/startup-failure/shutdown/process/lock and Pi/Cursor regressions still run.
Native hosting is synthetic AppKit evidence, distinct from physical IME interaction or real accounts.
No production credentials, installed CLI account, network or real model request is used.

Local command logs and native PNGs are under ignored `dist/qa/issue-23/`. The release package keeps
all four tables for all four locales in DurableChat_AppLocalization.bundle, using the unchanged
packaging script. #24 retains repository-wide validator/CI and final aggregate QA ownership; the
parent retains Cursor Agent Grok 4.7 High review, remote checks and merge. No delegate/review/watch
is started by this implementation.

Local #23 validation (2026-11-10): **136 tests passed** (ChatUI 42, ChatCore 14,
AppLocalization 11, app integration 14, AgentRuntime 55) with the prescribed CLT command.
`scripts/build-app.sh` produced the release app; an independent Foundation probe resolved
108 Runtime and 13 App entries in every packaged locale and confirmed Common/ChatUI were
present with development localization en. Deep/strict codesign verification passed before
and after GUI QA. Existing CLT missing Developer library/framework linker warnings and the
existing native AX compatibility API deprecation remain nonfatal.

CUA ran only the packaged `--test-runtime` app. After an initial inventory timeout, direct
app attachment succeeded. It observed the existing mock Codex login, user-run login/logout
instructions, Pi OAuth/Cursor distinction and unknown-limit help; selected Japanese,
Simplified Chinese and Korean and saw settings update immediately; closed Settings and
observed the Korean workspace with the same faux-1 model; reopened Settings with Korean
retained; and used Reset to System to restore deterministic English. It typed/sent a local
Pi message and observed simulated streaming. Attempts to select the Codex model and to
change language during streaming were rejected repeatedly by CUA's
“The user changed ... Re-query the latest state ...” guard, so these interactions are
**not** claimed as GUI passes. Streaming-language/IME identity proof is the passing native
host test with the real local Codex executable fixture. Physical IME/candidate windows,
real-account access and dynamic app-menu GUI verification remain unverified. Command-Q
returned `App quit`; its exact temporary root was removed, confirming normal cleanup.
