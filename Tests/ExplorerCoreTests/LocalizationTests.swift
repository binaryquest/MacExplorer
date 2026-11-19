import Foundation
import Testing
@testable import ExplorerCore

struct LocalizationTests {
    private static let project = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private let packs = LocalizationCatalog(externalDirectories: [project.appendingPathComponent("Localizations")])
    private let bundled = LocalizationCatalog(externalDirectories: [])

    @Test func onlyEnglishShipsInTheAppAndInstalledPacksResolveRegionalVariants() {
        #expect(bundled.languages == [.english])
        #expect(bundled.language(for: "uk-UA") == .english)
        let identifiers = packs.languages.map(\.identifier)
        #expect(Set(["en", "uk", "es", "fr", "pt", "de"]).isSubset(of: identifiers))
        for (system, expected) in [("es-MX", "es"), ("fr-CA", "fr"), ("pt-BR", "pt"), ("de-CH", "de"),
                                   ("uk-UA", "uk"), ("en-GB", "en"), ("ja-JP", "ja"), ("zh-CN", "zh-Hans"), ("zh-TW", "zh-Hant"), ("ko-KR", "ko"), ("id-ID", "id"), ("sr-Cyrl-RS", "sr"), ("nb-NO", "nb"), ("he-IL", "he"), ("fa-IR", "en")] {
            #expect(packs.language(for: system).identifier == expected)
        }
        #expect(InterfaceLanguage.resolve(nil, systemLanguage: nil) == .english)
        #expect(InterfaceLanguage.resolve(.english, systemLanguage: "de-DE") == .english)
    }

    @Test(arguments: ["zh-Hans", "ja", "it", "pl", "zh-Hant", "tr", "nl", "sv", "fi",
                      "lt", "lv", "et", "ar", "bg", "hi", "da", "ka",
                      "id", "ko", "th", "bn", "ur", "vi", "sr",
                      "ro", "cs", "sk", "hu", "sq", "hr", "he",
                      "el", "sl", "nb", "ga", "hy", "az"])
    func newPacksLoadTheirInterfaceAndCountKeys(code: String) throws {
        let folder = Self.project.appendingPathComponent("Localizations/\(code).lproj")
        let translated = try readPlist(folder.appendingPathComponent("Localizable.strings"))
        let countRules = try readPlist(folder.appendingPathComponent("Localizable.stringsdict"))
        let language = try #require(packs.languages.first { $0.identifier == code })
        let l10n = L10n(language: language, catalog: packs)
        #expect(translated["Settings…"] != nil)
        #expect(countRules["%lld items"] != nil)
        for (key, value) in translated {
            let text = try #require(value as? String)
            #expect(l10n.text(key) == text, "Invalid translation for \(code): \(key)")
        }
        let fallback = L10n(language: .english, catalog: bundled)
        for key in countRules.keys {
            let counts = [0, 1, 2, 5, 11].map { l10n.count(key, $0) }
            #expect(counts.allSatisfy { !$0.contains("%lld") && !$0.isEmpty })
            #expect(counts != [0, 1, 2, 5, 11].map { fallback.count(key, $0) })
        }
    }

    private func readPlist(_ url: URL) throws -> [String: Any] {
        let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return try #require(value as? [String: Any])
    }

    @Test func additionalTranslationsAndCredits() {
        for (code, singular, plural) in [("es", "1 elemento", "2 elementos"), ("fr", "1 élément", "2 éléments"),
                                          ("pt", "1 item", "2 itens"), ("de", "1 Objekt", "2 Objekte")] {
            let localization = L10n(language: InterfaceLanguage(identifier: code), catalog: packs)
            #expect(localization.count("%lld items", 1) == singular)
            #expect(localization.count("%lld items", 2) == plural)
        }
        for code in ["uk", "es", "fr", "pt", "de"] {
            let credit = L10n(language: InterfaceLanguage(identifier: code), catalog: packs).localizationCredit
            #expect(credit?.title.contains("andyzoer") == true)
            #expect(credit?.url.absoluteString == "https://github.com/andyzoer")
        }
        #expect(L10n(language: .english, catalog: bundled).localizationCredit == nil)
    }

    @Test func externalFilesAddLanguagesAndFallBackToEnglish() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let italian = directory.appendingPathComponent("it.lproj")
        let french = directory.appendingPathComponent("fr.lproj")
        let invalid = directory.appendingPathComponent("nl.lproj")
        for folder in [italian, french, invalid] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try #"""
        "This Mac" = "Questo Mac";
        "Open in %1$@" = "Apri in %1$@";
        "%lld items" = "Elementi: %lld";
        "%lld results" = "Risultati: %@";
        "Search %1$@" = "Cerca %@";
        "Loading %1$@…" = "%%1$@%";
        "Removed key" = "Obsoleto";
        """#.write(to: italian.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        try #"""
        "This Mac" = "Mon Mac";
        "Search" = "";
        """#.write(to: french.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        try #"""
        "Title" = "Traduzione italiana";
        "URL" = "https://example.org/credits";
        """#.write(to: italian.appendingPathComponent("LocalizationCredit.strings"), atomically: true, encoding: .utf8)
        try "broken".write(to: invalid.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)

        let catalog = LocalizationCatalog(externalDirectories: [directory])
        #expect(catalog.languages.contains(InterfaceLanguage(identifier: "it")))
        #expect(!catalog.languages.contains(InterfaceLanguage(identifier: "nl")))
        let localization = L10n(language: catalog.language(for: "it-IT"), catalog: catalog)
        #expect(localization.text("This Mac") == "Questo Mac")
        #expect(localization.text("Open in %1$@") == "Apri in %1$@")
        #expect(localization.text("Search") == "Search")
        #expect(localization.text("Search %1$@") == "Search %1$@")
        #expect(localization.text("Loading %1$@…") == "Loading %1$@…")
        #expect(localization.text("Future key") == "Future key")
        #expect(localization.count("%lld items", 2) == "Elementi: 2")
        #expect(localization.count("%lld results", 1) == "1 result")
        #expect(localization.count("%lld results", 2) == "2 results")
        #expect(localization.localizationCredit?.title == "Traduzione italiana")

        let overridden = L10n(language: catalog.language(for: "fr-CA"), catalog: catalog)
        #expect(overridden.text("This Mac") == "Mon Mac")
        #expect(overridden.text("Search") == "Search")
        #expect(overridden.count("%lld items", 2) == "2 items")
        #expect(overridden.localizationCredit == nil)
    }

    @Test func userDirectoryOverridesPacksBesideTheApp() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let adjacent = directory.appendingPathComponent("Adjacent")
        let installed = directory.appendingPathComponent("Installed")
        for (root, title) in [(adjacent, "Adjacent"), (installed, "Installed")] {
            let pack = root.appendingPathComponent("it.lproj")
            try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
            try "\"About Explorer\" = \"\(title)\";".write(
                to: pack.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        }
        let catalog = LocalizationCatalog(externalDirectories: [adjacent, installed])
        let italian = L10n(language: catalog.language(for: "it-IT"), catalog: catalog)
        #expect(italian.language.identifier == "it")
        #expect(italian.text("About Explorer") == "Installed")
    }

    @Test func installingPacksCopiesOnlyResourcesAndRequiresApprovalForReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Selected")
        let pack = source.appendingPathComponent("it.lproj")
        let installed = root.appendingPathComponent("App Support")
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        let strings = pack.appendingPathComponent("Localizable.strings")
        try "\"Search\" = \"Cerca\";".write(to: strings, atomically: true, encoding: .utf8)
        try Data("ignored".utf8).write(to: pack.appendingPathComponent("unrelated.txt"))
        let installedPack = installed.appendingPathComponent("it.lproj")
        let first = try LocalizationCatalog.install(from: pack, into: installed)
        #expect(first)
        #expect(!FileManager.default.fileExists(atPath: installedPack.appendingPathComponent("unrelated.txt").path))
        try "\"Search\" = \"Ricerca\";".write(to: strings, atomically: true, encoding: .utf8)
        let french = source.appendingPathComponent("fr.lproj")
        try FileManager.default.createDirectory(at: french, withIntermediateDirectories: false)
        try "\"Search\" = \"Rechercher\";".write(to: french.appendingPathComponent("Localizable.strings"),
                                                  atomically: true, encoding: .utf8)
        #expect(throws: LocalizationCatalog.ReplacementRequired(identifiers: ["it"])) {
            try LocalizationCatalog.install(from: source, into: installed)
        }
        #expect(try String(contentsOf: installedPack.appendingPathComponent("Localizable.strings"), encoding: .utf8) == "\"Search\" = \"Cerca\";")
        #expect(!FileManager.default.fileExists(atPath: installed.appendingPathComponent("fr.lproj").path))

        let update = try LocalizationCatalog.install(from: source, into: installed, replacing: ["it"])
        #expect(update)
        let catalog = LocalizationCatalog(externalDirectories: [installed])
        let l10n = L10n(language: catalog.language(for: "it-IT"), catalog: catalog)
        #expect(l10n.text("Search") == "Ricerca")
        #expect(catalog.language(for: "fr-FR").identifier == "fr")
    }

    @Test func externalPluralRulesUseTheExternalLanguage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("pl.lproj")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"""
        "Search" = "Szukaj";
        """#.write(to: folder.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        let rule: [String: Any] = [
            "NSStringLocalizedFormatKey": "%#@count@",
            "count": [
                "NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
                "NSStringFormatValueTypeKey": "lld",
                "one": "%lld element",
                "few": "%lld elementy",
                "many": "%lld elementów",
                "other": "Elementy: %lld",
            ],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: ["%lld items": rule], format: .xml, options: 0)
        try data.write(to: folder.appendingPathComponent("Localizable.stringsdict"))
        let catalog = LocalizationCatalog(externalDirectories: [directory])
        let polish = L10n(language: catalog.language(for: "pl-PL"), catalog: catalog)
        #expect(polish.count("%lld items", 1) == "1 element")
        #expect(polish.count("%lld items", 2) == "2 elementy")
        #expect(polish.count("%lld items", 5) == "5 elementów")
    }

    @Test func lookupAndFallback() {
        let english = L10n(language: .english, catalog: bundled)
        let ukrainian = L10n(language: InterfaceLanguage(identifier: "uk"), catalog: packs)
        #expect(english.text("This Mac") == "This Mac")
        #expect(ukrainian.text("This Mac") == "Цей Mac")
        #expect(ukrainian.text("Untranslated text") == "Untranslated text")
        let format = ukrainian.text("Open in %1$@")
        #expect(String(format: format, locale: ukrainian.locale, "Example % App") == "Відкрити в «Example % App»")
    }

    @Test func ukrainianPluralForms() {
        let ukrainian = L10n(language: InterfaceLanguage(identifier: "uk"), catalog: packs)
        #expect(ukrainian.count("%lld items", 0) == "0 елементів")
        #expect(ukrainian.count("%lld items", 1) == "1 елемент")
        #expect(ukrainian.count("%lld items", 2) == "2 елементи")
        #expect(ukrainian.count("%lld items", 5) == "5 елементів")
        #expect(ukrainian.count("%lld items", 11) == "11 елементів")
        #expect(ukrainian.count("%lld items", 21) == "21 елемент")
        #expect(ukrainian.count("%lld items", 24) == "24 елементи")
    }

    @Test func englishPluralForms() {
        let english = L10n(language: .english, catalog: bundled)
        #expect(english.count("%lld items", 1) == "1 item")
        #expect(english.count("%lld items", 2) == "2 items")
    }
}
