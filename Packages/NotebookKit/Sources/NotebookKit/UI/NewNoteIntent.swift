import AppIntents

/// New Note in Shortcuts, in Spotlight and on the iPhone's Action button: Notebook comes to the front with a new note
/// in the default folder and the caret in its title, as ⌘N makes one with nothing open. A shortcut can give it text to
/// start with. It runs in the app, so a widget or a control can have it too.
public struct NewNoteIntent: AppIntent {
    public static let title: LocalizedStringResource = "New Note"
    public static let description = IntentDescription("Opens Notebook with a new note in the default folder, ready for its title.")
    public static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Text", description: "What the note starts with.", inputOptions: String.IntentInputOptions(multiline: true))
    public var text: String?

    public static var parameterSummary: some ParameterSummary {
        Summary("New note with \(\.$text)")
    }

    public init() {}

    public init(text: String?) {
        self.text = text
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        let workspace = Workspace.shared
        guard await workspace.newNoteFromOutside(text: text ?? "") != nil else {
            throw workspace.locations.isEmpty ? NewNoteIntentError.noLocation : .notMade
        }
        return .result()
    }
}

enum NewNoteIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noLocation
    case notMade

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noLocation: "Choose where your notes are in Notebook first."
        case .notMade: "The note couldn’t be made."
        }
    }
}

/// NotebookKit's intents, for the app to take into its App Shortcuts (`NotebookShortcuts` in the app target).
public struct NotebookKitIntents: AppIntentsPackage {}
