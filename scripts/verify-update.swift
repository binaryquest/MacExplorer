import Foundation
import CryptoKit

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "ExplorerRelease", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
do {
    try require(CommandLine.arguments.count == 3, "Usage: verify-update.swift RELEASE_DIRECTORY APP_INFO_PLIST")
    let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let plistURL = URL(fileURLWithPath: CommandLine.arguments[2])
    let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as! [String: Any]
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: info["SUPublicEDKey"] as! String)!)
    let feed = try Data(contentsOf: directory.appendingPathComponent("appcast.xml"))
    let text = String(decoding: feed, as: UTF8.self)
    let regex = try NSRegularExpression(pattern: #"<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/=]+)\nlength: ([0-9]+)\n-->\n?$"#)
    guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let signatureRange = Range(match.range(at: 1), in: text), let lengthRange = Range(match.range(at: 2), in: text),
          let signature = Data(base64Encoded: String(text[signatureRange])), let length = Int(text[lengthRange]) else {
        throw NSError(domain: "ExplorerRelease", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing appcast signature"])
    }
    try require(length > 0 && length < feed.count, "Invalid signed feed length")
    try require(key.isValidSignature(signature, for: feed.prefix(length)), "Appcast signature does not match the application's public key")
    let xml = try XMLDocument(data: Data(feed.prefix(length)), options: [])
    let items = xml.rootElement()?.elements(forName: "channel").first?.elements(forName: "item") ?? []
    let build = info["CFBundleVersion"] as! String
    let item = items.first { $0.elements(forName: "sparkle:version").first?.stringValue == build }
    guard let enclosure = item?.elements(forName: "enclosure").first,
          let archiveSignature = enclosure.attribute(forName: "sparkle:edSignature")?.stringValue.flatMap({ Data(base64Encoded: $0) }) else {
        throw NSError(domain: "ExplorerRelease", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing signed enclosure for current build"])
    }
    let version = info["CFBundleShortVersionString"] as! String
    let archive = try Data(contentsOf: directory.appendingPathComponent("MacExplorer-\(version).dmg"))
    try require(key.isValidSignature(archiveSignature, for: archive), "Installer signature does not match the application's public key")
    print("Verified feed and DMG signatures against the embedded Sparkle public key")
} catch {
    fputs("Release verification failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
