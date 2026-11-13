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
            dependencies: ["BCModel", "BCStore", "BCTransport"]
        ),
        .testTarget(
            name: "BCStreamingTests",
            dependencies: ["BCStreaming", "BCModel", "BCStore", "BCTransport"]
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
    ],
    swiftLanguageModes: [.v6]
)
