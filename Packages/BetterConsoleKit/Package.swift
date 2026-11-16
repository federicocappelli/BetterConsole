// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BetterConsoleKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "BCModel", targets: ["BCModel"]),
        .library(name: "BCTransport", targets: ["BCTransport"]),
        .library(name: "BCStore", targets: ["BCStore"]),
        .library(name: "BCStreaming", targets: ["BCStreaming"]),
        .library(name: "BCMobileDevice", targets: ["BCMobileDevice"]),
        .library(name: "BCFilter", targets: ["BCFilter"]),
        .library(name: "BCFiles", targets: ["BCFiles"]),
    ],
    targets: [
        .target(name: "BCModel"),
        .testTarget(
            name: "BCModelTests",
            dependencies: ["BCModel"],
            resources: [.copy("Fixtures")]
        ),
        .target(
            name: "BCTransport",
            dependencies: ["BCModel"]
        ),
        .testTarget(
            name: "BCTransportTests",
            dependencies: ["BCTransport"],
            resources: [.copy("Fixtures")]
        ),
        .target(
            name: "BCStore",
            dependencies: ["BCModel"]
        ),
        .testTarget(
            name: "BCStoreTests",
            dependencies: ["BCStore", "BCModel"]
        ),
        .target(
            name: "BCStreaming",
            dependencies: ["BCModel", "BCStore", "BCTransport", "BCFilter"]
        ),
        .testTarget(
            name: "BCStreamingTests",
            dependencies: ["BCStreaming", "BCModel", "BCStore", "BCTransport", "BCFilter"]
        ),
        // The only module that touches Apple's private MobileDevice.framework (dlopen'd at
        // runtime, never linked), so the physical-device transport can be swapped out.
        .target(
            name: "BCMobileDevice",
            dependencies: ["BCModel", "BCTransport"]
        ),
        .testTarget(
            name: "BCMobileDeviceTests",
            dependencies: ["BCMobileDevice", "BCModel", "BCTransport"],
            resources: [.copy("Fixtures")]
        ),
        .target(
            name: "BCFilter",
            dependencies: ["BCModel"]
        ),
        .testTarget(
            name: "BCFilterTests",
            dependencies: ["BCFilter", "BCModel"]
        ),
        // Log files: the BetterConsole .log format (Save Logs) and a best-effort parser for
        // other text logs, plus the transport that reads a file into a session.
        .target(
            name: "BCFiles",
            dependencies: ["BCModel", "BCTransport"]
        ),
        .testTarget(
            name: "BCFilesTests",
            dependencies: ["BCFiles", "BCModel", "BCTransport"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
