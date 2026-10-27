import XCTest
@testable import NotebookKit

/// What a test sets reaches no other test run on the Mac, and the tests stay out of the app's own stores, also when
/// they run with `swift test` (#136, #198).
final class TestRunTests: XCTestCase {
    func testSettingsAreTheRunsOwn() throws {
        let key = "NotebookTestRunProbe"
        UserDefaults.standard.set("here", forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let own = TestRun.folder.appendingPathComponent("Settings").path
        XCTAssertEqual(UserDefaults.standard.persistentDomain(forName: own)?[key] as? String, "here")
        let shared = try XCTUnwrap(Bundle.main.bundleIdentifier)
        XCTAssertNil(UserDefaults.standard.persistentDomain(forName: shared)?[key], "in the settings every test run shares")
    }

    func testTheAppsStoresAreLeftAlone() {
        XCTAssertTrue(ProcessInfo.isTesting)
        XCTAssertNil(SearchIndex.storeURL(), "the kept index")
        XCTAssertNil(SearchIndex.storeURL(library: "/tmp/Notes", name: "Spotlight", in: .applicationSupportDirectory), "Spotlight's record")
    }
}
