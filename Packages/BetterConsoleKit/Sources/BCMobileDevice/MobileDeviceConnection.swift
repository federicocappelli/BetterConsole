import CoreFoundation
import Darwin
import Foundation

/// Opens `com.apple.os_trace_relay` on a device over USB or the network (Wi-Fi sync), using
/// the call sequence proven by the Task 0 spike (the same for both interfaces): connect,
/// validate pairing, start session, secure-start the service, stop the session, send
/// `StartActivity`. Over Wi-Fi this process talks to the device itself (measured: the service
/// socket is TCP over IPv6 link-local on en0, not a usbmuxd UNIX socket), so macOS Local
/// Network privacy applies; a final failed Wi-Fi open is explained as `localNetworkDenied`
/// when the access check says it is off.
struct MobileDeviceConnector: OSTraceConnector {
    static let serviceName = "com.apple.os_trace_relay"
    /// `kCFPropertyListBinaryFormat_v1_0`.
    static let binaryPlistFormat = 200
    /// Reads return at least this often, so a lost peer is noticed even without data.
    static let readTimeoutSeconds = 1

    let monitor: MobileDeviceMonitor
    var localNetworkDenied: @Sendable () -> Bool = { LocalNetworkAccess.isDenied() }

    init(monitor: MobileDeviceMonitor) {
        self.monitor = monitor
    }

    func interfaces(of deviceID: String) -> Set<DeviceInterface> {
        monitor.interfaces(of: deviceID)
    }

    func explain(_ error: any Error, openingOver interface: DeviceInterface) -> any Error {
        guard interface == .network else { return error }
        return LocalNetworkAccess.explain(error, isDenied: localNetworkDenied)
    }

    func open(deviceID: String, over interface: DeviceInterface) throws -> any OSTraceConnection {
        let api = monitor.api
        guard let deviceRef = monitor.retainedDevice(udid: deviceID, interface: interface) else {
            throw MobileDeviceError.deviceNotConnected
        }
        let device = deviceRef.pointer
        var connected = false
        var handedOver = false  // once the connection exists, it owns the device
        do {
            try api.check("AMDeviceConnect", api.deviceConnect(device))
            connected = true
            guard api.deviceIsPaired(device) == 1 else { throw MobileDeviceError.notPaired }
            try api.check("AMDeviceValidatePairing", api.deviceValidatePairing(device))
            try api.check("AMDeviceStartSession", api.deviceStartSession(device))
            var connectionPointer: UnsafeMutableRawPointer?
            let name = Self.serviceName as CFString
            let started = MobileDeviceAPI.withPointer(to: name) {
                api.deviceSecureStartService(device, $0, nil, &connectionPointer)
            }
            // The session is only needed to start the service.
            _ = api.deviceStopSession(device)
            try api.check("AMDeviceSecureStartService", started)
            guard let connectionPointer else {
                throw MobileDeviceError.callFailed(function: "AMDeviceSecureStartService", code: -1, text: "no connection")
            }
            let connection = MobileDeviceConnection(
                api: api, device: deviceRef, connection: OpaqueRef(connectionPointer), interface: interface)
            handedOver = true
            do {
                try connection.start()
            } catch {
                connection.close()  // releases the device too
                throw error
            }
            // The device answers now: a name still missing (Wi-Fi reads that failed) is read.
            monitor.streamOpened(udid: deviceID, over: interface)
            return connection
        } catch {
            if !handedOver {
                if connected { _ = api.deviceDisconnect(device) }
                api.deviceRelease(device)
            }
            throw error
        }
    }
}

/// A live service connection. Holds a +1 on the device and the connection until `close`.
///
/// Sendable: all stored properties are immutable values. Thread use follows the
/// `OSTraceConnection` contract (enforced by `OSTraceStreamSession`'s lock): `interrupt` only
/// calls `shutdown(2)` on the socket, which is safe concurrently with a blocked read, and is
/// never called once `close` has started, so the descriptor cannot have been reused.
final class MobileDeviceConnection: OSTraceConnection {
    private let api: MobileDeviceAPI
    private let device: OpaqueRef
    private let connection: OpaqueRef
    private let socket: Int32
    private let interface: DeviceInterface

    init(api: MobileDeviceAPI, device: OpaqueRef, connection: OpaqueRef, interface: DeviceInterface) {
        self.api = api
        self.device = device
        self.connection = connection
        self.interface = interface
        self.socket = api.serviceConnectionGetSocket(connection.pointer)
    }

    /// TCP keep-alive on a Wi-Fi connection: a dead link makes the read fail after about
    /// 3 s idle + 5 unanswered 1 s probes, instead of the stream waiting silently. Best
    /// effort: ignored if the socket is not TCP.
    private static let keepAliveIdle: Int32 = 3
    private static let keepAliveInterval: Int32 = 1
    private static let keepAliveCount: Int32 = 5

    /// Sets the read timeout (and keep-alive over Wi-Fi) and sends the `StartActivity` request.
    func start() throws {
        var timeout = timeval(tv_sec: MobileDeviceConnector.readTimeoutSeconds, tv_usec: 0)
        _ = setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        if interface == .network {
            func set(_ level: Int32, _ option: Int32, _ value: Int32) {
                var value = value
                _ = setsockopt(socket, level, option, &value, socklen_t(MemoryLayout<Int32>.size))
            }
            set(SOL_SOCKET, SO_KEEPALIVE, 1)
            set(IPPROTO_TCP, TCP_KEEPALIVE, Self.keepAliveIdle)
            set(IPPROTO_TCP, TCP_KEEPINTVL, Self.keepAliveInterval)
            set(IPPROTO_TCP, TCP_KEEPCNT, Self.keepAliveCount)
        }
        let request = [
            "Request": "StartActivity",
            "MessageFilter": 65535,  // every level, including debug
            "Pid": -1,               // every process
            "StreamFlags": 60,
        ] as [String: Any] as CFDictionary
        let result = MobileDeviceAPI.withPointer(to: request) {
            api.serviceConnectionSendMessage(connection.pointer, $0, MobileDeviceConnector.binaryPlistFormat)
        }
        try api.check("AMDServiceConnectionSendMessage", result)
    }

    func receive(into buffer: UnsafeMutableRawBufferPointer) -> ReceiveResult {
        let clock = ContinuousClock()
        let start = clock.now
        return Self.receive(
            timeout: .seconds(MobileDeviceConnector.readTimeoutSeconds),
            now: { clock.now - start },
            read: {
                errno = 0
                let count = api.serviceConnectionReceive(connection.pointer, buffer.baseAddress!, buffer.count)
                return (count, errno)
            },
            sleep: { Thread.sleep(forTimeInterval: Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18) })
    }

    /// Interprets one raw read. `now` is the time since the read started. A "would block" that
    /// came back before the read timeout (a socket that is non-blocking, or a TLS layer that
    /// returns early) waits out the rest of it, so the reader thread never spins.
    static func receive(
        timeout: Duration, now: () -> Duration, read: () -> (count: Int, errno: Int32), sleep: (Duration) -> Void
    ) -> ReceiveResult {
        let (count, error) = read()
        if count > 0 { return .bytes(count) }
        if count == 0 { return .closed }
        let elapsed = now()
        switch error {
        case EAGAIN, EWOULDBLOCK, EINTR:
            if elapsed < timeout { sleep(timeout - elapsed) }
            return .timedOut
        case 0:
            // The TLS layer can fail without setting errno. A call that waited out the read
            // timeout is a timeout; one that failed at once is a dead connection (never spin).
            return elapsed >= .milliseconds(500) ? .timedOut : .failed("connection lost")
        default:
            return .failed(String(cString: strerror(error)))
        }
    }

    func interrupt() {
        _ = shutdown(socket, SHUT_RDWR)
    }

    func close() {
        _ = api.serviceConnectionInvalidate(connection.pointer)
        Unmanaged<AnyObject>.fromOpaque(connection.pointer).release()
        _ = api.deviceDisconnect(device.pointer)
        api.deviceRelease(device.pointer)
    }
}
