import AppLocalization
import Foundation
import Testing
@testable import LocalizationAudit

private struct AuditInventory: Decodable { let tables: [String: [String]] }
private let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Test func aggregateResourceAuditRejectsBrokenTablesAndAllLocaleManifestDrift() throws {
    let manifest = try JSONDecoder().decode(AuditInventory.self,
        from: Data(contentsOf: repositoryRoot.appendingPathComponent("scripts/localization/inventory.json"))).tables
    #expect(ResourceAudit.issues(resources: Localizer.resources, manifest: manifest).isEmpty)
    // Each mutation gets its own Bundle URL: Foundation caches resource lookups per bundle.
    let mutations: [(String, (URL) throws -> Void)] = [
        ("missing audited key", { root in try mutateTable(root, language: "ja") { $0.removeValue(forKey: "Send") } }),
        ("extra audited key", { root in try mutateTable(root, language: "ko") { $0["Unknown key"] = "unexpected" } }),
        ("empty value", { root in try mutateTable(root, language: "zh-Hans") { $0["Send"] = " \n " } }),
        ("invalidTemplate", { root in try mutateTable(root, language: "en") { $0["Send"] = "Broken {" } }),
        ("placeholderMismatch", { root in try mutateTable(root, language: "ja") { $0["Message number (1–{count})"] = "{wrong}" } }),
        // English drift in every locale must fail independently of resource-to-resource parity.
        ("missing audited key", { root in
            for language in ["en", "ja", "zh-Hans", "ko"] {
                try mutateTable(root, language: language) { $0.removeValue(forKey: "Send") }
            }
        }),
        ("source placeholder mismatch", { root in
            for language in ["en", "ja", "zh-Hans", "ko"] {
                try mutateTable(root, language: language) { $0["Message number (1–{count})"] = "Changed {wrong}" }
            }
        }),
        ("missingOrInvalidTable", { root in try Data("not a property list".utf8).write(to: root.appendingPathComponent("ko.lproj/App.strings")) }),
        ("missingOrInvalidTable", { root in try FileManager.default.removeItem(at: root.appendingPathComponent("zh-Hans.lproj/Runtime.strings")) }),
        ("resource table files differ", { root in try Data("\"Extra\" = \"value\";".utf8).write(to: root.appendingPathComponent("en.lproj/Unregistered.strings")) }),
        ("language directories differ", { root in try FileManager.default.createDirectory(at: root.appendingPathComponent("unexpected.lproj"), withIntermediateDirectories: true) }),
    ]
    for (expected, mutate) in mutations {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalizationAudit-\(UUID()).bundle")
        try FileManager.default.copyItem(at: repositoryRoot.appendingPathComponent("Sources/AppLocalization/Resources"), to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        try mutate(root)
        let resources = try #require(Bundle(url: root))
        let issues = ResourceAudit.issues(resources: resources, manifest: manifest)
        #expect(issues.contains { $0.contains(expected) }, "Missing expected audit failure \(expected): \(issues)")
    }
}

private func mutateTable(_ root: URL, language: String, _ mutate: (inout [String: String]) -> Void) throws {
    let url = root.appendingPathComponent("\(language).lproj/ChatUI.strings")
    var entries = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
    mutate(&entries)
    try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0).write(to: url)
}

@Test func auditedResourceInventoryCanGrowWhileUnregisteredKeysStillFail() throws {
    var manifest = try JSONDecoder().decode(AuditInventory.self,
        from: Data(contentsOf: repositoryRoot.appendingPathComponent("scripts/localization/inventory.json"))).tables
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalizationAudit-Growth-\(UUID()).bundle")
    try FileManager.default.copyItem(at: repositoryRoot.appendingPathComponent("Sources/AppLocalization/Resources"), to: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let info = ["CFBundleDevelopmentRegion": "en", "CFBundleIdentifier": "test.LocalizationAudit.\(UUID())"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: root.appendingPathComponent("Info.plist"))
    let addedKey = "Future presentation {name}"
    for language in ["en", "ja", "zh-Hans", "ko"] {
        try mutateTable(root, language: language) { $0[addedKey] = "\(language) presentation {name}" }
    }
    let bundle = try #require(Bundle(url: root))
    #expect(ResourceAudit.issues(resources: bundle, manifest: manifest).contains { $0.contains("extra audited key") })
    manifest["ChatUI", default: []].append(addedKey)
    #expect(ResourceAudit.issues(resources: bundle, manifest: manifest).isEmpty)
    // A new table also needs the owning LocalizationTable contract extended; typos cannot pass.
    manifest["UnregisteredTable"] = [addedKey]
    #expect(ResourceAudit.issues(resources: bundle, manifest: manifest).contains("Invalid inventory tables"))
}
