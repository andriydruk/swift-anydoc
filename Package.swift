// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "swift-anydoc",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "AnyDoc", targets: ["AnyDoc"]),
        .executable(name: "anydoc-cli", targets: ["anydoc-cli"]),
    ],
    targets: [
        // The library: pure Swift, zero dependencies. No Foundation — the
        // stdlib and (for file reads only) the platform libc are the world.
        .target(name: "AnyDoc", path: "Sources/AnyDoc"),
        .executableTarget(name: "anydoc-cli", dependencies: ["AnyDoc"], path: "Sources/anydoc-cli"),
        .testTarget(
            name: "AnyDocTests", dependencies: ["AnyDoc"], path: "Tests/AnyDocTests",
            // Binary payloads the tests feed to parsers directly.
            resources: [.copy("Resources")]),
    ]
)
