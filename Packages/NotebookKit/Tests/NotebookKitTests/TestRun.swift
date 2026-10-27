import Darwin
import Foundation
import NotebookTestSupport
import XCTest
@testable import NotebookKit

/// What this test run has of its own, as other test runs and builds share the Mac with it (#136, #198): its settings,
/// which `UserDefaults.standard` is here (Tests/NotebookTestSupport), and a folder that goes when the run ends.
enum TestRun {
    static var folder: URL { NotebookTestRunFolder() }

    /// Empty settings of their own, for a store that is given its settings: hidden folders, reminders, the App
    /// Group's. Kept in the run's folder, not in ~/Library/Preferences.
    static func settings() -> UserDefaults {
        UserDefaults(suiteName: folder.appendingPathComponent("Settings \(UUID().uuidString)").path)!
    }

    /// How long a test waits for what it waits for before it fails: a wait ends as soon as that has happened, so this
    /// only has to be long enough for a Mac busy with other test runs and builds.
    static let patience: TimeInterval = 30

    /// Waits until the file watchers made so far are watching. They start a moment after the locations have been read,
    /// which on a busy Mac can be a while, and a change made before then is never told about.
    static func watching() async {
        await withCheckedContinuation { done in FileWatcher.whenWatching { done.resume() } }
    }

    /// Waits while `condition` holds, at most `patience`; the test then checks what it waited for.
    @MainActor
    static func wait(while condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(patience)
        while condition(), Date() < end { try await Task.sleep(for: .milliseconds(20)) }
    }
}

/// Timing what the main thread does, on a Mac that other test runs and builds share.
enum Timing {
    /// The processor time this thread has had: the work it did, without the time it waited for a core.
    static func threadTime() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000_000
    }

    /// How much more the Mac has to do than it has cores for: the load average of the last minute per core.
    static var loadPerCore: Double {
        var loads = [Double](repeating: 0, count: 1)
        guard getloadavg(&loads, 1) == 1 else { return 0 }
        return loads[0] / Double(ProcessInfo.processInfo.activeProcessorCount)
    }

    /// Over this, timings say more about the Mac than about Notebook.
    static let overloaded = 2.0
}

extension XCTestCase {
    /// Checks that what `measure` measures, in seconds of the main thread's processor time (`Timing.threadTime`), stays
    /// under `budget`. Other work only ever adds time, so the best of up to `attempts` counts. Still over budget on a
    /// Mac with far more to do than it has cores for, the test is skipped with what it measured, unless it took more
    /// than `reference.ratio` times what `reference` measures there and then, work the Mac slows down as much: then it
    /// isn't only the Mac, and the test fails. Over budget on any other Mac, it fails.
    func assertFast(_ what: String, under budget: TimeInterval, attempts: Int = 3,
                    comparedWith reference: (what: String, ratio: Double, measure: () throws -> TimeInterval)? = nil,
                    file: StaticString = #filePath, line: UInt = #line, _ measure: () throws -> TimeInterval) throws {
        var best = TimeInterval.infinity
        for _ in 0..<attempts {
            best = min(best, try measure())
            if best < budget { return }
        }
        var measured = String(format: "%@: %.1f ms, over the %.1f ms budget, at best of %d", what, best * 1000, budget * 1000, attempts)
        guard Timing.loadPerCore > Timing.overloaded else { return XCTFail(measured, file: file, line: line) }
        if let reference {
            var now = TimeInterval.infinity
            for _ in 0..<attempts { now = min(now, try reference.measure()) }
            measured += String(format: "; %@ %.1f ms", reference.what, now * 1000)
            guard best <= now * reference.ratio else {
                return XCTFail(measured + String(format: ", more than %.0f times as long", reference.ratio), file: file, line: line)
            }
        }
        throw XCTSkip(measured + String(format: ", on a Mac with a load of %.1f per core", Timing.loadPerCore), file: file, line: line)
    }
}
