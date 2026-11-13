import CoreFoundation
import Darwin
import Foundation

/// Opens `com.apple.os_trace_relay` on a USB device using the call sequence proven by the
/// Task 0 spike: connect, validate pairing, start session, secure-start the service, stop the
/// session, send `StartActivity`.
struct MobileDeviceConnector: OSTraceConnector {
    static let serviceName = "com.apple.os_trace_relay"
    /// `kCFPropertyListBinaryFormat_v1_0`.
    static let binaryPlistFormat = 200
    /// Reads return at least this often, so a lost peer is noticed even without data.
    static let readTimeoutSeconds = 1

    let monitor: MobileDeviceMonitor

    func open(deviceID: String) throws -> any OSTraceConnection {
        let api = monitor.api
        guard let deviceRef = monitor.retainedUSBDevice(udid: deviceID) else {
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
            let connection = MobileDeviceConnection(api: api, device: deviceRef, connection: OpaqueRef(connectionPointer))
            handedOver = true
            do {
                try connection.start()
            } catch {
                connection.close()  // releases the device too
                throw error
            }
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

    init(api: MobileDeviceAPI, device: OpaqueRef, connection: OpaqueRef) {
        self.api = api
        self.device = device
        self.connection = connection
        self.socket = api.serviceConnectionGetSocket(connection.pointer)
    }

    /// Sets the read timeout and sends the `StartActivity` request.
    func start() throws {
        var timeout = timeval(tv_sec: MobileDeviceConnector.readTimeoutSeconds, tv_usec: 0)
        _ = setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
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
        let started = ContinuousClock.now
        errno = 0
        let count = api.serviceConnectionReceive(connection.pointer, buffer.baseAddress!, buffer.count)
        let error = errno
        if count > 0 { return .bytes(count) }
        if count == 0 { return .closed }
        switch error {
        case EAGAIN, EWOULDBLOCK, EINTR:
            return .timedOut
        case 0:
            // The TLS layer can fail without setting errno. A call that waited out the read
            // timeout is a timeout; one that failed at once is a dead connection (never spin).
            return ContinuousClock.now - started >= .milliseconds(500) ? .timedOut : .failed("connection lost")
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
