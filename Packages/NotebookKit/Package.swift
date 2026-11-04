// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotebookKit",
    defaultLocalization: "en",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        // A framework the app carries once, in its Frameworks folder, for itself and the Quick Look and thumbnail
        // extensions, which find it there; linked statically, each would carry a copy of its own. NotebookCapture is
        // inside it, so the app takes it from here and has it only once. The resources of NotebookKit and SwiftMath go
        // into it too (Config/notebookkit-resources.sh).
        .library(name: "NotebookKit", type: .dynamic, targets: ["NotebookKit", "NotebookCapture"]),
        // What the widgets' and the share extension share with the app, without the rest of NotebookKit: the New Note
        // intent. They link it statically, so they stay small.
        .library(name: "NotebookCapture", targets: ["NotebookCapture"]),
    ],
    dependencies: [
        // Exact, as in Issues: its Mac images come out upside down and MermaidImage turns them round,
        // which a fix upstream would undo.
        .package(url: "https://github.com/lukilabs/beautiful-mermaid-swift", exact: "1.0.4"),
        .package(url: "https://github.com/mgriebling/SwiftMath", from: "1.7.3"),
    ],
    targets: [
        .target(
            name: "NotebookCapture",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "NotebookKit",
            dependencies: [
                "NotebookCapture",
                .product(name: "BeautifulMermaid", package: "beautiful-mermaid-swift"),
                .product(name: "SwiftMath", package: "SwiftMath"),
            ],
            // Passes of the app icon's notebook, made by Tools/AppIcon/make.sh.
            resources: [.copy("Resources/NotebookIcon")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Settings and a folder of each test run's own, as the tests are loaded: every `swift test` on a Mac runs as
        // xctest and would share xctest's settings with every other run at the same time.
        .target(
            name: "NotebookTestSupport",
            path: "Tests/NotebookTestSupport"
        ),
        .testTarget(
            name: "NotebookKitTests",
            dependencies: ["NotebookKit", "NotebookCapture", "NotebookTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
