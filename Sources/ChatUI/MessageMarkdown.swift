import Foundation

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
        var code = ""
        var fence: (character: Character, count: Int, language: String?)?

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }

        let lines = source.components(separatedBy: "\n")
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let current = fence {
                let run = trimmed.prefix(while: { $0 == current.character })
                if run.count >= current.count && trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces).isEmpty {
                    blocks.append(.code(language: current.language, text: code))
                    code = ""
                    fence = nil
                } else { code += rawLine + (index < lines.count - 1 ? "\n" : "") }
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
        if let fence { blocks.append(.code(language: fence.language, text: code)) }
        return blocks
    }
}

enum MessageLinkPolicy {
    static func allows(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "")
    }
}

