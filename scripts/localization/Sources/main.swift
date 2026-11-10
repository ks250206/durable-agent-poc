import AppLocalization
import Foundation

struct Inventory: Decodable { let tables: [String: [String]] }

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 2 else {
        throw NSError(domain: "LocalizationAudit", code: 2, userInfo: [NSLocalizedDescriptionKey:
            "Usage: LocalizationAudit <inventory.json> <source-resources-directory|resource.bundle>"])
    }
    let manifest = try JSONDecoder().decode(Inventory.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[0])))
    guard let resources = Bundle(path: arguments[1]) else {
        throw NSError(domain: "LocalizationAudit", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot open resource bundle/directory"])
    }
    let issues = ResourceAudit.issues(resources: resources, manifest: manifest.tables)
    for issue in issues { print(issue) }
    guard issues.isEmpty else { exit(1) }
    let languages = AppLanguage.allCases.map(\.resourceIdentifier).joined(separator: "/")
    let counts = LocalizationTable.allCases.map { "\($0.rawValue) \(manifest.tables[$0.rawValue]?.count ?? 0)" }.joined(separator: ", ")
    print("Resource audit passed: \(languages) × \(counts); exact Foundation lookup and app contracts: \(resources.bundlePath)")
} catch {
    FileHandle.standardError.write(Data("Localization audit failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
