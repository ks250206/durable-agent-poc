# Issue #35 component handoff

`MessageRow(message:)` and `ComposerView(store:)` keep their existing public initializers.
They consume the optional `AppearanceSettings` / `LocalizationSettings` environment owners;
standalone callers can still provide explicit `colorScheme` / `locale`. There are no defaults
reads, app-wide appearance writes, runtime/model discovery, or new action APIs here.

The transcript continues to own its reading column. `MessageColumnLayout` places assistant
content on its leading edge and a user bubble of at most 82% of that column on its trailing
edge. Its finite width proposal confines long Unicode/URL prose. Fenced code has a separate
horizontal scroll surface, language label, and original-text copy. Code payload extraction
retains original CRLF, whitespace, and trailing line endings, including partial streaming
fences. No syntax execution, external dependencies, table parser, or syntax highlighter is
introduced. The existing HTTP/HTTPS-only open-URL policy is retained.

The composer uses the shared 20pt radius, palette, editor font, focus stroke, shadow, and
spacing. Send and Stop use the existing `ComposerInput` gates. Editing remains enabled while
streaming. The compact key hint has four translations; full IME and Command+Enter help stays
on the native editor and tooltip. No duplicate model label or unsupported action is added.

`CompositionTextView.updateNSView` applies concrete `nsAppearance`, text/font/background,
insertion point, selection, and typing colors **to the same native editor**. It never swaps
its coordinator, text storage, undo manager, selected ranges, or marked text to update its
presentation. The only new editor callback reports focus for the panel stroke. Existing
IME, submission, Task-hop, draft synchronization, and origin Stop logic is unchanged.

## Verification and evidence

The new tests live under the shared serialized `NativeUITests` suite. They assert actual
native AX bubble/body/metadata/text bounds at 400 and 1200pt in all four locales and both
schemes, real horizontal code scrolling, source preservation, 28pt copy targets, and real
copy clicks using disposable pasteboards. Tests require `NSScreen`; they move oversized
render windows to anchor each interactive target on the connected screen and assert its
bounds rather than exempting targets on small CI displays.

The real Composer binding test forces Light/Dark against the opposite ambient scheme while
changing locale and receiving stream events during marked text. It checks editor, storage,
coordinator, scroll and undo identities, selection, marked range, focus, unchanged draft,
concrete text/background/cursor/selection colors, and subsequent native undo/redo.

With `CHAT_UI_ARTIFACTS_DIR` set, app-owned synthetic component PNGs are written as:

- `message-composer-{en,ja-JP,zh-Hans,ko}-{400,1200}-{light,dark}.png`
- `editor-forced-{en,ja-JP,zh-Hans,ko}-{light,dark}-opposite-ambient.png`

These are synthetic component hosts, not certification of the parallel app/Settings/shell
wiring or physical Japanese input-method behavior. No reference attachments or their
conversation contents are copied into this repository or these artifacts. Physical IME,
VoiceOver speech, real accounts, and provider/network calls remain outside this component QA.
