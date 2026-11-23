import Foundation

package struct InterfaceLanguage: Equatable, Sendable {
    package static let preferenceKey = "explorer.interfaceLanguage"
    package static let english = Self(identifier: "en")
    package static var available: [Self] { LocalizationCatalog.current.languages }

    package let identifier: String

    package init(identifier: String) { self.identifier = identifier }

    package var title: String {
        let name = Locale(identifier: identifier).localizedString(forIdentifier: identifier) ?? identifier
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    package static func manualSelection(_ preference: String?) -> Self? {
        available.first { $0.identifier == preference }
    }

    package static func resolve(_ selection: Self?, systemLanguage: String? = Locale.preferredLanguages.first) -> Self {
        if let selection { return selection }
        return LocalizationCatalog.current.language(for: systemLanguage)
    }
}

package struct LocalizationCatalog: Sendable {
    // Discover the files once so Settings and windows agree until the next launch.
    package static let current: Self = {
        let app = Bundle.main.bundleURL
        let adjacent = app.pathExtension == "app" ? ["Localizations", "Explorer-Localizations"].map {
            app.deletingLastPathComponent().appendingPathComponent($0, isDirectory: true)
        } : []
        // User-installed packs take precedence over copies beside Explorer.app.
        let bundled = app.appendingPathComponent("Contents/Resources/Localizations", isDirectory: true)
        return Self(externalDirectories: [bundled] + adjacent + [userDirectory])
    }()

    private static let userDirectory = URL.applicationSupportDirectory
        .appendingPathComponent("Explorer/Localizations", isDirectory: true)
    private static let resources = Bundle.main.url(forResource: "en", withExtension: "lproj") == nil ? Bundle.module : .main
    private let english: Bundle?
    private let external: [String: ExternalLocalization]

    package init(externalDirectories: [URL]) {
        english = Self.resources.url(forResource: "en", withExtension: "lproj").flatMap(Bundle.init(url:))

        var external: [String: ExternalLocalization] = [:]
        for directory in externalDirectories {
            guard let folders = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                              options: [.skipsHiddenFiles]) else { continue }
            for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where folder.pathExtension == "lproj" {
                guard let identifier = Self.identifier(for: folder),
                      let translation = ExternalLocalization(folder: folder) else { continue }
                external[identifier] = translation
            }
        }
        self.external = external
    }

    private static func identifier(for folder: URL) -> String? {
        let name = folder.deletingPathExtension().lastPathComponent
        guard folder.pathExtension == "lproj",
              name.wholeMatch(of: /[A-Za-z]{2,8}(?:-[A-Za-z0-9]{2,8})*/) != nil,
              name.lowercased() != "base" else { return nil }
        return Locale(identifier: name).identifier(.bcp47)
    }

    package struct ReplacementRequired: Error, Equatable {
        package let identifiers: [String]
    }

    package static func install(from source: URL, replacing confirmed: Set<String> = []) throws -> Bool {
        try install(from: source, into: userDirectory, replacing: confirmed)
    }

    package static func install(from source: URL, into destination: URL, replacing confirmed: Set<String> = []) throws -> Bool {
        let files = FileManager.default
        let candidates = source.pathExtension == "lproj" ? [source] :
            try files.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var packs: [String: URL] = [:]
        for folder in candidates.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let identifier = identifier(for: folder), ExternalLocalization(folder: folder) != nil else { continue }
            packs[identifier] = folder
        }
        guard !packs.isEmpty else { return false }

        let orderedPacks = packs.sorted { $0.key < $1.key }
        let unconfirmed = orderedPacks.map(\.key).filter {
            !confirmed.contains($0) && files.fileExists(atPath: destination.appendingPathComponent("\($0).lproj").path)
        }
        guard unconfirmed.isEmpty else { throw ReplacementRequired(identifiers: unconfirmed) }

        try files.createDirectory(at: destination, withIntermediateDirectories: true)
        let staging = destination.appendingPathComponent(".install-\(UUID())", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }

        for (identifier, source) in orderedPacks {
            let copy = staging.appendingPathComponent("\(identifier).lproj", isDirectory: true)
            try files.createDirectory(at: copy, withIntermediateDirectories: false)
            for filename in ["Localizable.strings", "Localizable.stringsdict", "LocalizationCredit.strings"] {
                let resource = source.appendingPathComponent(filename)
                if files.fileExists(atPath: resource.path) {
                    let data = try Data(contentsOf: resource)
                    try data.write(to: copy.appendingPathComponent(filename))
                }
            }
        }
        for (identifier, _) in orderedPacks {
            let name = "\(identifier).lproj"
            let copy = staging.appendingPathComponent(name, isDirectory: true)
            let installed = destination.appendingPathComponent(name, isDirectory: true)
            if files.fileExists(atPath: installed.path) {
                guard confirmed.contains(identifier) else { throw ReplacementRequired(identifiers: [identifier]) }
                _ = try files.replaceItemAt(installed, withItemAt: copy)
            } else {
                try files.moveItem(at: copy, to: installed)
            }
        }
        return true
    }

    package var languages: [InterfaceLanguage] {
        Set(external.keys).union(["en"]).sorted().map(InterfaceLanguage.init(identifier:))
    }

    private func languageCandidates(for identifier: String) -> [String] {
        let language = Locale(identifier: identifier).language
        let exact = Locale(identifier: identifier).identifier(.bcp47)
        guard let base = language.languageCode?.identifier else { return [exact] }
        if let script = language.script?.identifier {
            let scripted = "\(base)-\(script)"
            if scripted != exact { return [exact, scripted, base] }
        }
        return exact == base ? [exact] : [exact, base]
    }

    package func language(for systemLanguage: String?) -> InterfaceLanguage {
        if let systemLanguage,
           let identifier = languageCandidates(for: systemLanguage).first(where: { $0 == "en" || external[$0] != nil }) {
            return InterfaceLanguage(identifier: identifier)
        }
        return .english
    }

    fileprivate func text(_ key: String, in language: InterfaceLanguage) -> String {
        for identifier in languageCandidates(for: language.identifier) {
            if let value = external[identifier]?.text(key) { return value }
        }
        return english?.translation(key) ?? key
    }

    fileprivate func plural(_ key: String, count: Int64, in language: InterfaceLanguage) -> (format: String, locale: Locale) {
        for identifier in languageCandidates(for: language.identifier) {
            let locale = Locale(identifier: identifier)
            if let override = external[identifier] {
                if let format = override.countLabel(key) { return (format, locale) }
                if let categoryRule = english?.translation("Category", table: "PluralRules"),
                   let format = override.plural(key, category: String(format: categoryRule, locale: locale, count)) {
                    return (format, locale)
                }
            }
        }
        return (english?.translation(key) ?? key, Locale(identifier: "en"))
    }

    fileprivate func credit(in language: InterfaceLanguage) -> (title: String, url: URL)? {
        for identifier in languageCandidates(for: language.identifier) {
            if let credit = external[identifier]?.credit {
                return credit
            }
        }
        return nil
    }
}

private struct ExternalLocalization: Sendable {
    private let strings: [String: String]
    private let plurals: [String: [String: String]]
    let credit: (title: String, url: URL)?

    init?(folder: URL) {
        guard let strings = Self.read("Localizable.strings", in: folder) as? [String: String], !strings.isEmpty else { return nil }
        self.strings = strings
        plurals = (Self.read("Localizable.stringsdict", in: folder) ?? [:]).compactMapValues(Self.pluralForms)
        let credits = Self.read("LocalizationCredit.strings", in: folder) as? [String: String]
        credit = makeLocalizationCredit(title: credits?["Title"], address: credits?["URL"])
    }

    private static func read(_ filename: String, in folder: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(filename)),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return nil }
        return plist as? [String: Any]
    }

    func text(_ key: String) -> String? {
        guard let value = strings[key], !value.isEmpty else { return nil }
        let token = /%%|%[1-9][0-9]*\$@/
        let expected = key.matches(of: token).map { String($0.output) }.filter { $0 != "%%" }.sorted()
        if !expected.isEmpty {
            let actual = value.matches(of: token).map { String($0.output) }.filter { $0 != "%%" }.sorted()
            guard value.wholeMatch(of: /(?:[^%]|%%|%[1-9][0-9]*\$@)*/) != nil, actual == expected else { return nil }
        }
        return value
    }

    private static func pluralForms(_ value: Any) -> [String: String]? {
        guard let entry = value as? [String: Any], entry.count == 2,
              entry["NSStringLocalizedFormatKey"] as? String == "%#@count@",
              var forms = entry["count"] as? [String: String],
              forms.removeValue(forKey: "NSStringFormatSpecTypeKey") == "NSStringPluralRuleType",
              forms.removeValue(forKey: "NSStringFormatValueTypeKey") == "lld" else { return nil }
        let valid = forms.filter { category, format in
            ["zero", "one", "two", "few", "many", "other"].contains(category)
                && !format.isEmpty
                && format.wholeMatch(of: /(?:[^%]|%%)*(?:%lld(?:[^%]|%%)*)?/) != nil
        }
        return valid["other"] == nil ? nil : valid
    }

    func plural(_ key: String, category: String) -> String? {
        plurals[key]?[category] ?? plurals[key]?["other"]
    }

    func countLabel(_ key: String) -> String? {
        // External count labels can use a neutral wording with one integer.
        guard let value = strings[key],
              value.wholeMatch(of: /(?:[^%]|%%)*%lld(?:[^%]|%%)*/) != nil else { return nil }
        return value
    }
}

private func makeLocalizationCredit(title: String?, address: String?) -> (title: String, url: URL)? {
    guard let title, !title.isEmpty, let address,
          let url = URL(string: address), url.scheme == "https", url.host != nil else { return nil }
    return (title, url)
}

private extension Bundle {
    func translation(_ key: String, table: String? = nil) -> String? {
        let missing = "\u{E000}"
        let value = localizedString(forKey: key, value: missing, table: table)
        return value == missing || value.isEmpty ? nil : value
    }

}

package struct L10n: Sendable {
    package static let current = L10n(language: InterfaceLanguage.resolve(
        InterfaceLanguage.manualSelection(UserDefaults.standard.string(forKey: InterfaceLanguage.preferenceKey))
    ))

    package let language: InterfaceLanguage
    package var locale: Locale { Locale(identifier: language.identifier) }
    package static var locale: Locale { current.locale }

    private let catalog: LocalizationCatalog

    package init(language: InterfaceLanguage, catalog: LocalizationCatalog = .current) {
        self.language = language
        self.catalog = catalog
    }

    package var localizationCredit: (title: String, url: URL)? { catalog.credit(in: language) }

    package func text(_ key: String) -> String { catalog.text(key, in: language) }

    package static func text(_ key: String) -> String { current.text(key) }

    package static func text(_ key: String, _ arguments: any CustomStringConvertible...) -> String {
        String(format: current.text(key), locale: locale, arguments: arguments.map(\.description))
    }

    package func count(_ key: String, _ count: Int) -> String {
        let number = Int64(count)
        let plural = catalog.plural(key, count: number, in: language)
        return String(format: plural.format, locale: plural.locale, number)
    }

    package static func byteCount(_ bytes: Int64) -> String {
        if current.language == .english && Locale.current.language.languageCode?.identifier == "en" {
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        return bytes.formatted(.byteCount(style: .file).locale(locale))
    }

    package static func count(_ key: String, _ count: Int) -> String { current.count(key, count) }
}
