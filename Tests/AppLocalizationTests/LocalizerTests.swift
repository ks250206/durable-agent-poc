import AppLocalization
import Foundation
import Testing

/// Unique on-disk bundles exercise real Foundation lookup and per-key fallback, not mock dictionaries.
struct TestCatalog {
    let url: URL
    let bundle: Bundle

    init(table: LocalizationTable = .common, entries: [AppLanguage: [String: String]]) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("Localization-\(UUID()).bundle")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "tests.\(UUID())", "CFBundleDevelopmentRegion": "en"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Info.plist"))
        for (language, strings) in entries {
            let folder = url.appendingPathComponent("\(language.resourceIdentifier).lproj")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: strings, format: .xml, options: 0)
                .write(to: folder.appendingPathComponent("\(table.rawValue).strings"))
        }
        bundle = try #require(Bundle(url: url))
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

@Test func genuineModuleResourcesAndExplicitLocales() throws {
    let translations: [AppLanguage: String] = [.english: "Language", .japanese: "言語", .simplifiedChinese: "语言", .korean: "언어"]
    for language in AppLanguage.allCases {
        let localizer = Localizer(language: language)
        #expect(localizer.string("Language") == translations[language])
        #expect(localizer.resolve(LocalizedMessage("Language")).source == .localized)
        #expect(localizer.bundle.bundleURL.lastPathComponent.lowercased() == "\(language.resourceIdentifier).lproj".lowercased())
        #expect(localizer.bundle.localizedString(forKey: "Language", value: nil, table: "Common") == translations[language])
        #expect(localizer.locale == language.locale)
        #expect(LocalizationValidation.keys(table: .common, language: language).count == 10)
    }
    #expect(Set(Localizer.resources.localizations.map { $0.lowercased() }).isSuperset(of: ["en", "ja", "zh-hans", "ko"]))
    #expect(LocalizationValidation.issues().isEmpty)
    #expect(LocalizationValidation.keys(table: .common).contains("Reset to System"))
    // Follow-up tables must not masquerade as complete with English placeholder translations.
    for table in [LocalizationTable.chatUI, .runtime, .app] {
        #expect(LocalizationValidation.keys(table: table).isEmpty)
        #expect(LocalizationValidation.issues(tables: [table]).count == 4)
    }
    let regional = Localizer(locale: Locale(identifier: "en_GB"))
    #expect(regional.language == .english)
    #expect(regional.locale.identifier == "en_GB")
    #expect(Localizer(locale: Locale(identifier: "ja_JP")).string("Language") == "言語")
    let unsupported = Localizer(locale: Locale(identifier: "zh_Hant_TW"))
    #expect(unsupported.language == .english)
    #expect(unsupported.locale == AppLanguage.english.locale)
    #expect(unsupported.string("Language") == "Language")
}

@Test func explicitFallbackForMissingKeyTableBundleAndBadTranslation() throws {
    let catalog = try TestCatalog(entries: [
        .english: ["English only": "English only", "hello": "Hello, {name}", "Same": "Same", "empty": ""],
        .japanese: ["hello": "こんにちは、{wrong}", "Same": "同じ", "empty": ""],
    ])
    defer { catalog.remove() }
    let localizer = Localizer(language: .japanese, resources: catalog.bundle)
    #expect(localizer.string("English only") == "English only")
    #expect(localizer.resolve(LocalizedMessage("English only")).source == .englishFallback)
    #expect(localizer.resolve(LocalizedMessage("Same")).source == .localized)
    #expect(localizer.string("Same") == "同じ")
    #expect(localizer.string("empty").isEmpty)
    let hello = LocalizedMessage("hello", arguments: ["name": .string("Ada")])
    #expect(localizer.string(hello) == "Hello, Ada")
    #expect(localizer.resolve(hello).source == .englishFallback)
    let missing = LocalizedMessage("stable.id", table: .app, fallback: "Ready, {name}", arguments: ["name": .string("Ada")])
    #expect(localizer.string(missing) == "Ready, Ada")
    #expect(localizer.resolve(missing).source == .sourceFallback)
    #expect(localizer.string("Unknown English message", table: .runtime) == "Unknown English message")
    #expect(localizer.resolve(LocalizedMessage("Unknown English message")).source == .keyFallback)
    let absentLocale = Localizer(language: .korean, resources: catalog.bundle)
    #expect(absentLocale.string("Same") == "Same")
    #expect(absentLocale.resolve(LocalizedMessage("Same")).source == .englishFallback)
}

@Test func namedInterpolationNumbersEscapesAndCountSelection() throws {
    let catalog = try TestCatalog(entries: [
        .english: ["progress": "{current} of {total}: {name} ({fraction}%)", "braces": "{{{value}}}",
                   "one": "{count} message", "other": "{count} messages"],
        .japanese: ["progress": "{name}：全{total}件中{current}件（{fraction}%）", "braces": "{{{value}}}",
                    "one": "単数は使わない", "other": "{count}件のメッセージ"],
    ])
    defer { catalog.remove() }
    let english = Localizer(locale: Locale(identifier: "en_US"), resources: catalog.bundle)
    let japanese = Localizer(language: .japanese, resources: catalog.bundle)
    let values: [String: LocalizationArgument] = ["current": .integer(1_234), "total": .integer(5_678),
                                                "name": .string("x {total} %s 🧪"), "fraction": .decimal(12.5)]
    #expect(english.string("progress", arguments: values) == "1,234 of 5,678: x {total} %s 🧪 (12.5%)")
    #expect(japanese.string("progress", arguments: values) == "x {total} %s 🧪：全5,678件中1,234件（12.5%）")
    #expect(english.string("braces", arguments: ["value": .string("{raw}")]) == "{{raw}}")
    for count in [0, 1, 2, 1_000] {
        let plural = LocalizedMessage.plural(count: count,
            one: LocalizedMessage("one", arguments: ["count": .integer(count)]),
            other: LocalizedMessage("other", arguments: ["count": .integer(count)]))
        #expect(english.string(plural) == "\(count.formatted(.number.locale(english.locale))) \(count == 1 ? "message" : "messages")")
        #expect(japanese.string(plural) == "\(count.formatted(.number.locale(japanese.locale)))件のメッセージ")
    }
    for language in [AppLanguage.simplifiedChinese, .korean] {
        let localizer = Localizer(language: language, resources: catalog.bundle)
        #expect(localizer.string(.plural(count: 1, one: LocalizedMessage("one"), other: LocalizedMessage("other", arguments: ["count": .integer(1)]))) == "1 messages")
    }
    #expect(LocalizationTemplate.placeholders(in: "{b} {a} {a} {{literal}}") == ["a", "b"])
    for malformed in ["{", "}", "{bad name}", "{}", "{nested{value}}"] {
        #expect(LocalizationTemplate.placeholders(in: malformed) == nil)
    }
    // Invalid caller contracts are safe and explicit; the coverage validator catches translation defects.
    #expect(english.string("hello {missing}", arguments: ["wrong": .string("x")]) == "hello {missing}")
    #expect(english.string("%d %@ %n") == "%d %@ %n")
}

@Test func backgroundDiagnosticsAreSendableExactAndRemainRelocalizable() async throws {
    let catalog = try TestCatalog(table: .runtime, entries: [
        .english: ["Disconnected.": "Disconnected.", "Failure {id}": "Failure {id}"],
        .japanese: ["Disconnected.": "接続されていません。", "Failure {id}": "エラー {id}"],
    ])
    defer { catalog.remove() }
    let japanese = Localizer(language: .japanese, resources: catalog.bundle)
    let english = Localizer(language: .english, resources: catalog.bundle)
    let message = await Task.detached { LocalizedMessage("Failure {id}", table: .runtime, arguments: ["id": .integer(42)]) }.value
    #expect(await Task.detached { japanese.diagnostic("Disconnected.") }.value == "接続されていません。")
    #expect(japanese.string(message) == "エラー 42")
    #expect(english.string(message) == "Failure 42")
    for unknown in ["provider: {raw} %n", "model/ja-JP", "Disconnected. extra", "ユーザーの本文"] {
        #expect(japanese.diagnostic(unknown) == unknown)
    }
    #expect(japanese.diagnostic("Failure {id}") == "Failure {id}")
}

@Test func validatorFindsKeyAndFormatCoverageFailures() throws {
    let catalog = try TestCatalog(entries: [
        .english: ["a": "A {count}", "b": "B", "c": "C", "broken": "{"],
        .japanese: ["a": "A {wrong}", "b": "{", "extra": "Extra"],
    ])
    defer { catalog.remove() }
    let issues = LocalizationValidation.issues(resources: catalog.bundle)
    #expect(issues.contains { $0.language == .japanese && $0.key == "a" && $0.kind == .placeholderMismatch })
    #expect(issues.contains { $0.language == .japanese && $0.key == "b" && $0.kind == .invalidTemplate })
    #expect(issues.contains { $0.language == .japanese && $0.key == "c" && $0.kind == .missingKey })
    #expect(issues.contains { $0.language == .japanese && $0.key == "extra" && $0.kind == .unexpectedKey })
    #expect(issues.contains { $0.language == .english && $0.key == "broken" && $0.kind == .invalidTemplate })
    #expect(issues.filter { $0.kind == .missingOrInvalidTable }.map(\.language) == [.simplifiedChinese, .korean])
    let localizer = Localizer(language: .japanese, resources: catalog.bundle)
    #expect(localizer.string("a", arguments: ["count": .integer(2)]) == "A 2")
    #expect(localizer.string("b") == "B")
}

@Test func interpolatedStringDiagnosticsNeedOnlyAnExplicitPresentationAdapter() throws {
    let source = "Model selected. Send with {provider}."
    let exact = "Model selected. Send with stable."
    let catalog = try TestCatalog(table: .runtime, entries: [
        .english: [source: source, exact: exact], .japanese: [source: "{provider}で送信できます。", exact: exact],
    ])
    defer { catalog.remove() }
    let localizer = Localizer(language: .japanese, resources: catalog.bundle)
    let template = DiagnosticTemplate(source)
    let diagnostic = "Model selected. Send with 🧪 %s {code}."
    #expect(localizer.diagnostic(diagnostic) == diagnostic)
    #expect(localizer.diagnostic(diagnostic, templates: [template]) == "🧪 %s {code}で送信できます。")
    #expect(localizer.diagnostic(exact, templates: [template]) == exact)
    #expect(localizer.diagnostic("Unknown provider failure.", templates: [template]) == "Unknown provider failure.")
    #expect(template.message(matching: "prefix " + diagnostic) == nil)
    #expect(template.message(matching: diagnostic + " suffix") == nil)
    #expect(DiagnosticTemplate("{a}{b}").message(matching: "abc") == nil)
    #expect(DiagnosticTemplate("{a}").message(matching: "abc") == nil)
    #expect(DiagnosticTemplate("{a} = {a}").message(matching: "x = y") == nil)
    #expect(DiagnosticTemplate("{a} = {a}").message(matching: "x = x") != nil)
    #expect(DiagnosticTemplate("Broken {a").message(matching: "anything") == nil)
}

@Test func malformedEnglishEntryDoesNotDisableValidFallbackInterpolation() throws {
    let catalog = try TestCatalog(entries: [
        .english: ["greeting": "Hello {broken", "Hello {name}": "Hello {broken"],
        .japanese: ["greeting": "こんにちは {wrong}", "Hello {name}": "こんにちは {broken"],
    ])
    defer { catalog.remove() }
    for language in AppLanguage.allCases {
        let localizer = Localizer(language: language, resources: catalog.bundle)
        let fallback = LocalizedMessage("greeting", fallback: "Hello {name}", arguments: ["name": .string("Ada")])
        #expect(localizer.string(fallback) == "Hello Ada")
        #expect(localizer.resolve(fallback).source == .sourceFallback)
        let key = LocalizedMessage("Hello {name}", arguments: ["name": .string("Ada")])
        #expect(localizer.string(key) == "Hello Ada")
        #expect(localizer.resolve(key).source == .keyFallback)
    }
    // Valid English still defines the contract: a caller can't replace its placeholder set.
    let valid = try TestCatalog(entries: [.english: ["greeting": "Hello {name}"]])
    defer { valid.remove() }
    #expect(Localizer(language: .english, resources: valid.bundle).string(
        "greeting", fallback: "Hello {other}", arguments: ["other": .string("Ada")]) == "Hello {other}")
}
