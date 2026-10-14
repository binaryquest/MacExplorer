import XCTest
@testable import ExplorerCore

final class StorageTests: XCTestCase {
    func testVirtualLocationHistoryAndFilesystemRootStayDistinct() {
        var history = NavigationHistory(BrowserLocation.thisMac)
        XCTAssertNil(history.parent)
        history.visit(URL(fileURLWithPath: "/", isDirectory: true))
        XCTAssertEqual(history.entries.count, 2)
        history.visit(URL(fileURLWithPath: "/"))
        XCTAssertEqual(history.entries.count, 2)
        XCTAssertEqual(history.back(), BrowserLocation.thisMac)
        XCTAssertEqual(history.forward()?.path, "/")
        history.visit(BrowserLocation.thisMac)
        XCTAssertEqual(history.current, BrowserLocation.thisMac)
    }
    func testOverviewSessionRestorationAndPathEntry() throws {
        let token = BrowserLocation.stored(BrowserLocation.thisMac)
        let session = WorkspaceSession(left: PaneSession(paths: ["/tmp", token], active: 1), right: PaneSession(paths: [token]), dualPane: true)
        let restored = try JSONDecoder().decode(WorkspaceSession.self, from: JSONEncoder().encode(session)).sanitized
        XCTAssertEqual(restored, session)
        XCTAssertEqual(BrowserLocation.restored(restored.left.paths[1]), BrowserLocation.thisMac)
        XCTAssertNil(BrowserLocation.restored("explorer://unknown"))
        XCTAssertEqual(FolderPath.resolve("this mac", relativeTo: URL(fileURLWithPath: "/")), BrowserLocation.thisMac)
        XCTAssertEqual(FolderPath.resolve("Downloads", relativeTo: BrowserLocation.thisMac)?.path, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path)
        XCTAssertEqual(FolderPath.resolve("/tmp", relativeTo: BrowserLocation.thisMac)?.path, "/tmp")
    }
    func testCapacityUnknownFullLowSpaceAndInvalidValues() {
        XCTAssertNil(StorageCapacity(total: 0, available: 10))
        XCTAssertNil(StorageCapacity(total: 100, available: nil))
        XCTAssertNil(StorageCapacity(total: 100, available: -1))
        XCTAssertEqual(StorageCapacity(total: 100, available: 120)?.available, 100)
        XCTAssertEqual(StorageCapacity(total: 100, available: 0)?.usedFraction, 1)
        XCTAssertTrue(StorageCapacity(total: 100, available: 9)!.lowSpace)
        XCTAssertFalse(StorageCapacity(total: 100, available: 10)!.lowSpace)
        XCTAssertEqual(StorageCapacity(total: 1_000, available: 250)?.usedFraction, 0.75)
    }
    func testVisibleVolumesExcludeSystemMountsAndDuplicates() {
        let paths = ["/", "/System/Volumes/Data", "/System/Volumes/Preboot", "/private/var/vm", "/Volumes/.timemachine/backup", "/Volumes/External", "/Volumes/External", "/Volumes/NAS", "/custom/share"]
        let actual = StorageDiscovery.visibleVolumes(paths.map { URL(fileURLWithPath: $0) }).map(\.path)
        XCTAssertEqual(actual, ["/", "/Volumes/External", "/Volumes/NAS", "/custom/share"])
    }
    func testGoogleDriveAccountsKnownFoldersAndProviderRoots() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("explorer-storage-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let paths = ["Library/CloudStorage/GoogleDrive-one@example.test/My Drive", "Library/CloudStorage/GoogleDrive-one@example.test/Shared drives", "Library/CloudStorage/GoogleDrive-one@example.test/Unrelated", "Library/CloudStorage/GoogleDrive-two@example.test/My Drive", "Library/CloudStorage/OneDrive-Work", "Google Drive"]
        for path in paths { try FileManager.default.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true) }
        try Data().write(to: home.appendingPathComponent("Library/CloudStorage/not-a-folder"))
        let roots = StorageDiscovery.cloudRoots(home: home, mounted: [])
        XCTAssertEqual(roots.count, 4)
        let locations = roots.map(StorageDiscovery.cloud)
        let first = try XCTUnwrap(locations.first { $0.detail == "Google Drive · one@example.test" })
        XCTAssertEqual(first.children.map(\.title), ["My Drive", "Shared drives"])
        XCTAssertTrue(first.children.allSatisfy { $0.capacity == nil && $0.kind == .googleDrive })
        XCTAssertEqual(StorageDiscovery.overview(locations, query: "one@example").count, 2)
        XCTAssertEqual(StorageDiscovery.overview(locations, query: "My Drive").count, 2)
        XCTAssertEqual(locations.first { $0.kind == .cloud }?.title, "OneDrive (Work)")
    }
    func testCloudVolumesAreNotShownTwiceAndKeepQuotaUnknown() {
        let url = URL(fileURLWithPath: "/Volumes/GoogleDrive")
        let volume = StorageLocation(url: url, title: "GoogleDrive", kind: .externalDrive, capacity: StorageCapacity(total: 100, available: 50))
        let cloud = StorageLocation(url: url, title: "Google Drive", kind: .googleDrive)
        let overview = StorageDiscovery.overview([volume, cloud])
        XCTAssertEqual(overview.count, 1); XCTAssertNil(overview.first?.capacity)
    }
    func testVirtualLocationsCannotBeDropDestinationsOrSources() {
        let file = URL(fileURLWithPath: "/tmp/file")
        XCTAssertNil(FileDropPlan.make(sources: [file], destination: BrowserLocation.thisMac, internalDrag: true, copyRequested: true, moveRequested: false, supportsCopy: true, supportsMove: true))
        XCTAssertNil(FileDropPlan.make(sources: [BrowserLocation.thisMac], destination: URL(fileURLWithPath: "/tmp"), internalDrag: true, copyRequested: true, moveRequested: false, supportsCopy: true, supportsMove: true))
    }
}
