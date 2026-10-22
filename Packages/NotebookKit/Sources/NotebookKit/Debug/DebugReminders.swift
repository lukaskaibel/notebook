#if DEBUG
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import UserNotifications

/// The debug remote's commands for reminders, the same on the Mac and on iPhone and iPad:
///
///     remind <minutes from now | 2026-10-16T14:00> <note>   sets a reminder, as Remind Me… does
///     unremind <note>                                        removes it
///     reminders                                              every reminder, where its note is and its points
///     firereminder <note>                                    its notification in a second, as at its time
///     tapreminder <open|later|done> <note>                   a tap on the notification, or one of its actions
///     notifications                                          the notifications waiting and shown
///     reminderline                                           the bell under the open note's title
///     remindme <note>                                        Remind Me… from a menu: the popover or the sheet
///     remindme close                                         puts the popover away (Mac)
///     remindtype <text>                                      types a time into Remind Me (empty clears it)
///     remindkey <down|up|return>                             a key in Remind Me's field (on the Mac a key event,
///                                                            key equivalents first, as a keyboard's)
///     permission [provisional]                               asks for notifications, and logs the answer
@MainActor
enum DebugReminders {
    /// Posted for remindtype and remindkey, which Remind Me takes as typed.
    static let keyboard = Notification.Name("NotebookDebugReminderKeyboard")

    static func run(_ command: String, _ argument: String, workspace: Workspace, url: (String) -> URL?, log: @escaping (String) -> Void) -> Bool {
        let split = argument.split(separator: " ", maxSplits: 1).map(String.init)
        switch command {
        case "remind":
            guard split.count == 2, let note = url(split[1]), let date = date(split[0]) else { log("remind: <minutes|date> <note>"); break }
            workspace.setReminder(for: note, at: date)
            log("remind \(note.lastPathComponent) at \(date.formatted(date: .abbreviated, time: .standard)): \(workspace.reminder(for: note)?.note ?? "not set")")
        case "unremind":
            guard let note = url(argument) else { break }
            workspace.removeReminder(for: note)
            log("unremind \(note.lastPathComponent): \(workspace.reminders.all.count) left")
        case "reminders":
            let lines = workspace.reminders.all.map { reminder in
                let found = workspace.url(for: reminder)
                let text = found.flatMap { NoteDocument.read($0) }.map(NotePoints.text(of:)) ?? ""
                return "\(reminder.id) \(Workspace.reminderText(reminder.date)) \(reminder.note) -> \(found?.path ?? "not found")\n  " + text.replacingOccurrences(of: "\n", with: "\n  ")
            }
            log("reminders (\(workspace.reminders.all.count), iCloud \(workspace.reminders.isInICloud)):\n" + lines.joined(separator: "\n"))
        case "firereminder":
            guard let note = url(argument), let reminder = workspace.reminder(for: note) else { log("firereminder: no reminder for \(argument)"); break }
            let isOpen = note == workspace.currentURL && workspace.note?.isLoaded == true
            ReminderNotifications.shared.fireSoon(ReminderNotifications.Job(id: reminder.id, date: reminder.date, title: SearchSection.displayName(note),
                                                                           note: reminder.note, url: note, text: isOpen ? workspace.editor.text : nil))
            log("firereminder \(note.lastPathComponent) active \(ReminderNotifications.shared.isActive)")
        case "tapreminder":
            guard split.count == 2, let note = url(split[1]), let reminder = workspace.reminder(for: note) else { log("tapreminder: no reminder for \(argument)"); break }
            switch split[0] {
            case "later": workspace.remindAgain(reminder.id, in: 60 * 60)
            case "done": workspace.finishReminder(reminder.id)
            default: workspace.openReminder(reminder.id)
            }
            log("tapreminder \(split[0]): open \(workspace.currentURL?.lastPathComponent ?? "nothing"), reminder \(workspace.reminders.reminder(reminder.id).map { Workspace.reminderText($0.date) } ?? "done")")
        case "notifications":
            Task {
                let center = UNUserNotificationCenter.current()
                let settings = await center.notificationSettings()
                let pending = await center.pendingNotificationRequests().map { request in
                    let date = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()?.formatted(date: .abbreviated, time: .standard) ?? "soon"
                    return "  pending \(request.identifier) at \(date): \(request.content.title) | \(request.content.subtitle) | \(request.content.body.replacingOccurrences(of: "\n", with: " / "))"
                }
                let delivered = await center.deliveredNotifications().map { "  shown \($0.request.identifier): \($0.request.content.title)" }
                log("notifications (allowed \(settings.authorizationStatus.rawValue), time sensitive \(settings.timeSensitiveSetting.rawValue)):\n" + (pending + delivered).joined(separator: "\n"))
            }
        case "permission":
            // permission [provisional]: asks for notifications as the first reminder does, and says what the system
            // answered. Provisional needs no answer from a person: notifications then go quietly to Notification Center.
            Task {
                do {
                    let options: UNAuthorizationOptions = argument == "provisional" ? [.alert, .sound, .provisional] : [.alert, .sound]
                    let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: options)
                    log("permission: granted \(granted)")
                } catch {
                    log("permission: \(error)")
                }
            }
        case "reminderline":
            let button = workspace.editor.textView.reminderButton
            #if os(macOS)
            let title = button.title
            #else
            let title = button.configuration?.attributedTitle.map { String($0.characters) } ?? ""
            #endif
            log("reminderline: \(button.isHidden ? "none" : title) at \(button.frame.integral), meta “\(workspace.editor.metaText)” at \(workspace.editor.textView.metaLabel.frame.integral)")
        case "remindtype", "remindkey":
            #if os(macOS)
            if command == "remindkey", let window = workspace.reminderPopover?.contentViewController?.view.window,
               let (characters, code) = ["return": ("\r", UInt16(36)), "down": (String(UnicodeScalar(NSDownArrowFunctionKey)!), 125), "up": (String(UnicodeScalar(NSUpArrowFunctionKey)!), 126)][argument] {
                let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nothing"
                let modifiers: NSEvent.ModifierFlags = code == 36 ? [] : [.function, .numericPad]
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                       context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { continue }
                    if type == .keyDown, window.performKeyEquivalent(with: event) { continue }
                    window.sendEvent(event)
                }
                log("remindkey \(argument) to \(responder)")
                break
            }
            #endif
            NotificationCenter.default.post(name: keyboard, object: nil, userInfo: ["command": command, "argument": argument])
            log("\(command) \(argument)")
        case "remindme":
            #if os(macOS)
            if argument == "close" {
                workspace.reminderPopover?.close()
                log("remindme close")
                break
            }
            #endif
            guard let note = url(argument) else { break }
            #if os(macOS)
            var anchor: NSView?
            if note != workspace.currentURL, let outline = workspace.sidebar?.outline, let node = workspace.node(for: note, reading: false) {
                let row = outline.row(forItem: node)
                if row >= 0 { anchor = outline.view(atColumn: 0, row: row, makeIfNecessary: true) }
            }
            workspace.askForReminder(note, from: anchor)
            #else
            workspace.askForReminder(note)
            #endif
            log("remindme \(note.lastPathComponent)")
        default:
            return false
        }
        return true
    }

    /// Minutes from now, or a date and time such as 2026-10-16T14:00.
    private static func date(_ text: String) -> Date? {
        if let minutes = Double(text.trimmingCharacters(in: CharacterSet(charactersIn: "+"))) { return Date(timeIntervalSinceNow: minutes * 60) }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter.date(from: text)
    }
}
#endif
