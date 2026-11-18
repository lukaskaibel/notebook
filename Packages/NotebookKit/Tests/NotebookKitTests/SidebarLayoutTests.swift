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

    /// With a mouse attached Recent's row, which scrolls sideways, has no scroll bar under its cards: one took its room
    /// from the row's height and cut off the top of the cards.
    func testRecentHasNoScrollBarWithAMouseAttached() async throws {
        UserDefaults.standard.set("Always", forKey: "AppleShowScrollBars")
        let delay = Workspace.recentCardsDelay
        Workspace.recentCardsDelay = .zero
        defer {
            UserDefaults.standard.removeObject(forKey: "AppleShowScrollBars")
            Workspace.recentCardsDelay = delay
        }
        let (workspace, sidebar, window) = try await makeSidebar()
        for index in 2...4 { workspace.open(library.appendingPathComponent("Note \(index).md")) }
        try await until("Recent has four cards") { workspace.recentCardURLs.count >= 4 }

        func cards() -> (cell: NSView, scrollView: NSScrollView)? {
            guard let row = recentRow(in: sidebar),
                  let cell = sidebar.outline.view(atColumn: 0, row: row, makeIfNecessary: true) else { return nil }
            window.layoutIfNeeded()
            window.displayIfNeeded()
            return Self.descendants(of: cell).lazy.compactMap { $0 as? NSScrollView }.first.map { (cell, $0) }
        }
        try await until("the cards run past the row's edge") {
            guard let scrollView = cards()?.scrollView, let content = scrollView.documentView else { return false }
            return content.frame.width > scrollView.contentView.bounds.width
        }
        let (cell, scrollView) = try XCTUnwrap(cards())
        let bars = Self.descendants(of: scrollView).compactMap { $0 as? NSScroller }.filter { !$0.isHiddenOrHasHiddenAncestor && $0.frame.width > $0.frame.height }
        XCTAssertEqual(bars.count, 0, "style \(scrollView.scrollerStyle.rawValue), has bar \(scrollView.hasHorizontalScroller)")
        let content = try XCTUnwrap(scrollView.documentView)
        XCTAssertGreaterThanOrEqual(scrollView.contentView.bounds.height, content.frame.height, "the cards fit, nothing cut off")
        XCTAssertLessThanOrEqual(scrollView.frame.height, cell.frame.height, "the row holds them")

        // It still scrolls, with two fingers or a mouse's side wheel.
        let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -120, wheel3: 0))
        scrollView.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: wheel)))
        try await until("the row scrolled") { scrollView.contentView.bounds.minX > 0 }
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
}
#endif
