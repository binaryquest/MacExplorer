import Foundation
import Testing
@testable import ExplorerApp

@Suite @MainActor
struct UpdateTests {
    @Test func developmentDemoAndMalformedFeedsCannotStartUpdates() {
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        let valid: [String: Any] = ["ExplorerUpdatesEnabled": true, "SUFeedURL": "https://downloads.bquick.io/explorer/stable/appcast.xml", "SUPublicEDKey": key]
        #expect(UpdateConfiguration(info: valid).isValid)
        for override: [String: Any] in [[:], ["ExplorerUpdatesEnabled": false], ["ExplorerDemo": true], ["SUPublicEDKey": "invalid"],
                                       ["SUFeedURL": "http://example.test/feed.xml"], ["SUFeedURL": "file:///tmp/feed.xml"],
                                       ["SUFeedURL": "https://user:password@example.test/feed.xml"]] {
            let info = override.isEmpty ? [:] : valid.merging(override) { _, replacement in replacement }
            #expect(!UpdateConfiguration(info: info).isValid)
        }
    }

    @Test func migrationPreservesUserChoicesAndDoesNotRepeat() throws {
        let session = Data("saved tabs".utf8)
        let legacy: [String: Any] = ["explorer.session.v2": session, "explorer.appearance": "dark", "explorer.shortcut.enabled": false,
                                     "UnrelatedPreference": "ignore", "SUFeedURL": "https://unexpected.test"]
        let current: [String: Any] = ["explorer.appearance": "light", "NewPreference": "keep"]
        let migrated = PreferenceMigration.migratedDomain(current: current, legacy: legacy)
        #expect(migrated["explorer.session.v2"] as? Data == session)
        #expect(migrated["explorer.appearance"] as? String == "light")
        #expect(migrated["explorer.shortcut.enabled"] as? Bool == false)
        #expect(migrated["NewPreference"] as? String == "keep")
        #expect(migrated["UnrelatedPreference"] == nil)
        #expect(migrated["SUFeedURL"] == nil)
        let repeatMigration = PreferenceMigration.migratedDomain(current: migrated, legacy: ["explorer.new": true])
        #expect(repeatMigration["explorer.new"] == nil)
    }

    @Test func updateRelaunchWaitsUntilSafeAndResumesExactlyOnce() {
        var ready = false
        var calls = 0
        let gate = UpdateRelaunchGate { ready }
        #expect(gate.postpone { calls += 1 })
        gate.resumeIfReady()
        #expect(calls == 0)
        #expect(gate.hasPendingRelaunch)
        ready = true
        gate.resumeIfReady()
        gate.resumeIfReady()
        #expect(calls == 1)
        #expect(!gate.hasPendingRelaunch)
        #expect(!gate.postpone { calls += 1 })
        #expect(calls == 1) // Sparkle handles the immediate path itself.
    }
}
