import AppLocalization
import Foundation

/// Uses the same parser/lookup/validation contracts as the app, with an independent audited
/// manifest so deleting a key in every locale cannot masquerade as parity success.
struct ResourceAudit {
    static func issues(resources: Bundle, manifest: [String: [String]]) -> [String] {
        let tables = LocalizationTable.allCases
        var problems = LocalizationValidation.issues(tables: tables, resources: resources).map {
            "\($0.language.resourceIdentifier)/\($0.table.rawValue) \($0.key ?? "<table>"): \($0.kind)"
        }
        if resources.bundleURL.pathExtension == "bundle", resources.developmentLocalization != "en" {
            problems.append("Resource bundle development localization must be en")
        }
        if Set(manifest.keys) != Set(tables.map(\.rawValue)) { problems.append("Invalid inventory tables") }
        let fileManager = FileManager.default
        if let root = resources.resourceURL,
           let files = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let actualLocales = Set(files.filter { $0.pathExtension == "lproj" }.map { $0.deletingPathExtension().lastPathComponent })
            if actualLocales != Set(AppLanguage.allCases.map(\.resourceIdentifier)) {
                problems.append("Resource language directories differ from AppLanguage")
            }
        } else { problems.append("Cannot enumerate resource directory") }
        for language in AppLanguage.allCases {
            guard let url = resources.url(forResource: language.resourceIdentifier, withExtension: "lproj"),
                  let files = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { continue }
            let actualTables = Set(files.filter { $0.pathExtension == "strings" }.map { $0.deletingPathExtension().lastPathComponent })
            if actualTables != Set(tables.map(\.rawValue)) {
                problems.append("\(language.resourceIdentifier): resource table files differ from LocalizationTable")
            }
            if files.contains(where: { $0.pathExtension == "stringsdict" }) {
                problems.append("\(language.resourceIdentifier): stringsdict requires extending the template contract")
            }
        }
        for table in tables {
            let keys = manifest[table.rawValue] ?? []
            if keys.isEmpty || Set(keys).count != keys.count || keys.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                problems.append("\(table.rawValue): empty or duplicate audited keys")
            }
            for language in AppLanguage.allCases {
                let prefix = "\(language.resourceIdentifier)/\(table.rawValue)"
                let actual = LocalizationValidation.keys(table: table, language: language, resources: resources)
                for key in Set(keys).subtracting(actual).sorted() { problems.append("\(prefix): missing audited key \(key)") }
                for key in actual.subtracting(keys).sorted() { problems.append("\(prefix): extra audited key \(key)") }
                guard let url = resources.url(forResource: language.resourceIdentifier, withExtension: "lproj"),
                      let bundle = Bundle(url: url),
                      let file = bundle.url(forResource: table.rawValue, withExtension: "strings"),
                      let data = try? Data(contentsOf: file),
                      let entries = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
                else { continue } // Existing contract already reports malformed/missing tables.
                let localizer = Localizer(language: language, resources: resources)
                for key in keys.sorted() {
                    guard let value = entries[key] else { continue }
                    if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        problems.append("\(prefix): empty value \(key)")
                    }
                    guard let names = LocalizationTemplate.placeholders(in: key) else {
                        problems.append("\(prefix): malformed source key \(key)"); continue
                    }
                    if LocalizationTemplate.placeholders(in: value) != names {
                        problems.append("\(prefix): source placeholder mismatch \(key)")
                    }
                    let arguments = Dictionary(uniqueKeysWithValues: names.map {
                        ($0, LocalizationArgument.string("verbatim-{raw}-%n-日本語"))
                    })
                    let resolved = localizer.resolve(LocalizedMessage(key, table: table, arguments: arguments))
                    if resolved.source != .localized || resolved.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        problems.append("\(prefix): actual lookup failed \(key)")
                    }
                    // Independent Foundation lookup of this exact lproj, without Localizer fallback.
                    if bundle.localizedString(forKey: key, value: "<missing-audit-key>", table: table.rawValue) != value {
                        problems.append("\(prefix): Foundation lookup differs \(key)")
                    }
                }
            }
        }
        return problems.sorted()
    }
}
