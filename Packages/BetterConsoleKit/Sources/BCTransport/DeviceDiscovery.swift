import BCModel

/// Publishes the current set of devices whenever it changes.
public protocol DeviceDiscovery: Sendable {
    func devices() -> AsyncStream<[LogDevice]>
}
