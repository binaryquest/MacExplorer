import XCTest
@testable import ExplorerCore

private actor SearchResults {
    var items: [FileItem] = []
    var updates = 0
    func append(_ update: SearchUpdate) { items += update.matches; updates += 1 }
}

@MainActor
final class DirectorySearchTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("explorer-search-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    @discardableResult private func file(_ path: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: url); return url
    }
    func testRecursiveNamesLocationsAndDuplicateNames() async throws {
        let root = try fixture()
        let one = try file("One/Report.txt", in: root), two = try file("Two/Deep/Report.txt", in: root)
        try file("unrelated.txt", in: root)
        let results = SearchResults()
        let summary = try await DirectorySearch.run(root: root, query: "  REPORT  ", onUpdate: { await results.append($0) })
        let matches = await results.items
        XCTAssertEqual(Set(matches.map { $0.url.resolvingSymlinksInPath() }), Set([one, two].map { $0.resolvingSymlinksInPath() })); XCTAssertEqual(summary.scanned, 6)
        XCTAssertEqual(DirectorySearch.location(of: one, relativeTo: root), "One")
        XCTAssertEqual(DirectorySearch.location(of: two, relativeTo: root), "Two/Deep")
        XCTAssertEqual(Set(matches.map { DirectorySearch.location(of: $0.url, relativeTo: root) }), ["One", "Two/Deep"])
        XCTAssertEqual(FileSort().apply(to: matches.reversed()).map { DirectorySearch.location(of: $0.url, relativeTo: root) }, ["One", "Two/Deep"])
        XCTAssertFalse(summary.reachedLimit); XCTAssertEqual(summary.unreadableFolders, 0)
    }
    func testSearchRootMayBeASymlinkAndLocationsRemainRelative() async throws {
        let root = try fixture(); try file("Actual/Child/match.txt", in: root)
        let alias = root.appendingPathComponent("Alias"), actual = root.appendingPathComponent("Actual")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let results = SearchResults()
        _ = try await DirectorySearch.run(root: alias, query: "match", onUpdate: { await results.append($0) })
        let items = await results.items; XCTAssertEqual(items.count, 1)
        XCTAssertEqual(DirectorySearch.location(of: actual.appendingPathComponent("Child/match.txt"), relativeTo: alias), "Child")
    }
    func testUnreadableSubfolderIsReportedWhileOtherResultsContinue() async throws {
        let root = try fixture(); try file("Blocked/match.txt", in: root); try file("Visible/match.txt", in: root)
        let blocked = root.appendingPathComponent("Blocked")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
        let results = SearchResults()
        let summary = try await DirectorySearch.run(root: root, query: "match", onUpdate: { await results.append($0) })
        let items = await results.items; XCTAssertEqual(items.count, 1); XCTAssertEqual(summary.unreadableFolders, 1)
    }
    func testHiddenFoldersAndPackagesAreNotTraversedByDefault() async throws {
        let root = try fixture()
        try file(".hidden/match.txt", in: root); try file("Visible/.match.txt", in: root)
        try file("Tool.app/Contents/match.txt", in: root); try file("Visible/match.txt", in: root)
        let visible = SearchResults()
        _ = try await DirectorySearch.run(root: root, query: "match", onUpdate: { await visible.append($0) })
        let visibleItems = await visible.items; XCTAssertEqual(visibleItems.count, 1)
        let hidden = SearchResults()
        _ = try await DirectorySearch.run(root: root, query: "match", showHidden: true, onUpdate: { await hidden.append($0) })
        let hiddenItems = await hidden.items; XCTAssertEqual(hiddenItems.count, 3)
        XCTAssertFalse(hiddenItems.contains { $0.url.path.contains("Tool.app/") })
    }
    func testDirectorySymlinkDoesNotCreateDuplicateResultsOrCycles() async throws {
        let root = try fixture(); try file("Folder/match.txt", in: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Folder/loop"), withDestinationURL: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("match-link"), withDestinationURL: root.appendingPathComponent("Folder"))
        let results = SearchResults()
        _ = try await DirectorySearch.run(root: root, query: "match", onUpdate: { await results.append($0) })
        let items = await results.items; XCTAssertEqual(Set(items.map(\.name)), ["match.txt", "match-link"])
    }
    func testProgressBatchesAndResultLimit() async throws {
        let root = try fixture()
        for index in 0..<220 { try file("match-\(index).txt", in: root) }
        let results = SearchResults()
        let summary = try await DirectorySearch.run(root: root, query: "match", resultLimit: 150, onUpdate: { await results.append($0) })
        let items = await results.items, updates = await results.updates
        XCTAssertEqual(items.count, 150); XCTAssertTrue(summary.reachedLimit); XCTAssertGreaterThanOrEqual(updates, 2)
    }
    func testCancellationStopsFurtherBatches() async throws {
        let root = try fixture(); for index in 0..<220 { try file("match-\(index).txt", in: root) }
        let results = SearchResults()
        let task = Task {
            try await DirectorySearch.run(root: root, query: "match") { update in
                await results.append(update)
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        let items = await results.items; XCTAssertLessThan(items.count, 220)
    }
    func testMissingRootReportsFailureRatherThanEmptySuccess() async throws {
        let root = try fixture().appendingPathComponent("missing")
        do { _ = try await DirectorySearch.run(root: root, query: "match", onUpdate: { _ in }); XCTFail("Expected failure") } catch {}
    }
    func testBlankQueryDoesNotTraverseAndUnicodeMatches() async throws {
        let root = try fixture(); try file("café.txt", in: root)
        let results = SearchResults()
        let empty = try await DirectorySearch.run(root: root, query: " \n ", onUpdate: { await results.append($0) })
        XCTAssertEqual(empty.scanned, 0)
        _ = try await DirectorySearch.run(root: root, query: "CAFE", onUpdate: { await results.append($0) })
        let items = await results.items; XCTAssertEqual(items.map(\.name), ["café.txt"])
    }
}

final class WorkspaceModelTests: XCTestCase {
    func testFavoritesDeduplicateReorderAndPersistAnEmptyList() throws {
        var favorites = Favorites()
        XCTAssertTrue(favorites.pin(URL(fileURLWithPath: "/One")))
        XCTAssertFalse(favorites.pin(URL(fileURLWithPath: "/Two/../One")))
        XCTAssertFalse(favorites.pin(URL(string: "https://example.com")!))
        favorites.pin(URL(fileURLWithPath: "/Two")); favorites.pin(URL(fileURLWithPath: "/Three"))
        let third = favorites.items[2].id; favorites.move(third, by: -100)
        XCTAssertEqual(favorites.items.map(\.path), ["/Three", "/One", "/Two"])
        favorites.move(third, by: 100)
        XCTAssertEqual(favorites.items.map(\.path), ["/One", "/Two", "/Three"])
        let data = try JSONEncoder().encode(favorites)
        XCTAssertEqual(try JSONDecoder().decode(Favorites.self, from: data), favorites)
        for item in favorites.items { favorites.unpin(item.url) }
        let empty = try JSONDecoder().decode(Favorites.self, from: JSONEncoder().encode(favorites))
        XCTAssertTrue(empty.items.isEmpty)
    }
    func testFavoritesSanitizeDuplicateIDsAndPaths() {
        let one = Favorite(url: URL(fileURLWithPath: "/One"))
        let duplicateID = Favorite(id: one.id, url: URL(fileURLWithPath: "/Two"))
        XCTAssertEqual(Favorites([one, one, duplicateID]).items, [one])
        let two = Favorite(url: URL(fileURLWithPath: "/Two"))
        XCTAssertEqual(Favorites([one, duplicateID, two]).items, [one, two])
    }
    func testDualPaneSessionRetainsSeparateTabsModesAndActivePane() throws {
        let left = PaneSession(paths: ["/One", "/Two"], active: 1, modes: ["details", "large"])
        let right = PaneSession(paths: ["/Three"], modes: ["small"])
        let session = WorkspaceSession(left: left, right: right, dualPane: true, activeRight: true)
        let restored = try JSONDecoder().decode(WorkspaceSession.self, from: JSONEncoder().encode(session)).sanitized
        XCTAssertEqual(restored, session); XCTAssertEqual(restored.left.active, 1); XCTAssertTrue(restored.activeRight)
    }
    func testSessionSanitizesPathsAndKeepsModesAligned() {
        let pane = PaneSession(paths: ["relative", "/One", "/Two"], active: 2, modes: ["small", "large", "details"])
        XCTAssertEqual(pane.paths, ["/One", "/Two"]); XCTAssertEqual(pane.modes, ["large", "details"]); XCTAssertEqual(pane.active, 1)
        XCTAssertEqual(PaneSession(paths: ["/One"], active: 99).active, 0)
        let invalid = WorkspaceSession(left: pane, dualPane: true, activeRight: true)
        XCTAssertFalse(invalid.dualPane); XCTAssertFalse(invalid.activeRight)
        let large = PaneSession(paths: (0..<40).map { "/\($0)" }, active: 30)
        XCTAssertEqual(large.paths.count, 20); XCTAssertEqual(large.active, 19)
    }
}
