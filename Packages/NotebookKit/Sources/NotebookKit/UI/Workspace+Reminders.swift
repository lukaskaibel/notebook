#if os(macOS)
import AppKit
#else
import BackgroundTasks
import UIKit
#endif
import SwiftUI

/// A note to set a reminder for, in a sheet.
struct ReminderRequest: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Reminders of notes: set from a note's menus, shown under its title and in its row, carried along when Notebook
/// renames, moves or throws the note away, and scheduled as notifications on every device.
extension Workspace {
    // MARK: - Finding them

    func reminder(for url: URL) -> Reminder? {
        // Read, so what shows a reminder shows it again when its time comes.
        _ = remindersDue
        guard !reminders.all.isEmpty else { return nil }
        return reminders.reminder(for: hiddenKey(for: url))
    }

    /// Where a reminder's note is on this device: at its place, or, moved in the Finder, wherever its name is in the
    /// same location (and the reminder follows it there). Nil when no location here has it, or with `searching` false
    /// when it isn't at its place.
    func url(for reminder: Reminder, searching: Bool = true) -> URL? {
        for location in locations {
            // Linked folders first: a note on iCloud Drive's Desktop is in ~/Desktop on a Mac.
            let folders = location.folders.map { (url: $0.url, key: hiddenKey(for: $0.url)) }.sorted { $0.key.count > $1.key.count }
            guard let folder = folders.first(where: { reminder.note.hasPrefix($0.key + "/") }) else { continue }
            let url = folder.url.appendingPathComponent(String(reminder.note.dropFirst(folder.key.count + 1))).standardizedFileURL
            if FileManager.default.fileExists(atPath: url.path) { return url }
            guard searching else { return nil }
            // Every device that has the location finds the same one: the least deep, then by address.
            let found = index.entries.filter { $0.kind == .note && $0.locationID == location.id && $0.name == reminder.name && FileManager.default.fileExists(atPath: $0.url.path) }
                .min { ($0.url.pathComponents.count, $0.path) < ($1.url.pathComponents.count, $1.path) }
                // File events can give "/private/tmp/…" for the location's "/tmp/…".
                .map { location.url.path.hasPrefix("/private/") ? $0.url : URL(fileURLWithPath: HiddenFolders.withoutPrivate($0.url.path)) }
            if let found {
                reminders.move(reminder.note, to: hiddenKey(for: found))
                updateReminderLine()
                sidebarRefreshRows()
            }
            return found
        }
        return nil
    }

    /// "Today 14:00", "Tomorrow 9:00", "Friday 9:00", "24 Oct 9:00", in the words and the clock of your settings.
    static func reminderText(_ date: Date) -> String {
        ReminderText.text(date, time: true)
    }

    // MARK: - Setting them

    /// Remind Me… from a menu. On the Mac a popover comes from the row the menu was for, or from the line under the
    /// open note's title; on iPhone and iPad a sheet comes up.
    #if os(macOS)
    func askForReminder(_ url: URL, from anchor: NSView? = nil) {
        let view = anchor ?? (url == currentURL && note != nil ? editor.textView.reminderAnchor : nil)
        guard let view, view.window != nil else { return beep() }
        reminderPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        let controller = NSHostingController(rootView: ReminderPicker(workspace: self, url: url) { [weak popover] in popover?.performClose(nil) })
        controller.sizingOptions = .preferredContentSize
        popover.contentViewController = controller
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
        reminderPopover = popover
    }
    #else
    func askForReminder(_ url: URL) {
        reminderRequest = ReminderRequest(url: url)
    }
    #endif

    /// Sets a note's reminder, or changes its time or place. The first one asks whether Notebook may send
    /// notifications, and the first with a place whether it may use your location.
    func setReminder(for url: URL, at date: Date?, place: TodoPlace? = nil) {
        guard date != nil || place != nil else { return removeReminder(for: url) }
        let reminder = reminders.set(note: hiddenKey(for: url), date: date, place: place)
        #if DEBUG
        unscheduledReminders.remove(reminder.id)
        #endif
        if let place { PlaceHistory.add(place) }
        ReminderNotifications.shared.withdraw(reminder.id)
        remindersChanged(scheduling: [])
        Task {
            let allowed = await askForReminderPermissions(place: place != nil)
            // Scheduled either way: turned on later, notifications come for it.
            scheduleReminders([reminder.id])
            if !allowed { reportNotificationsOff() }
        }
    }

    /// Asks whether Notebook may send notifications, and with a place whether it may use your location (on iPhone and
    /// iPad, which remind you there). Says whether notifications may come.
    func askForReminderPermissions(place: Bool) async -> Bool {
        let allowed = await ReminderNotifications.shared.requestPermission()
        #if os(iOS)
        if place, ReminderNotifications.shared.isActive {
            let wasAllowed = PlaceAccess.shared.isAllowed
            if !(await PlaceAccess.shared.requestAccess()) {
                report("Notebook can’t use your location.", "The place is kept, but your iPhone can’t remind you there. Allow Notebook to use your location in Settings › Apps › Notebook › Location.")
            } else if !wasAllowed {
                // Places weren't watched until now.
                scheduleReminders()
                scheduleTodoNotifications()
            }
        }
        #endif
        return allowed
    }

    func reportNotificationsOff() {
        #if os(macOS)
        report("Notifications for Notebook are turned off.", "The reminder is kept, but Notebook can’t tell you when it’s time. Turn on notifications for Notebook in System Settings › Notifications.")
        #else
        report("Notifications for Notebook are turned off.", "The reminder is kept, but Notebook can’t tell you when it’s time. Turn on notifications for Notebook in Settings › Apps › Notebook.")
        #endif
    }

    func removeReminder(for url: URL) {
        guard let reminder = reminder(for: url) else { return }
        finishReminder(reminder.id)
    }

    /// Done, from the notification or the note: the reminder leaves the store, here and on your other devices.
    func finishReminder(_ id: UUID) {
        reminders.remove(id)
        ReminderNotifications.shared.withdraw(id)
        remindersChanged(scheduling: [])
    }

    /// Remind Me in 1 Hour, from the notification.
    @discardableResult
    func remindAgain(_ id: UUID, in interval: TimeInterval) -> Task<Void, Never>? {
        guard var reminder = reminders.reminder(id) else { return nil }
        // To the minute, so the time shown is the time it comes.
        reminder.date = Self.minute(after: interval)
        reminders.set(reminder)
        ReminderNotifications.shared.withdraw(id)
        remindersChanged(scheduling: [])
        return scheduleReminders([id])
    }

    /// A time this far from now, to the minute, so the time shown is the time it comes.
    static func minute(after interval: TimeInterval) -> Date {
        let later = Date(timeIntervalSinceNow: interval)
        var date = Calendar.current.date(bySetting: .second, value: 0, of: later) ?? later
        if date < later { date += 60 }
        return date
    }

    /// A tap on the notification: the note opens, wherever it is now. When the tap started the app, once the
    /// locations have been looked up: a note on iCloud Drive's Desktop is found through them.
    func openReminder(_ id: UUID, note: String? = nil) {
        start()
        whenSurveyed { [weak self] in
            guard let self else { return }
            let reminder = reminders.reminder(id) ?? note.map { Reminder(id: id, note: $0, date: nil) }
            guard let reminder, let url = url(for: reminder) else { return beep() }
            showWindow?()
            #if os(macOS)
            NSApp.activate()
            #endif
            open(url)
        }
    }

    // MARK: - Keeping up

    /// After a reminder was set, changed or finished, here or on another device: the line under the note's title,
    /// the rows, and the notifications (of `scheduling`, or all of them).
    func remindersChanged(scheduling ids: Set<UUID>? = nil) {
        updateReminderLine()
        sidebarRefreshRows()
        watchForDueReminders()
        if ids?.isEmpty != true { scheduleReminders(ids) }
    }

    /// Schedules the notifications of the reminders to come (or only of `ids`), with the note's points read off the
    /// main thread. All of them at launch, after iCloud brought changes, and once search knows every file.
    @discardableResult
    func scheduleReminders(_ ids: Set<UUID>? = nil) -> Task<Void, Never>? {
        // Before the reminders are read there is nothing to go by.
        guard ReminderNotifications.shared.isActive, isStarted else { return nil }
        var jobs: [ReminderNotifications.Job] = []
        for reminder in reminders.all where ids?.contains(reminder.id) ?? true {
            #if DEBUG
            if unscheduledReminders.contains(reminder.id) { continue }
            #endif
            let url = url(for: reminder)
            // The open note's text is newer than its file while you type.
            let isOpen = url != nil && url == note?.url.standardizedFileURL && note?.isLoaded == true
            jobs.append(ReminderNotifications.Job(id: reminder.id, date: reminder.date, place: reminder.place, title: url.map(SearchSection.displayName) ?? reminder.name,
                                                  note: reminder.note, url: url, text: isOpen ? editor.text : nil))
        }
        // Locations given on the command line come with reminders of their own: the ones you set stay scheduled.
        return ReminderNotifications.shared.schedule(jobs, everything: ids == nil && !temporaryLocations, known: Set(reminders.all.map(\.id)))
    }

    /// A note with a reminder was saved: its notification takes the note's points again.
    func noteSaved(_ url: URL) {
        guard let reminder = reminder(for: url) else { return }
        scheduleReminders([reminder.id])
    }

    /// Files changed in these folders, here or through iCloud: notes with reminders there are read again for their
    /// notifications. The open note's saves say so themselves.
    func remindersMayHaveChanged(in folders: [URL]) {
        guard !reminders.all.isEmpty else { return }
        let paths = Set(folders.map { HiddenFolders.withoutPrivate($0.standardizedFileURL.path) })
        let ids = reminders.all.filter { reminder in
            guard let url = url(for: reminder, searching: false), url != note?.url.standardizedFileURL else { return false }
            return paths.contains(HiddenFolders.withoutPrivate(url.deletingLastPathComponent().path))
        }.map(\.id)
        if !ids.isEmpty { scheduleReminders(Set(ids)) }
    }

    /// A note renamed or moved in Notebook keeps its reminder, and so do the notes of a folder; one thrown away loses it.
    func reminderMoved(from old: URL, to new: URL?) {
        guard !reminders.all.isEmpty else { return }
        let before = reminders.all
        if let new { reminders.move(hiddenKey(for: old), to: hiddenKey(for: new)) } else { reminders.forget(hiddenKey(for: old)) }
        guard reminders.all != before else { return }
        let kept = Set(reminders.all.map(\.id))
        for reminder in before where !kept.contains(reminder.id) { ReminderNotifications.shared.withdraw(reminder.id) }
        // The ones kept carry the note's new name.
        let moved = Set(reminders.all.filter { !before.contains($0) }.map(\.id))
        remindersChanged(scheduling: moved)
    }

    /// Wakes up when the next reminder's time comes, for the bell under the title and in the rows to turn red, and a
    /// to-do's pill and its row in To-dos; and at midnight, when Tomorrow becomes Today.
    func watchForDueReminders() {
        dueTimer?.invalidate()
        dueTimer = nil
        let nextTodo = todos.items.lazy.compactMap { $0.todo.due }.map { $0.hasTime ? $0.date() : Calendar.current.date(byAdding: .day, value: 1, to: $0.date()) ?? $0.date() }.filter { $0 > .now }.min()
        let nextNote = reminders.all.compactMap(\.date).first { $0 > .now }
        // At midnight too: "Tomorrow" becomes "Today".
        let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now))
        guard let next = [nextTodo, nextNote, midnight].compactMap({ $0 }).min() else { return }
        let timer = Timer(fire: next.addingTimeInterval(0.5), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.remindersDue += 1
                self.updateReminderLine()
                self.sidebarRefreshRows()
                self.refreshTodoPills()
                self.watchForDueReminders()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dueTimer = timer
    }

    /// The bell and the time in the line under the open note's title.
    func updateReminderLine() {
        guard let currentURL, note != nil, let reminder = reminder(for: currentURL) else {
            editor.setReminder(nil, isOverdue: false)
            return
        }
        editor.setReminder(reminder.text, isOverdue: reminder.isOverdue)
    }

    func sidebarRefreshRows() {
        #if os(macOS)
        sidebar?.refreshRows()
        #else
        sidebarReloadAll()
        #endif
    }

    #if os(iOS)
    /// What the iPhone and iPad do when the system gives them time in the background: take in the reminders set on
    /// another device, which iOS doesn't wake an app for, and schedule them.
    static let reminderRefreshTask = "com.lukaskbl.Notebook.reminders"

    func refreshRemindersInBackground() async {
        start()
        reminders.reload()
        await scheduleReminders()?.value
        // The to-dos once every note has been read, as far as the time given allows: changed on another device, their
        // dates came with the files.
        for _ in 0..<40 where !todos.isReady {
            try? await Task.sleep(for: .milliseconds(500))
        }
        await scheduleTodoNotifications()?.value
        scheduleReminderRefresh()
    }

    /// Asks for time in the background in an hour or so, for reminders that come from your other devices.
    func scheduleReminderRefresh() {
        guard reminders.isInICloud else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.reminderRefreshTask)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        BGTaskScheduler.shared.submitTaskRequest(request) { _ in }
    }
    #endif
}
