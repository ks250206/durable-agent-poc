import Foundation

/// Opt-in adapter for app-owned interpolated English diagnostics carried as plain String.
/// Register only known source templates at presentation; never apply to conversation/model text.
public struct DiagnosticTemplate: Equatable, Sendable {
    public let source: String
    public let key: String
    public let table: LocalizationTable

    public init(_ source: String, key: String? = nil, table: LocalizationTable = .runtime) {
        self.source = source
        self.key = key ?? source
        self.table = table
    }

    /// Exact full-string match. Captures stay verbatim strings, including IDs and percent/braces.
    /// Malformed, adjacent, conflicting repeated, and all-capture patterns fail closed.
    public func message(matching diagnostic: String) -> LocalizedMessage? {
        guard let parts = LocalizationTemplate.parse(source) else { return nil }
        var pattern = "\\A"
        var names: [String] = []
        var previousWasArgument = false
        var hasLiteral = false
        for part in parts {
            switch part {
            case .literal(let literal):
                pattern += NSRegularExpression.escapedPattern(for: literal)
                if !literal.isEmpty { previousWasArgument = false; hasLiteral = true }
            case .argument(let name):
                guard !previousWasArgument else { return nil }
                pattern += "(.*?)"
                names.append(name)
                previousWasArgument = true
            }
        }
        guard hasLiteral else { return nil }
        pattern += "\\z"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators),
              let match = regex.firstMatch(in: diagnostic, range: NSRange(diagnostic.startIndex..., in: diagnostic)) else { return nil }
        var arguments: [String: LocalizationArgument] = [:]
        for (index, name) in names.enumerated() {
            guard let range = Range(match.range(at: index + 1), in: diagnostic) else { return nil }
            let argument = LocalizationArgument.string(String(diagnostic[range]))
            if let previous = arguments[name], previous != argument { return nil }
            arguments[name] = argument
        }
        return LocalizedMessage(key, table: table, fallback: source, arguments: arguments)
    }
}

extension Localizer {
    /// Static exact keys take precedence; patterns are an explicit allowlist in caller order.
    public func diagnostic(_ source: String, table: LocalizationTable = .runtime,
                           templates: [DiagnosticTemplate]) -> String {
        if let exact = diagnosticMessage(source, table: table) { return string(exact) }
        for template in templates {
            if let message = template.message(matching: source) { return string(message) }
        }
        return source
    }
}

extension LocalizationSettings {
    public func diagnostic(_ source: String, table: LocalizationTable = .runtime,
                           templates: [DiagnosticTemplate]) -> String {
        localizer.diagnostic(source, table: table, templates: templates)
    }
}
