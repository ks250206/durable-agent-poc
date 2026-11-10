import Foundation

public struct LocalizationIssue: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case missingOrInvalidTable, missingKey, unexpectedKey, invalidTemplate, placeholderMismatch
    }
    public let language: AppLanguage
    public let table: LocalizationTable
    public let key: String?
    public let kind: Kind
}

public enum LocalizationValidation {
    /// English is the source-of-truth key/placeholder manifest. Missing/unparseable tables fail.
    /// Follow-up owners call this with their table(s), never omit failures for incomplete locales.
    public static func issues(tables: [LocalizationTable] = [.common],
                              resources: Bundle = Localizer.resources) -> [LocalizationIssue] {
        var issues: [LocalizationIssue] = []
        for table in tables {
            let source = entries(language: .english, table: table, resources: resources)
            for language in AppLanguage.allCases {
                guard let entries = entries(language: language, table: table, resources: resources) else {
                    issues.append(LocalizationIssue(language: language, table: table, key: nil, kind: .missingOrInvalidTable))
                    continue
                }
                let source = source ?? [:]
                for key in Set(source.keys).subtracting(entries.keys).sorted() {
                    issues.append(LocalizationIssue(language: language, table: table, key: key, kind: .missingKey))
                }
                for key in Set(entries.keys).subtracting(source.keys).sorted() {
                    issues.append(LocalizationIssue(language: language, table: table, key: key, kind: .unexpectedKey))
                }
                for key in entries.keys.sorted() {
                    guard let value = entries[key] else { continue }
                    guard let names = LocalizationTemplate.placeholders(in: value) else {
                        issues.append(LocalizationIssue(language: language, table: table, key: key, kind: .invalidTemplate))
                        continue
                    }
                    if let original = source[key], let sourceNames = LocalizationTemplate.placeholders(in: original), names != sourceNames {
                        issues.append(LocalizationIssue(language: language, table: table, key: key, kind: .placeholderMismatch))
                    }
                }
            }
        }
        return issues
    }

    /// Also permits tests to assert a required set of source keys, including dynamic call sites.
    public static func keys(table: LocalizationTable, language: AppLanguage = .english,
                            resources: Bundle = Localizer.resources) -> Set<String> {
        Set(entries(language: language, table: table, resources: resources)?.keys.map { $0 } ?? [])
    }

    private static func entries(language: AppLanguage, table: LocalizationTable, resources: Bundle) -> [String: String]? {
        guard let bundle = Localizer.languageBundle(language, resources: resources),
              let url = bundle.url(forResource: table.rawValue, withExtension: "strings"),
              let data = try? Data(contentsOf: url),
              let entries = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
              !entries.isEmpty else { return nil }
        return entries
    }
}
