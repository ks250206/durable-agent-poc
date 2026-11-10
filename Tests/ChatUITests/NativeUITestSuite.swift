import Testing

/// AppKit focus, key windows and the input context are process-global. Serialize all
/// native host suites together; backend concurrency remains explicitly exercised in its tests.
@Suite(.serialized)
struct NativeUITests {}
