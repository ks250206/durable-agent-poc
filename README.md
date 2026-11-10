<img src="assets/icon.svg" width="64" height="64" alt="">

# DurableChat

Native SwiftUI chat for macOS 14+, with durable Pi, Cursor CLI and Codex CLI conversations,
a native IME-aware composer, full-history transcript overview, and provider settings.
All three backends share the history sidebar; stable namespaced IDs and account bindings survive reopening.

Normal launch opens saved history and provider configuration. **No model is selected by default.**
No sign-in or model request starts automatically. Settings/status discovery can read Keychain and run
Cursor's official status/models commands and Codex app-server account/model discovery. Only an explicit
Send starts generation; history remains browsable when credentials or a model are unavailable.

## Build and start

Use Swift 6.4.2 / macOS 27.2 SDK, as required by pinned PiDurableKit (deployment target remains macOS 14).
Xcode 27.2 or Command Line Tools 27.2 is required; Xcode 26's SDK cannot build this revision.
On the development machine:

```sh
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
export PATH="$DEVELOPER_DIR/usr/bin:$PATH"
swift build --build-system swiftbuild
swift test -Xswiftc -plugin-path -Xswiftc "$DEVELOPER_DIR/usr/lib/swift/host/plugins/testing"
scripts/build-app.sh
open dist/DurableChat.app
```

For full Xcode, select `/Applications/Xcode_27.2.app/Contents/Developer` and use the Testing plugin
under `$(dirname "$(xcrun --find swiftc)")/../lib/swift/host/plugins/testing` when it is not under
`$DEVELOPER_DIR/usr/lib`. Native tests need a macOS WindowServer session; a failure to create/host
native views is a test blocker, not a reason to skip them.

`build-app.sh [debug|release] [output-directory]` pins `--build-system swiftbuild`, copies resource bundles
into `Contents/Resources`, includes upstream notices, validates Info.plist, and applies/verifies an
ad-hoc signature. It replaces only `DurableChat.app` in that output directory. This is a local development
build: no Developer ID signing, notarization, hardened-runtime distribution, or production Keychain/OAuth
entitlements have been certified. A macOS trust/authentication prompt must be handled by the user.

## Configure an account

1. Open **Settings…** in the workspace or the app menu (Command-comma).
2. Choose an account. API-key providers store keys in macOS Keychain. ChatGPT subscription OAuth
   (`openai-codex`) uses its secure browser sign-in and remains separate from OpenAI API-key billing.
   Cancel sign-in or close Settings to dismiss an in-progress login.
3. For Cursor, install the official [Cursor CLI](https://cursor.com/docs/cli/overview). Optionally save an
   absolute executable path; otherwise `agent`/`cursor-agent` is discovered. Finder's PATH may differ
   from Terminal's. Use **Sign in with Cursor**, Cancel sign-in, Sign out, and Refresh provider state;
   `agent login` / `agent status` in Terminal are also supported. Credentials stay in Cursor's CLI store.
   Only choose a trusted executable. Cursor runs in the app-owned workspace, in read-only ask mode.
4. For **Codex CLI · codex-cli**, install the official [Codex CLI](https://learn.chatgpt.com/docs/cli).
   Enter an optional trusted absolute executable path and click **Save Codex CLI path**. In Terminal,
   run `codex login` and choose ChatGPT yourself (or use the configured executable's path), then click
   **Refresh existing CLI login and models**. To sign out, run `codex logout` yourself. The app never starts
   CLI login/logout, reads `auth.json`, or extracts tokens. This uses the existing CLI ChatGPT session,
   separately from Pi ChatGPT OAuth and Cursor. API-key CLI authentication stays unsupported.
   A detected login does not guarantee model entitlement; usage limits/remaining quota are unknown here.
   See the [official authentication reference](https://learn.chatgpt.com/docs/cli/reference#codex-login).
5. Select a discovered model and click **Use selected model**. Browsing accounts, changing a model in
   Settings, refreshing, and dismissing Settings do not change the active model. Applying a model saves
   the explicit account/model preference. Disable sending clears that active choice explicitly.
6. Create **New conversation**, type a message, and Send. Enter sends committed text; Shift+Enter inserts
   a newline. Enter during marked-text composition does not submit. Stop preserves partial output.

A conversation is bound to its original account, including separate Pi API-key, Pi OAuth, Cursor and Codex CLI routes.
Applying a model for another account clears selection and shows the instruction to create a new compatible
conversation. Selecting saved history restores that account's last explicitly applied model, or leaves
sending disabled if none exists. A model cannot forward another account's history. Existing unbound Pi/Codex history
from before routing metadata was recorded stays read-only because its account cannot be proved; choose
a model and create a new conversation to send. No account is guessed. Switching conversations never selects
a late background stream or displays another conversation's send failure.

## Local data and shutdown

Production data lives under `~/Library/Application Support/DurableChat/`:

- `conversations.sqlite` and SQLite WAL: Pi history.
- `providers.json`: Pi nonsecret per-provider preferences.
- `routing.json`: explicit active/last-used models, selection and conversation/account bindings.
- `Cursor/`: CLI preferences, durable history/session mappings, private ask-mode workspace and lock.
- `Codex/`: nonsecret preferences, durable history/thread mappings, private read-only workspace and lock.

Transcripts are local plaintext storage, not an encrypted credential vault. Do not run two copies over
the same storage root. A storage/configuration error is shown without deleting or resetting files.
Pi keys/OAuth are in Keychain, and Cursor/Codex credentials are owned by their official CLIs. No raw
credential is copied into routing files. Quit waits for app-owned settings probes/login/logout cancellation, stops every origin's
pending/generating work, explicitly closes Pi/SQLite, cancels router observers, releases Cursor's owner,
and awaits Codex backend/settings shutdown, owned-process termination and lock release (also on startup failure).
Interrupted work is restored as stopped; launching never resumes a paid generation.

## Isolated verification modes

```sh
open -n dist/DurableChat.app --args --demo
open -n dist/DurableChat.app --args --test-runtime
```

`--demo` is deterministic, visibly labeled, read-only sample data. It initializes no provider, reads no
credentials, and discovers no CLI. It is never a fallback for failed normal startup.

`--test-runtime` is explicit and visibly labeled **ISOLATED TEST RUNTIME / SIMULATED**. It uses a fresh temp
SQLite file, Pi FauxProvider with in-memory credentials and denied URLSession networking, plus app-generated
Cursor and Codex CLI fixtures. Every Codex account/catalog probe and generation uses the local fixture
executable; no personal Codex discovery occurs. Codex starts with no chosen model; apply it explicitly in
Settings. All responses and seeded history are labeled simulated. Settings/auth operations affect only
those fixtures. It never opens personal credentials or the installed CLI. Quit deletes that temporary
workspace. A forced kill can leave a `DurableChat-Isolated-*` directory in the system temp directory; it can
be removed after that test process exits. Neither QA mode validates provider accounts or paid responses.

Tests use injected fixture backends, temporary paths, FauxProvider and executable CLI fixtures. They cover
atomic subscription/ordering, mixed namespaces, account/model routing, persistence, origin cancellation during
preflight, late streams/failures, actual subprocess cleanup, and full `NSHostingView` composition with the real
Composer and Minimap at 400/1200 pt in light/dark appearances. Set `CHAT_UI_ARTIFACTS_DIR` to save native PNGs.
Existing AppKit tests cover synthetic marked text, confirmation Enter, Shift+Enter/newlines, undo/redo and
submission gating. These are separate from physical input-method testing.

The [macOS workflow](.github/workflows/macos.yml) uses the official `xcode-27` runner, explicitly selects installed
Xcode 27.2 (or CLT with verified 27.2 SDK), builds, runs all tests with native WindowServer requirements, packages
and uploads an ad-hoc-signed app archive and PNGs. Actions are pinned to commit SHAs with read-only repository
permissions. Availability/toolchain sources: [runner announcement](https://github.com/actions/runner-images/issues/14404)
and [official image manifest](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md).
CI success must be read from the actual PR checks; workflow configuration alone is not a CI pass.

Implementation verification and outstanding GUI/account limits are recorded in
[application integration notes](docs/Integration.md). Physical Japanese IME/candidate-window behavior, real user
OAuth/Keychain access, real Cursor login/logout, real Codex CLI ChatGPT account/model access, paid streaming,
and subscription entitlement are **unverified**.

PiDurableKit remains pinned in the manifest and lockfile at `4e1120bbdc7c5329a2f3c05a22bec4b9c9a076bb`.
Component contracts: [shared API](docs/SharedContracts.md), [Pi runtime](docs/PiRuntime.md),
[Cursor runtime](docs/CursorRuntime.md), [Codex runtime](docs/CodexRuntime.md). Issues #9 and #21 supply
application composition and routing. Localization work remains separate in #22/#23.

### App language

Open Settings to choose System, 日本語, English, 简体中文 or 한국어. The language changes immediately
and the override survives reopening; Reset to System removes the override. Workspace, settings,
app-owned menus and existing diagnostics update together while the editor and active response stay
in place. Conversation text, titles, model names and external errors remain verbatim. Demo and
`--test-runtime` use disposable language preferences; production preferences are not used for QA.
See [localization contracts and ownership](docs/Localization.md) for details.
