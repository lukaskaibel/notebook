#if os(macOS)
import AppKit
import XCTest
@testable import NotebookKit

/// Recent's row in the Mac's sidebar is as tall as its cards, which follow the sidebar's width, but not the scroll bar's
/// room. With a mouse attached (or scroll bars set to show always) the scroll bar takes room as the files grow past the
/// window; when Recent took its height from that narrower width, files a few points past the edge fitted once it came,
/// lost it, grew past the edge again, and so on: a new note that brought them there stopped the app, in 1.3.0 build
/// 2026.1109.36. That endless round needs the window on screen; this checks what started it.
@MainActor
final class SidebarLayoutTests: XCTestCase {
    private var library: URL!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        library = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-sidebar-layout-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        for index in 1...24 {
            try "Note \(index).\n".write(to: library.appendingPathComponent("Note \(index).md"), atomically: true, encoding: .utf8)
        }
        UserDefaults.standard.set(library.path, forKey: "NotebookLibrary")
        UserDefaults.standard.set("Notes", forKey: "NotebookLibraryName")
        UserDefaults.standard.removeObject(forKey: "expandedFolders")
        UserDefaults.standard.removeObject(forKey: "collapsedSections")
    }

    override func tearDown() async throws {
        for key in ["NotebookLibrary", "NotebookLibraryName", "expandedFolders", "collapsedSections"] { UserDefaults.standard.removeObject(forKey: key) }
        windows.forEach { $0.close() }
        try? FileManager.default.removeItem(at: library)
    }

    private func until(_ what: String, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(TestRun.patience)
        while !condition() {
            guard Date() < end else { return XCTFail("never: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The library, read, in a sidebar filling a window, with a note opened so Recent shows, and scroll bars that take
    /// room, as with a mouse attached.
    private func makeSidebar() async throws -> (Workspace, SidebarController, NSWindow) {
        let workspace = Workspace()
        let sidebar = SidebarController(workspace: workspace)
        workspace.start()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        windows.append(window)
        sidebar.scrollView.frame = window.contentView!.bounds
        sidebar.scrollView.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(sidebar.scrollView)
        try await until("the library was read") { workspace.hasReadLocations && workspace.reader.isIdle }
        workspace.open(library.appendingPathComponent("Note 1.md"))
        try await until("Recent shows") { recentRow(in: sidebar) != nil }
        sidebar.scrollView.scrollerStyle = .legacy
        window.layoutIfNeeded()
        return (workspace, sidebar, window)
    }

    private func recentRow(in sidebar: SidebarController) -> Int? {
        (0..<sidebar.outline.numberOfRows).first { row in
            if case .recent? = (sidebar.outline.item(atRow: row) as? SidebarEntry)?.kind { return true }
            return false
        }
    }

    private func setHeight(_ height: CGFloat, of window: NSWindow) {
        window.setContentSize(NSSize(width: 260, height: height))
        window.layoutIfNeeded()
        window.displayIfNeeded()
    }

    /// Recent's row keeps its height whether the scroll bar is there or not: the files' height never depends on the
    /// scroll bar it decides on.
    func testRecentKeepsItsHeightAsTheScrollBarComesAndGoes() async throws {
        let (_, sidebar, window) = try await makeSidebar()
        let files = sidebar.outline.frame.height
        setHeight(files + 200, of: window)
        let row = try XCTUnwrap(recentRow(in: sidebar))
        let roomy = (width: sidebar.outline.bounds.width, recent: sidebar.outline.rect(ofRow: row).height)
        setHeight(files / 2, of: window)
        XCTAssertEqual(sidebar.scrollView.scrollerStyle, .legacy)
        let cramped = (width: sidebar.outline.bounds.width, recent: sidebar.outline.rect(ofRow: row).height)
        XCTAssertLessThan(cramped.width, roomy.width, "the scroll bar takes room")
        XCTAssertEqual(cramped.recent, roomy.recent, "Recent is as tall either way")
    }
}
#endif
