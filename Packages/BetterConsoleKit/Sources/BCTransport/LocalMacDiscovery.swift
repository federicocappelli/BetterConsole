import BCModel
import Foundation

/// Emits the local Mac once; it is always present.
public struct LocalMacDiscovery: DeviceDiscovery {
    public init() {}

    public func devices() -> AsyncStream<[LogDevice]> {
        let device = LogDevice(
            id: "local",
            name: Host.current().localizedName ?? "This Mac",
            kind: .thisMac,
            model: nil,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
        return AsyncStream { continuation in
            continuation.yield([device])
            continuation.finish()
        }
    }
}
