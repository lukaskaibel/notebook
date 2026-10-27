import XCTest
@testable import NotebookKit

/// iOS moves an app's folder with each update of the app, and the notes kept in it move along: a path kept from before
/// in this device's earlier Documents folder is found again at the same place in the new one. Nothing else moves:
/// another device's Documents folder, kept in iCloud with the hidden folders and reminders, or another app's.
final class MovedFolderTests: XCTestCase {
    private let apps = "/private/var/mobile/Containers/Data/Application"
    private var old: String { apps + "/OLD-UUID/Documents" }
    private var new: String { apps + "/NEW-UUID/Documents" }

    func testAPathInTheOldFolderIsFoundInTheNewOne() {
        XCTAssertEqual(Workspace.rerooted(old + "/Journal/Day 1.md", from: [old], into: new), new + "/Journal/Day 1.md")
        XCTAssertEqual(Workspace.rerooted(old + "/Journal", from: [old], into: new), new + "/Journal")
        XCTAssertEqual(Workspace.rerooted(old, from: [old], into: new), new, "the folder itself, as a default folder")
        XCTAssertEqual(Workspace.rerooted("/var/mobile/Containers/Data/Application/OLD-UUID/Documents/Journal", from: [old], into: new), new + "/Journal",
                       "as file events name it")
        let older = apps + "/OLDER-UUID/Documents"
        XCTAssertEqual(Workspace.rerooted(older + "/Journal", from: [old, older], into: new), new + "/Journal", "from two updates ago")
    }

    func testOtherPathsStayAsTheyWere() {
        let otherDevice = apps + "/IPAD-UUID/Documents/Journal"
        XCTAssertEqual(Workspace.rerooted(otherDevice, from: [old], into: new), otherDevice, "another device's, kept in iCloud")
        let obsidian = apps + "/OBSIDIAN-UUID/Documents/Vault/Day 1.md"
        XCTAssertEqual(Workspace.rerooted(obsidian, from: [old], into: new), obsidian, "another app's, in On My iPhone")
        XCTAssertEqual(Workspace.rerooted(new + "/Journal", from: [old], into: new), new + "/Journal", "where it is already")
        let archive = apps + "/OLD-UUID/Documents Archive/Day 1.md"
        XCTAssertEqual(Workspace.rerooted(archive, from: [old], into: new), archive, "not its Documents")
        XCTAssertEqual(Workspace.rerooted(old + "/Journal", from: [], into: new), old + "/Journal", "no update known")
    }

    /// The bookmark of a location in Documents finds it in the new folder: that says where the folder was before, the
    /// first time after updating from a version that didn't keep it.
    func testALocationFoundByItsBookmarkSaysWhereDocumentsWas() {
        // Without "/private", as hidden folders and reminders keep their paths.
        let plain = "/var/mobile/Containers/Data/Application/OLD-UUID/Documents"
        XCTAssertEqual(Workspace.formerDocuments(moved: old, to: new, documents: new), plain, "Keep Notes on This iPhone")
        XCTAssertEqual(Workspace.formerDocuments(moved: old + "/Notes", to: new + "/Notes", documents: new), plain, "a folder in it")
        XCTAssertEqual(Workspace.formerDocuments(moved: plain, to: new, documents: new), plain)
    }

    func testOtherMovesSayNothing() {
        let obsidian = apps + "/OBSIDIAN-UUID/Documents/Vault", moved = apps + "/OBSIDIAN-NEW/Documents/Vault"
        XCTAssertNil(Workspace.formerDocuments(moved: obsidian, to: moved, documents: new), "another app's folder, moved by its own update")
        XCTAssertNil(Workspace.formerDocuments(moved: obsidian, to: new + "/Notes", documents: new), "not the same place")
        XCTAssertNil(Workspace.formerDocuments(moved: "/private/var/mobile/Library/Mobile Documents/Notes", to: new, documents: new), "not an app's Documents")
        XCTAssertNil(Workspace.formerDocuments(moved: old + "/Notes", to: new + "/Notes Renamed", documents: new), "renamed, not moved by an update")
        XCTAssertNil(Workspace.formerDocuments(moved: new + "/Documents/Notes", to: new + "/Notes", documents: new), "moved out of a folder named Documents")
    }

    /// Only a folder that is gone was moved by an update: a folder you moved into Notebook's from another app's leaves
    /// that app's Documents folder where it was, and teaches nothing.
    func testOnlyAGoneFolderWasMovedByAnUpdate() throws {
        let apps = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-moved-\(UUID().uuidString)/Data/Application")
        defer { try? FileManager.default.removeItem(at: apps.deletingLastPathComponent().deletingLastPathComponent()) }
        let new = apps.appendingPathComponent("NEW/Documents").path, old = apps.appendingPathComponent("OLD/Documents").path
        let obsidian = apps.appendingPathComponent("OBSIDIAN/Documents").path
        try FileManager.default.createDirectory(atPath: new + "/Notes", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: obsidian, withIntermediateDirectories: true)

        XCTAssertEqual(Workspace.movedByUpdate(old + "/Notes", to: new + "/Notes", documents: new), old, "the app's folder of before, gone")
        XCTAssertNil(Workspace.movedByUpdate(obsidian + "/Notes", to: new + "/Notes", documents: new), "moved in from Obsidian, still there")
        XCTAssertNil(Workspace.movedByUpdate(new + "/Notes", to: new + "/Notes", documents: new), "not moved")
    }

    /// A to-do's notification is named from its note's place in Documents, so a place that reminded you doesn't remind
    /// you again after an update.
    func testANoteInDocumentsIsNamedFromThere() {
        XCTAssertEqual(Workspace.lastingPath(old + "/Garden.md", documents: old), Workspace.lastingPath(new + "/Garden.md", documents: new))
        XCTAssertEqual(Workspace.lastingPath(new + "/Garden.md", documents: new), "Documents/Garden.md")
        XCTAssertEqual(Workspace.lastingPath("/private/tmp/Notes/Garden.md", documents: new), "/tmp/Notes/Garden.md", "elsewhere, as it is")
    }
}
