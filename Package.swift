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
        // The library: zero fetched dependencies. No Foundation — the stdlib,
        // the platform libc and the system zlib are the world.
        // The system zlib. Not a fetched dependency — no `.package(...)` is
        // declared — but a link against a library macOS, the iOS SDK and every
        // mainstream Linux already ship. It replaces the in-repo inflater on
        // the hot path; that implementation stays as the fallback and as the
        // thing zlib is differentially tested against.
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .target(name: "AnyDoc", dependencies: ["CZlib"], path: "Sources/AnyDoc"),
        .executableTarget(name: "anydoc-cli", dependencies: ["AnyDoc"], path: "Sources/anydoc-cli"),
        .testTarget(
            name: "AnyDocTests", dependencies: ["AnyDoc", "CZlib"], path: "Tests/AnyDocTests",
            // Binary payloads the tests feed to parsers directly.
            resources: [.copy("Resources")]),
    ]
)
