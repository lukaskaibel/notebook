// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotebookKit",
    defaultLocalization: "en",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        .library(name: "NotebookKit", targets: ["NotebookKit"]),
        // What the widgets' extension shares with the app, without the rest of NotebookKit: the New Note intent.
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
        .testTarget(
            name: "NotebookKitTests",
            dependencies: ["NotebookKit", "NotebookCapture"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
