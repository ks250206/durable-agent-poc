import AppLocalization
import ChatCore
@testable import ChatUI
import Foundation
import Testing

// Audited ChatUI source inventory: workspace/sidebar/empty/connection, composer/IME,
// message roles/status/Markdown/copy, and every minimap/help/AX/count branch.
// Product/provider names, saved titles, IDs, paths and transcript content stay verbatim.
private let chatUIKeys: Set<String> = [
    "All messages…",
    "{count} message in total",
    "All {count} messages",
    "Assistant",
    "Browse every message or jump to an exact message number",
    "Choose and configure a provider when runtime integration is installed.",
    "Clear conversation search",
    "Code",
    "Complete",
    "Connect a provider in Settings to send messages.",
    "Connected",
    "Connecting…",
    "Connection failed",
    "Conversation map",
    "Conversation map help",
    "Conversation not loaded",
    "Conversation transcript",
    "Conversations",
    "Copied",
    "Copied to clipboard",
    "Copy code",
    "Copy failed",
    "Copy message",
    "Create and select a new conversation",
    "Creating…",
    "DEMO — read-only sample data",
    "Demo · Read only",
    "Disconnected",
    "Dismiss error",
    "Dismiss selection error",
    "Done",
    "DurableChat application shell",
    "Empty message",
    "Enter / ⌘Enter to send · Shift+Enter for a new line\nConfirm IME composition before sending.",
    "Enter or Command+Enter sends committed text. Shift+Enter inserts a new line. Confirm IME composition before sending.",
    "Every message is included, from top (oldest) to bottom (newest). The four lanes show System, User, Assistant, and Tool messages. Height and width encode compressed UTF-8 text length, not measured transcript height. Very dense messages occupy subpixels.\n\nThe outlined band is the transcript’s visible range. The dotted line is the keyboard target; it can differ while a jump is pending. Click to jump. Up/Down, Page Up/Down, and Home/End jump through messages. Return or Space repeats a jump. Tab leaves the map. Open All messages for an accessible list and exact message-number navigation.",
    "Failed",
    "Go",
    "Hover to preview. Click to jump.\n↑ ↓ navigate · Home / End",
    "How can I help?",
    "Jump to latest message",
    "Latest",
    "Loading messages…",
    "Message",
    "Message number",
    "Message number (1–{count})",
    "Message {current} of {total}, {role}, {bytes} UTF-8 bytes, {status}",
    "Message {number}, {role}, {bytes} UTF-8 bytes, {status}. {preview}",
    "New conversation",
    "No backend connected",
    "No conversations yet",
    "No matches",
    "No messages yet",
    "No model selected",
    "None",
    "Responding…",
    "Response failed",
    "Response in progress",
    "Response stopped",
    "Sample conversations. Sending and creating conversations are disabled.",
    "Search conversations",
    "Select a conversation",
    "Select a conversation or create a new one to get started.",
    "Selected model",
    "Send",
    "Sending…",
    "Show or hide conversations",
    "Show transcript overview",
    "Start a conversation",
    "Stop",
    "Stop response",
    "Stopped",
    "Stopping…",
    "Streaming",
    "System",
    "Toggle conversations sidebar",
    "Tool",
    "Transcript overview",
    "Try another conversation title.",
    "Untitled conversation",
    "Up and Down navigate every message. Home and End jump to the ends. Return repeats a jump. Use All messages for individual messages and exact message numbers.",
    "User",
    "Viewing {first}–{last} of {total}",
    "Visible range unavailable",
    "Waiting for response…",
    "Waiting for the backend connection.",
    "Waiting for the backend to load this conversation.",
    "Write a message below when your provider and model are ready.",
    "You",
    "Your conversations will appear here.",
    "{conversations}; {messages}.",
    "{count} message · entire history",
    "{count} message. Visible range unavailable.",
    "{count} messages · entire history",
    "{count} messages. Visible range unavailable.",
    "{count} sample conversation",
    "{count} sample conversations",
    "{count} sample message",
    "{count} sample messages",
    "{language} code block, horizontally scrollable",
    "{number} · {role} · {bytes} bytes · {status}",
    "{number} · {role} · {status}",
    "{role} message",
    "{title}. {detail}",
]

@Test func allFourChatUITablesMatchAuditedKeysAndNamedFormats() throws {
    #expect(LocalizationValidation.issues(tables: [.chatUI]).isEmpty)
    for language in AppLanguage.allCases {
        #expect(LocalizationValidation.keys(table: .chatUI, language: language) == chatUIKeys)
        let localizer = Localizer(language: language)
        for key in chatUIKeys {
            let names = try #require(LocalizationTemplate.placeholders(in: key))
            let arguments = Dictionary(uniqueKeysWithValues: names.map { ($0, LocalizationArgument.string("verbatim {x} %n 日本語")) })
            let resolution = localizer.resolve(LocalizedMessage(key, table: .chatUI, arguments: arguments))
            #expect(resolution.source == .localized, "Missing or invalid \(language.rawValue): \(key)")
            // Full source-copy fill cannot masquerade as translated non-English prose.
            if language != .english, names.isEmpty { #expect(resolution.text != key) }
        }
    }
}

@Test func chatPresentationUsesExplicitLocaleCountsRolesAndVerbatimValues() {
    let expected = ["Send", "送信", "发送", "전송"]
    for (index, language) in AppLanguage.allCases.enumerated() {
        let localizer = Localizer(language: language)
        #expect(localizer.chat("Send") == expected[index])
        #expect(ConnectionPresentation(.connecting, localizer: localizer).title == localizer.chat("Connecting…"))
        #expect(ConnectionPresentation(.failed("unknown {provider} %n"), localizer: localizer).detail == "unknown {provider} %n")
        #expect(localizer.role(.user) == localizer.chat("User"))
        #expect(localizer.role(.user, userIsYou: true) == localizer.chat("You"))
        for status in [MessageStatus.complete, .streaming, .stopped, .failed] {
            #expect(!localizer.status(status).isEmpty)
        }
        for count in [0, 1, 2, 10_000] {
            let actual = localizer.chatCount(count, one: "{count} message · entire history", other: "{count} messages · entire history")
            let key = language == .english && count == 1 ? "{count} message · entire history" : "{count} messages · entire history"
            #expect(actual == localizer.chat(key, ["count": .integer(count)]))
            #expect(actual.contains(count.formatted(.number.locale(localizer.locale))))
        }
        let saved = ConversationSummary(id: ConversationID("saved"), title: "New conversation {count} %n")
        #expect(ConversationFilter.title(saved, localizer: localizer) == saved.title)
        let blank = ConversationSummary(id: ConversationID("blank"), title: " ")
        #expect(ConversationFilter.title(blank, localizer: localizer) == localizer.chat("Untitled conversation"))
        #expect(ConversationFilter.matching([blank], query: localizer.chat("Untitled conversation"), localizer: localizer) == [blank])
    }
    let regional = Localizer(locale: Locale(identifier: "en_GB"))
    #expect(regional.chat("Message number (1–{count})", ["count": .integer(10_000)]) == "Message number (1–10,000)")
    // Legacy pure-logic callers keep their English default.
    #expect(ConnectionPresentation(.connected).title == "Connected")
}
