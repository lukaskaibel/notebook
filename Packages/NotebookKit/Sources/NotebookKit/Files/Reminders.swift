import Foundation

/// A reminder of a note: at a time, when you arrive at or leave a place, or both.
struct Reminder: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    /// The note, by the name `HiddenFolders.key(for:links:)` gives it: its place in iCloud, the same on a Mac, an iPhone
    /// and an iPad, or its path when it isn't in iCloud.
    var note: String
    var date: Date?
    var place: TodoPlace?

    init(id: UUID, note: String, date: Date?, place: TodoPlace? = nil) {
        self.id = id
        self.note = note
        self.date = date
        self.place = place
    }

    /// The note's name, for when the note can't be found on this device.
    var name: String { ((note as NSString).lastPathComponent as NSString).deletingPathExtension }

    /// Its time has passed.
    var isOverdue: Bool { date.map { $0 <= .now } ?? false }

    /// "Tomorrow 8:30", "Arriving at Pharmacy", or both.
    var text: String {
        [date.map { ReminderText.text($0, time: true) }, place?.phrase].compactMap { $0 }.joined(separator: ", ")
    }
}

/// The reminders of notes. Not in the notes: setting one never changes the file, and the time doesn't go along with a
/// note you share. They are kept in iCloud's key-value store, which takes them to your other devices, and in the app's
/// settings, which is all a build without the iCloud entitlement has. Each device schedules its own notifications from
/// them. A reminder that is done leaves the store.
@MainActor
@Observable
final class Reminders {
    /// Every reminder, soonest first.
    private(set) var all: [Reminder] = []
    /// Another device set, changed or finished a reminder.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let cloud: NSUbiquitousKeyValueStore?
    @ObservationIgnored private var observer: NSObjectProtocol?

    private static let defaultsKey = "reminders"
    private static let uploadedKey = "remindersInICloud"
    private static let cloudPrefix = "reminder."
    /// Reminders with a place, under keys of their own: a build from before places can't read them, and so never
    /// writes one back without its place.
    private static let placePrefix = "placeReminder."

    /// With no defaults and no cloud the reminders are kept for this run only (tests, the sample notes).
    init(defaults: UserDefaults? = .standard, cloud: NSUbiquitousKeyValueStore? = .default) {
        self.defaults = defaults
        // Without the entitlement the store keeps nothing, and says so here.
        self.cloud = cloud?.synchronize() == true ? cloud : nil
        all = Self.sorted(defaults?.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode([Reminder].self, from: $0) } ?? [])
        guard let cloud = self.cloud else { return }
        // Reminders set before iCloud was there go up once; from then on iCloud has the last word.
        if defaults?.bool(forKey: Self.uploadedKey) != true {
            for reminder in all { Self.write(reminder, to: cloud) }
            defaults?.set(true, forKey: Self.uploadedKey)
        }
        all = Self.read(cloud)
        save()
        observer = NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    /// Whether iCloud takes them to your other devices.
    var isInICloud: Bool { cloud != nil }

    /// Takes in what iCloud has now: after another device changed a reminder, or when the iPhone gets time in the
    /// background to look.
    func reload() {
        guard let cloud else { return }
        cloud.synchronize()
        let fresh = Self.read(cloud)
        guard fresh != all else { return }
        all = fresh
        save()
        onChange?()
    }

    /// The reminder of a note, by its name in the store.
    func reminder(for note: String) -> Reminder? {
        all.first { $0.note == note }
    }

    func reminder(_ id: UUID) -> Reminder? {
        all.first { $0.id == id }
    }

    /// Sets or changes a reminder.
    func set(_ reminder: Reminder) {
        guard all.first(where: { $0.id == reminder.id }) != reminder else { return }
        all.removeAll { $0.id == reminder.id }
        all = Self.sorted(all + [reminder])
        if let cloud { Self.write(reminder, to: cloud) }
        save()
    }

    /// A note has one reminder: setting a time or a place changes the one it has.
    @discardableResult
    func set(note: String, date: Date?, place: TodoPlace? = nil) -> Reminder {
        var reminder = reminder(for: note) ?? Reminder(id: UUID(), note: note, date: date, place: place)
        reminder.date = date
        reminder.place = place
        set(reminder)
        return reminder
    }

    /// Done, or taken away.
    func remove(_ id: UUID) {
        guard all.contains(where: { $0.id == id }) else { return }
        all.removeAll { $0.id == id }
        cloud?.removeObject(forKey: Self.cloudKey(id))
        cloud?.removeObject(forKey: Self.placeKey(id))
        save()
    }

    /// A note renamed or moved in Notebook keeps its reminder, and so do the notes in a folder renamed or moved.
    func move(_ old: String, to new: String) {
        for var reminder in all where reminder.note == old || reminder.note.hasPrefix(old + "/") {
            reminder.note = new + reminder.note.dropFirst(old.count)
            set(reminder)
        }
    }

    /// A note thrown away takes its reminder with it, and a folder the reminders of its notes.
    func forget(_ old: String) {
        for reminder in all where reminder.note == old || reminder.note.hasPrefix(old + "/") { remove(reminder.id) }
    }

    private func save() {
        defaults?.set(try? JSONEncoder().encode(all), forKey: Self.defaultsKey)
    }

    /// One entry per reminder, so reminders set on two devices at the same time are both kept. The store's keys can
    /// have 64 bytes: the reminder's identifier fits, the note's path is in the value.
    static func cloudKey(_ id: UUID) -> String {
        cloudPrefix + id.uuidString
    }

    static func placeKey(_ id: UUID) -> String {
        placePrefix + id.uuidString
    }

    private static func write(_ reminder: Reminder, to cloud: NSUbiquitousKeyValueStore) {
        guard let data = try? JSONEncoder().encode(reminder) else { return }
        // Under one key or the other, never both.
        let (key, other) = reminder.place == nil ? (cloudKey(reminder.id), placeKey(reminder.id)) : (placeKey(reminder.id), cloudKey(reminder.id))
        cloud.set(data, forKey: key)
        cloud.removeObject(forKey: other)
    }

    private static func read(_ cloud: NSUbiquitousKeyValueStore) -> [Reminder] {
        var byID: [UUID: Reminder] = [:]
        for (key, value) in cloud.dictionaryRepresentation {
            guard key.hasPrefix(cloudPrefix) || key.hasPrefix(placePrefix), let data = value as? Data,
                  let reminder = try? JSONDecoder().decode(Reminder.self, from: data) else { continue }
            // Both, while another device moves one: the one with the place is the newer.
            if byID[reminder.id]?.place == nil { byID[reminder.id] = reminder }
        }
        return sorted(Array(byID.values))
    }

    private static func sorted(_ reminders: [Reminder]) -> [Reminder] {
        // Those at a place only after the rest.
        reminders.sorted { a, b in
            let aDate = a.date ?? .distantFuture, bDate = b.date ?? .distantFuture
            return aDate != bDate ? aDate < bDate : a.id.uuidString < b.id.uuidString
        }
    }
}
