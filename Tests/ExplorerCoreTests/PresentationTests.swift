import XCTest
@testable import ExplorerCore

final class PresentationTests: XCTestCase {
    private let source = URL(fileURLWithPath: "/fixtures/Source/file.txt")
    private let destination = URL(fileURLWithPath: "/fixtures/Destination")
    private func plan(_ sources: [URL]? = nil, to target: URL? = nil, internalDrag: Bool = true,
                      copy: Bool = false, move: Bool = false, supportsCopy: Bool = true, supportsMove: Bool = true) -> FileDropPlan? {
        FileDropPlan.make(sources: sources ?? [source], destination: target ?? destination, internalDrag: internalDrag,
                         copyRequested: copy, moveRequested: move, supportsCopy: supportsCopy, supportsMove: supportsMove)
    }
    func testInternalMoveAndExternalCopyDefaults() {
        XCTAssertEqual(plan()?.action, .move)
        XCTAssertEqual(plan(internalDrag: false)?.action, .copy)
        XCTAssertEqual(plan(copy: true)?.action, .copy)
        XCTAssertEqual(plan(internalDrag: false, move: true)?.action, .move)
        XCTAssertEqual(plan(copy: true, move: true)?.action, .copy)
    }
    func testUnsupportedActionIsRejectedInsteadOfSilentlyChangingIntent() {
        XCTAssertNil(plan(supportsMove: false))
        XCTAssertNil(plan(copy: true, supportsCopy: false))
        XCTAssertNil(plan(internalDrag: false, supportsCopy: false))
        XCTAssertEqual(plan(internalDrag: false, supportsMove: false)?.action, .copy)
    }
    func testRejectsSelfDescendantRootAndNonFileURLs() {
        let folder = URL(fileURLWithPath: "/fixtures/Source")
        XCTAssertNil(plan([folder], to: folder))
        XCTAssertNil(plan([folder], to: folder.appendingPathComponent("nested")))
        XCTAssertNil(plan([URL(fileURLWithPath: "/")]))
        XCTAssertNil(plan([URL(string: "https://example.com/file")!]))
        XCTAssertNil(plan(to: URL(string: "https://example.com/folder")!))
        XCTAssertNil(plan([]))
        XCTAssertNotNil(plan([folder], to: URL(fileURLWithPath: "/fixtures/Source-two")))
    }
    func testSameFolderCopyAllowedButNoOpMoveRejected() {
        XCTAssertNil(plan(to: source.deletingLastPathComponent()))
        XCTAssertEqual(plan(to: source.deletingLastPathComponent(), copy: true)?.action, .copy)
    }
    func testDeduplicationAndLexicalPathNormalization() throws {
        let duplicate = URL(fileURLWithPath: "/fixtures/Source/../Source/file.txt")
        let result = try XCTUnwrap(plan([source, duplicate, source]))
        XCTAssertEqual(result.sources, [source])
        XCTAssertNil(plan([URL(fileURLWithPath: "/fixtures/Source")], to: URL(fileURLWithPath: "/fixtures/Source/nested/../child")))
    }
    func testThumbnailCacheInvalidatesByContentMetadataAndResolution() {
        func item(_ modified: TimeInterval, _ size: Int64) -> FileItem {
            FileItem(url: source, name: "file.txt", isDirectory: false, modified: Date(timeIntervalSince1970: modified), size: size)
        }
        let identity = ThumbnailIdentity(item: item(1, 100), pixels: 192)
        XCTAssertEqual(identity, ThumbnailIdentity(item: item(1, 100), pixels: 192))
        XCTAssertNotEqual(identity, ThumbnailIdentity(item: item(2, 100), pixels: 192))
        XCTAssertNotEqual(identity, ThumbnailIdentity(item: item(1, 101), pixels: 192))
        XCTAssertNotEqual(identity, ThumbnailIdentity(item: item(1, 100), pixels: 320))
    }
    func testDropRunsThroughConflictResolutionAndUndo() async throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("explorer-drop-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt"), destination = root.appendingPathComponent("Destination")
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("new".utf8).write(to: source)
        let old = destination.appendingPathComponent("source.txt")
        try Data("old".utf8).write(to: old)
        let drop = try XCTUnwrap(plan([source], to: destination))
        let engine = FileOperationEngine(trashItem: { url in
            let target = root.appendingPathComponent(UUID().uuidString)
            try FileManager().moveItem(at: url, to: target); return target
        })
        let result = await engine.perform(drop.operation, resolve: { _ in ConflictResolution(.keepBoth) })
        XCTAssertNil(result.error); XCTAssertFalse(fm.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: old, encoding: .utf8), "old")
        let moved = try XCTUnwrap(result.completed.first)
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "new")
        let undo = await engine.undo(); XCTAssertNil(undo.error)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "new")
        XCTAssertFalse(fm.fileExists(atPath: moved.path))
    }
}
