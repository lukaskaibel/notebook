import AppKit

// A sandboxed stand-in for Notebook: the first time, you pick a folder in an Open panel and it keeps a security-scoped
// bookmark to it, as Notebook does for a location. Each run it resolves that bookmark (as Notebook does after a
// relaunch) and makes a plain bookmark to the folder for another process, kept as hex in its defaults ("plain"), with
// what happened in "log". It then quits.
let defaults = UserDefaults.standard
let app = NSApplication.shared
app.setActivationPolicy(.regular)

func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

func handOn(_ folder: URL, how: String) {
    do {
        let plain = try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(hex(plain), forKey: "plain")
        defaults.set("\(how): plain bookmark to \(folder.path), \(plain.count) bytes", forKey: "log")
    } catch {
        defaults.set("\(how): plain bookmark failed: \(error)", forKey: "log")
    }
    defaults.synchronize()
}

DispatchQueue.main.async {
    if let kept = defaults.data(forKey: "location") {
        var stale = false
        if let folder = try? URL(resolvingBookmarkData: kept, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale),
           folder.startAccessingSecurityScopedResource() {
            handOn(folder, how: "relaunch")
        } else {
            defaults.set("relaunch: kept bookmark didn't resolve", forKey: "log")
        }
        exit(0)
    }
    app.activate()
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory().components(separatedBy: "/Library/Containers").first! + "/NotebookQLProto")
    panel.message = "Quick Look prototype: choose the NotebookQLProto folder"
    panel.prompt = "Choose"
    guard panel.runModal() == .OK, let folder = panel.url else { defaults.set("cancelled", forKey: "log"); exit(1) }
    if let kept = try? folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
        defaults.set(kept, forKey: "location")
    }
    handOn(folder, how: "picked")
    exit(0)
}
app.run()
