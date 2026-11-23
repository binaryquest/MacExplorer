import AppKit
import Testing
@testable import ExplorerApp

@Suite @MainActor
struct PathSuggestionTests {
    @Test func tabShowsChildFoldersAndEditingClearsPreviousSuggestions() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Explorer-Suggestions-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["Alpha/Child", "Alpine", "Beta"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let bar = PathBar(frame: NSRect(x: 0, y: 60, width: 420, height: 34))
        window.contentView?.addSubview(bar)
        bar.update(root)
        let visible = try #require(bar.subviews.compactMap { $0 as? NSTextField }.first)
        #expect(!visible.isHidden && visible.stringValue == root.path)
        bar.beginEditing()
        let field = try #require(bar.subviews.compactMap { $0 as? NSTextField }.first)
        let editor = try #require(field.currentEditor() as? NSTextView)

        func enter(_ text: String) {
            field.stringValue = text
            bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        }
        func press(_ command: Selector) -> Bool {
            bar.control(field, textView: editor, doCommandBy: command)
        }

        enter("Alp")
        bar.update(root)
        #expect(field.stringValue == "Alp")
        await bar.suggestionTask?.value
        #expect(press(#selector(NSResponder.insertTab(_:))))
        #expect(field.stringValue == "Alpha/")
        await bar.suggestionTask?.value
        #expect(press(#selector(NSResponder.moveDown(_:))))
        #expect(field.stringValue == "Alpha/Child")

        enter("Alpine")
        #expect(!press(#selector(NSResponder.moveDown(_:))))
        #expect(field.stringValue == "Alpine")
        let supersededLookup = try #require(bar.suggestionTask)
        enter("Be")
        #expect(supersededLookup.isCancelled)
        await supersededLookup.value
        await bar.suggestionTask?.value
        #expect(press(#selector(NSResponder.moveDown(_:))))
        #expect(field.stringValue == "Beta")
    }
}
