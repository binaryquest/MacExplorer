import XCTest
import Darwin
@testable import ExplorerCore

@MainActor
final class ArchiveTests: XCTestCase {
    private let fm = FileManager.default
    private func fixture() throws -> (URL, FileOperationEngine) {
        let root = fm.temporaryDirectory.appendingPathComponent("Explorer-ZIP-\(UUID())").resolvingSymlinksInPath()
        try fm.createDirectory(at: root.appendingPathComponent("Trash"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, FileOperationEngine(trashItem: { url in
            let trash = root.appendingPathComponent("Trash/\(UUID())")
            try FileManager.default.moveItem(at: url, to: trash); return trash
        }))
    }
    private func file(_ name: String, in root: URL, text: String = "original") throws -> URL {
        let url = root.appendingPathComponent(name)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url); return url
    }
    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    private func assertClean(_ root: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".explorer-archive-") }, file: file, line: line)
    }

    func testRoundTripMultipleItemsUnicodeNewlinesAndLiteralShellNamesThenUndo() async throws {
        let (root, engine) = try fixture()
        let names = ["-leading.txt", "@literal", "line\nbreak.json", "Space & Quote's $(literal) 日本語.yaml", ".hidden"]
        let inputs = try names.map { try file($0, in: root) }
        let archive = root.appendingPathComponent("Archive.zip"), output = root.appendingPathComponent("Unpacked")
        let compress = await engine.perform(.compress(inputs, to: archive))
        XCTAssertNil(compress.error); XCTAssertEqual(compress.completed, [archive])
        let extract = await engine.perform(.extract(archive, to: output))
        XCTAssertNil(extract.error); XCTAssertEqual(extract.completed, [output])
        for name in names { XCTAssertEqual(try read(output.appendingPathComponent(name)), "original") }
        let undoExtract = await engine.undo(); XCTAssertNil(undoExtract.error)
        XCTAssertFalse(fm.fileExists(atPath: output.path)); XCTAssertTrue(fm.fileExists(atPath: archive.path))
        let undoCompress = await engine.undo(); XCTAssertNil(undoCompress.error)
        XCTAssertFalse(fm.fileExists(atPath: archive.path))
        for input in inputs { XCTAssertEqual(try read(input), "original") }
        try assertClean(root)
    }

    func testFoldersEmptyFoldersSymlinksAndDuplicateSelection() async throws {
        let (root, engine) = try fixture()
        let input = try file("Folder/nested/config.json", in: root)
        let folder = root.appendingPathComponent("Folder")
        try fm.createDirectory(at: folder.appendingPathComponent("Empty"), withIntermediateDirectories: false)
        try fm.createSymbolicLink(atPath: folder.appendingPathComponent("link").path, withDestinationPath: "nested/config.json")
        let archive = root.appendingPathComponent("Folder.zip"), output = root.appendingPathComponent("Result")
        let compress = await engine.perform(.compress([folder, input, folder], to: archive))
        XCTAssertNil(compress.error)
        let extract = await engine.perform(.extract(archive, to: output)); XCTAssertNil(extract.error)
        XCTAssertEqual(try read(output.appendingPathComponent("Folder/nested/config.json")), "original")
        XCTAssertTrue(fm.fileExists(atPath: output.appendingPathComponent("Folder/Empty").path))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: output.appendingPathComponent("Folder/link").path), "nested/config.json")
    }

    func testSearchSelectionsKeepDistinctParentPaths() async throws {
        let (root, engine) = try fixture()
        let one = try file("One/settings.json", in: root, text: "one")
        let two = try file("Two/settings.json", in: root, text: "two")
        let archive = root.appendingPathComponent("Archive.zip"), output = root.appendingPathComponent("Result")
        let compress = await engine.perform(.compress([one, two], to: archive)); XCTAssertNil(compress.error)
        let extract = await engine.perform(.extract(archive, to: output)); XCTAssertNil(extract.error)
        XCTAssertEqual(try read(output.appendingPathComponent("One/settings.json")), "one")
        XCTAssertEqual(try read(output.appendingPathComponent("Two/settings.json")), "two")
    }

    func testConflictsReplaceAndUndoRestoreExistingArchiveAndFolder() async throws {
        let (root, engine) = try fixture()
        let input = try file("input.txt", in: root), archive = try file("Archive.zip", in: root, text: "old zip")
        let output = root.appendingPathComponent("Result")
        let old = try file("Result/keep.txt", in: root, text: "keep")
        let compress = await engine.perform(.compress([input], to: archive), resolve: { _ in .init(.replace) })
        XCTAssertNil(compress.error)
        let extract = await engine.perform(.extract(archive, to: output), resolve: { _ in .init(.replace) })
        XCTAssertNil(extract.error); XCTAssertFalse(fm.fileExists(atPath: old.path))
        let undoExtract = await engine.undo(); XCTAssertNil(undoExtract.error)
        XCTAssertEqual(try read(old), "keep")
        let undoCompress = await engine.undo(); XCTAssertNil(undoCompress.error)
        XCTAssertEqual(try read(archive), "old zip")
        try assertClean(root)
    }

    func testKeepBothSkipAndCancelLeaveExistingOutputUntouched() async throws {
        let (root, engine) = try fixture()
        let input = try file("input.txt", in: root), archive = try file("Archive.zip", in: root, text: "keep")
        let kept = await engine.perform(.compress([input], to: archive), resolve: { _ in .init(.keepBoth) })
        XCTAssertNil(kept.error); XCTAssertEqual(kept.completed.first?.lastPathComponent, "Archive - Copy.zip")
        let skipped = await engine.perform(.compress([input], to: archive), resolve: { _ in .init(.skip) })
        XCTAssertEqual(skipped.skipped, 1)
        let cancelled = await engine.perform(.compress([input], to: archive), resolve: { _ in .init(.cancel) })
        XCTAssertTrue(cancelled.cancelled); XCTAssertEqual(try read(archive), "keep")
        let output = root.appendingPathComponent("Result")
        try fm.createDirectory(at: output, withIntermediateDirectories: false)
        let extracted = await engine.perform(.extract(try XCTUnwrap(kept.completed.first), to: output), resolve: { _ in .init(.keepBoth) })
        XCTAssertNil(extracted.error); XCTAssertEqual(extracted.completed.first?.lastPathComponent, "Result - Copy")
    }

    func testUndoProtectsEditedExtractedFiles() async throws {
        let (root, engine) = try fixture()
        let archive = try zip([("file.txt", "original", false)], in: root)
        let output = root.appendingPathComponent("Result")
        let extract = await engine.perform(.extract(archive, to: output)); XCTAssertNil(extract.error)
        let edited = try file("file.txt", in: output, text: "edited")
        let undo = await engine.undo(); XCTAssertNotNil(undo.error); XCTAssertEqual(try read(edited), "edited")
    }

    func testUnsafeTraversalAndSymlinkTraversalNeverEscapeStaging() async throws {
        let (root, engine) = try fixture()
        let outside = try file("outside/keep.txt", in: root, text: "untouched")
        let output = root.appendingPathComponent("Result")
        for entries in [[("../../outside/keep.txt", "bad", false)],
                        [("escape", outside.deletingLastPathComponent().path, true), ("escape/keep.txt", "bad", false)]] {
            let archive = try zip(entries, in: root)
            let extract = await engine.perform(.extract(archive, to: output))
            XCTAssertNotNil(extract.error); XCTAssertTrue(extract.completed.isEmpty)
            XCTAssertEqual(try read(outside), "untouched"); XCTAssertFalse(fm.fileExists(atPath: output.path))
            try assertClean(root)
        }
    }

    func testAbsoluteEntriesAreConfinedAndQuarantineIsPreserved() async throws {
        let (root, engine) = try fixture()
        let outside = try file("outside.txt", in: root, text: "untouched")
        let archive = try zip([(outside.path, "extracted", false)], in: root)
        let quarantine = Data("0081;12345678;ExplorerTests;".utf8)
        XCTAssertEqual(quarantine.withUnsafeBytes { setxattr(archive.path, "com.apple.quarantine", $0.baseAddress, quarantine.count, 0, 0) }, 0)
        let output = root.appendingPathComponent("Result")
        let result = await engine.perform(.extract(archive, to: output)); XCTAssertNil(result.error)
        XCTAssertEqual(try read(outside), "untouched")
        let extracted = output.appendingPathComponent(String(outside.path.dropFirst()))
        XCTAssertEqual(try read(extracted), "extracted")
        XCTAssertEqual(getxattr(extracted.path, "com.apple.quarantine", nil, 0, 0, 0), quarantine.count)
    }

    func testCancellationAndCorruptZIPDoNotPublishPartialFiles() async throws {
        let (root, engine) = try fixture()
        let input = try file("input.txt", in: root)
        let archive = root.appendingPathComponent("Archive.zip")
        let task = Task { await engine.perform(.compress([input], to: archive), progress: { _ in
            withUnsafeCurrentTask { $0?.cancel() }
        }) }
        let cancelled = await task.value
        XCTAssertTrue(cancelled.cancelled); XCTAssertFalse(fm.fileExists(atPath: archive.path))
        let broken = try file("broken.zip", in: root, text: "PK\u{3}\u{4}broken")
        let output = root.appendingPathComponent("Result")
        let corrupt = await engine.perform(.extract(broken, to: output))
        XCTAssertNotNil(corrupt.error); XCTAssertFalse(fm.fileExists(atPath: output.path))
        try assertClean(root)
    }

    func testSelfDestinationAndConcurrentDestinationAreProtected() async throws {
        let (root, engine) = try fixture()
        let input = try file("Folder/input.txt", in: root), folder = input.deletingLastPathComponent()
        let invalid = await engine.perform(.compress([folder], to: folder.appendingPathComponent("recursive.zip")))
        XCTAssertNotNil(invalid.error)
        let archive = root.appendingPathComponent("Archive.zip")
        let raced = await engine.perform(.compress([input], to: archive), progress: { _ in
            try? Data("arrived during compression".utf8).write(to: archive)
        })
        XCTAssertNotNil(raced.error); XCTAssertEqual(try read(archive), "arrived during compression")
        try assertClean(root)
    }

    func testNonRegularZIPIsRejectedWithoutWaitingForInput() async throws {
        let (root, engine) = try fixture()
        let pipe = root.appendingPathComponent("pipe.zip")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        let result = await engine.perform(.extract(pipe, to: root.appendingPathComponent("Result")))
        XCTAssertNotNil(result.error); XCTAssertTrue(result.completed.isEmpty)
        try assertClean(root)
    }

    /// Minimal independent stored-ZIP fixture writer: permits malicious entry
    /// names and Unix symlink metadata that normal archive creation sanitizes.
    private func zip(_ entries: [(String, String, Bool)], in root: URL) throws -> URL {
        var data = Data(), central = Data()
        func bytes<T: FixedWidthInteger>(_ value: T) -> Data {
            var little = value.littleEndian; return withUnsafeBytes(of: &little) { Data($0) }
        }
        for (name, text, symlink) in entries {
            let path = Data(name.utf8), content = Data(text.utf8), offset = UInt32(data.count)
            var crc: UInt32 = 0xffffffff
            for byte in content {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0) }
            }
            crc ^= 0xffffffff
            data += bytes(UInt32(0x04034b50))
            for value: UInt16 in [20, 0x0800, 0, 0, 0] { data += bytes(value) }
            for value in [crc, UInt32(content.count), UInt32(content.count)] { data += bytes(value) }
            data += bytes(UInt16(path.count)); data += bytes(UInt16(0)); data += path; data += content
            central += bytes(UInt32(0x02014b50))
            for value: UInt16 in [0x0314, 20, 0x0800, 0, 0, 0] { central += bytes(value) }
            for value in [crc, UInt32(content.count), UInt32(content.count)] { central += bytes(value) }
            for value: UInt16 in [UInt16(path.count), 0, 0, 0, 0] { central += bytes(value) }
            central += bytes(UInt32(symlink ? 0o120777 : 0o100644) << 16)
            central += bytes(offset); central += path
        }
        let centralOffset = UInt32(data.count); data += central
        data += bytes(UInt32(0x06054b50))
        for value: UInt16 in [0, 0, UInt16(entries.count), UInt16(entries.count)] { data += bytes(value) }
        data += bytes(UInt32(central.count)); data += bytes(centralOffset); data += bytes(UInt16(0))
        let url = root.appendingPathComponent("fixture-\(UUID()).zip"); try data.write(to: url); return url
    }
}
