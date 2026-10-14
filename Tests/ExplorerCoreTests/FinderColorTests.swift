import XCTest
import Darwin
@testable import ExplorerCore

@MainActor
final class FinderColorTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("explorer-colors-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func file(_ root: URL, _ name: String = "file.txt") throws -> URL {
        let url = root.appendingPathComponent(name); try Data("original".utf8).write(to: url); return url
    }
    private func tags(_ entries: [String], at url: URL) throws {
        try rawTags(PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0), at: url)
    }
    private func rawTags(_ data: Data, at url: URL) throws {
        let result = data.withUnsafeBytes { setxattr(url.path, FinderColors.attribute, $0.baseAddress, data.count, 0, 0) }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
    func testReadsModernMultipleColorsAndLegacyLabels() throws {
        let root = try fixture(), url = try file(root)
        try tags(["Client\n2", "Keep", "Blue\n4", "Second green\n2"], at: url)
        var fresh = url, values = URLResourceValues(); values.labelNumber = 6; try fresh.setResourceValues(values)
        let summary = FinderColors.summary(at: url)
        XCTAssertEqual(summary.colors, [.green, .blue, .red])
        XCTAssertEqual(summary.names, ["Client", "Keep", "Blue", "Second green"])
        let item = try XCTUnwrap(FileSystem.list(root).first)
        XCTAssertEqual(item.finderColors, summary)
    }
    func testChangeRemoveAndUndoPreserveCustomTagsExactly() async throws {
        let root = try fixture(), url = try file(root), engine = FileOperationEngine()
        try tags(["Client\n2", "Keep", "Blue\n4", "Red"], at: url)
        let original = try FinderColors.read(url)
        let change = await engine.perform(.color([url], .red)); XCTAssertNil(change.error)
        let changed = try FinderColors.read(url)
        XCTAssertEqual(try changed.entries, ["Red\n6", "Client\n2", "Keep", "Red"])
        XCTAssertEqual(changed.label, 6)
        let remove = await engine.perform(.color([url], .none)); XCTAssertNil(remove.error)
        XCTAssertEqual(try FinderColors.read(url).entries, ["Client\n2", "Keep", "Red"])
        XCTAssertEqual(FinderColors.summary(at: url).colors, [.green])
        let undoRemove = await engine.undo(); XCTAssertNil(undoRemove.error)
        XCTAssertEqual(try FinderColors.read(url), changed)
        let undoChange = await engine.undo(); XCTAssertNil(undoChange.error)
        XCTAssertEqual(try FinderColors.read(url), original)
        XCTAssertEqual(try Data(contentsOf: url), Data("original".utf8))
    }
    func testMultipleItemsAndFolderContentsAreNotRecursivelyChanged() async throws {
        let root = try fixture(), folder = root.appendingPathComponent("Folder"), engine = FileOperationEngine()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let child = try file(folder), second = try file(root)
        let report = await engine.perform(.color([folder, second, second], .purple)); XCTAssertNil(report.error)
        XCTAssertEqual(report.completed.count, 2)
        XCTAssertEqual(FinderColors.summary(at: folder).colors, [.purple])
        XCTAssertEqual(FinderColors.summary(at: second).colors, [.purple])
        XCTAssertTrue(FinderColors.summary(at: child).colors.isEmpty)
        try Data("edited child".utf8).write(to: child)
        let undo = await engine.undo(); XCTAssertNil(undo.error)
        XCTAssertTrue(FinderColors.summary(at: folder).colors.isEmpty)
        XCTAssertTrue(FinderColors.summary(at: second).colors.isEmpty)
        XCTAssertEqual(try Data(contentsOf: child), Data("edited child".utf8))
    }
    func testColorAndRenameShareUndoOrder() async throws {
        let root = try fixture(), url = try file(root), engine = FileOperationEngine()
        let color = await engine.perform(.color([url], .orange)); XCTAssertNil(color.error)
        let rename = await engine.perform(.rename(url, to: "renamed.txt")); XCTAssertNil(rename.error)
        let renamed = root.appendingPathComponent("renamed.txt")
        XCTAssertEqual(FinderColors.summary(at: renamed).colors, [.orange])
        let undoRename = await engine.undo(); XCTAssertNil(undoRename.error)
        XCTAssertEqual(FinderColors.summary(at: url).colors, [.orange])
        let undoColor = await engine.undo(); XCTAssertNil(undoColor.error)
        XCTAssertTrue(FinderColors.summary(at: url).colors.isEmpty)
    }
    func testUndoRefusesTagsChangedElsewhere() async throws {
        let root = try fixture(), url = try file(root), engine = FileOperationEngine()
        let report = await engine.perform(.color([url], .blue)); XCTAssertNil(report.error)
        try tags(["External\n2"], at: url)
        let before = try FinderColors.read(url)
        let undo = await engine.undo(); XCTAssertNotNil(undo.error)
        XCTAssertEqual(try FinderColors.read(url), before)
    }
    func testMalformedTagsAreNotOverwritten() async throws {
        let root = try fixture(), url = try file(root), engine = FileOperationEngine()
        try rawTags(Data("not a plist".utf8), at: url)
        let original = try FinderColors.read(url)
        let report = await engine.perform(.color([url], .red)); XCTAssertNotNil(report.error)
        XCTAssertTrue(report.completed.isEmpty)
        XCTAssertEqual(try FinderColors.read(url), original)
    }
    func testPartialFailureRemainsUndoableAndSymlinkTargetIsUntouched() async throws {
        let root = try fixture(), url = try file(root, "a.txt"), engine = FileOperationEngine()
        let report = await engine.perform(.color([url, root.appendingPathComponent("z-missing")], .yellow))
        XCTAssertNotNil(report.error); XCTAssertEqual(report.completed, [url])
        let undo = await engine.undo(); XCTAssertNil(undo.error)
        XCTAssertTrue(FinderColors.summary(at: url).colors.isEmpty)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        let rejected = await engine.perform(.color([link], .green)); XCTAssertNotNil(rejected.error)
        XCTAssertTrue(FinderColors.summary(at: url).colors.isEmpty)
    }
}
