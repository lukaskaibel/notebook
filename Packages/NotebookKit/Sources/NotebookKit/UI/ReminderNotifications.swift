#if os(iOS)
import CoreLocation
#endif
import Foundation
import UserNotifications

/// The notifications of reminders. Each device schedules its own from the reminders it knows: the note's name as the
/// title, the time or the place under it, and the note's first points as the text, read off the main thread; a to-do's
/// words as the title, with its notes as the text. Time Sensitive, so they get through a Focus. A tap opens the note;
/// Remind Me in 1 Hour and Done are their actions. Places remind you on iPhone and iPad, which watch them while you
/// let Notebook use your location; a Mac can't.
@MainActor
final class ReminderNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ReminderNotifications()

    nonisolated static let category = "reminder"
    nonisolated static let laterAction = "later"
    nonisolated static let doneAction = "done"
    private nonisolated static let prefix = "reminder."
    nonisolated static let todoPrefix = "todo."
    /// iPhone and iPad keep 64 notifications waiting; a few are left for the reminders of notes.
    nonisolated static let todoLimit = 48
    /// An app may watch 20 places at once.
    nonisolated static let placeLimit = 16

    /// Only the app schedules notifications: tests and previews leave the system's alone.
    private(set) var isActive = false
    /// The last scheduling, which the next waits for, so an older one never takes away what a newer one added.
    private var last: Task<Void, Never>?

    /// What a notification is made from: the reminder, and the note's text when it is open.
    struct Job: Sendable {
        var id: UUID
        var date: Date?
        var place: TodoPlace? = nil
        var title: String
        /// The note's name in the store, to find it again after the reminder is done.
        var note: String
        var url: URL?
        var text: String?
    }

    /// What a to-do's notifications are made from.
    struct TodoJob: Sendable, Hashable {
        /// Named after the note, the to-do's line and its notes: a to-do changed is a new notification.
        var identifier: String
        var date: Date?
        var place: TodoPlace?
        /// The to-do's words, the note's name, and the to-do's notes.
        var title: String
        var noteName: String
        var body: String
        /// Where it is, to find it again from the notification.
        var path: String
        var line: Int
        var source: String

        /// "14:00 · Kyoto trip", "Arriving at Pharmacy · Kyoto trip".
        func subtitle(forPlace: Bool) -> String {
            let when = forPlace ? place?.phrase : date.map { $0.formatted(date: .omitted, time: .shortened) }
            return [when, noteName].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// Called as the app starts, before a tap on a notification can reach it.
    static func activate() {
        guard !shared.isActive else { return }
        shared.isActive = true
        let center = UNUserNotificationCenter.current()
        center.delegate = shared
        let later = UNNotificationAction(identifier: laterAction, title: "Remind Me in 1 Hour", options: [], icon: UNNotificationActionIcon(systemImageName: "clock"))
        let done = UNNotificationAction(identifier: doneAction, title: "Done", options: [], icon: UNNotificationActionIcon(systemImageName: "checkmark"))
        center.setNotificationCategories([UNNotificationCategory(identifier: category, actions: [later, done], intentIdentifiers: [], options: [])])
    }

    nonisolated static func identifier(_ id: UUID) -> String { prefix + id.uuidString }
    /// The notification of a reminder's place, next to the one of its time.
    nonisolated static func placeIdentifier(_ id: UUID) -> String { prefix + id.uuidString + ".place" }

    /// Asks for notifications the first time a reminder is set. False when they are turned off.
    func requestPermission() async -> Bool {
        guard isActive else { return true }
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .denied: return false
        default: return true
        }
    }

    /// Schedules the reminders to come. With `everything`, these are all there are: notifications of reminders that
    /// are gone, done here or on another device, go too, including those already shown.
    @discardableResult
    func schedule(_ jobs: [Job], everything: Bool, known: Set<UUID> = []) -> Task<Void, Never>? {
        guard isActive else { return nil }
        let previous = last
        let task = Task.detached(priority: .utility) {
            await previous?.value
            let center = UNUserNotificationCenter.current()
            let now = Date()
            let watchesPlaces = await Self.watchesPlaces
            let pending = await center.pendingNotificationRequests().map(\.identifier)
            let fired = Self.firedPlaces(prefix: Self.prefix, pending: Set(pending))
            if everything {
                var coming = Set(jobs.filter { ($0.date ?? .distantPast) > now }.map { Self.identifier($0.id) })
                if watchesPlaces { coming.formUnion(jobs.filter { $0.place?.hasCoordinates == true }.map { Self.placeIdentifier($0.id) }) }
                center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.hasPrefix(Self.prefix) && !coming.contains($0) })
                let all = Set(known.flatMap { [Self.identifier($0), Self.placeIdentifier($0)] })
                let delivered = await center.deliveredNotifications().map(\.request.identifier)
                center.removeDeliveredNotifications(withIdentifiers: delivered.filter { $0.hasPrefix(Self.prefix) && !all.contains($0) })
            }
            for job in jobs {
                let isComing = (job.date ?? .distantPast) > now
                let hasPlace = watchesPlaces && job.place?.hasCoordinates == true && !fired.contains(Self.placeIdentifier(job.id))
                guard isComing || hasPlace else { continue }
                let text = job.text ?? job.url.flatMap(Self.readIfHere)
                if let date = job.date, isComing {
                    let request = UNNotificationRequest(identifier: Self.identifier(job.id), content: Self.content(for: job, text: text, place: false), trigger: Self.trigger(at: date))
                    try? await center.add(request)
                }
                #if os(iOS)
                if hasPlace, let place = job.place, let trigger = Self.trigger(at: place, identifier: Self.placeIdentifier(job.id)) {
                    try? await center.add(UNNotificationRequest(identifier: Self.placeIdentifier(job.id), content: Self.content(for: job, text: text, place: true), trigger: trigger))
                }
                #endif
            }
            await Self.armPlaces(prefix: Self.prefix, center: center, keepingFired: everything ? Set(known.map(Self.placeIdentifier)) : nil)
        }
        last = task
        return task
    }

    /// The to-dos with a reminder: their notifications, soonest first, as many as can wait at once. Those of to-dos
    /// changed or done since go, the ones waiting, and the ones shown unless the to-do is still open (`open`).
    @discardableResult
    func scheduleTodos(_ jobs: [TodoJob], open: Set<String>) -> Task<Void, Never>? {
        guard isActive else { return nil }
        let previous = last
        let task = Task.detached(priority: .utility) {
            await previous?.value
            let center = UNUserNotificationCenter.current()
            let now = Date()
            let watchesPlaces = await Self.watchesPlaces
            let timed = jobs.filter { ($0.date ?? .distantPast) > now }.sorted { $0.date! < $1.date! }.prefix(Self.todoLimit)
            let pending = Set(await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.todoPrefix) })
            let fired = Self.firedPlaces(prefix: Self.todoPrefix, pending: pending)
            let placed = watchesPlaces ? Array(jobs.filter { $0.place?.hasCoordinates == true && !fired.contains($0.identifier + ".place") }.prefix(Self.placeLimit)) : []
            let wanted = Set(timed.map(\.identifier) + placed.map { $0.identifier + ".place" })
            center.removePendingNotificationRequests(withIdentifiers: Array(pending.subtracting(wanted)))
            let shown = await center.deliveredNotifications().map(\.request.identifier).filter { $0.hasPrefix(Self.todoPrefix) }
            center.removeDeliveredNotifications(withIdentifiers: shown.filter { !open.contains($0.replacingOccurrences(of: ".place", with: "")) })
            for job in timed where !pending.contains(job.identifier) {
                try? await center.add(UNNotificationRequest(identifier: job.identifier, content: Self.content(for: job, place: false), trigger: Self.trigger(at: job.date!)))
            }
            #if os(iOS)
            for job in placed where !pending.contains(job.identifier + ".place") {
                guard let place = job.place, let trigger = Self.trigger(at: place, identifier: job.identifier + ".place") else { continue }
                try? await center.add(UNNotificationRequest(identifier: job.identifier + ".place", content: Self.content(for: job, place: true), trigger: trigger))
            }
            #endif
            await Self.armPlaces(prefix: Self.todoPrefix, center: center, keepingFired: Set(jobs.map { $0.identifier + ".place" }))
        }
        last = task
        return task
    }

    // MARK: - Places, once

    /// A place reminds you once, as a time does: the next arrival doesn't bring it again, until the reminder changes.
    /// What was waiting at the last scheduling and isn't now has come (or was taken back, which `withdraw` says).
    private nonisolated static let armedKey = "armedPlaces"
    private nonisolated static let firedKey = "firedPlaces"

    /// The places of `prefix` that have come since they were scheduled.
    nonisolated static func firedPlaces(prefix: String, pending: Set<String>) -> Set<String> {
        let defaults = UserDefaults.standard
        let armed = Set(defaults.stringArray(forKey: armedKey) ?? []).filter { $0.hasPrefix(prefix) }
        var fired = Set(defaults.stringArray(forKey: firedKey) ?? [])
        fired.formUnion(armed.subtracting(pending))
        defaults.set(Array(fired), forKey: firedKey)
        return fired.filter { $0.hasPrefix(prefix) }
    }

    /// Notes which places of `prefix` are waiting now; with `keepingFired`, forgets the ones that came of reminders that
    /// are gone.
    nonisolated static func armPlaces(prefix: String, center: UNUserNotificationCenter, keepingFired known: Set<String>?) async {
        let waiting = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) && $0.hasSuffix(".place") }
        let defaults = UserDefaults.standard
        let others = (defaults.stringArray(forKey: armedKey) ?? []).filter { !$0.hasPrefix(prefix) }
        defaults.set(others + waiting, forKey: armedKey)
        if let known {
            let fired = (defaults.stringArray(forKey: firedKey) ?? []).filter { !$0.hasPrefix(prefix) || known.contains($0) }
            defaults.set(fired, forKey: firedKey)
        }
    }

    /// Taken back rather than come: a place changed or the reminder is done.
    private nonisolated static func disarm(_ identifiers: [String]) {
        let defaults = UserDefaults.standard
        for key in [armedKey, firedKey] {
            defaults.set((defaults.stringArray(forKey: key) ?? []).filter { !identifiers.contains($0) }, forKey: key)
        }
    }

    /// A reminder changed or finished: its notifications go, the ones waiting and the ones shown.
    func withdraw(_ id: UUID) {
        guard isActive else { return }
        Self.disarm([Self.placeIdentifier(id)])
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier(id), Self.placeIdentifier(id)])
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier(id), Self.placeIdentifier(id)])
    }

    /// A to-do's notification again at a later time, as it was but for the time, for the to-do as it is now.
    func remindAgain(_ identifier: String, todo: TodoReference, at date: Date, like shown: (title: String, subtitle: String, body: String, thread: String)) async {
        guard isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = shown.title
        let note = shown.subtitle.components(separatedBy: " · ").dropFirst().joined(separator: " · ")
        content.subtitle = [date.formatted(date: .omitted, time: .shortened), note].filter { !$0.isEmpty }.joined(separator: " · ")
        content.body = shown.body
        content.sound = .default
        content.categoryIdentifier = Self.category
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = shown.thread
        content.userInfo = ["todo": identifier, "path": todo.url.path, "line": todo.line, "source": todo.source]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: Self.trigger(at: date)))
    }

    /// Done, from a to-do's notification: its notifications go and it is ticked. One that repeats has the next one's
    /// notification in when this returns, since from the Lock Screen the app has only this moment.
    func finishTodo(_ todo: TodoReference, identifier: String, workspace: Workspace) async {
        withdrawTodo(identifier)
        await workspace.setTodoDone(todo, true)?.value
    }

    /// A to-do's notifications put in now, as the to-dos' own scheduling makes them a moment later: for the next one of
    /// a to-do that repeats, ticked while the app may have only a moment.
    func scheduleTodo(_ job: TodoJob) async {
        guard isActive else { return }
        let center = UNUserNotificationCenter.current()
        if let date = job.date, date > .now {
            try? await center.add(UNNotificationRequest(identifier: job.identifier, content: Self.content(for: job, place: false), trigger: Self.trigger(at: date)))
        }
        #if os(iOS)
        if Self.watchesPlaces, let place = job.place, let trigger = Self.trigger(at: place, identifier: job.identifier + ".place") {
            try? await center.add(UNNotificationRequest(identifier: job.identifier + ".place", content: Self.content(for: job, place: true), trigger: trigger))
            await Self.armPlaces(prefix: Self.todoPrefix, center: center, keepingFired: nil)
        }
        #endif
    }

    /// A to-do was done or changed: its notifications go at once, before the list of to-dos has caught up.
    func withdrawTodo(_ identifier: String) {
        guard isActive else { return }
        Self.disarm([identifier + ".place"])
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier, identifier + ".place"])
        center.removeDeliveredNotifications(withIdentifiers: [identifier, identifier + ".place"])
    }

    /// Whether this device reminds you at places: iPhone and iPad do while Notebook may use your location.
    private static var watchesPlaces: Bool {
        #if os(iOS)
        PlaceAccess.shared.isAllowed
        #else
        false
        #endif
    }

    private nonisolated static func trigger(at date: Date) -> UNCalendarNotificationTrigger {
        UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date), repeats: false)
    }

    #if os(iOS)
    private nonisolated static func trigger(at place: TodoPlace, identifier: String) -> UNLocationNotificationTrigger? {
        guard let latitude = place.latitude, let longitude = place.longitude else { return nil }
        let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude), radius: TodoPlace.radius, identifier: identifier)
        region.notifyOnEntry = !place.leaving
        region.notifyOnExit = place.leaving
        return UNLocationNotificationTrigger(region: region, repeats: false)
    }
    #endif

    /// Shows a reminder's notification in a moment, as it will at its time: for the debug remote.
    func fireSoon(_ job: Job) {
        guard isActive else { return }
        Task.detached(priority: .userInitiated) {
            let text = job.text ?? job.url.flatMap(Self.readIfHere)
            let request = UNNotificationRequest(identifier: Self.identifier(job.id), content: Self.content(for: job, text: text, place: job.date == nil),
                                                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    /// A to-do's notification, as it will come, in a moment: for the debug remote.
    func fireSoon(_ job: TodoJob) {
        guard isActive else { return }
        Task.detached(priority: .userInitiated) {
            let request = UNNotificationRequest(identifier: job.identifier, content: Self.content(for: job, place: job.date == nil),
                                                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    nonisolated static func content(for job: TodoJob, place: Bool) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = job.title
        content.subtitle = job.subtitle(forPlace: place)
        content.body = job.body
        content.sound = .default
        content.categoryIdentifier = category
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = job.path
        content.userInfo = ["todo": job.identifier, "path": job.path, "line": job.line, "source": job.source]
        return content
    }

    nonisolated static func content(for job: Job, text: String?, place: Bool) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = job.title
        content.subtitle = (place ? job.place?.phrase : job.date?.formatted(date: .omitted, time: .shortened)) ?? ""
        content.body = text.map(NotePoints.text(of:)) ?? ""
        content.sound = .default
        content.categoryIdentifier = category
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["reminder": job.id.uuidString, "note": job.note]
        return content
    }

    /// The text of a note on this device. One still in iCloud is asked for, for next time, rather than waited for:
    /// the notification goes without its points instead of late.
    private nonisolated static func readIfHere(_ url: URL) -> String? {
        guard NoteDocument.wait(for: url) == nil else {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            return nil
        }
        return NoteDocument.read(url)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Shown while Notebook is in front too: a reminder is something you asked for.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        let id = (userInfo["reminder"] as? String).flatMap(UUID.init(uuidString:))
        let note = userInfo["note"] as? String
        let done = UncheckedSendable(completionHandler)
        if let identifier = userInfo["todo"] as? String, let path = userInfo["path"] as? String, let line = userInfo["line"] as? Int, let source = userInfo["source"] as? String {
            let todo = TodoReference(url: URL(fileURLWithPath: path), line: line, source: source)
            let shown = response.notification.request.content
            let again = UncheckedSendable((title: shown.title, subtitle: shown.subtitle, body: shown.body, thread: shown.threadIdentifier))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let workspace = Workspace.shared
                    workspace.start()
                    if action == UNNotificationDefaultActionIdentifier {
                        workspace.openTodo(todo, fromNotification: true)
                        return done.value()
                    }
                    // From the Lock Screen the app gets a moment: once the locations can be reached (the action may
                    // have started the app), the note is written, and then the moment is over.
                    Task {
                        await workspace.surveyed()
                        switch action {
                        case Self.laterAction:
                            let date = Workspace.minute(after: 60 * 60)
                            let later = workspace.remindOfTodoAgain(todo, at: date, notes: again.value.body)
                            await later.task?.value
                            // The notification for the new time goes in now, as the to-dos' own scheduling will make it.
                            await Self.shared.remindAgain(later.identifier, todo: later.todo, at: date, like: again.value)
                        case Self.doneAction:
                            await Self.shared.finishTodo(todo, identifier: identifier, workspace: workspace)
                        default: break
                        }
                        done.value()
                    }
                }
            }
            return
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let id else { return done.value() }
                let workspace = Workspace.shared
                // An action can be what started the app: the reminders are read first.
                workspace.start()
                var task: Task<Void, Never>?
                switch action {
                case UNNotificationDefaultActionIdentifier: workspace.openReminder(id, note: note)
                case Self.laterAction: task = workspace.remindAgain(id, in: 60 * 60)
                case Self.doneAction: workspace.finishReminder(id)
                default: break
                }
                // An action from the Lock Screen gets the app only for a moment: the new time is scheduled first.
                Task {
                    await task?.value
                    done.value()
                }
            }
        }
    }
}

/// A value the compiler can't tell is safe to send, that is only used once on the other side.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
