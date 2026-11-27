// swift-tools-version: 6.0
import PackageDescription

// The SDK is built on the official OpenTelemetry Swift packages: the API and
// SDK from opentelemetry-swift-core, the OTLP/HTTP exporters (and on Apple
// platforms the URLSession instrumentation) from opentelemetry-swift.
var tracewayDependencies: [Target.Dependency] = [
    .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"),
    .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
    .product(name: "OpenTelemetryProtocolExporterHTTP", package: "opentelemetry-swift"),
    // Issues are encoded to OTLP protobuf when they are written to disk.
    .product(name: "SwiftProtobuf", package: "swift-protobuf"),
]

#if canImport(Darwin)
// opentelemetry-swift only declares this product when its manifest is
// evaluated on an Apple host.
tracewayDependencies.append(
    .product(name: "URLSessionInstrumentation", package: "opentelemetry-swift")
)
#endif

let package = Package(
    name: "Traceway",
    platforms: [
        .iOS(.v13),
        // For `swift test` on a Mac host; the SDK itself targets iOS.
        .macOS(.v12),
    ],
    products: [
        .library(name: "Traceway", targets: ["Traceway"]),
    ],
    dependencies: [
        .package(url: "https://github.com/open-telemetry/opentelemetry-swift-core.git", from: "2.6.0"),
        .package(url: "https://github.com/open-telemetry/opentelemetry-swift.git", from: "2.6.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.1"),
    ],
    targets: [
        .target(
            name: "Traceway",
            dependencies: tracewayDependencies,
            // The privacy manifest App Store Connect reads for the SDK: the
            // required-reason APIs it calls and the data it collects.
            resources: [.copy("PrivacyInfo.xcprivacy")],
            // `zlib` ships with the Apple SDKs; it gzips replay uploads.
            linkerSettings: [
                .linkedLibrary("z", .when(platforms: [.iOS, .macOS])),
            ]
        ),
        .testTarget(
            name: "TracewayTests",
            dependencies: ["Traceway"],
            // The shared wireframe stylesheet, byte for byte the Android
            // and Flutter SDKs' copy; `wireframeCss` must equal it. MetricKit
            // payloads as `jsonRepresentation()` gives them, for the parser.
            resources: [.copy("Resources/wireframe.css"), .copy("Resources/MetricKit")]
        ),
        // The README's snippets as an app in Swift 6 language mode writes
        // them: they must compile without `@preconcurrency`.
        .testTarget(
            name: "TracewaySwift6Tests",
            dependencies: ["Traceway"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ],
    swiftLanguageModes: [.v5]
)
