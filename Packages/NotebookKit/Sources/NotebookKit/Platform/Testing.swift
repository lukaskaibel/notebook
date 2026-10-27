import Foundation

extension ProcessInfo {
    /// Notebook's tests run in this process: from Xcode, which says so in the environment, or from `swift test`, which
    /// doesn't. The app's own stores in Application Support and the caches, Spotlight and reading the text in pictures
    /// stay out of them.
    static let isTesting: Bool = {
        if processInfo.environment["XCTestConfigurationFilePath"] != nil { return true }
        #if DEBUG
        // `swift test` builds for debugging; a build that ships never looks for XCTest, so nothing turns these off there.
        return NSClassFromString("XCTestCase") != nil
        #else
        return false
        #endif
    }()
}
