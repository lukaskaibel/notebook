import Foundation

/// How a folder looks in the sidebar: a symbol or an emoji instead of the folder, and a colour. Kept where the Finder
/// keeps what Customize Folder chooses (macOS 26 and later): the symbol or emoji in an attribute of the folder, the
/// colour as one of the Finder's colour tags, which tint folders. Both stay with the folder when it is renamed or
/// moved, iCloud Drive takes them to your other devices, and the Finder and the Files app show them too.
public struct FolderIcon: Equatable, Hashable, Sendable {
    /// An SF Symbol's name.
    public var symbol: String?
    public var emoji: String?
    public var color: FolderColor?

    public init(symbol: String? = nil, emoji: String? = nil, color: FolderColor? = nil) {
        self.symbol = symbol
        self.emoji = emoji
        self.color = color
    }

    /// The plain folder, as every folder looks until you choose something else.
    public var isPlain: Bool { symbol == nil && emoji == nil && color == nil }
}

/// The colours of the Finder's tags, in the order the Finder lists them. The number is the one a tag carries.
public enum FolderColor: Int, CaseIterable, Sendable {
    case red = 6, orange = 7, yellow = 5, green = 2, blue = 4, purple = 3, gray = 1

    /// The name of the Finder's tag of this colour.
    public var name: String {
        switch self {
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .purple: "Purple"
        case .gray: "Gray"
        }
    }

    /// The tag as the Finder writes it: its name, a line break and its colour.
    var tag: String { "\(name)\n\(rawValue)" }
}

/// Reading and writing a folder's look where the Finder has it.
enum FolderIcons {
    /// Customize Folder's symbol or emoji, as JSON: `{"sym":"star"}` or `{"emoji":"🍕"}`. "#S" asks iCloud Drive to
    /// sync it.
    static let attribute = "com.apple.icon.folder#S"
    /// The Finder's tags: a property list of names, each with its colour after a line break ("Red\n6").
    static let tagsAttribute = "com.apple.metadata:_kMDItemUserTags"

    /// A folder's look; nil for the plain folder. Reads two small attributes, which the folder listings do for every
    /// folder, off the main thread.
    nonisolated static func read(_ url: URL) -> FolderIcon? {
        var icon = FolderIcon()
        if let data = value(attribute, of: url), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            icon.symbol = (json["sym"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            icon.emoji = (json["emoji"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        if let data = value(tagsAttribute, of: url) { icon.color = color(of: tags(in: data)) }
        return icon.isPlain ? nil : icon
    }

    /// Gives a folder a look, or the plain one back with nil. Of the tags only the plain colour ones ("Red", "Blue")
    /// change; the folder's other tags stay, and so does anything else the Finder keeps with the symbol. Says whether
    /// it could.
    @discardableResult
    nonisolated static func write(_ icon: FolderIcon?, to url: URL) -> Bool {
        var done = false
        var error: NSError?
        // Only the folder's attributes change, not what is in it: other apps showing the folder needn't let go of it.
        NSFileCoordinator().coordinate(writingItemAt: url, options: .contentIndependentMetadataOnly, error: &error) { url in
            done = writeSymbol(icon, to: url) && writeColor(icon?.color, to: url)
        }
        return done && error == nil
    }

    private nonisolated static func writeSymbol(_ icon: FolderIcon?, to url: URL) -> Bool {
        var json = value(attribute, of: url).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        json["sym"] = nil
        json["emoji"] = nil
        // One or the other, as Customize Folder chooses.
        if let emoji = icon?.emoji {
            json["emoji"] = emoji
        } else if let symbol = icon?.symbol {
            json["sym"] = symbol
        }
        guard !json.isEmpty else { return remove(attribute, from: url) }
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes]) else { return false }
        return set(attribute, to: data, on: url)
    }

    private nonisolated static func writeColor(_ color: FolderColor?, to url: URL) -> Bool {
        let old = value(tagsAttribute, of: url).map(tags) ?? []
        var new = old.filter { !isColorTag($0) }
        if let color { new.append(color.tag) }
        guard new != old else { return true }
        guard !new.isEmpty else { return remove(tagsAttribute, from: url) }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: new, format: .binary, options: 0) else { return false }
        return set(tagsAttribute, to: data, on: url)
    }

    nonisolated static func tags(in data: Data) -> [String] {
        (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String] ?? []
    }

    /// The folder's colour: that of its last tag with one, as the Finder tints it. A tag without a number that is
    /// named after a colour has that colour.
    nonisolated static func color(of tags: [String]) -> FolderColor? {
        for tag in tags.reversed() {
            let parts = tag.split(separator: "\n", omittingEmptySubsequences: false)
            if parts.count > 1, let number = Int(parts[parts.count - 1]) {
                if let color = FolderColor(rawValue: number) { return color }
            } else if let color = FolderColor.allCases.first(where: { $0.name.caseInsensitiveCompare(tag) == .orderedSame }) {
                return color
            }
        }
        return nil
    }

    /// One of the Finder's plain colour tags, which only colour: "Red", whatever its number.
    private nonisolated static func isColorTag(_ tag: String) -> Bool {
        let name = tag.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? tag
        return FolderColor.allCases.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: - Extended attributes

    nonisolated static func value(_ name: String, of url: URL) -> Data? {
        url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let size = getxattr(path, name, nil, 0, 0, 0)
            guard size > 0 else { return nil }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
            return read == size ? data : nil
        }
    }

    private nonisolated static func set(_ name: String, to data: Data, on url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return data.withUnsafeBytes { setxattr(path, name, $0.baseAddress, data.count, 0, 0) } == 0
        }
    }

    private nonisolated static func remove(_ name: String, from url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return removexattr(path, name, 0) == 0 || errno == ENOATTR
        }
    }
}
