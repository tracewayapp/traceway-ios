// swift-tools-version: 5.9
import PackageDescription

// Fieldmart's platform-neutral code: launch settings, the seeded generator and
// tick model, fixture models and URLs, the journey file, the probe and marker
// line formats. No UIKit, so it builds and tests on Linux as well as in the
// app, the UI tests and on a Mac.
let package = Package(
    name: "FieldmartCore",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "FieldmartCore", targets: ["FieldmartCore"]),
    ],
    targets: [
        .target(name: "FieldmartCore"),
        .testTarget(name: "FieldmartCoreTests", dependencies: ["FieldmartCore"]),
    ]
)
