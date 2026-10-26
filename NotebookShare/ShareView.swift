import NotebookCapture
import SwiftUI
import UniformTypeIdentifiers

/// The sheet Notebook shows in the share sheet, as Notes does: what is shared, a title for a new note, and where it
/// goes, a new note in the default folder or the end of the note opened last.
struct ShareView: View {
    let content: SharedContent
    let done: (_ kept: Bool) -> Void

    @State private var title = ""
    @State private var appendsToLastNote = false
    @State private var problem: String?
    @State private var isSaving = false
    private let places = SharedNotes.places

    init(content: SharedContent, done: @escaping (_ kept: Bool) -> Void) {
        self.content = content
        self.done = done
    }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            form
                .navigationTitle("Notebook")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { done(false) } }
                    ToolbarItem(placement: .confirmationAction) {
                        if isSaving { ProgressView() } else { Button("Save", action: save).disabled(!content.isLoaded) }
                    }
                }
        }
        .onChange(of: content.isLoaded, initial: true) { title = content.suggestedTitle }
        #else
        VStack(spacing: 0) {
            form
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { done(false) }
                    .keyboardShortcut(.cancelAction)
                if isSaving { ProgressView().controlSize(.small) }
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!content.isLoaded || isSaving)
            }
            .padding()
        }
        .frame(width: 420)
        .onChange(of: content.isLoaded, initial: true) { title = content.suggestedTitle }
        #endif
    }

    private var form: some View {
        Form {
            Section {
                if !appendsToLastNote {
                    TextField("Title", text: $title, prompt: Text("Untitled"))
                        .font(.headline)
                }
                TextField("Text", text: Bindable(content).text, prompt: Text("Add text"), axis: .vertical)
                    .lineLimit(3...8)
                if let link = content.link {
                    Label {
                        VStack(alignment: .leading) {
                            if let page = content.linkTitle { Text(page).lineLimit(1) }
                            Text(link.absoluteString).foregroundStyle(.secondary).lineLimit(1)
                        }
                    } icon: {
                        Image(systemName: "link")
                    }
                }
                ForEach(content.files, id: \.self) { file in
                    Label(file.lastPathComponent, systemImage: isPicture(file) ? "photo" : "doc")
                        .lineLimit(1)
                }
            }
            Section {
                Picker("Add to", selection: $appendsToLastNote) {
                    Text("New Note in \(places?.defaultFolder ?? "Inbox")").tag(false)
                    if let last = places?.lastNoteTitle {
                        Text("End of “\(last)”").tag(true)
                    }
                }
            } footer: {
                Text(problem ?? "Notebook adds it to your notes as soon as it’s open.")
                    .foregroundStyle(problem == nil ? Color.secondary : Color.red)
            }
        }
        .formStyle(.grouped)
    }

    private func save() {
        let destination: SharedNote.Destination = appendsToLastNote ? places?.lastNote.map { .endOf(path: $0) } ?? .newNote : .newNote
        isSaving = true
        Task {
            do {
                try await content.keep(as: title, at: destination)
                done(true)
            } catch {
                isSaving = false
                problem = SharedNotes.folder == nil ? "This build of Notebook has no App Group to keep it in."
                    : "Notebook couldn’t keep it: \(error.localizedDescription)"
            }
        }
    }

    private func isPicture(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }
}
