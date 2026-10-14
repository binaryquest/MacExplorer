import XCTest
@testable import ExplorerCore

final class NavigationTests: XCTestCase {
    func testHistoryBranchesAfterBack() {
        var history = NavigationHistory(URL(fileURLWithPath: "/one"))
        history.visit(URL(fileURLWithPath: "/two"))
        history.visit(URL(fileURLWithPath: "/three"))
        XCTAssertEqual(history.back()?.path, "/two")
        XCTAssertTrue(history.canGoForward)
        history.visit(URL(fileURLWithPath: "/new"))
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.entries.map(\.path), ["/one", "/two", "/new"])
        XCTAssertEqual(history.back()?.path, "/two")
        XCTAssertEqual(history.forward()?.path, "/new")
    }
    func testHistoryAvoidsDuplicatesAndStopsAtRoot() {
        var history = NavigationHistory(URL(fileURLWithPath: "/"))
        history.visit(URL(fileURLWithPath: "/"))
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertNil(history.parent)
        XCTAssertNil(history.back())
        XCTAssertNil(history.forward())
        history.visit(URL(fileURLWithPath: "/Users/name"))
        XCTAssertEqual(history.parent?.path, "/Users")
    }
    func testHistoryIsBounded() {
        var history = NavigationHistory(URL(fileURLWithPath: "/"))
        for i in 0..<200 { history.visit(URL(fileURLWithPath: "/folder\(i)")) }
        XCTAssertEqual(history.entries.count, 100)
        XCTAssertEqual(history.current.path, "/folder199")
    }
    func testPathResolution() {
        let base = URL(fileURLWithPath: "/Users/person/Documents")
        XCTAssertEqual(FolderPath.resolve("../Downloads", relativeTo: base)?.path, "/Users/person/Downloads")
        XCTAssertEqual(FolderPath.resolve("/tmp/a b", relativeTo: base)?.path, "/tmp/a b")
        XCTAssertEqual(FolderPath.resolve("file:///tmp/a%20b", relativeTo: base)?.path, "/tmp/a b")
        XCTAssertEqual(FolderPath.resolve("~", relativeTo: base)?.path, FileManager.default.homeDirectoryForCurrentUser.path)
        XCTAssertNil(FolderPath.resolve("  ", relativeTo: base))
    }
}

final class FileSystemTests: XCTestCase {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("explorer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testListsMetadataHiddenFilesAndDirectorySymlinks() throws {
        let root = try fixture()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: false)
        try Data("hello".utf8).write(to: root.appendingPathComponent("file.txt"))
        try Data().write(to: root.appendingPathComponent(".hidden"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Link"), withDestinationURL: root.appendingPathComponent("Folder"))
        let items = try FileSystem.list(root)
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items.first { $0.name == "file.txt" }?.size, 5)
        XCTAssertTrue(try XCTUnwrap(items.first { $0.name == "Folder" }).isNavigable)
        XCTAssertTrue(try XCTUnwrap(items.first { $0.name == "Link" }).isNavigable)
        XCTAssertTrue(try XCTUnwrap(items.first { $0.name == "Link" }).isSymbolicLink)
        XCTAssertEqual(FileSort().apply(to: items).count, 3)
        XCTAssertEqual(FileSort().apply(to: items, showHidden: true).count, 4)
    }
    func testMissingFolderAndFilePathsFail() throws {
        let root = try fixture()
        XCTAssertThrowsError(try FileSystem.list(root.appendingPathComponent("missing")))
        let file = root.appendingPathComponent("file.txt")
        try Data().write(to: file)
        XCTAssertThrowsError(try FileSystem.validateDirectory(file))
        XCTAssertNoThrow(try FileSystem.validateDirectory(root))
    }
    func testMacTemporaryDirectoryAlias() throws {
        let root = try fixture()
        let link = root.appendingPathComponent("System temp")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/tmp"))
        XCTAssertNoThrow(try FileSystem.validateDirectory(URL(fileURLWithPath: "/tmp")))
        XCTAssertNoThrow(try FileSystem.validateDirectory(link))
        XCTAssertTrue(try XCTUnwrap(FileSystem.list(root).first).isNavigable)
    }
    func testNaturalSortAndFoldersStayFirst() {
        let items = [
            FileItem(url: URL(fileURLWithPath: "/file10.txt"), name: "file10.txt", isDirectory: false, size: 10),
            FileItem(url: URL(fileURLWithPath: "/file2.txt"), name: "file2.txt", isDirectory: false, size: 2),
            FileItem(url: URL(fileURLWithPath: "/Folder"), name: "Folder", isDirectory: true),
            FileItem(url: URL(fileURLWithPath: "/Demo.app"), name: "Demo.app", isDirectory: true, isPackage: true)
        ]
        XCTAssertEqual(FileSort().apply(to: items).map(\.name), ["Folder", "Demo.app", "file2.txt", "file10.txt"])
        XCTAssertEqual(FileSort(ascending: false).apply(to: items).first?.name, "Folder")
        XCTAssertEqual(FileSort().apply(to: items, query: "FILE2").map(\.name), ["file2.txt"])
        XCTAssertFalse(items.last!.isNavigable)
        XCTAssertEqual(FileSort(key: .size, ascending: false).apply(to: items).map(\.name), ["Folder", "file10.txt", "file2.txt", "Demo.app"])
    }
    func testLargeFolderEnumerationAndSort() throws {
        let root = try fixture()
        for i in 0..<10_000 {
            _ = FileManager.default.createFile(atPath: root.appendingPathComponent("item\(i).txt").path, contents: Data())
        }
        let start = Date()
        let items = try FileSystem.list(root)
        let sorted = FileSort().apply(to: items)
        XCTAssertEqual(sorted.count, 10_000)
        XCTAssertEqual(sorted.first?.name, "item0.txt")
        XCTAssertEqual(sorted.last?.name, "item9999.txt")
        print("10,000-file enumeration + natural sort: \(String(format: "%.3f", Date().timeIntervalSince(start)))s")
    }
}
