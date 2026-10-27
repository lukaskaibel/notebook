import XCTest
@testable import NotebookKit

/// Folders hidden from the sidebar: named the same on every device, kept, and left out of the sidebar, search and
/// Move To until their location shows them. Built on a stand-in iCloud Drive, as in LocationTests.
@MainActor
final class HiddenFolderTests: XCTestCase {
    private var base: URL!
    private var drive: URL!
    private var defaults: UserDefaults!
    private var desktop: URL { base.appendingPathComponent("Desktop") }
    private var archive: URL { drive.appendingPathComponent("Archive") }
    private var old: URL { archive.appendingPathComponent("2025/Old apartment.md") }
    private var draft: URL { drive.appendingPathComponent("Papers/Draft.md") }

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-hidden-\(UUID().uuidString)").standardizedFileURL
        let containers = base.appendingPathComponent("Mobile Documents")
        drive = containers.appendingPathComponent("com~apple~CloudDocs")
        try make(archive.appendingPathComponent("2025"))
        try make(drive.appendingPathComponent("Papers"))
        try make(desktop.appendingPathComponent("Trip"))
        try make(containers.appendingPathComponent("iCloud~md~obsidian/Documents/Vault"))
        try "# Handover\n".write(to: old, atomically: true, encoding: .utf8)
        try "# Draft\n".write(to: draft, atomically: true, encoding: .utf8)
        try "# Plan\n".write(to: desktop.appendingPathComponent("Trip/Plan.md"), atomically: true, encoding: .utf8)
        let link = drive.appendingPathComponent("Desktop")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: desktop)
        XCTAssertEqual(lchflags(link.path, UInt32(UF_HIDDEN)), 0)
        UserDefaults.standard.set(drive.path, forKey: "NotebookICloudDrive")
        defaults = TestRun.settings()
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "NotebookICloudDrive")
        UserDefaults.standard.removeObject(forKey: "NotebookLibrary")
        try? FileManager.default.removeItem(at: base)
    }

    private func make(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// A library folder for this run only, so nothing is kept, and iCloud Drive opened as File › Open does.
    private func makeWorkspace() async throws -> (Workspace, SidebarController, Location) {
        let library = base.appendingPathComponent("Library")
        try make(library)
        UserDefaults.standard.set(library.path, forKey: "NotebookLibrary")
        let workspace = Workspace()
        workspace.start()
        workspace.openFolder(drive)
        let sidebar = SidebarController(workspace: workspace)
        try await TestRun.wait(while: { workspace.index.isBuilding || workspace.index.entry(for: old) == nil })
        let location = try XCTUnwrap(workspace.location(containing: drive))
        return (workspace, sidebar, location)
    }

    private func shown(_ sidebar: SidebarController, _ workspace: Workspace, _ location: Location) throws -> [String] {
        try sidebar.visibleChildren(of: XCTUnwrap(workspace.root(for: location))).map(\.name)
    }

    func testFoldersAreNamedByTheirPlaceInICloud() {
        let links = Location.iCloudDriveLinks(in: drive)
        XCTAssertEqual(HiddenFolders.key(for: archive, links: links), "com~apple~CloudDocs/Archive")
        // A Mac keeps Desktop in ~/Desktop, an iPhone in iCloud Drive: both name it the same.
        XCTAssertEqual(HiddenFolders.key(for: desktop, links: links), "com~apple~CloudDocs/Desktop")
        XCTAssertEqual(HiddenFolders.key(for: desktop.appendingPathComponent("Trip"), links: links), "com~apple~CloudDocs/Desktop/Trip")
        let iPhone = URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Desktop/Trip")
        XCTAssertEqual(HiddenFolders.key(for: iPhone, links: []), "com~apple~CloudDocs/Desktop/Trip")
        let vault = base.appendingPathComponent("Mobile Documents/iCloud~md~obsidian/Documents/Vault")
        XCTAssertEqual(HiddenFolders.key(for: vault, links: links), "iCloud~md~obsidian/Documents/Vault")
        XCTAssertEqual(HiddenFolders.key(for: URL(fileURLWithPath: "/Users/someone/Notes/Old/"), links: links), "/Users/someone/Notes/Old")
    }

    /// File events report "/private/tmp/…" for what the sidebar has as "/tmp/…".
    func testPrivateAndPlainPathsAreOneFolder() {
        XCTAssertEqual(HiddenFolders.key(for: URL(fileURLWithPath: "/private/tmp/Notes/Old"), links: []), "/tmp/Notes/Old")
        XCTAssertEqual(HiddenFolders.key(for: URL(fileURLWithPath: "/tmp/Notes/Old"), links: []), "/tmp/Notes/Old")
        let index = SearchIndex()
        index.hiddenPaths = ["/tmp/Notes/Old"]
        XCTAssertTrue(index.isHidden(URL(fileURLWithPath: "/private/tmp/Notes/Old/Note.md")))
        XCTAssertTrue(index.isHidden(URL(fileURLWithPath: "/tmp/Notes/Old")))
        XCTAssertFalse(index.isHidden(URL(fileURLWithPath: "/private/tmp/Notes/Older/Note.md")))
    }

    func testHiddenFoldersAreKeptAndFollowRenames() {
        let store = HiddenFolders(defaults: defaults, cloud: nil)
        store.set("com~apple~CloudDocs/Archive", hidden: true)
        store.set("com~apple~CloudDocs/Archive/2025", hidden: true)
        store.set("com~apple~CloudDocs/Archived", hidden: true)
        XCTAssertEqual(HiddenFolders(defaults: defaults, cloud: nil).keys, ["com~apple~CloudDocs/Archive", "com~apple~CloudDocs/Archive/2025", "com~apple~CloudDocs/Archived"])

        store.move("com~apple~CloudDocs/Archive", to: "com~apple~CloudDocs/Old")
        XCTAssertEqual(HiddenFolders(defaults: defaults, cloud: nil).keys, ["com~apple~CloudDocs/Archived", "com~apple~CloudDocs/Old", "com~apple~CloudDocs/Old/2025"])
        store.forget("com~apple~CloudDocs/Old")
        XCTAssertEqual(HiddenFolders(defaults: defaults, cloud: nil).keys, ["com~apple~CloudDocs/Archived"])
    }

    /// Tests run without the iCloud entitlement, as a build without a team does: the store refuses, the settings keep them.
    func testWithoutICloudTheSettingsKeepThem() {
        HiddenFolders(defaults: defaults, cloud: .default).set("com~apple~CloudDocs/Archive", hidden: true)
        XCTAssertEqual(HiddenFolders(defaults: defaults, cloud: .default).keys, ["com~apple~CloudDocs/Archive"])
    }

    func testCloudKeysFitTheStore() {
        let long = String(repeating: "A folder with a long name/", count: 20)
        XCTAssertLessThanOrEqual(HiddenFolders.cloudKey(long).utf8.count, 64)
        XCTAssertEqual(HiddenFolders.cloudKey(long), HiddenFolders.cloudKey(long))
        XCTAssertNotEqual(HiddenFolders.cloudKey("com~apple~CloudDocs/Archive"), HiddenFolders.cloudKey("com~apple~CloudDocs/Archived"))
    }

    func testHiddenFoldersLeaveTheSidebarSearchAndMoveTo() async throws {
        let (workspace, sidebar, location) = try await makeWorkspace()
        XCTAssertEqual(try shown(sidebar, workspace, location), ["Archive", "Desktop", "Obsidian", "Papers"])
        XCTAssertFalse(workspace.hasHiddenFolders(in: location))
        XCTAssertFalse(workspace.canHide(drive), "a location's own top stays")
        XCTAssertTrue(workspace.canHide(desktop))

        workspace.setHidden(archive, true)
        workspace.setHidden(desktop, true)
        XCTAssertEqual(try shown(sidebar, workspace, location), ["Obsidian", "Papers"])
        XCTAssertTrue(workspace.hasHiddenFolders(in: location))
        XCTAssertTrue(workspace.isHidden(drive.appendingPathComponent("Desktop")), "the link and the folder are one")

        XCTAssertTrue(workspace.index.files(matching: "Old apartment").isEmpty)
        XCTAssertTrue(workspace.index.textHits("Handover").isEmpty)
        XCTAssertTrue(workspace.index.folders(matching: "2025").isEmpty)
        XCTAssertTrue(workspace.index.files(matching: "Plan").isEmpty)
        XCTAssertEqual(workspace.index.files(matching: "Draft").map(\.name), ["Draft"])
        XCTAssertEqual(workspace.index.resolve("Old apartment", from: draft)?.lastPathComponent, "Old apartment.md", "links still find it")
        let targets = workspace.moveTargets(for: draft).first { $0.location.id == location.id }?.folders
        XCTAssertEqual(targets?.map(\.name), ["iCloud Drive", "Obsidian", "Vault", "Papers"])

        workspace.showHiddenFolders(true, in: location)
        XCTAssertEqual(try shown(sidebar, workspace, location), ["Archive", "Desktop", "Obsidian", "Papers"])
        XCTAssertEqual(workspace.index.files(matching: "Old apartment").map(\.name), ["Old apartment"])
        XCTAssertTrue(workspace.showsAllHiddenFolders)

        // With its last hidden folder shown again, the location stops showing hidden ones.
        workspace.setHidden(archive, false)
        XCTAssertTrue(workspace.showsHiddenFolders(in: location))
        workspace.setHidden(desktop, false)
        XCTAssertFalse(workspace.showsHiddenFolders(in: location))
        XCTAssertFalse(workspace.hasHiddenFolders)
    }

    func testViewMenuShowsEveryLocationsHiddenFolders() async throws {
        let (workspace, sidebar, location) = try await makeWorkspace()
        let library = try XCTUnwrap(workspace.locations.first { $0.id != location.id })
        try make(library.url.appendingPathComponent("Clutter"))
        await workspace.readAgain(library.url)
        workspace.setHidden(library.url.appendingPathComponent("Clutter"), true)
        workspace.setHidden(archive, true)
        XCTAssertEqual(try shown(sidebar, workspace, library), [])

        workspace.toggleAllHiddenFolders()
        XCTAssertTrue(workspace.showsHiddenFolders(in: library) && workspace.showsHiddenFolders(in: location))
        XCTAssertEqual(try shown(sidebar, workspace, library), ["Clutter"])
        workspace.toggleAllHiddenFolders()
        XCTAssertFalse(workspace.showsHiddenFolders(in: library) || workspace.showsHiddenFolders(in: location))
    }

    func testRenamedFoldersStayHiddenAndTrashedOnesAreForgotten() async throws {
        let (workspace, sidebar, location) = try await makeWorkspace()
        workspace.setHidden(archive, true)
        let renaming = await workspace.rename(archive, to: "Old").value
        let renamed = try XCTUnwrap(renaming)
        XCTAssertTrue(workspace.isHidden(renamed))
        XCTAssertEqual(try shown(sidebar, workspace, location), ["Desktop", "Obsidian", "Papers"])

        _ = await workspace.trash(renamed).value
        XCTAssertTrue(workspace.hidden.keys.isEmpty)
        try make(renamed)
        await workspace.readAgain(drive)
        XCTAssertEqual(try shown(sidebar, workspace, location), ["Desktop", "Obsidian", "Old", "Papers"])
    }
}
