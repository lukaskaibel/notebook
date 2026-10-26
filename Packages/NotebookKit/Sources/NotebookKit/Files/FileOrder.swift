import Foundation
import Observation

/// How the files in a folder are sorted: by name, as the Finder sorts, or newest first by when they were last edited or
/// were made, as Notes sorts.
public enum FileOrder: String, CaseIterable, Identifiable, Sendable {
    case name, dateEdited, dateCreated

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .name: "Name"
        case .dateEdited: "Date Edited"
        case .dateCreated: "Date Created"
        }
    }

    var isByDate: Bool { self != .name }
}

/// The order you chose, and the one place that knows where it is kept: every folder asks here how it is sorted, so
/// keeping an order per folder later changes nothing else. For now one order goes for every folder, in the user
/// defaults of this device.
@MainActor
@Observable
public final class FileOrders {
    private var order: FileOrder

    init() {
        order = UserDefaults.standard.string(forKey: "fileOrder").flatMap(FileOrder.init(rawValue:)) ?? .name
    }

    /// How a folder's files are sorted.
    public func order(of folder: URL?) -> FileOrder {
        order
    }

    /// Sorts a folder's files another way. The sidebar and the lists follow.
    public func set(_ order: FileOrder, for folder: URL?) {
        guard order != self.order else { return }
        self.order = order
        UserDefaults.standard.set(order.rawValue, forKey: "fileOrder")
        NotificationCenter.default.post(name: .notebookFileOrderChanged, object: nil)
    }
}

public extension Notification.Name {
    static let notebookFileOrderChanged = Notification.Name("NotebookFileOrderChanged")
}
