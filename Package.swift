// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Traceway",
    platforms: [
        .iOS(.v13),
    ],
    products: [
        .library(name: "Traceway", targets: ["Traceway"]),
    ],
    targets: [
        .target(
            name: "Traceway",
            // `zlib` is a system module shipped with the Apple SDKs, so no
            // SPM dependency is needed. The SDK module map links libz, but we
            // add the linker flag explicitly to be safe on every platform.
            linkerSettings: [
                .linkedLibrary("z"),
            ]
        ),
        .testTarget(
            name: "TracewayTests",
            dependencies: ["Traceway"]
        ),
    ]
)
