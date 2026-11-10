import AgentRuntime
import AppLocalization
import ChatCore
import Foundation
import Testing

// Audited issue #23 inventory: settings labels, auth/status branches, safe diagnostics,
// routing notices/templates and app lifecycle/menu/isolated-mode presentation. #24 owns
// repository-wide extraction/CI; these tests deliberately stay with this issue's surfaces.
private let runtimeInventory: Set<String> = Set(#"""
API key
Account
Cancel sign-in
ChatGPT subscription sign-in requires your interaction in the secure authentication session. It is separate from an OpenAI API key.
Choose a model
Choose a provider
Choose a provider and model in Settings, then use Use selected model. History remains available without signing in.
Codex CLI absolute path (blank: discover)
Codex CLI authentication kind is unsupported. An existing ChatGPT CLI login is required.
Codex CLI could not be launched safely.
Codex CLI credentials are managed by the official CLI. API keys are unsupported on this route.
Codex CLI exited unexpectedly.
Codex CLI is using API-key authentication. Choose ChatGPT with codex login in Terminal, then refresh.
Codex CLI requires an existing ChatGPT login. In Terminal, run codex login and choose ChatGPT, then refresh Codex CLI settings here. The official CLI owns your login. To sign out, run codex logout yourself.
Codex CLI returned an incompatible or oversized response.
Codex CLI timed out.
Codex CLI was not found. Install it or set an absolute executable path.
Codex conversation storage is unavailable.
Codex operation was cancelled.
Codex rejected the request. Check CLI compatibility, ChatGPT login, access, and limits.
Codex response failed. Check CLI compatibility, ChatGPT login, access, and limits.
Codex runtime is shut down.
Codex submission is too large or has an invalid message ID.
Configured
Conversation routing preferences could not be read.
Conversation routing preferences could not be saved.
Credentials remain in Cursor's official CLI store. Only use a trusted executable.
Cursor CLI absolute path (blank: discover)
Cursor CLI could not be launched.
Cursor CLI failed (exit {code}). Check Cursor login, subscription, and limits.
Cursor CLI lacks the required read-only print protocol. Update Cursor CLI.
Cursor CLI returned an invalid or incomplete response.
Cursor CLI timed out.
Cursor CLI was not found. Install it or set an executable path.
Cursor conversation storage is unavailable.
Cursor operation was cancelled.
Cursor response failed. Check CLI login, subscription, limits, and compatibility.
Cursor status is unavailable.
Cursor uses its official browser login; API keys are not accepted by this service.
Demo data is read-only. Connect a backend to send messages.
Disable sending (clear active model)
Enter a message.
Enter an API key, or remove the stored key.
Existing CLI ChatGPT login detected
In Terminal, run codex login and choose ChatGPT, then refresh Codex CLI settings here. The official CLI owns your login. To sign out, run codex logout yourself.
Install Cursor CLI, then run agent login in Terminal to open Cursor's official browser login. Use agent status to check authentication.
Install the official Codex CLI, or enter its absolute executable path. Only use a trusted executable.
Isolated test runtime only supports its simulated Codex executable.
Message ID is already in use.
Message ID was already used for a different submission.
Model
Model selected. Create a new conversation to send with {provider}.
No backend is connected.
Not configured
Provider
Provider configuration could not be loaded.
Provider models could not be loaded.
Provider preferences could not be read.
Provider preferences could not be saved.
Provider settings could not be loaded.
Providers could not be loaded.
Refresh existing CLI login and models
Refresh provider state
Remove API key
Save API key
Save CLI path
Save Codex CLI path
Saved conversations could not be restored.
Saved history has no recorded account. Browse it here; use Settings to choose a model, then create a new conversation to send.
Select a configured provider and model.
Select or create a conversation.
Settings error: {message}
Sign in with ChatGPT
Sign in with Cursor
Sign out
Sign-in failed. Try again.
Signed out
Signing in…
Some work could not be saved during shutdown.
Status
The API key could not be saved.
The backend event stream ended. Reconnect to continue.
The conversation and model use different accounts. Select a compatible conversation in Settings.
The conversation could not be created.
The conversation could not be stopped.
The conversation database could not be closed cleanly.
The conversation database could not be opened.
The conversation selection could not be saved.
The credential could not be removed.
The key is stored in Keychain. Its value is never loaded into this field.
The message could not be submitted.
The new conversation could not be observed.
The provider request failed.
The runtime could not refresh its saved state. Close and reopen it.
The settings operation failed. Check the provider and try again.
This account or authentication route is not supported by Pi.
This backend's observation stopped. Quit and reopen DurableChat.
This conversation is busy.
This conversation's provider or model is unavailable. History is still available; check Settings to reconnect.
This message ID already identifies a different submission.
This provider has no available models.
This provider's credentials or models could not be loaded.
This reuses your existing Codex CLI ChatGPT login, separately from Pi ChatGPT OAuth and Cursor. API-key CLI authentication is unsupported. Credentials remain owned by the official CLI.
Unavailable: {model}
Unsupported Cursor provider account.
Unsupported routing preferences.
Usage limits and remaining quota are unknown here; login detection does not guarantee model access or availability.
Use selected model
"""#.split(separator: "\n").map(String.init))

private let appInventory: Set<String> = Set(#"""
Codex CLI · existing ChatGPT login · usage limits unknown
DEMO • deterministic, read-only sample data
Demo is read-only. Relaunch without --demo to configure providers.
Dismiss
DurableChat could not open its saved workspace. Check that another copy is not running and that Application Support/DurableChat is readable. Your files have not been reset.
ISOLATED TEST RUNTIME • SIMULATED responses • temporary history • no AI calls
Opening saved workspace…
Provider settings will be available after the workspace opens.
Quit DurableChat
Ready. Only an explicit Send starts a model request.
Settings…
Some active work could not be saved while closing the runtime.
The model could not be applied. Refresh Settings and choose an available model.
"""#.split(separator: "\n").map(String.init))

@Test func runtimeAndAppTablesHaveCompleteAuditedFourLanguageInventory() throws {
    #expect(LocalizationValidation.issues(tables: [.runtime, .app]).isEmpty)
    for (table, inventory) in [(LocalizationTable.runtime, runtimeInventory), (.app, appInventory)] {
        for language in AppLanguage.allCases {
            #expect(LocalizationValidation.keys(table: table, language: language) == inventory)
            for key in inventory {
                let names = try #require(LocalizationTemplate.placeholders(in: key))
                let arguments = Dictionary(uniqueKeysWithValues: names.map { ($0, LocalizationArgument.string("raw {count} %n 日本語")) })
                let result = Localizer(language: language).resolve(LocalizedMessage(key, table: table, arguments: arguments))
                #expect(result.source == .localized)
                if language != .english { #expect(result.text != key) }
                if !names.isEmpty { #expect(result.text.contains("raw {count} %n 日本語")) }
            }
        }
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(contentsOf: root.appendingPathComponent("Sources/AgentRuntime/ProviderSettingsView.swift"), encoding: .utf8)
    // Catch new literal labels/failures omitted from the audited inventory.
    for pattern in [#"label\(\"([^\"]+)\""#, #"failure = \"([^\"]+)\""#, #"title: \"(Sign in[^\"]+)\""#] {
        let regex = try NSRegularExpression(pattern: pattern)
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            let range = try #require(Range(match.range(at: 1), in: source))
            #expect(runtimeInventory.contains(String(source[range])))
        }
    }
}

@Test @MainActor func canonicalDiagnosticsAndExplicitTemplatesStayUnmodifiedAndUnknownTextStaysVerbatim() throws {
    let cases: [(ChatBackendError, String)] = [
        (.disconnected, "No backend is connected."),
        (.demoReadOnly, "Demo data is read-only. Connect a backend to send messages."),
        (.emptyMessage, "Enter a message."), (.noConversation, "Select or create a conversation."),
        (.noModel, "Select a configured provider and model."), (.busy, "This conversation is busy."),
    ]
    let original = "Model selected. Create a new conversation to send with provider-{name}-%n."
    let unknown = "External provider failure: No backend is connected. /path/{name} %n 日本語"
    for language in AppLanguage.allCases {
        let localizer = Localizer(language: language)
        for (error, source) in cases {
            #expect(error.localizedDescription == source)
            #expect(RuntimePresentation.diagnostic(source, localizer: localizer) == localizer.string(source, table: .runtime))
        }
        let presented = RuntimePresentation.diagnostic(original, localizer: localizer)
        #expect(presented.contains("provider-{name}-%n"))
        #expect(presented == localizer.string("Model selected. Create a new conversation to send with {provider}.", table: .runtime,
            arguments: ["provider": .string("provider-{name}-%n")]))
        let cursor = CursorRuntimeError.processFailed(123).localizedDescription
        #expect(cursor == "Cursor CLI failed (exit 123). Check Cursor login, subscription, and limits.")
        #expect(RuntimePresentation.diagnostic(cursor, localizer: localizer) == localizer.string(
            "Cursor CLI failed (exit {code}). Check Cursor login, subscription, and limits.", table: .runtime, arguments: ["code": .string("123")]))
        #expect(RuntimePresentation.diagnostic(unknown, localizer: localizer) == unknown)
        #expect(RuntimePresentation.diagnostic("prefix " + original, localizer: localizer) == "prefix " + original)
        #expect(ChatBackendError.unavailable(unknown).localizedDescription == unknown)
        for error in [CodexRuntimeError.unavailable, .launch, .cancelled, .timedOut, .invalidOutput, .rpc, .exited, .storage, .closed] {
            #expect(runtimeInventory.contains(error.localizedDescription))
        }
        for error in [CursorRuntimeError.unavailable, .unsupportedCLI, .launch, .cancelled, .timedOut, .invalidOutput, .storage] {
            #expect(runtimeInventory.contains(error.localizedDescription))
        }
    }
}
