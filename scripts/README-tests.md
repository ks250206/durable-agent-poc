# Complete Swift test evidence

Use the selected macOS 27.2 toolchain and its Testing macro plugin:

```sh
python3 scripts/run-verified-tests.py \
  --plugin-path "$DEVELOPER_DIR/usr/lib/swift/host/plugins/testing" \
  --output dist/qa/verified-tests
```

The runner first builds/discovers every test, then runs ChatUI, app integration,
localization and unknown future targets one function per process, sequentially.
Only the non-UI ChatCore and AgentRuntime targets are batched. Each discovered
function is assigned exactly once; there is no retry, exclusion list, headless
skip or replacement of native assertions. Parameterized cases remain part of
their original Swift Testing function.

The original grouped run reproduced a clean process exit before the native
suite finished. LLDB stopped at `exit` from `swift_task_asyncMainDrainQueue`,
with unfinished tests. A corresponding upstream report is
[Swift issue #91716](https://github.com/swiftlang/swift/issues/91716).
Process isolation avoids carrying AppKit window/responder/run-loop state from
one native test function into the next; it changes no product runtime code.

Exit status alone is insufficient. After every invocation the validator requires
an xUnit result for exactly the expected discovered IDs, with no missing or
extra functions, skipped tests, failures or errors. A missing/malformed report
also fails. Finally, the aggregate report must match the entire discovery list.
SwiftPM can write Swift Testing results to a separate `-swift-testing.xml`
path. Both it and the requested XCTest path are cleared before execution and
all existing reports are validated and combined; neither framework is discarded.
CI uploads the discovery list, per-invocation reports and aggregate report.
Discovery/build is bounded to 300 seconds, each test invocation to 180 seconds;
timeout or cancellation terminates that invocation's process group.
