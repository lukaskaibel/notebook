import AppIntents

/// New Note in Shortcuts, in Spotlight, on the iPhone's Action button, in the widgets and in Control Center: Notebook
/// comes to the front with a new note in the default folder and the caret in its title, as ⌘N makes one with nothing
/// open. A shortcut can give it text to start with.
///
/// It lives apart from NotebookKit so the widgets' extension can have it without the rest of the app. It opens the
/// app, so the system always runs it there, also when it is tapped in a widget; the app says how it makes the note
/// (`makeNote`).
public struct NewNoteIntent: AppIntent {
    public static let title: LocalizedStringResource = "New Note"
    public static let description = IntentDescription("Opens Notebook with a new note in the default folder, ready for its title.")
    public static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Text", description: "What the note starts with.", inputOptions: String.IntentInputOptions(multiline: true))
    public var text: String?

    public static var parameterSummary: some ParameterSummary {
        Summary("New note with \(\.$text)")
    }

    /// Makes the note with the text given, set by the app as it starts, before the system hands it an intent.
    @MainActor public static var makeNote: ((String) async throws -> Void)?

    /// What a tap on a New Note widget opens Notebook with where the system doesn't run the intent: on the Lock Screen
    /// of a locked iPhone it only opens the app. The app makes the note for it all the same (`QuickCapture`).
    public static let widgetURL = URL(string: "notebook-widget:new-note")!

    public init() {}

    public init(text: String?) {
        self.text = text
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        guard let makeNote = Self.makeNote else { throw NewNoteIntentError.notMade }
        try await makeNote(text ?? "")
        return .result()
    }
}

public enum NewNoteIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noLocation
    case notMade

    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noLocation: "Choose where your notes are in Notebook first."
        case .notMade: "The note couldn’t be made."
        }
    }
}

/// The intents here, for the app and the widgets' extension to take in (`NotebookKitIntents`,
/// `NotebookWidgetsIntents`).
public struct NotebookCaptureIntents: AppIntentsPackage {}
