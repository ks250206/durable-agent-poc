import AppKit
import AppLocalization
import ChatCore
import SwiftUI

private typealias StoredState<Value> = SwiftUI.State<Value>

/// Lightweight block parsing around Foundation's inline Markdown renderer. Unclosed fences
/// remain code while streaming. Source text is always retained for lossless message copy.
enum MessageBlock: Equatable {
    case paragraph(String)
    case heading(Int, String)
    case quote(String)
    case listItem(String, String)
    case code(language: String?, text: String)
    case divider

    static func parse(_ source: String) -> [MessageBlock] {
        var blocks: [MessageBlock] = []
        var paragraph: [String] = []
        var code: [String] = []
        var fence: (character: Character, count: Int, language: String?)?

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }

        for line in source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let current = fence {
                let run = trimmed.prefix(while: { $0 == current.character })
                if run.count >= current.count && trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces).isEmpty {
                    blocks.append(.code(language: current.language, text: code.joined(separator: "\n") + (code.isEmpty ? "" : "\n")))
                    code = []
                    fence = nil
                } else { code.append(line) }
                continue
            }
            if let character = trimmed.first, character == "`" || character == "~" {
                let count = trimmed.prefix(while: { $0 == character }).count
                let info = trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces)
                if count >= 3 && (character != "`" || !info.contains("`")) {
                    flushParagraph()
                    fence = (character, count, info.split(whereSeparator: { $0.isWhitespace }).first.map(String.init))
                    continue
                }
            }
            if trimmed.isEmpty { flushParagraph(); continue }
            let headingLevel = trimmed.prefix(while: { $0 == "#" }).count
            if (1...6).contains(headingLevel), trimmed.dropFirst(headingLevel).first == " " {
                flushParagraph()
                blocks.append(.heading(headingLevel, String(trimmed.dropFirst(headingLevel + 1))))
            } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph(); blocks.append(.divider)
            } else if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph(); blocks.append(.quote(String(trimmed.dropFirst(min(2, trimmed.count)))))
            } else if ["- ", "* ", "+ "].contains(where: { trimmed.hasPrefix($0) }) {
                flushParagraph(); blocks.append(.listItem("•", String(trimmed.dropFirst(2))))
            } else if let range = trimmed.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                flushParagraph()
                blocks.append(.listItem(String(trimmed[range]).trimmingCharacters(in: .whitespaces), String(trimmed[range.upperBound...])))
            } else { paragraph.append(line) }
        }
        flushParagraph()
        if let fence { blocks.append(.code(language: fence.language, text: code.joined(separator: "\n"))) }
        return blocks
    }
}

enum MessageLinkPolicy {
    static func allows(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "")
    }
}

@MainActor
public struct MessageRow: View {
    @ChatLocalization private var localization
    public let message: ChatMessage

    public init(message: ChatMessage) { self.message = message }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: roleSymbol).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(roleTitle).font(.headline)
                Spacer(minLength: 4)
                CopyTextButton(text: message.content, label: localization.chat("Copy message"))
            }
            VStack(alignment: .leading, spacing: 12) {
                if message.content.isEmpty {
                    Text(message.status == .streaming ? localization.chat("Waiting for response…") : localization.chat("Empty message"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(MessageBlock.parse(message.content).enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }
                }
            }
            .font(.body).lineSpacing(4).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let status = statusLabel {
                Label(status.title, systemImage: status.symbol)
                    .font(.caption).foregroundStyle(message.status == .failed ? Color.red : Color.secondary)
            }
        }
        .padding(16)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(message.role == .user ? Color.primary.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 16))
        .environment(\.openURL, OpenURLAction { url in
            MessageLinkPolicy.allows(url) ? .systemAction : .discarded
        })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localization.chat("{role} message", ["role": .string(roleTitle)]))
        .accessibilityIdentifier("message.\(message.id.rawValue)")
    }

    @ViewBuilder private func blockView(_ block: MessageBlock) -> some View {
        switch block {
        case .paragraph(let text): inline(text).fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            inline(text).font(level <= 2 ? .title2.bold() : .headline)
                .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
        case .quote(let text):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(ChatTheme.separator).frame(width: 3)
                inline(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.fixedSize(horizontal: false, vertical: true)
        case .listItem(let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).foregroundStyle(.secondary)
                inline(text).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            }
        case .code(let language, let text): CodeBlockView(language: language, text: text)
        case .divider: Divider()
        }
    }

    private func inline(_ source: String) -> Text {
        let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        return Text(parsed ?? AttributedString(source))
    }

    private var roleTitle: String {
        localization.role(message.role, userIsYou: true)
    }
    private var roleSymbol: String {
        switch message.role {
        case .user: "person.crop.circle"
        case .assistant: "sparkle"
        case .system: "gearshape"
        case .tool: "wrench.and.screwdriver"
        }
    }
    private var statusLabel: (title: String, symbol: String)? {
        switch message.status {
        case .complete: nil
        case .streaming: (localization.chat("Responding…"), "ellipsis")
        case .stopped: (localization.chat("Response stopped"), "stop.circle")
        case .failed: (localization.chat("Response failed"), "exclamationmark.triangle")
        }
    }
}

@MainActor
private struct CodeBlockView: View {
    @ChatLocalization private var localization
    let language: String?
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? localization.chat("Code")).font(.caption.monospaced()).lineLimit(1)
                Spacer(minLength: 8)
                CopyTextButton(text: text, label: localization.chat("Copy code"))
            }.padding(10)
            Divider()
            ScrollView(.horizontal) {
                Text(verbatim: text).font(.system(.body, design: .monospaced))
                    .lineSpacing(3).textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
            }
            .accessibilityLabel(localization.chat("{language} code block, horizontally scrollable", ["language": .string(language ?? localization.chat("Code"))]))
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(ChatTheme.inset, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ChatTheme.separator, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

@MainActor
struct CopyTextButton: View {
    @ChatLocalization private var localization
    let text: String
    let label: String
    private let pasteboard: NSPasteboard
    @StoredState private var copied = false

    init(text: String, label: String, pasteboard: NSPasteboard = .general) {
        self.text = text
        self.label = label
        self.pasteboard = pasteboard
    }

    var body: some View {
        Button {
            pasteboard.clearContents()
            copied = pasteboard.setString(text, forType: .string)
            NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                                 userInfo: [.announcement: copied ? localization.chat("Copied to clipboard") : localization.chat("Copy failed"),
                                            .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        } label: { Label(copied ? localization.chat("Copied") : label, systemImage: copied ? "checkmark" : "doc.on.doc").labelStyle(.iconOnly) }
        .buttonStyle(.borderless).accessibilityLabel(copied ? localization.chat("Copied to clipboard") : label)
        .help(copied ? localization.chat("Copied") : label)
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(2)); copied = false } catch {}
        }
    }
}
