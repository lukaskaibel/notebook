import XCTest

/// Not a test of Notebook: a remote for the system's own apps, such as the Home Screen, where
/// Tools/app-store-screenshots.sh puts Notebook's widgets for the App Store pictures. Notebook itself has its debug
/// remote (Debug/DebugRemote+UIKit.swift); the system has none, so this taps it as a person would. It runs only when
/// the script starts it with the path of a command file (`TEST_RUNNER_STORE_MEDIA_COMMANDS`), reads that file a line at
/// a time as lines come, and writes `> <line>` to `<file>.log` after each, or `? <line>` when it found nothing to do:
///   open <bundle identifier>   brings that app to the front, launching it if needed (com.apple.springboard at first)
///   home                       the Home button: back to the Home Screen
///   tap <label>                taps the first element with that accessibility label
///   tapfirst <label>           taps the first element whose label starts with that
///   tapcell <label>            taps the list cell with that label, such as an app in the widget gallery
///   open-item <name>           taps the item of a Files folder whose label starts with that name
///   press <seconds> <label>    holds a finger on it
///   tapat <x> <y>              taps there, in points from the top left of the screen
///   pressat <seconds> <x> <y>  holds a finger there
///   swipe left|right|up|down   swipes across the app
///   type <text>                types into what has the keyboard
///   tree                       writes what the app shows to the log, for finding labels
///   wait <seconds>
///   done                       ends the remote
final class StoreMediaRemote: XCTestCase {
    private var path = ""

    func testRemote() throws {
        guard let path = ProcessInfo.processInfo.environment["STORE_MEDIA_COMMANDS"] else {
            throw XCTSkip("Only for Tools/app-store-media.sh.")
        }
        self.path = path
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
            case "home":
                XCUIDevice.shared.press(.home)
            case "tap", "tapfirst":
                let format = command == "tap" ? "label == %@" : "label BEGINSWITH %@"
                guard let found = element(argument, in: app, format: format) else { continue }
                found.tap()
            case "tapat", "pressat":
                let numbers = argument.split(separator: " ").compactMap { Double($0) }
                guard numbers.count >= 2 else { continue }
                let point = app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: numbers[numbers.count - 2], dy: numbers[numbers.count - 1]))
                if command == "tapat" { point.tap() } else { point.press(forDuration: numbers[0]) }
            case "swipe":
                switch argument {
                case "left": app.swipeLeft()
                case "right": app.swipeRight()
                case "up": app.swipeUp()
                default: app.swipeDown()
                }
            case "type":
                app.typeText(argument)
            case "tapcell":
                let cell = app.cells.matching(NSPredicate(format: "label == %@", argument)).firstMatch
                guard cell.waitForExistence(timeout: 10) else {
                    append("? no cell \(argument)", to: log)
                    continue
                }
                cell.tap()
            case "open-item":
                // An item in a Files folder: its cell, since tapping its name starts renaming it.
                let cell = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", argument)).firstMatch
                XCTAssertTrue(cell.waitForExistence(timeout: 10), "No item \(argument)")
                cell.tap()
            case "tree":
                append(app.debugDescription, to: log)
            case "press":
                let (seconds, label) = Self.split(argument)
                guard let found = element(label, in: app) else { continue }
                found.press(forDuration: Double(seconds) ?? 1)
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

    /// The first element with that label, waited for; nil (and `? …` in the log) when none comes.
    private func element(_ label: String, in app: XCUIApplication, format: String = "label == %@") -> XCUIElement? {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: format, label)).firstMatch
        guard element.waitForExistence(timeout: 10) else {
            append("? nothing labelled \(label)", to: path + ".log")
            return nil
        }
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
