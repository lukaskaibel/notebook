import Foundation

// makebookmarks <note> <picture>: prints three bookmarks to <picture> as "<kind> <hex>" lines:
// document (security-scoped, relative to <note>), app (security-scoped, app-scoped) and plain (no security scope).
let note = URL(fileURLWithPath: CommandLine.arguments[1])
let picture = URL(fileURLWithPath: CommandLine.arguments[2])

func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

let kinds: [(String, URL.BookmarkCreationOptions, URL?)] = [
    ("document", [.withSecurityScope, .securityScopeAllowOnlyReadAccess], note),
    ("app", [.withSecurityScope, .securityScopeAllowOnlyReadAccess], nil),
    ("plain", [], nil),
]
// A plain bookmark to a folder: makebookmarks <note> <picture> <folder> also prints "folder <hex>".
if CommandLine.arguments.count > 3 {
    let folder = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
    print("folder", hex(try! folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)))
}
for (kind, options, relative) in kinds {
    do {
        let data = try picture.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: relative)
        print(kind, hex(data))
    } catch {
        FileHandle.standardError.write("\(kind) failed: \(error)\n".data(using: .utf8)!)
    }
}
