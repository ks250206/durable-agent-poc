# Repository localization audit

Run `scripts/validate-localization.sh`, then `scripts/build-app.sh`, then
`scripts/validate-localization.sh dist/DurableChat.app`. Uses the selected Swift toolchain and
Python 3 standard library only. Neither command launches the app or accesses accounts.

`inventory.json` reuses the audited #20/#22/#23 inventories: Common 10, ChatUI 104, Runtime 108,
App 13 keys. Its source section accounts for **every Swift string site in Sources**, including
nested interpolation, raw/multiline strings, dynamic branches, AX help, canonical diagnostics,
wire/ID/symbol/path data and fixture/verbatim transcript exceptions. Site prefixes and occurrence
counts fail closed on new strings, changed sinks, removals or files. Three reusable Common controls
(Cancel, Close, Save) are explicitly reserved, not falsely claimed as displayed. The two anchored
Runtime diagnostic templates and the fixed login-instructions composition have explicit mappings.
The current manifest is a reviewed boundary, not a general Swift semantic/data-flow analyzer.
Variable-only presentation changes still require code review and native/GUI QA.

The table/language loops derive from LocalizationTable/AppLanguage; there is no hardcoded
four-table/key-count ceiling. Future UI/appearance additions extend the owning enum/resources and
audited manifest together, keeping exact-set validation strict.

There is deliberately no automatic inventory update option. For a legitimate source change, review
its literal and sink, add the key to its owner's audited set and all locales, and edit the manifest
entry with the proper classification, keys and reason. Do not bless unknown prose as data merely to
make CI green. Existing fixture strings and provider/model names remain verbatim.

`LocalizationAudit` imports the existing AppLocalization contracts. It checks the manifest against
each actual source/compiled table, rejects empty/invalid/missing/extra keys and mismatched/malformed
placeholders, requires `.localized` resolution for every key, and independently compares Foundation's
exact-lproj lookup with each serialized entry. This also detects a key removed in all four languages.
No fallback counts as coverage. The CLI reads the supplied resource directory/bundle, never silently
substitutes its linked module's resources. Tests mutate temp bundles and source sites to prove failures.

Counts, key/format parity and nonfallback lookup do **not** certify linguistic quality, runtime
layout, VoiceOver or physical IME behavior. See docs/Integration.md for final evidence and limits.
