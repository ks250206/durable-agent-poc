<img src="assets/icon.svg" width="64" height="64" alt="">

# DurableChat

Swift 6 / macOS 14+ native app foundation for #3. Normal launch is empty and disconnected.
No provider is initialized, no credentials are read, and no AI request is made by this shell.
`--demo` explicitly selects deterministic, labeled, read-only sample data.

```sh
swift build
swift test
scripts/build-app.sh                 # release, ad-hoc signed dist/DurableChat.app
open dist/DurableChat.app
open dist/DurableChat.app --args --demo
# Or: swift run DurableChat --demo
```

Use a compatible Swift compiler/SDK pair. The pinned PiDurableKit revision contains a Foundation Models
adapter requiring macOS 27 SDK APIs when that framework is importable; Xcode with the macOS 26 SDK
cannot compile it. On the implementation machine, select the installed newer Command Line Tools
for the current shell only before the commands above:

```sh
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
export PATH="$DEVELOPER_DIR/usr/bin:$PATH"
# Verified pair: Swift 6.4.2, macOS 27.2 SDK; deployment target remains macOS 14.
```

That Command Line Tools release also needs the bundled Swift Testing plugin path passed explicitly
(the default Swift Build engine does not discover it). Its verified test invocation is:

```sh
swift test -Xswiftc -plugin-path -Xswiftc "$DEVELOPER_DIR/usr/lib/swift/host/plugins/testing"
```

`build-app.sh [debug|release] [output-directory]` explicitly selects `--build-system swiftbuild` and copies SwiftPM resource bundles into `Contents/Resources`
where Swift Build's `Bundle.module` expects them, includes upstream third-party notices, validates the plist,
and applies/verifies an ad-hoc signature. It replaces only `DurableChat.app` in the output directory.
This is local development packaging, not a notarized distribution.

Products are `DurableChat` (executable), `ChatCore`, `ChatUI`, and `AgentRuntime`, with corresponding
library test targets. PiDurableKit is pinned in both the manifest and lockfile to
`4e1120bbdc7c5329a2f3c05a22bec4b9c9a076bb` from `https://github.com/finnvoor/PiDurableKit`.

[Shared contracts and insertion points](docs/SharedContracts.md) define the API handoff for
#4 chat UI, #5 IME composer, #6 minimap, #7 Pi runtime/settings, #8 Cursor CLI, and #9 integration.
Those implementations, real authentication, persistence, CI, and native interaction verification
remain in their own issues. #3 supplies only the buildable shell, common contracts, and state tests.
