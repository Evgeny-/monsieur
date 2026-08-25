// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Monsieur",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Monsieur",
            path: "Sources/Monsieur",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Depends on the executable target directly rather than splitting out
        // a library target: SwiftPM has been able to test an `@main`-based
        // executable target this way since Swift 5.5, because `@main` (unlike
        // top-level code in a literal `main.swift`) compiles to an ordinary
        // type that a library-style build can link without pulling in the
        // program's actual entry point. `MonsieurApp.swift` qualifies.
        .testTarget(
            name: "MonsieurTests",
            dependencies: ["Monsieur"],
            path: "Tests/MonsieurTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
