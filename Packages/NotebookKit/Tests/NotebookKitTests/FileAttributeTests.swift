import XCTest
@testable import NotebookKit

/// What the Finder and other apps keep on a note's file, its tags and other extended attributes, stays when Notebook
/// writes the note: saving what was typed, ticking a to-do in To-dos and changing its links.
@MainActor
final class FileAttributeTests: XCTestCase {
    private var library: URL!
    private var note: URL { library.appendingPathComponent("Note.md") }
    private let attribute = "com.example.notebook-test"

    override func setUp() async throws {
        library = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-attributes-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try "# Note\n\n- [ ] Water the plants\n\nSee [[Plan]].\n".write(to: note, atomically: true, encoding: .utf8)
        var url = note
        var values = URLResourceValues()
        values.tagNames = ["Red"]
        try url.setResourceValues(values)
        let value = Array("kept".utf8)
        XCTAssertEqual(setxattr(note.path, attribute, value, value.count, 0, 0), 0)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "NotebookLibrary")
        try? FileManager.default.removeItem(at: library)
    }

    private func assertKept(_ when: String, file: StaticString = #filePath, line: UInt = #line) {
        var url = note
        url.removeAllCachedResourceValues()
        XCTAssertEqual(try url.resourceValues(forKeys: [.tagNamesKey]).tagNames, ["Red"], "the tag, after \(when)", file: file, line: line)
        var value = [UInt8](repeating: 0, count: 16)
        let length = getxattr(note.path, attribute, &value, value.count, 0, 0)
        XCTAssertEqual(length > 0 ? String(decoding: value.prefix(length), as: UTF8.self) : nil, "kept", "the attribute, after \(when)", file: file, line: line)
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(condition(), "timed out")
    }

    func testTagsAndAttributesStayWhenANoteIsWritten() async throws {
        let document = NoteDocument(url: note)
        document.update(text: document.text + "More.\n")
        await document.save()
        document.close()
        XCTAssertTrue(try String(contentsOf: note, encoding: .utf8).hasSuffix("More.\n"))
        assertKept("saving")

        UserDefaults.standard.set(library.path, forKey: "NotebookLibrary")
        let workspace = Workspace()
        workspace.start()
        try await until { !workspace.index.isBuilding && workspace.todos.isReady }
        let todo = try XCTUnwrap(workspace.todos.items.first { $0.todo.text == "Water the plants" })
        await workspace.setTodoDone(todo.reference, true)?.value
        XCTAssertTrue(try String(contentsOf: note, encoding: .utf8).contains("- [x] Water the plants"))
        assertKept("ticking a to-do")

        let rewritten = FileOperations.rewriteLinks(in: note) { text in
            (text.replacingOccurrences(of: "[[Plan]]", with: "[[Plans/Plan]]"), [])
        }
        XCTAssertNotNil(rewritten)
        XCTAssertTrue(try String(contentsOf: note, encoding: .utf8).contains("[[Plans/Plan]]"))
        assertKept("changing its links")
    }
}
