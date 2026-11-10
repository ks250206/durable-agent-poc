import Foundation

/// All four tables live in AppLocalization's resource bundle. Owners add only their own tables.
public enum LocalizationTable: String, CaseIterable, Sendable {
    case common = "Common"
    case chatUI = "ChatUI"
    case runtime = "Runtime"
    case app = "App"
}

/// Named interpolation avoids printf type mismatches and allows translation reordering.
/// Values are inserted once, verbatim; user/model/code content is never a localization key.
public enum LocalizationArgument: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case decimal(Double)

    fileprivate func rendered(locale: Locale) -> String {
        switch self {
        case .string(let value): value
        case .integer(let value): value.formatted(.number.locale(locale))
        case .decimal(let value): value.formatted(.number.locale(locale))
        }
    }
}

/// Retain this value until presentation to allow live re-localization of a background diagnostic.
public struct LocalizedMessage: Equatable, Sendable {
    indirect enum Content: Equatable, Sendable {
        case key(String, LocalizationTable, String?, [String: LocalizationArgument])
        case plural(Int, LocalizedMessage, LocalizedMessage)
    }
    let content: Content

    public init(_ key: String, table: LocalizationTable = .common, fallback: String? = nil,
                arguments: [String: LocalizationArgument] = [:]) {
        content = .key(key, table, fallback, arguments)
    }

    private init(content: Content) { self.content = content }

    /// Integer cardinal counts: English uses one only for 1; ja/zh-Hans/ko always use other.
    /// Both branches must supply their own arguments (typically `count: .integer(count)`).
    public static func plural(count: Int, one: Self, other: Self) -> Self {
        Self(content: .plural(count, one, other))
    }
}

/// Grammar: `{name}` placeholders; `{{` and `}}` emit literal braces. Names are ASCII
/// letters/digits/underscore. `%` is ordinary text, never a printf instruction.
public enum LocalizationTemplate {
    enum Part { case literal(String), argument(String) }

    public static func placeholders(in template: String) -> Set<String>? {
        guard let parts = parse(template) else { return nil }
        return Set(parts.compactMap { if case .argument(let name) = $0 { name } else { nil } })
    }

    static func render(_ template: String, arguments: [String: LocalizationArgument], locale: Locale) -> String? {
        guard let parts = parse(template), placeholders(in: template) == Set(arguments.keys) else { return nil }
        return parts.map { part in
            switch part {
            case .literal(let text): text
            case .argument(let name): arguments[name]?.rendered(locale: locale) ?? ""
            }
        }.joined()
    }

    static func parse(_ template: String) -> [Part]? {
        var parts: [Part] = []
        var literal = ""
        var index = template.startIndex
        while index < template.endIndex {
            let character = template[index]
            let next = template.index(after: index)
            if character == "{" || character == "}" {
                if next < template.endIndex, template[next] == character {
                    literal.append(character)
                    index = template.index(after: next)
                    continue
                }
                guard character == "{", let closing = template[next...].firstIndex(of: "}") else { return nil }
                let name = String(template[next..<closing])
                guard !name.isEmpty, name.utf8.allSatisfy({
                    (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95
                }) else { return nil }
                parts.append(.literal(literal))
                literal = ""
                parts.append(.argument(name))
                index = template.index(after: closing)
            } else {
                literal.append(character)
                index = next
            }
        }
        parts.append(.literal(literal))
        return parts
    }
}
