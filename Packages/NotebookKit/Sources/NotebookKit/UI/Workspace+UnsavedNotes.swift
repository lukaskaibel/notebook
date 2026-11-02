#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What Notebook says about a note left that couldn't be written (`NoteDocument.onUnsaved`): where what was typed is
/// kept, or, when it couldn't be kept anywhere, that it is only in Notebook now, with Copy Text and Try Again.
struct UnsavedReport: Identifiable {
    let id = UUID()
    /// The note's name.
    var name: String
    /// The note in Notebook's folder that keeps what was typed. Nil when there is none: then Notebook asks.
    var copy: URL?
    /// Why the note couldn't be written, as the system says it, when it did.
    var reason: String?
    /// The note waiting for an answer, when there is no copy.
    var unsaved: UnsavedNote?

    var title: String { "Couldn’t Save “\(name)”" }

    @MainActor
    var message: String {
        let why = reason.map { $0 + " " } ?? ""
        if let copy {
            return why + "What you typed is kept as “\(copy.lastPathComponent)” in \(UnsavedNotes.placeName). The note itself is as it was last saved."
        }
        return why + "No copy could be kept in Notebook’s folder either. Copy what you typed to paste it somewhere else, or try again."
    }

    /// A copy kept that wasn't told about yet, as it is remembered between launches.
    struct Untold: Codable, Equatable {
        var name: String
        /// The copy's name in Notebook's folder, whose place on iPhone and iPad changes with an update.
        var copy: String
        var reason: String?
    }

    var untold: Untold? {
        copy.map { Untold(name: name, copy: $0.lastPathComponent, reason: reason) }
    }

    enum Answer { case ok, show, copyText, tryAgain }
}

extension Workspace {
    /// Listens for notes left that couldn't be written, and tells about copies kept that the last run couldn't tell
    /// about: as the Mac quit, or when the system ended Notebook in the background before it came back.
    func tellAboutUnsavedNotes() {
        guard !ProcessInfo.isTesting else { return }
        NoteDocument.onUnsaved = { [weak self] in self?.tell($0) }
        // Kept in case Notebook was ended, and its note written after all: nothing to tell.
        NoteDocument.onWrittenAfterAll = { Self.forget($0.lastPathComponent) }
        let untold = Self.untold
        guard !untold.isEmpty else { return }
        let folder = UnsavedNotes.folder
        Task {
            let found = await Task.detached(priority: .utility) {
                untold.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.copy).path) }
            }.value
            // Moved or thrown away since: found already.
            for gone in untold where !found.contains(gone) { Self.forget(gone.copy) }
            for told in found {
                show(UnsavedReport(name: told.name, copy: folder.appendingPathComponent(told.copy), reason: told.reason))
            }
        }
    }

    private func tell(_ unsaved: UnsavedNote) {
        let report = UnsavedReport(name: unsaved.name, copy: unsaved.copy, reason: unsaved.reason, unsaved: unsaved.copy == nil ? unsaved : nil)
        guard let untold = report.untold else { return ask(report) }
        // Remembered until it was shown: quitting doesn't leave it untold. Kept again, it is one copy.
        Self.forget(untold.copy)
        Self.untold.append(untold)
        // As the Mac quits, it is told at the next launch; so is a copy kept as Notebook went out of sight on iPhone
        // and iPad, in case it is ended there, unless its note is written after all.
        guard !hasQuit, !unsaved.mayStillBeWritten else { return }
        show(report)
    }

    /// Where a copy was kept: once Notebook is in front.
    private func show(_ report: UnsavedReport) {
        inFront { [weak self] in
            guard let self else { return }
            #if os(macOS)
            let alert = NSAlert()
            alert.messageText = report.title
            alert.informativeText = report.message
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Show in Finder")
            present(alert) { [weak self] response in
                self?.answer(report, response == .alertSecondButtonReturn ? .show : .ok)
            }
            #else
            unsavedReports.append(report)
            #endif
        }
    }

    /// Nowhere to keep what was typed: asked at once, also as the Mac quits, which waits for the answer, as the text is
    /// only in Notebook now.
    private func ask(_ report: UnsavedReport) {
        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = report.title
        alert.informativeText = report.message
        alert.addButton(withTitle: "Copy Text")
        alert.addButton(withTitle: "Try Again")
        if !NSApp.isActive { NSApp.requestUserAttention(.criticalRequest) }
        present(alert) { [weak self] response in
            self?.answer(report, response == .alertSecondButtonReturn ? .tryAgain : .copyText)
        }
        #else
        unsavedReports.append(report)
        #endif
    }

    func answer(_ report: UnsavedReport, _ answer: UnsavedReport.Answer) {
        #if os(iOS)
        unsavedReports.removeAll { $0.id == report.id }
        #endif
        if let untold = report.untold { Self.forget(untold.copy) }
        switch answer {
        case .ok:
            break
        case .show:
            guard let copy = report.copy else { return }
            #if os(macOS)
            NSWorkspace.shared.activateFileViewerSelecting([copy])
            #else
            open(copy)
            #endif
        case .copyText:
            guard let unsaved = report.unsaved else { return }
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(unsaved.text, forType: .string)
            #else
            UIPasteboard.general.string = unsaved.text
            #endif
            unsaved.letGo()
        case .tryAgain:
            report.unsaved?.tryAgain()
        }
    }

    // MARK: - Remembered

    private static let untoldKey = "unsavedNotesUntold"

    private static var untold: [UnsavedReport.Untold] {
        get {
            UserDefaults.standard.data(forKey: untoldKey).flatMap { try? JSONDecoder().decode([UnsavedReport.Untold].self, from: $0) } ?? []
        }
        set {
            if newValue.isEmpty {
                UserDefaults.standard.removeObject(forKey: untoldKey)
            } else {
                UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: untoldKey)
            }
        }
    }

    /// Forgets the copy of this name: told, gone, or thrown away again.
    private static func forget(_ copy: String) {
        guard untold.contains(where: { $0.copy == copy }) else { return }
        untold.removeAll { $0.copy == copy }
    }
}
