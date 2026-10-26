import XCTest
@testable import NotebookKit

/// Version history's store: copies of notes, where they go, what is skipped, how they are thinned and that they follow
/// notes Notebook renames and moves.
@MainActor
final class NoteHistoryTests: XCTestCase {
    private var folder: URL!
    /// Stands in for iCloud: "…/Mobile Documents/com~apple~CloudDocs".
    private var drive: URL!
    private var local: URL!
    private var cloud: URL!
    private var history: NoteHistory!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-history-\(UUID().uuidString)", isDirectory: true)
        drive = folder.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        local = folder.appendingPathComponent("Application Support/History.noindex", isDirectory: true)
        cloud = folder.appendingPathComponent("Library/Mobile Documents/iCloud~com~lukaskbl~Notebook/History", isDirectory: true)
        try? FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        history = NoteHistory(local: local, cloud: .folder(cloud), iCloudDrive: drive.path)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func copies(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    // MARK: - Names

    func testNameSaysWhenAndOnWhat() throws {
        let zone = try XCTUnwrap(TimeZone(secondsFromGMT: 2 * 3600))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 15, minute: 32, second: 10)))
        let name = NoteHistory.name(for: date, device: "iPhone", timeZone: zone)
        XCTAssertEqual(name, "2026-10-24 at 15.32.10 +0200 (iPhone).md")
        let parsed = try XCTUnwrap(NoteHistory.parse(name))
        XCTAssertEqual(parsed.date, date)
        XCTAssertEqual(parsed.device, "iPhone")
        // The same moment taken in New York reads as the same moment.
        let newYork = try XCTUnwrap(TimeZone(secondsFromGMT: -4 * 3600))
        XCTAssertEqual(NoteHistory.name(for: date, device: "Mac", timeZone: newYork), "2026-10-24 at 09.32.10 -0400 (Mac).md")
        XCTAssertEqual(NoteHistory.parse("2026-10-24 at 09.32.10 -0400 (Mac).md")?.date, date)
    }

    func testNamesOfCopiesNotDownloadedAndOthers() throws {
        XCTAssertEqual(NoteHistory.parse(".2026-10-24 at 15.32.10 +0200 (iPad).md.icloud")?.device, "iPad")
        let named = try XCTUnwrap(NoteHistory.parse("2026-10-24 at 15.32.10 +0200 (iPhone 3f9a2c).md"))
        XCTAssertEqual(named.device, "iPhone")
        XCTAssertEqual(named.deviceID, "3f9a2c")
        XCTAssertEqual(NoteHistory.realName(of: ".2026-10-24 at 15.32.10 +0200 (iPad).md.icloud"), "2026-10-24 at 15.32.10 +0200 (iPad).md")
        // Without a time zone, in this device's time.
        let plain = try XCTUnwrap(NoteHistory.parse("2026-10-24 at 15.32.10 (Mac).md"))
        XCTAssertEqual(Calendar.current.component(.hour, from: plain.date), 15)
        XCTAssertEqual(Calendar.current.component(.minute, from: plain.date), 32)
        XCTAssertNil(NoteHistory.parse("Weekend.md"))
        XCTAssertNil(NoteHistory.parse(".DS_Store"))
        XCTAssertNil(NoteHistory.parse("2026-10-24 at 15.32.10 +0200 (Mac).txt"))
    }

    // MARK: - Places

    func testPlacesInICloudAreTheSameOnEveryDevice() throws {
        let note = drive.appendingPathComponent("Recipes/Weekend.md")
        XCTAssertEqual(NoteHistory.place(of: note, iCloudDrive: drive.path).path, "com~apple~CloudDocs/Recipes/Weekend.md")
        XCTAssertTrue(NoteHistory.place(of: note, iCloudDrive: drive.path).isInICloud)
        // Another app's iCloud folder, however the location was added.
        let obsidian = URL(fileURLWithPath: "/Users/someone/Library/Mobile Documents/iCloud~md~obsidian/Documents/Vault/Idea.md")
        XCTAssertEqual(NoteHistory.place(of: obsidian, iCloudDrive: drive.path).path, "iCloud~md~obsidian/Documents/Vault/Idea.md")
        // An iPhone's iCloud Drive is somewhere else on disk, and the same place.
        let phone = URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Recipes/Weekend.md")
        XCTAssertEqual(NoteHistory.place(of: phone, iCloudDrive: drive.path).path, "com~apple~CloudDocs/Recipes/Weekend.md")
    }

    func testDesktopKeptInICloudIsInICloud() throws {
        // A Mac keeping Desktop in iCloud has it in the home folder, and a hidden link to it in iCloud Drive.
        let desktop = folder.appendingPathComponent("Desktop", isDirectory: true)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: drive.appendingPathComponent("Desktop").path, withDestinationPath: desktop.path)
        let place = NoteHistory.place(of: desktop.appendingPathComponent("Plans/Trip.md"), iCloudDrive: drive.path)
        XCTAssertTrue(place.isInICloud)
        XCTAssertEqual(place.path, "com~apple~CloudDocs/Desktop/Plans/Trip.md")
    }

    func testPlacesElsewhereAreTheirPaths() {
        let place = NoteHistory.place(of: URL(fileURLWithPath: "/private/tmp/Notes/Ideas/Plan.md"), iCloudDrive: drive.path)
        XCTAssertFalse(place.isInICloud)
        XCTAssertEqual(place.path, "tmp/Notes/Ideas/Plan.md")
    }

    // MARK: - Keeping copies

    func testCopiesOfANoteInICloudGoToICloud() async throws {
        let note = drive.appendingPathComponent("Recipes/Weekend.md")
        history.keep("# Weekend\n\nEggs\n", of: note, device: "Mac")
        await history.written()
        let there = cloud.appendingPathComponent("com~apple~CloudDocs/Recipes/Weekend.md")
        XCTAssertEqual(copies(in: there).count, 1)
        XCTAssertTrue(copies(in: there)[0].hasSuffix(" (Mac).md"), "\(copies(in: there))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.path), "nothing on this device")
        let versions = await history.versions(of: note)
        XCTAssertEqual(versions.map(\.device), ["Mac"])
        let text = await history.text(of: versions[0])
        XCTAssertEqual(text, "# Weekend\n\nEggs\n")
    }

    func testCopiesOfOtherNotesStayOnThisDevice() async throws {
        let note = folder.appendingPathComponent("Notes/Plan.md")
        history.keep("Plan", of: note)
        await history.written()
        let here = local.appendingPathComponent(NoteHistory.place(of: note, iCloudDrive: drive.path).path)
        XCTAssertEqual(copies(in: here).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloud.path))
    }

    func testWithoutICloudEveryCopyStaysOnThisDevice() async throws {
        let history = NoteHistory(local: local, cloud: .none, iCloudDrive: drive.path)
        let note = drive.appendingPathComponent("Weekend.md")
        history.keep("Weekend", of: note)
        await history.written()
        XCTAssertEqual(copies(in: local.appendingPathComponent("com~apple~CloudDocs/Weekend.md")).count, 1)
        let versions = await history.versions(of: note)
        XCTAssertEqual(versions.count, 1)
    }

    func testTheSameTextIsntKeptTwice() async throws {
        let note = drive.appendingPathComponent("Weekend.md")
        let start = Date()
        history.keep("one", of: note, at: start)
        history.keep("one", of: note, at: start + 60)
        history.keep("two", of: note, at: start + 120)
        history.keep("two", of: note, at: start + 180)
        history.keep("one", of: note, at: start + 240)
        // Nor an empty note's.
        history.keep(" \n", of: note, at: start + 300)
        let versions = await history.versions(of: note)
        var texts: [String] = []
        for version in versions { texts.append(await history.text(of: version) ?? "") }
        XCTAssertEqual(texts, ["one", "two", "one"], "newest first")
    }

    func testTheNewestCopyIsReadWhenNotKnown() async throws {
        let note = drive.appendingPathComponent("Weekend.md")
        history.keep("one", of: note, at: Date() - 60)
        await history.written()
        // Another run, or another device, knows nothing of it but what is on disk.
        let again = NoteHistory(local: local, cloud: .folder(cloud), iCloudDrive: drive.path)
        again.keep("one", of: note)
        let versions = await again.versions(of: note)
        XCTAssertEqual(versions.count, 1)
    }

    func testTwoCopiesInOneSecondStayInOrder() async throws {
        let note = drive.appendingPathComponent("Weekend.md")
        let now = Date()
        history.keep("mine", of: note, at: now)
        history.keep("theirs", of: note, at: now)
        let versions = await history.versions(of: note)
        XCTAssertEqual(versions.count, 2)
        XCTAssertEqual(versions[0].date.timeIntervalSince(versions[1].date), 1, accuracy: 0.01)
        let newest = await history.text(of: versions[0])
        XCTAssertEqual(newest, "theirs")
    }

    // MARK: - Thinning

    func testThinningKeepsTheNewestOfEachHourDayAndWeek() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 17, minute: 30)))
        func ago(_ seconds: TimeInterval) -> Date { now - seconds }
        let dates = [
            ago(5 * 60), ago(15 * 60), ago(55 * 60), // the last hour: all stay
            ago(2 * 3600 + 60), ago(2 * 3600 + 600), // 15.29 and 15.20: the newest of the hour stays
            ago(3 * 86400), ago(3 * 86400 + 3600), // two on one day: one stays
            ago(100 * 86400), ago(101 * 86400), // the same week, a Saturday and a Friday: one stays
            ago(400 * 86400), // older than a year: goes
        ]
        let removed = Set(NoteHistory.thinning(dates, now: now, calendar: calendar))
        XCTAssertEqual(removed, [4, 6, 8, 9])
    }

    /// The simulation in #106: a note written in every day for a year, three times a day, with a copy every ten
    /// minutes while writing, keeps about 80 copies, and none older than a year.
    func testAYearOfWritingEveryDayKeepsAboutEighty() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 10, day: 1)))
        var kept: [Date] = []
        var made = 0
        for day in 0..<730 {
            for session in [8.0, 13.0, 20.0] {
                for copy in 0..<4 {
                    let date = start + Double(day) * 86400 + session * 3600 + Double(copy) * 600
                    kept.append(date)
                    made += 1
                    let removed = Set(NoteHistory.thinning(kept, now: date, calendar: calendar))
                    kept = kept.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
                }
            }
        }
        XCTAssertEqual(made, 8760)
        XCTAssert((70...95).contains(kept.count), "\(kept.count) copies")
        let last = try XCTUnwrap(kept.max())
        XCTAssertGreaterThan(try XCTUnwrap(kept.min()), try XCTUnwrap(calendar.date(byAdding: .year, value: -1, to: last)))
    }

    func testThinningRemovesCopies() async throws {
        let note = drive.appendingPathComponent("Weekend.md")
        let now = Date()
        let noon = Calendar.current.startOfDay(for: now) - 2 * 86400 + 12 * 3600
        history.keep("a year and a day ago", of: note, at: now - 366 * 86400)
        history.keep("two days ago", of: note, at: noon)
        history.keep("two days ago, later", of: note, at: noon + 60)
        history.keep("now", of: note, at: now)
        let versions = await history.versions(of: note)
        var texts: [String] = []
        for version in versions { texts.append(await history.text(of: version) ?? "") }
        XCTAssertEqual(texts, ["now", "two days ago, later"])
    }

    func testTidyingUpRemovesWhatIsAYearOldInTheTrash() async throws {
        let kept = drive.appendingPathComponent("Kept.md")
        history.keep("new", of: kept)
        await history.written()
        // A note thrown away long ago, whose copies wait in the History's Trash.
        let gone = cloud.appendingPathComponent(".Trash/1700000000 abcdef12/com~apple~CloudDocs/Gone.md")
        func writeOld() throws {
            let copy = gone.appendingPathComponent(NoteHistory.name(for: Date() - 400 * 86400, device: "iPhone 111111"))
            try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
            try "old".write(to: copy, atomically: true, encoding: .utf8)
        }
        try writeOld()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "notebook-history-\(UUID().uuidString)"))
        history.tidyUp(defaults: defaults)
        await history.written()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloud.appendingPathComponent(".Trash/1700000000 abcdef12").path), "emptied folders go too")
        let versions = await history.versions(of: kept)
        XCTAssertEqual(versions.count, 1)
        // Once a day at most.
        try writeOld()
        history.tidyUp(defaults: defaults)
        await history.written()
        XCTAssertTrue(FileManager.default.fileExists(atPath: gone.path))
    }

    // MARK: - Following notes

    func testCopiesFollowARenamedNote() async throws {
        let note = drive.appendingPathComponent("Recipes/Weekend.md")
        history.keep("before", of: note, at: Date() - 60)
        let renamed = drive.appendingPathComponent("Recipes/Saturday.md")
        history.follow(from: note, to: renamed)
        history.keep("after", of: renamed)
        let old = await history.versions(of: note)
        XCTAssertEqual(old, [])
        let versions = await history.versions(of: renamed)
        XCTAssertEqual(versions.count, 2)
    }

    func testCopiesFollowAMovedFolder() async throws {
        let note = drive.appendingPathComponent("Recipes/Weekend.md")
        let other = drive.appendingPathComponent("Recipes/Cake.md")
        history.keep("weekend", of: note)
        history.keep("cake", of: other)
        let moved = drive.appendingPathComponent("Archive/Food", isDirectory: true)
        history.follow(from: drive.appendingPathComponent("Recipes", isDirectory: true), to: moved)
        let weekend = await history.versions(of: moved.appendingPathComponent("Weekend.md"))
        let cake = await history.versions(of: moved.appendingPathComponent("Cake.md"))
        XCTAssertEqual(weekend.count, 1)
        XCTAssertEqual(cake.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloud.appendingPathComponent("com~apple~CloudDocs/Recipes").path))
    }

    func testANoteAndAFolderOfTheSameNameKeepTheirsApart() async throws {
        let note = drive.appendingPathComponent("Recipes.md")
        let inFolder = drive.appendingPathComponent("Recipes/Cake.md")
        history.keep("the note", of: note)
        history.keep("cake", of: inFolder)
        history.follow(from: drive.appendingPathComponent("Recipes", isDirectory: true), to: drive.appendingPathComponent("Food", isDirectory: true))
        let stays = await history.versions(of: note)
        XCTAssertEqual(stays.count, 1)
        let went = await history.versions(of: drive.appendingPathComponent("Food/Cake.md"))
        XCTAssertEqual(went.count, 1)
    }

    func testCopiesFollowANoteOutOfICloudAndBack() async throws {
        let note = drive.appendingPathComponent("Weekend.md")
        history.keep("in iCloud", of: note)
        let outside = folder.appendingPathComponent("Notes/Weekend.md")
        history.follow(from: note, to: outside)
        await history.written()
        XCTAssertEqual(copies(in: local.appendingPathComponent(NoteHistory.place(of: outside, iCloudDrive: drive.path).path)).count, 1)
        history.follow(from: outside, to: note)
        let back = await history.versions(of: note)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(copies(in: cloud.appendingPathComponent("com~apple~CloudDocs/Weekend.md")).count, 1)
    }

    func testATrashedNotesCopiesWaitInTheTrashAndComeBackWhereItGoes() async throws {
        // A note thrown away: its copies go to the History's Trash, and a note given its name doesn't get them.
        let plan = drive.appendingPathComponent("Plan.md")
        history.keep("thrown away", of: plan, at: Date() - 120)
        history.trash(plan, as: "1700000000 abcdef12")
        let none = await versions(plan)
        XCTAssertEqual(none, [])
        let new = drive.appendingPathComponent("Untitled.md")
        history.keep("new", of: new)
        history.follow(from: new, to: plan)
        let taken = await versions(plan)
        XCTAssertEqual(taken, ["new"])
        // Put back next to it, under a name of its own: its copies come along.
        let back = drive.appendingPathComponent("Plan 2.md")
        history.putBack("1700000000 abcdef12", to: back)
        let own = await versions(back)
        XCTAssertEqual(own, ["thrown away"])
        let still = await versions(plan)
        XCTAssertEqual(still, ["new"])
    }

    func testCopiesNotDownloadedStayInICloudAndAreFoundThere() async throws {
        let note = drive.appendingPathComponent("Weekend.md")
        history.keep("here", of: note)
        await history.written()
        // A copy from another device that iCloud hasn't brought down, as iPhone and iPad show it.
        let there = cloud.appendingPathComponent("com~apple~CloudDocs/Weekend.md")
        let placeholder = there.appendingPathComponent(".2026-10-01 at 10.00.00 +0200 (iPhone 1a2b3c).md.icloud")
        try Data().write(to: placeholder)
        let outside = folder.appendingPathComponent("Notes/Weekend.md")
        history.follow(from: note, to: outside)
        await history.written()
        XCTAssertEqual(copies(in: there), [placeholder.lastPathComponent], "not carried along as a stub")
        // The note's versions are looked for where it stayed too.
        let listed = await history.versions(of: outside)
        XCTAssertEqual(Set(listed.map(\.device)), ["Mac", "iPhone"])
        XCTAssertEqual(listed.count, 2)
        // Back into iCloud, as Undo takes it: they join up again.
        history.follow(from: outside, to: note)
        await history.written()
        XCTAssertEqual(copies(in: there).count, 2)
        let back = await history.versions(of: note)
        XCTAssertEqual(back.count, 2)
    }

    /// The texts of a note's versions, newest first.
    private func versions(_ note: URL) async -> [String] {
        var texts: [String] = []
        for version in await history.versions(of: note) { texts.append(await history.text(of: version) ?? "?") }
        return texts
    }

    // MARK: - Clocks and devices

    func testThinningCountsInOneCalendarEverywhere() throws {
        XCTAssertEqual(NoteHistory.calendar.timeZone.secondsFromGMT(), 0)
        XCTAssertEqual(NoteHistory.calendar.firstWeekday, 2)
        // 23.30 and 0.30 in Berlin in summer are one day in UTC: one stays, whichever device thins.
        let utc = NoteHistory.calendar
        let late = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 21, minute: 30)))
        let removed = NoteHistory.thinning([late, late + 3600], now: late + 10 * 86400)
        XCTAssertEqual(removed, [0])
    }

    func testTheNewestCopyStaysWhateverTheClockSays() {
        let now = Date()
        XCTAssertEqual(NoteHistory.thinning([now - 500 * 86400, now - 400 * 86400], now: now), [0])
        XCTAssertEqual(Set(NoteHistory.thinning([now - 500 * 86400, now - 400 * 86400], now: now, keepsNewest: false)), [0, 1])
    }

    func testAClockSetAheadDoesntTakeAwayAnotherDevicesCopies() async throws {
        let note = drive.appendingPathComponent("Weekend.md")
        let now = Date()
        for (days, text) in [(300.0, "a"), (200, "b"), (40, "c"), (2, "d")] {
            history.keep(text, of: note, at: now - days * 86400, device: "iPhone 111111")
        }
        // A Mac whose clock is two years ahead writes the note.
        history.keep("e", of: note, at: now + 730 * 86400, device: "Mac 222222")
        let kept = await versions(note)
        XCTAssertEqual(kept, ["e", "d", "c", "b", "a"])
    }

    func testTidyingUpLeavesEachOtherDevicesNewest() async throws {
        let note = drive.appendingPathComponent("Kept.md")
        // Copies an iPhone took, a year old and more, which it hasn't thinned since: it isn't used any more.
        let there = cloud.appendingPathComponent("com~apple~CloudDocs/Kept.md")
        try FileManager.default.createDirectory(at: there, withIntermediateDirectories: true)
        for (days, text) in [(400.0, "old, from the iPhone"), (500, "older, from the iPhone")] {
            try text.write(to: there.appendingPathComponent(NoteHistory.name(for: Date() - days * 86400, device: "iPhone 111111")), atomically: true, encoding: .utf8)
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "notebook-history-\(UUID().uuidString)"))
        history.tidyUp(defaults: defaults, device: "Mac 222222")
        let kept = await versions(note)
        XCTAssertEqual(kept, ["old, from the iPhone"], "its newest stays, whatever this clock says")
    }

    func testADayAheadWrittenDownDoesntStopTidyingUp() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "notebook-history-\(UUID().uuidString)"))
        defaults.set(Date() + 30 * 86400, forKey: "historyTidiedUp")
        let gone = cloud.appendingPathComponent(".Trash/1700000000 abcdef12/com~apple~CloudDocs/Gone.md")
        let copy = gone.appendingPathComponent(NoteHistory.name(for: Date() - 400 * 86400, device: "iPhone 111111"))
        try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
        try "old".write(to: copy, atomically: true, encoding: .utf8)
        history.tidyUp(defaults: defaults)
        await history.written()
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path))
    }

    func testTwoMacsInOneSecondKeepCopiesOfTheirOwn() async throws {
        let note = drive.appendingPathComponent("Weekend.md")
        let now = Date()
        history.keep("one Mac", of: note, at: now, device: "Mac aaaaaa")
        history.keep("the other", of: note, at: now, device: "Mac bbbbbb")
        let versions = await history.versions(of: note)
        XCTAssertEqual(versions.map(\.device), ["Mac", "Mac"])
        XCTAssertEqual(Set(versions.compactMap(\.deviceID)), ["aaaaaa", "bbbbbb"])
        XCTAssertEqual(versions[0].date, versions[1].date, "no second added: the names differ anyway")
        XCTAssertNotNil(NoteHistory.thisDevice.range(of: #" [0-9a-f]{6}$"#, options: .regularExpression))
    }

    func testOnlyTheCaseOfTheNameChanged() async throws {
        let note = drive.appendingPathComponent("weekend.md")
        history.keep("weekend", of: note)
        let renamed = drive.appendingPathComponent("Weekend.md")
        history.follow(from: note, to: renamed)
        await history.written()
        XCTAssertEqual(copies(in: cloud.appendingPathComponent("com~apple~CloudDocs")), ["Weekend.md"])
        let versions = await history.versions(of: renamed)
        XCTAssertEqual(versions.count, 1)
    }
}
