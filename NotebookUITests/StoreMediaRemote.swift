import XCTest

/// Not a test of Notebook: a remote for the system's own apps, such as Files, which Tools/app-store-media.sh films and
/// photographs for the App Store. Notebook itself has its debug remote (Debug/DebugRemote+UIKit.swift); Files has
/// none, so this taps it as a person would. It runs only when the script starts it with the path of a command file
/// (`TEST_RUNNER_STORE_MEDIA_COMMANDS`), reads that file a line at a time as lines come, and writes `> <line>` to
/// `<file>.log` after each:
///   open <bundle identifier>   brings that app to the front, launching it if needed
///   tap <label>                taps the first element with that accessibility label
///   open-item <name>           taps the item of a Files folder whose label starts with that name
///   tree                       writes what the app shows to the log, for finding labels
///   press <seconds> <label>    holds a finger on it
///   wait <seconds>
///   done                       ends the remote
final class StoreMediaRemote: XCTestCase {
    func testRemote() throws {
        guard let path = ProcessInfo.processInfo.environment["STORE_MEDIA_COMMANDS"] else {
            throw XCTSkip("Only for Tools/app-store-media.sh.")
        }
        let log = path + ".log"
        FileManager.default.createFile(atPath: log, contents: nil)
        var app = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        var done = 0
        let deadline = Date().addingTimeInterval(15 * 60)
        while Date() < deadline {
            let lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
                .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard done < lines.count else {
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }
            let line = lines[done]
            done += 1
            let (command, argument) = Self.split(line)
            switch command {
            case "open":
                app = XCUIApplication(bundleIdentifier: argument)
                app.activate()
            case "tap":
                element(argument, in: app).tap()
            case "open-item":
                // An item in a Files folder: its cell, since tapping its name starts renaming it.
                let cell = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", argument)).firstMatch
                XCTAssertTrue(cell.waitForExistence(timeout: 10), "No item \(argument)")
                cell.tap()
            case "tree":
                append(app.debugDescription, to: log)
            case "press":
                let (seconds, label) = Self.split(argument)
                element(label, in: app).press(forDuration: Double(seconds) ?? 1)
            case "wait":
                Thread.sleep(forTimeInterval: Double(argument) ?? 1)
            case "done":
                append("> done", to: log)
                return
            default:
                append("? \(line)", to: log)
                continue
            }
            append("> \(line)", to: log)
        }
        XCTFail("The script never said done.")
    }

    private func element(_ label: String, in app: XCUIApplication) -> XCUIElement {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 10), "Nothing labelled \(label)")
        return element
    }

    private static func split(_ line: String) -> (String, String) {
        guard let space = line.firstIndex(of: " ") else { return (line, "") }
        return (String(line[..<space]), String(line[line.index(after: space)...]))
    }

    private func append(_ line: String, to path: String) {
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        handle.closeFile()
    }
}
