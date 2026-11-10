# Four-language localization

The current application shares one observable language owner across workspace, settings and app-owned
commands. All four tables live in one AppLocalization bundle: **Common 10, ChatUI 109, Runtime 108,
App 13 keys per locale** (en, ja, zh-Hans, ko). #20 introduced the foundation, #22 translated ChatUI,
and #23 connected Runtime/App presentation; #24 adds the repository-wide audit and CI/package gates.
ChatCore stays independent of localization. The runtime protocols and credential boundary are unchanged.

Issue #36 adds five ChatUI keys for the standalone `PromptRail` label, ordinal, keyboard/hover
instructions, explicit dense-window range, and unavailable-center count. Both
`Tests/ChatUITests/LocalizationTests.swift` and `scripts/localization/inventory.json` register these
exact keys. New source literals are individually classified; source/resource validators remain fail
closed. Original input text in the native popover/AX value is verbatim data, never a translation key
or shortened preview. Common/Runtime/App and #32 Appearance ownership are unchanged. See the #36
handoff in SharedContracts.md for center measurement and integration details.

Run `scripts/validate-localization.sh` for the source inventory and tables, then
`scripts/validate-localization.sh dist/DurableChat.app` for the actual copied/compiled resource bundle.
The [auditor instructions](../scripts/localization/README.md) describe the fail-closed string-site inventory,
reserved Common controls, explicit diagnostic mappings and mutation tests. It uses the existing public
LocalizationValidation/LocalizationTemplate/Localizer contracts and an independently audited key manifest.
It checks missing/extra/empty/malformed entries, placeholder mismatches and exact-locale Foundation lookup.
Source coverage and format parity do not establish linguistic quality or replace native/GUI QA.
The current evidence and unverified limits are in [Integration.md](Integration.md).

## Foundation API (introduced in #20)

## Languages, settings, and observation

- `AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable`: `.english` (`en`),
  `.japanese` (`ja-JP`), `.simplifiedChinese` (`zh-Hans`), `.korean` (`ko`).
  `init?(identifier:)`, `negotiate(_ preferredLanguages: [String])`, `locale`,
  `resourceIdentifier`, `nameKey`. Japanese resources are `ja.lproj`.
- `LanguageChoice` has the same four cases plus `.system` (`system`), `language: AppLanguage?`,
  `nameKey`, and `init(persistedValue: String?)` (invalid/missing becomes System).
  Picker order is System, Japanese, English, Simplified Chinese, Korean.
- `@MainActor @Observable final class LocalizationSettings`:
  `init(defaults: UserDefaults = .standard, storageKey: String = defaultStorageKey,
  preferredLanguages: @escaping @MainActor () -> [String] = { Locale.preferredLanguages })`.
  Writable `choice`; derived `language`, `locale`, `localizer`; `resetToSystem()`;
  `refreshSystemLanguage()`; observing `string`, `text`, and `diagnostic` helpers below.
  `defaultStorageKey` is `DurableChat.languageOverride`.

The injectable defaults suite and preference provider make tests independent of personal defaults.
Only the override is saved. System removes the key. Initialization repairs corrupt/unsupported
values to System and canonicalizes supported saved aliases; unrelated defaults are untouched.
Reopening reads the override without changing system-wide `AppleLanguages`.

Negotiation walks **all ordered preferences**, selecting the first supported language, then English.
Language/script/region aliases include `ja`, `ja-jp`, `ja_JP`, `en-US`, `ko-KR`, `zh-CN`, `zh-SG`,
and `zh-Hans-CN` (case-insensitive; underscores accepted). Forms supported by this adapter are
`language[-Script][-REGION]`; corrupt values and other forms are unsupported.
Generic `zh` means Simplified Chinese, recording the assumption from #18. Explicit `zh-Hant`,
and region-only `zh-TW`/`zh-HK`/`zh-MO`, are unsupported and allow later preferences to win.
They do not silently select Simplified Chinese. Explicit `zh-Hans` takes precedence over region.

The application owns **one** settings instance in `@State` / AppSession, injects the same reference into
workspace and settings, and refreshes System preferences on activation and/or
`NSLocale.currentLocaleDidChangeNotification` (hop to MainActor). This library deliberately does
not install application lifecycle observers. The refresh method does not change an explicit choice.

```swift
// Owning application boundary (installed by #23).
@State private var localization = LocalizationSettings()

// At the owning view/scene boundary:
ContentView()
    .environment(localization)
    .environment(\.locale, localization.locale)

// In a consuming view:
@Environment(LocalizationSettings.self) private var localization
// Inside body:
localization.text(LocalizedMessage("Cancel"))
// Settings placement:
LanguagePickerView(localization: localization)
```

`LanguagePickerView: View` is standalone, initialized with `init(localization:)`; it binds `choice`
and localizes its label/options. No app window or settings scene is added here.

Read the settings helper inside `body` so Observation tracks the effective language. Avoid cached
localized Strings/Text, static label arrays, `.id(language)`, language-keyed WindowGroups, or rebuilding
ChatStore/navigation/editor owners. A locale environment change and body reevaluation preserve the
NSViewRepresentable's structural identity. `updateNSView` may update presentation properties such
as a placeholder; it must not replace the user's text or reset selection/marked text on language changes.
Keep conversation/user/model/code text, conversation titles, IDs, provider/model names, and executable
paths verbatim. Never run transcript content through `diagnostic` or treat it as a localization key.

## Lookup, locale, formatting, and counts

`Localizer: Sendable` is an immutable snapshot, with `language`, `locale`, and exact language
sub-`bundle`. `Localizer.resources` exposes the real SwiftPM `Bundle.module` for validation.
Initializers are `init(language: AppLanguage, resources: Bundle = Localizer.resources)` and
`init(locale: Locale, resources: Bundle = Localizer.resources)`.
The locale initializer retains supported regional number/date conventions (e.g. `en_GB`) while
using that language's resources. Unsupported explicit locales use **both** English locale and resources.
Settings use the canonical chosen language's locale, independent of the machine's current locale.

Public presentation API on both `Localizer` and `LocalizationSettings`:

```swift
func string(_ key: String, table: LocalizationTable = .common, fallback: String? = nil,
            arguments: [String: LocalizationArgument] = [:]) -> String
func string(_ message: LocalizedMessage) -> String
func text(_ message: LocalizedMessage) -> Text
func diagnostic(_ source: String, table: LocalizationTable = .runtime) -> String
func diagnostic(_ source: String, table: LocalizationTable = .runtime,
                templates: [DiagnosticTemplate]) -> String
```

`LocalizedMessage: Equatable, Sendable` has
`init(_ key: String, table: LocalizationTable = .common, fallback: String? = nil,
arguments: [String: LocalizationArgument] = [:])`.
English messages may be source keys. Stable non-English IDs require an English table entry or
an explicit English `fallback`. Lookup order is selected language → English → supplied fallback → key.
This is **per key**, including missing tables. `Localizer.resolve(_:) -> LocalizationResolution`
exposes `text` and `source`: `.localized`, `.englishFallback`, `.sourceFallback`, or `.keyFallback`.
Missing resource bundles never silently trigger a different system-preferred language.

`LocalizationArgument` is `.string(String)`, `.integer(Int)`, or `.decimal(Double)`.
Templates use named `{count}`/`{name}` placeholders. Names use ASCII letters/digits/underscore;
`{{` and `}}` escape braces. Translations may reorder/repeat names but must preserve their set.
The supplied argument-name set must match exactly. Substitution happens once: captured text with
braces, `%`, Markdown, or code is not interpreted. `%d`/`%@`/`%n` are ordinary text, not formats.
Malformed English entries do not block a valid explicit fallback or source key from defining the
placeholder contract and rendering. Valid English entries continue to define the required placeholder set.
Invalid translations fall back to English; invalid caller contracts safely return the source fallback/key
without substitution. Tests/validators must catch these defects; a safe fallback is not coverage success.

```swift
let message = LocalizedMessage("Message {current} of {total}", table: .chatUI,
    arguments: ["current": .integer(index + 1), "total": .integer(messages.count)])
localization.text(message) // Add translated templates in ChatUI.strings in #22.

let count = messages.count
let counted = LocalizedMessage.plural(count: count,
    one: LocalizedMessage("{count} message", table: .chatUI,
                         arguments: ["count": .integer(count)]),
    other: LocalizedMessage("{count} messages", table: .chatUI,
                           arguments: ["count": .integer(count)]))
localization.text(counted)

// Arbitrary Foundation formats use the same explicit locale:
let displayDate = date.formatted(.dateTime.year().month().day().locale(localization.locale))
let percent = fraction.formatted(.percent.locale(localization.locale))
// Insert the already formatted value as .string(percent) if needed in a sentence.
```

`LocalizedMessage.plural(count:one:other:)` selects English `one` only for integer 1;
Japanese/Simplified Chinese/Korean always select `other`. Both messages supply their own arguments.
This is integer cardinal selection for these four languages, not a general CLDR plural engine;
adding a language or fractional plural use requires extending this contract and tests.
Integer/decimal arguments use Foundation number styles with `localizer.locale`.

`text` returns `Text(verbatim:)` after explicit lookup. This avoids accidental second lookup in
Bundle.main and Markdown interpretation. For simple existing keys, `Text(LocalizedStringKey(key),
tableName: table.rawValue, bundle: localization.localizer.bundle)` with the locale environment is
also available, but use the helpers for this library's per-key fallback and named interpolation.

## Diagnostic strings and background work

Do not read the main-actor settings from runtime actors. Prefer retaining a `LocalizedMessage`
with typed arguments and rendering it in the view's body, or capture a Sendable `Localizer` snapshot
on the main actor for a one-off background presentation. A captured snapshot intentionally keeps
its original language. Do not persist translated messages into backend/conversation state.

Existing Foundation contracts already carry `String` diagnostics (`ChatFailure.message`, connection
failures, routing notices). `localization.diagnostic(source)` translates exact app-owned English
source keys in the Runtime table. Unknown provider/system error strings remain byte-for-byte unchanged.
This does not parse arbitrary prose or translate arbitrary provider text.

For existing interpolated String diagnostics, the runtime registers an explicit presentation adapter
without changing ChatCore types or stored source text:

```swift
let templates = [DiagnosticTemplate(
    "Model selected. Create a new conversation to send with {provider}.", table: .runtime)]
Text(verbatim: localization.diagnostic(notice, templates: templates))
```

`DiagnosticTemplate: Equatable, Sendable` has `init(_ source: String, key: String? = nil,
table: LocalizationTable = .runtime)` and `message(matching: String) -> LocalizedMessage?`.
Default key is the English source template. Matching anchors the **whole** string; captured values
are verbatim `.string` arguments. All-capture, adjacent-capture, malformed, and conflicting repeated
captures fail closed. Use only a small explicit allowlist of known app-owned diagnostic templates.
Exact static diagnostics take precedence; otherwise templates are tried in caller order. For numeric
formatting/cardinal selection, construct a typed `LocalizedMessage` while the count is available.
Do not infer structured numbers/IDs from arbitrary provider output. RuntimePresentation owns the actual diagnostic allowlist/translations.

## Resource/table ownership and validation contract

All resources live in `Sources/AppLocalization/Resources/{en,ja,zh-Hans,ko}.lproj/` and are processed
by SwiftPM (`defaultLocalization: "en"`, `.process("Resources")`, `Bundle.module`).

| Table (`LocalizationTable`) | Owner | Work |
| --- | --- | --- |
| `Common` (`.common`) | #20 | Language choices, Language, Cancel, Close, Save, Reset to System; complete in all four languages |
| `ChatUI` (`.chatUI`) | #22 | Create `ChatUI.strings` in each of the same four directories; all workspace/composer/minimap/ChatUI accessibility strings |
| `Runtime` (`.runtime`) | #23 | Create `Runtime.strings` in each locale; provider settings, app-owned errors/status/diagnostic templates |
| `App` (`.app`) | #23 | Create `App.strings` in each locale; app scenes/menu/startup/isolated mode and language-setting placement |

All four tables are present. Edit each table within its ownership boundary; do not duplicate Common
entries or create separate target bundles. All consumers import AppLocalization.

`LocalizationValidation.issues(tables: [LocalizationTable] = [.common], resources: Bundle =
Localizer.resources) -> [LocalizationIssue]` reads the real `.strings` property lists (including
compiled binary tables). It reports `missingOrInvalidTable`, `missingKey`, `unexpectedKey`,
`invalidTemplate`, and `placeholderMismatch`, with public `language`, `table`, `key`, `kind` fields.
English entries define the required key/placeholder manifest. Empty/missing/corrupt tables fail.
`keys(table:language:resources:) -> Set<String>` lets consumer tests compare required/dynamic keys
against an audited source inventory. `LocalizationTemplate.placeholders(in:) -> Set<String>?`
exposes the grammar check (`nil` = malformed).

Each owner must add tests like `#expect(LocalizationValidation.issues(tables: [.chatUI]).isEmpty)`
and compare `keys(table: .chatUI)` with its audited app-owned key set, including dynamic diagnostics,
plural branches, accessibility labels/help and empty/loading/error states. This validator proves
resource/format parity, not extraction completeness or linguistic quality. The audited source inventory and locale-specific visual QA remain necessary alongside this library contract. Named placeholders replace printf;
do not add `%lld`-style interpolation or `.stringsdict` entries without extending validation/runtime.

## Foundation verification contract and historical #20 evidence

Run with the pinned CLT toolchain:

```sh
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
export PATH="$DEVELOPER_DIR/usr/bin:$PATH"
swift test -Xswiftc -plugin-path -Xswiftc "$DEVELOPER_DIR/usr/lib/swift/host/plugins/testing"
scripts/build-app.sh
```

Tests cover aliases/ordered negotiation; invalid overrides/System fallback; all four persisted
choices/reopen/reset; synchronous Observation invalidation; actual module-bundle lookup; injected
locale/number formatting; missing key/table/language and invalid-format fallback; count selection;
escaped/reordered/repeated arguments; detached diagnostic presentation and explicit diagnostic adapters;
and validator failures. Temporary defaults suites and temporary bundles are removed after tests.
The native NSHostingView test switches all four choices beside a real NSTextView, verifying one
NSViewRepresentable instance, marked text, selection, text, focus, and updated presentation.
This is synthetic native hosting evidence; current ChatUI hookup and physical IME testing belong to
follow-ups. No personal credentials, network/model calls, provider discovery or app startup are needed.

The unchanged `scripts/build-app.sh` copies every swiftbuild `.bundle` into the packaged app's
`Contents/Resources`. Verify `DurableChat_AppLocalization.bundle` there, with all four `Common.strings`
and English development localization, then run `codesign --verify --deep --strict` on the app.
Swiftbuild uses `Contents/Resources` inside resource bundles; the legacy SwiftPM layout can be flat.
Package inspection should accommodate both. The executable's explicit manifest dependency keeps the
resource bundle in the build graph.

Historical #20 snapshot, not the current test total: verified on 2026-11-10 with CLT Swift 6.4.2 / macOS 27.2 SDK: all **98 tests passed**
(baseline 88 unchanged + 10 AppLocalization tests). `scripts/build-app.sh` produced the release
`dist/DurableChat.app`; deep/strict ad-hoc signature verification passed. An independent Foundation
probe opened the copied `DurableChat_AppLocalization.bundle`, checked development localization `en`,
read all 10 Common keys in every locale, and resolved Language as Language / 言語 / 语言 / 언어.
Logs and the probe are under ignored `dist/qa/`. CLT emitted its existing missing Developer library/
framework search-path linker warnings; there were no localization/compiler/test failures.
App-screen localization and lifecycle wiring were subsequently delivered by #22/#23. Physical IME
and real provider-account validation remain uncertified. CI/review results must be read separately from the PR; local validation is not CI.

## Primary API references

The resource layout and package default follow Apple's
[Localizing package resources](https://developer.apple.com/documentation/xcode/localizing-package-resources).
Lookup/fallback semantics are based on
[Bundle.localizedString(forKey:value:table:)](https://developer.apple.com/documentation/foundation/bundle/localizedstring(forkey:value:table:)).
The SwiftUI handoff uses Apple's
[Text initializer with table and bundle](https://developer.apple.com/documentation/swiftui/text/init(_:tablename:bundle:comment:))
and [EnvironmentValues.locale](https://developer.apple.com/documentation/swiftui/environmentvalues/locale).

## Issue #23 application/runtime handoff

`AppSession.localization` is the single observable language owner. App, Window, Settings,
`NativeWorkspaceView`, `NativeSettingsView`, the existing `LanguagePickerView`, and provider settings
share that reference and its explicit locale. The picker order and Common table stay owned by #20;
ChatUI/Common tables are unchanged. Language selection and Reset to System are available before
startup finishes and in demo mode too. `AppDelegate` refreshes System on activation and on the locale
notification (main-actor hop). Explicit overrides remain selected. Production uses the existing
`DurableChat.languageOverride`; no `AppleLanguages` mutation or translated persisted state is added.
Demo/test-runtime create a unique defaults suite, use deterministic English System preferences, and
remove that suite during shutdown. Tests inject suites/preference providers to verify reopen,
invalid fallback, System refresh/reset and unchanged unrelated defaults without personal preferences.

Runtime now has **108 keys**, App **13 keys**, in en/ja/zh-Hans/ko in the existing resource bundle.
`PresentationLocalizationTests` contains the reviewed inventory and verifies exact table parity,
placeholder contracts, resolved-language provenance, actual translations and the settings source's
literal labels/failures. Common and ChatUI validation remains with its original owners. App-owned
Settings and Quit menu commands use the App table; macOS-owned standard menus remain system UI.
The commands preserve the existing openSettings action and asynchronous AppDelegate termination path.

`AgentRuntime.RuntimePresentation` owns only two explicit `DiagnosticTemplate` adapters:

- `Model selected. Create a new conversation to send with {provider}.`
- `Cursor CLI failed (exit {code}). Check Cursor login, subscription, and limits.`

`diagnostic(_:localizer:)` applies exact Runtime keys first, then these anchored templates. Captures
are opaque strings: exit codes and IDs are not parsed/reformatted; typed counts elsewhere continue
to use the foundation's locale-aware number formatting. The fixed composite Codex login-required
message has its own exact key. Unknown provider/system text passes through unchanged. There is no
printf formatting, raw output translation, ChatCore localization dependency, or error-source mutation.

The necessary ChatUI diagnostic adapter seam is `EnvironmentValues.chatDiagnosticTemplates:
[DiagnosticTemplate]` (default `[]`). NativeWorkspaceView injects the Runtime-owned allowlist;
ChatUI forwards it only at existing failure/connection/selection diagnostic presentation sites.
This keeps AgentRuntime out of ChatUI dependencies and covers existing open dynamic Cursor errors.
It does not affect transcript rendering, conversation titles, user/model text, paths, IDs or secrets.
Do not register broad provider prose templates or translate those data values as keys.

Language changes invalidate presentation in place. They never key/remount a window, ChatStore,
TranscriptNavigation, ComposerInput or native editor. Provider settings retain their state/tasks;
a language change does not refresh provider discovery, choose/apply a model, or start/stop generation.
The existing API-key/Pi ChatGPT OAuth/Cursor/Codex CLI accounts and routes remain exact. Codex help
continues to instruct user-run `codex login` / `codex logout`, with unknown quota/entitlement and no
app login/logout/key operation on that route.

#24 supplies repository-wide inventory validation and CI/final aggregate QA. Consume these table and
adapter ownership boundaries there; do not duplicate resource tables or move presentation into
ChatCore. Physical IME/candidate-window behavior and real CLI account/model entitlement remain
uncertified by the synthetic native hosts and isolated executable fixtures used here.

Historical #23 verification snapshot: all 136 tests passed, release packaging and deep/strict signature
verification passed, and the independent packaged Foundation lookup resolved the complete
Runtime/App tables in every locale. Native host PNGs include settings/provider/status/error
screens at the required sizes and appearances. CUA confirmed language switching, shared
workspace propagation, Settings reopen and System reset; its popup safety guard prevented
certifying the attempted streaming-language/model-selection GUI path. See Integration.md
for the exact evidence and limits; synthetic composition is not physical IME certification.

## Issue #32 appearance ownership

`LocalizationTable.appearance` adds **Appearance.strings**, six keys in en/ja/zh-Hans/ko:
Appearance, System, Light, Dark, Use the system appearance, or always use Light or Dark., Reset to System.
These belong to the standalone `ChatUI.AppearancePickerView` and `AppearanceChoice.nameKey`;
Common/ChatUI/App/Runtime are unchanged. The appearance model stores canonical identifiers, never labels.
`AppearancePickerView(settings:localizer:)` receives the current language owner's localizer in body.
No scene or application localization owner is replaced; #33 owns placement.

Extend the strict source/resource inventory with this table, the enum raw value, each new Swift file
(including files with zero literals), dynamic choice-key coverage, picker labels/help, and the stable
appearance storage identifiers. No fallback is accepted as coverage. AppearanceTests also assert exact
six-key parity, `.localized` provenance and translated values in every locale. The aggregate source and
packaged resource audit remains mandatory; this table must not be exempted or treated as a reserved
future table. The full public API and native color/identity integration recipe are in SharedContracts.md.

Local #32 verification on 2026-11-10, after integrating main `dbc753e`: **145 Swift tests passed**
(139 baseline + 6 appearance), using the prescribed CLT/plugin command with a 300-second overall
limit (completed in about 82 seconds including build). Source and packaged-resource audits passed
for all five tables in all four languages, including all six Appearance keys with exact Foundation
lookup and `.localized` provenance. The unchanged release packaging script and
`codesign --verify --deep --strict` passed. Native artifacts are synthetic rendered hosts, stored only
under ignored `dist/qa/`; no user reference image is a resource or artifact. Production appearance
scene/editor adoption remains #33/#35; physical IME and OS accessibility setting changes are not
certified by these injected/synthetic tests. CI and independent review remain separate PR gates.
