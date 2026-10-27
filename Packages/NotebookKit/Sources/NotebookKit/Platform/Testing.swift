import Foundation

extension ProcessInfo {
    /// Notebook's tests run in this process: from Xcode, which says so in the environment, or from `swift test`, which
    /// doesn't. The app's own stores in Application Support and the caches, Spotlight and reading the text in pictures
    /// stay out of them.
    static let isTesting = processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
}
