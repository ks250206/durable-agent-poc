# AppLocalization — issue #20 handoff

`import AppLocalization` supplies the localization foundation for macOS 14+. This issue adds
no current-screen translations or application hookup. #22 owns ChatUI translation; #23 owns
settings/app wiring and Runtime/App translation after #21. Package.swift is wired here in wave 1:
AppLocalization has no package-target dependencies; ChatUI, AgentRuntime and DurableChatApp depend
on it; ChatCore remains independent. Existing package pins and the swiftbuild packaging script stay intact.

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

For #23: own **one** settings instance in `@State` / AppSession, inject the same reference into
workspace and settings, and refresh System preferences on activation and/or
`NSLocale.currentLocaleDidChangeNotification` (hop to MainActor). This library deliberately does
not install application lifecycle observers. The refresh method does not change an explicit choice.

```swift
// Application integration example ONLY; not installed by #20.
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

For existing interpolated String diagnostics, #23 can register an explicit presentation adapter
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
Do not infer structured numbers/IDs from arbitrary provider output. #23 owns the actual diagnostic
allowlist/translations; this issue ships none of its Runtime/App keys.

## Resource/table ownership and validation contract

All resources live in `Sources/AppLocalization/Resources/{en,ja,zh-Hans,ko}.lproj/` and are processed
by SwiftPM (`defaultLocalization: "en"`, `.process("Resources")`, `Bundle.module`).

| Table (`LocalizationTable`) | Owner | Work |
| --- | --- | --- |
| `Common` (`.common`) | #20 | Language choices, Language, Cancel, Close, Save, Reset to System; complete in all four languages |
| `ChatUI` (`.chatUI`) | #22 | Create `ChatUI.strings` in each of the same four directories; all workspace/composer/minimap/ChatUI accessibility strings |
| `Runtime` (`.runtime`) | #23 | Create `Runtime.strings` in each locale; provider settings, app-owned errors/status/diagnostic templates |
| `App` (`.app`) | #23 | Create `App.strings` in each locale; app scenes/menu/startup/isolated mode and language-setting placement |

No empty/fake English-only ChatUI/Runtime/App files are prefilled. Follow-up owners edit only their
tables; do not duplicate Common entries or create separate target bundles. Consumers can already
import AppLocalization, so no subsequent Package.swift changes are needed for these resources.

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
resource/format parity, not extraction completeness or linguistic quality. A UI-source inventory
and locale-specific visual QA remain necessary in #22/#23. Named placeholders replace printf;
do not add `%lld`-style interpolation or `.stringsdict` entries without extending validation/runtime.

## Verification

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
new resource bundle in the build graph even before #23 installs the app's language setting.

Verified locally on 2026-11-10 with CLT Swift 6.4.2 / macOS 27.2 SDK: all **98 tests passed**
(baseline 88 unchanged + 10 AppLocalization tests). `scripts/build-app.sh` produced the release
`dist/DurableChat.app`; deep/strict ad-hoc signature verification passed. An independent Foundation
probe opened the copied `DurableChat_AppLocalization.bundle`, checked development localization `en`,
read all 10 Common keys in every locale, and resolved Language as Language / 言語 / 语言 / 언어.
Logs and the probe are under ignored `dist/qa/`. CLT emitted its existing missing Developer library/
framework search-path linker warnings; there were no localization/compiler/test failures.
Current app-screen localization, app lifecycle wiring, physical IME and provider-account validation
remain outside #20. CI/review results must be read separately from the PR; local validation is not CI.

## Primary API references

The resource layout and package default follow Apple's
[Localizing package resources](https://developer.apple.com/documentation/xcode/localizing-package-resources).
Lookup/fallback semantics are based on
[Bundle.localizedString(forKey:value:table:)](https://developer.apple.com/documentation/foundation/bundle/localizedstring(forkey:value:table:)).
The SwiftUI handoff uses Apple's
[Text initializer with table and bundle](https://developer.apple.com/documentation/swiftui/text/init(_:tablename:bundle:comment:))
and [EnvironmentValues.locale](https://developer.apple.com/documentation/swiftui/environmentvalues/locale).
