import XCTest
@testable import ExplorerCore

@MainActor
final class FileOperationTests: XCTestCase {
    private let fm = FileManager.default
    private func fixture() throws -> URL {
        let root = fm.temporaryDirectory.appendingPathComponent("explorer-operations-\(UUID())").resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["Source", "Destination", "Trash"] {
            try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func engine(_ root: URL, crossVolume: Bool = false) -> FileOperationEngine {
        FileOperationEngine(trashItem: { source in
            let target = root.appendingPathComponent("Trash/\(UUID())-\(source.lastPathComponent)")
            try FileManager().moveItem(at: source, to: target)
            return target
        }, volumeID: { url in crossVolume && url.path.contains("/Source/") ? 1 : 2 })
    }
    @discardableResult private func file(_ path: String, in root: URL, text: String = "original") throws -> URL {
        let url = root.appendingPathComponent(path)
        try Data(text.utf8).write(to: url); return url
    }
    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    private func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    func testCopyKeepBothAndUndoPreserveOriginal() async throws {
        let root = try fixture(), engine = engine(root)
        let source = try file("Source/report.txt", in: root)
        let result = await engine.perform(.copy([source], to: source.deletingLastPathComponent()))
        XCTAssertNil(result.error)
        let copy = try XCTUnwrap(result.completed.first)
        XCTAssertEqual(copy.lastPathComponent, "report - Copy.txt")
        XCTAssertEqual(try read(copy), "original")
        let undo = await engine.undo()
        XCTAssertNil(undo.error); XCTAssertFalse(exists(copy)); XCTAssertTrue(exists(source))
    }
    func testMoveRenameAndStackedUndo() async throws {
        let root = try fixture(), engine = engine(root)
        let source = try file("Source/report.txt", in: root)
        let destination = root.appendingPathComponent("Destination")
        let move = await engine.perform(.move([source], to: destination))
        XCTAssertNil(move.error); XCTAssertFalse(exists(source))
        let moved = try XCTUnwrap(move.completed.first)
        let rename = await engine.perform(.rename(moved, to: "renamed.txt"))
        XCTAssertNil(rename.error); XCTAssertFalse(exists(moved))
        let undoRename = await engine.undo(); XCTAssertNil(undoRename.error)
        XCTAssertEqual(try read(moved), "original")
        let undoMove = await engine.undo(); XCTAssertNil(undoMove.error)
        XCTAssertEqual(try read(source), "original"); XCTAssertFalse(exists(moved))
    }
    func testReplaceThenUndoRestoresBothVersions() async throws {
        let root = try fixture(), engine = engine(root)
        let source = try file("Source/report.txt", in: root, text: "new")
        let old = try file("Destination/report.txt", in: root, text: "old")
        let result = await engine.perform(.copy([source], to: old.deletingLastPathComponent()), resolve: { _ in ConflictResolution(.replace) })
        XCTAssertNil(result.error); XCTAssertEqual(try read(old), "new")
        let undo = await engine.undo(); XCTAssertNil(undo.error)
        XCTAssertEqual(try read(old), "old"); XCTAssertEqual(try read(source), "new")
    }
    func testReplaceDirectoryIsWholeReplacementAndUndoRestoresTree() async throws {
        let root = try fixture(), engine = engine(root)
        let source = root.appendingPathComponent("Source/Folder"), old = root.appendingPathComponent("Destination/Folder")
        try fm.createDirectory(at: source, withIntermediateDirectories: false)
        try fm.createDirectory(at: old, withIntermediateDirectories: false)
        try file("new.txt", in: source); try file("old.txt", in: old)
        let result = await engine.perform(.move([source], to: old.deletingLastPathComponent()), resolve: { _ in ConflictResolution(.replace) })
        XCTAssertNil(result.error); XCTAssertFalse(exists(old.appendingPathComponent("old.txt")))
        XCTAssertTrue(exists(old.appendingPathComponent("new.txt")))
        let undo = await engine.undo(); XCTAssertNil(undo.error)
        XCTAssertTrue(exists(old.appendingPathComponent("old.txt")))
        XCTAssertTrue(exists(source.appendingPathComponent("new.txt")))
    }
    func testNewFolderTrashAndUndo() async throws {
        let root = try fixture(), engine = engine(root)
        let create = await engine.perform(.newFolder(in: root, name: "New folder"))
        XCTAssertNil(create.error); let folder = try XCTUnwrap(create.completed.first)
        let trash = await engine.perform(.trash([folder])); XCTAssertNil(trash.error); XCTAssertFalse(exists(folder))
        let restore = await engine.undo(); XCTAssertNil(restore.error); XCTAssertTrue(exists(folder))
        let remove = await engine.undo(); XCTAssertNil(remove.error); XCTAssertFalse(exists(folder))
    }
    func testUndoRefusesModifiedOutputAndRetainsRecord() async throws {
        let root = try fixture(), engine = engine(root)
        let source = try file("Source/report.txt", in: root)
        let result = await engine.perform(.copy([source], to: root.appendingPathComponent("Destination")))
        let copy = try XCTUnwrap(result.completed.first)
        try Data("edited externally".utf8).write(to: copy)
        let undo = await engine.undo(); XCTAssertNotNil(undo.error)
        XCTAssertEqual(try read(copy), "edited externally")
        let title = await engine.undoTitle; XCTAssertEqual(title, "Copy")
    }
    func testUndoRefusesOccupiedOriginalLocation() async throws {
        let root = try fixture(), engine = engine(root)
        let source = try file("Source/report.txt", in: root)
        let result = await engine.perform(.trash([source])); XCTAssertNil(result.error)
        try Data("unrelated".utf8).write(to: source)
        let undo = await engine.undo(); XCTAssertNotNil(undo.error)
        XCTAssertEqual(try read(source), "unrelated")
        try fm.removeItem(at: source)
        let retry = await engine.undo(); XCTAssertNil(retry.error)
        XCTAssertEqual(try read(source), "original")
    }
    func testUndoDetectsChangesInsideNewFolder() async throws {
        let root = try fixture(), engine = engine(root)
        let result = await engine.perform(.newFolder(in: root, name: "Folder"))
        let folder = try XCTUnwrap(result.completed.first)
        try file("keep.txt", in: folder)
        let undo = await engine.undo(); XCTAssertNotNil(undo.error)
        XCTAssertTrue(exists(folder.appendingPathComponent("keep.txt")))
    }
    func testSkipAndApplyToAll() async throws {
        let root = try fixture(), engine = engine(root)
        let one = try file("Source/one.txt", in: root), two = try file("Source/two.txt", in: root)
        try file("Destination/one.txt", in: root, text: "old"); try file("Destination/two.txt", in: root, text: "old")
        let calls = Counter()
        let result = await engine.perform(.copy([one, two], to: root.appendingPathComponent("Destination")), resolve: { _ in
            await calls.increment(); return ConflictResolution(.skip, applyToAll: true)
        })
        XCTAssertEqual(result.skipped, 2); XCTAssertTrue(result.completed.isEmpty)
        let count = await calls.value; XCTAssertEqual(count, 1)
    }
    func testCancelledConflictLeavesPartialBatchUndoable() async throws {
        let root = try fixture(), engine = engine(root)
        let one = try file("Source/one.txt", in: root), two = try file("Source/two.txt", in: root)
        try file("Destination/two.txt", in: root, text: "old")
        let result = await engine.perform(.copy([one, two], to: root.appendingPathComponent("Destination")), resolve: { _ in ConflictResolution(.cancel) })
        XCTAssertTrue(result.cancelled); XCTAssertEqual(result.completed.count, 1)
        let undo = await engine.undo(); XCTAssertNil(undo.error)
        XCTAssertFalse(exists(root.appendingPathComponent("Destination/one.txt")))
        XCTAssertEqual(try read(root.appendingPathComponent("Destination/two.txt")), "old")
    }
    func testDescendantAndAncestorDestinationsAreRejected() async throws {
        let root = try fixture(), engine = engine(root)
        let source = root.appendingPathComponent("Source")
        let child = source.appendingPathComponent("Source")
        try fm.createDirectory(at: child, withIntermediateDirectories: false)
        let descendant = await engine.perform(.copy([source], to: child))
        XCTAssertNotNil(descendant.error)
        let ancestor = await engine.perform(.move([child], to: root), resolve: { _ in ConflictResolution(.replace) })
        XCTAssertNotNil(ancestor.error); XCTAssertTrue(exists(child))
        let alias = root.appendingPathComponent("Alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: child)
        let linked = await engine.perform(.move([source], to: alias))
        XCTAssertNotNil(linked.error); XCTAssertTrue(exists(child))
    }
    func testSymlinksAreCopiedAndTrashedAsLinksIncludingDanglingLinks() async throws {
        let root = try fixture(), engine = engine(root)
        let target = try file("target.txt", in: root)
        let link = root.appendingPathComponent("Source/link")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        let copy = await engine.perform(.copy([link], to: root.appendingPathComponent("Destination")))
        XCTAssertNil(copy.error)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: copy.completed[0].path), target.path)
        let trash = await engine.perform(.trash([link])); XCTAssertNil(trash.error); XCTAssertTrue(exists(target))
        let dangling = root.appendingPathComponent("Source/dangling")
        try fm.createSymbolicLink(atPath: dangling.path, withDestinationPath: "missing")
        let result = await engine.perform(.trash([dangling])); XCTAssertNil(result.error)
        let undo = await engine.undo(); XCTAssertNil(undo.error)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: dangling.path), "missing")
    }
    func testNestedSelectionsArePruned() async throws {
        let root = try fixture(), engine = engine(root)
        let child = try file("Source/child.txt", in: root)
        let result = await engine.perform(.copy([child, root.appendingPathComponent("Source"), child], to: root.appendingPathComponent("Destination")))
        XCTAssertNil(result.error); XCTAssertEqual(result.completed.count, 1)
        XCTAssertTrue(exists(root.appendingPathComponent("Destination/Source/child.txt")))
    }
    func testCaseOnlyRenameAndUndo() async throws {
        let root = try fixture(), engine = engine(root)
        let source = try file("Source/report.txt", in: root)
        let result = await engine.perform(.rename(source, to: "REPORT.txt"))
        XCTAssertNil(result.error)
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: source.deletingLastPathComponent().path).contains("REPORT.txt"))
        let undo = await engine.undo(); XCTAssertNil(undo.error)
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: source.deletingLastPathComponent().path).contains("report.txt"))
    }
    func testReplacementRollbackWhenSourceDisappearsDuringConflict() async throws {
        let root = try fixture(), engine = engine(root)
        let source = try file("Source/report.txt", in: root)
        let old = try file("Destination/report.txt", in: root, text: "old")
        let result = await engine.perform(.move([source], to: old.deletingLastPathComponent()), resolve: { _ in
            try? FileManager().removeItem(at: source)
            return ConflictResolution(.replace)
        })
        XCTAssertNotNil(result.error); XCTAssertEqual(try read(old), "old")
    }
    func testReplacementFailureRestoresDestinationAndRemovesStaging() async throws {
        let root = try fixture()
        let source = try file("Source/report.txt", in: root)
        let old = try file("Destination/report.txt", in: root, text: "old")
        let engine = FileOperationEngine(trashItem: { _ in throw FileOperationError("Injected Trash failure") })
        let result = await engine.perform(.copy([source], to: old.deletingLastPathComponent()), resolve: { _ in ConflictResolution(.replace) })
        XCTAssertNotNil(result.error); XCTAssertEqual(try read(old), "old"); XCTAssertTrue(exists(source))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: old.deletingLastPathComponent().path), ["report.txt"])
    }
    func testCrossVolumeStrategyRetainsSourceAndUndoes() async throws {
        let root = try fixture(), engine = engine(root, crossVolume: true)
        let source = try file("Source/report.txt", in: root)
        let result = await engine.perform(.move([source], to: root.appendingPathComponent("Destination")))
        XCTAssertNil(result.error); XCTAssertFalse(exists(source))
        let destination = try XCTUnwrap(result.completed.first)
        XCTAssertEqual(try read(destination), "original")
        let undo = await engine.undo(); XCTAssertNil(undo.error)
        XCTAssertEqual(try read(source), "original"); XCTAssertFalse(exists(destination))
    }
    func testInvalidNamesAndExistingNewFolderAreRejected() async throws {
        for name in ["", "  ", ".", "..", "a/b", "a:b", "a\0b"] { XCTAssertThrowsError(try FileOperationEngine.validateName(name)) }
        let root = try fixture(), engine = engine(root)
        let result = await engine.perform(.newFolder(in: root, name: "Source"))
        XCTAssertNotNil(result.error); XCTAssertTrue(exists(root.appendingPathComponent("Source")))
    }
    func testUndoPreflightsEntireBatch() async throws {
        let root = try fixture(), engine = engine(root)
        let one = try file("Source/one.txt", in: root), two = try file("Source/two.txt", in: root)
        let result = await engine.perform(.copy([one, two], to: root.appendingPathComponent("Destination")))
        XCTAssertNil(result.error)
        try Data("edited".utf8).write(to: result.completed[0])
        let undo = await engine.undo(); XCTAssertNotNil(undo.error)
        XCTAssertTrue(exists(result.completed[1]))
    }
    func testRepeatedDestinationInOneBatchCanBeUndone() async throws {
        let root = try fixture(), engine = engine(root)
        let one = try file("Source/report.txt", in: root, text: "one")
        let two = try file("report.txt", in: root, text: "two")
        let result = await engine.perform(.copy([one, two], to: root.appendingPathComponent("Destination")), resolve: { _ in ConflictResolution(.replace) })
        XCTAssertNil(result.error); XCTAssertEqual(result.completed.count, 2)
        XCTAssertEqual(try read(result.completed[0]), "two")
        let undo = await engine.undo(); XCTAssertNil(undo.error)
        XCTAssertFalse(exists(result.completed[0])); XCTAssertTrue(exists(one)); XCTAssertTrue(exists(two))
    }
    func testCancellationBetweenItemsKeepsCompletedItemUndoable() async throws {
        let root = try fixture(), engine = engine(root)
        let one = try file("Source/one.txt", in: root), two = try file("Source/two.txt", in: root)
        let task = Task {
            await engine.perform(.copy([one, two], to: root.appendingPathComponent("Destination")), progress: { progress in
                if progress.index == 2 { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        let result = await task.value
        XCTAssertTrue(result.cancelled); XCTAssertEqual(result.completed.count, 1)
        let undo = await engine.undo(); XCTAssertNil(undo.error)
        XCTAssertFalse(exists(root.appendingPathComponent("Destination/one.txt")))
    }
    func testKeepBothHandlesExtensionsAndRepeatedCopies() async throws {
        let root = try fixture(), engine = engine(root)
        let source = try file("Source/report.txt", in: root)
        try file("Destination/report.txt", in: root, text: "old")
        try file("Destination/report - Copy.txt", in: root, text: "earlier")
        let result = await engine.perform(.copy([source], to: root.appendingPathComponent("Destination")), resolve: { _ in ConflictResolution(.keepBoth) })
        XCTAssertNil(result.error); XCTAssertEqual(result.completed.first?.lastPathComponent, "report - Copy (2).txt")
        XCTAssertEqual(try read(root.appendingPathComponent("Destination/report.txt")), "old")
    }
    func testBackupIsRestoredWhenCommitFailsAfterReplacement() async throws {
        let root = try fixture()
        let source = try file("Source/report.txt", in: root)
        let old = try file("Destination/report.txt", in: root, text: "old")
        let engine = FileOperationEngine(trashItem: { url in
            let backup = root.appendingPathComponent("Trash/backup")
            try FileManager().moveItem(at: url, to: backup)
            // Inject failure between moving the old destination aside and committing the move.
            try FileManager().moveItem(at: source, to: root.appendingPathComponent("Source/relocated.txt"))
            return backup
        })
        let result = await engine.perform(.move([source], to: old.deletingLastPathComponent()), resolve: { _ in ConflictResolution(.replace) })
        XCTAssertNotNil(result.error); XCTAssertEqual(try read(old), "old")
        XCTAssertEqual(try read(root.appendingPathComponent("Source/relocated.txt")), "original")
    }
}

private actor Counter {
    var value = 0
    func increment() { value += 1 }
}
