import CoreFoundation
import Darwin
import Foundation

/// An opaque MobileDevice object (`AMDeviceRef`, `AMDServiceConnectionRef`), stored as its
/// address so it can cross concurrency domains. Lifetime is managed explicitly with the
/// framework's retain/release calls by whoever holds it.
struct OpaqueRef: Sendable, Hashable {
    let bits: UInt

    init(_ pointer: UnsafeMutableRawPointer) { bits = UInt(bitPattern: pointer) }

    var pointer: UnsafeMutableRawPointer { UnsafeMutableRawPointer(bitPattern: bits)! }
}

/// The functions of Apple's private MobileDevice.framework that BetterConsole uses, resolved at
/// runtime with `dlopen`/`dlsym` (no link-time dependency). This module is the only place
/// MobileDevice symbols are referenced.
///
/// Sendable: every stored property is an immutable C function pointer resolved once in
/// `init`; the framework's functions themselves are callable from any thread.
final class MobileDeviceAPI: Sendable {
    static let frameworkPath = "/Library/Apple/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice"

    typealias Raw = UnsafeMutableRawPointer
    typealias NotificationCallback = @convention(c) (Raw?, Raw?) -> Void
    typealias SubscribeFn = @convention(c) (NotificationCallback, UInt32, UInt32, Raw?, UnsafeMutablePointer<Raw?>, UnsafeRawPointer?) -> Int32
    typealias DeviceIntFn = @convention(c) (Raw) -> Int32
    typealias DeviceCopyFn = @convention(c) (Raw) -> UnsafeRawPointer?
    typealias DeviceVoidFn = @convention(c) (Raw) -> Void
    typealias CopyValueFn = @convention(c) (Raw, UnsafeRawPointer?, UnsafeRawPointer?) -> UnsafeRawPointer?
    typealias StartServiceFn = @convention(c) (Raw, UnsafeRawPointer, UnsafeRawPointer?, UnsafeMutablePointer<Raw?>) -> Int32
    typealias SendMessageFn = @convention(c) (Raw, UnsafeRawPointer, Int) -> Int32
    typealias ReceiveFn = @convention(c) (Raw, Raw, Int) -> Int
    typealias ConnectionIntFn = @convention(c) (Raw) -> Int32
    typealias ErrorTextFn = @convention(c) (Int32) -> UnsafeRawPointer?

    let notificationSubscribeWithOptions: SubscribeFn
    let deviceRetain: DeviceCopyFn
    let deviceRelease: DeviceVoidFn
    let deviceCopyDeviceIdentifier: DeviceCopyFn
    let deviceGetInterfaceType: DeviceIntFn
    let deviceConnect: DeviceIntFn
    let deviceDisconnect: DeviceIntFn
    let deviceIsPaired: DeviceIntFn
    let deviceValidatePairing: DeviceIntFn
    let deviceStartSession: DeviceIntFn
    let deviceStopSession: DeviceIntFn
    let deviceCopyValue: CopyValueFn
    let deviceSecureStartService: StartServiceFn
    let serviceConnectionSendMessage: SendMessageFn
    let serviceConnectionReceive: ReceiveFn
    let serviceConnectionGetSocket: ConnectionIntFn
    let serviceConnectionInvalidate: ConnectionIntFn
    let copyErrorText: ErrorTextFn?

    /// The process-wide instance, or nil if the framework or a required symbol is missing.
    static func load() -> MobileDeviceAPI? { shared }

    private static let shared: MobileDeviceAPI? = MobileDeviceAPI()

    private init?() {
        // The handle is never closed: the framework stays loaded for the process lifetime.
        guard let handle = dlopen(Self.frameworkPath, RTLD_NOW) else { return nil }
        func resolve<T>(_ name: String, as _: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard
            let subscribe = resolve("AMDeviceNotificationSubscribeWithOptions", as: SubscribeFn.self),
            let retain = resolve("AMDeviceRetain", as: DeviceCopyFn.self),
            let release = resolve("AMDeviceRelease", as: DeviceVoidFn.self),
            let copyIdentifier = resolve("AMDeviceCopyDeviceIdentifier", as: DeviceCopyFn.self),
            let interfaceType = resolve("AMDeviceGetInterfaceType", as: DeviceIntFn.self),
            let connect = resolve("AMDeviceConnect", as: DeviceIntFn.self),
            let disconnect = resolve("AMDeviceDisconnect", as: DeviceIntFn.self),
            let isPaired = resolve("AMDeviceIsPaired", as: DeviceIntFn.self),
            let validatePairing = resolve("AMDeviceValidatePairing", as: DeviceIntFn.self),
            let startSession = resolve("AMDeviceStartSession", as: DeviceIntFn.self),
            let stopSession = resolve("AMDeviceStopSession", as: DeviceIntFn.self),
            let copyValue = resolve("AMDeviceCopyValue", as: CopyValueFn.self),
            let startService = resolve("AMDeviceSecureStartService", as: StartServiceFn.self),
            let sendMessage = resolve("AMDServiceConnectionSendMessage", as: SendMessageFn.self),
            let receive = resolve("AMDServiceConnectionReceive", as: ReceiveFn.self),
            let getSocket = resolve("AMDServiceConnectionGetSocket", as: ConnectionIntFn.self),
            let invalidate = resolve("AMDServiceConnectionInvalidate", as: ConnectionIntFn.self)
        else { return nil }
        notificationSubscribeWithOptions = subscribe
        deviceRetain = retain
        deviceRelease = release
        deviceCopyDeviceIdentifier = copyIdentifier
        deviceGetInterfaceType = interfaceType
        deviceConnect = connect
        deviceDisconnect = disconnect
        deviceIsPaired = isPaired
        deviceValidatePairing = validatePairing
        deviceStartSession = startSession
        deviceStopSession = stopSession
        deviceCopyValue = copyValue
        deviceSecureStartService = startService
        serviceConnectionSendMessage = sendMessage
        serviceConnectionReceive = receive
        serviceConnectionGetSocket = getSocket
        serviceConnectionInvalidate = invalidate
        copyErrorText = resolve("AMDCopyErrorText", as: ErrorTextFn.self)
    }

    // MARK: Helpers

    /// Takes ownership of a +1 CF object returned by a Copy function.
    static func takeCF<T: AnyObject>(_ pointer: UnsafeRawPointer?) -> T? {
        guard let pointer else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeRetainedValue() as? T
    }

    /// Calls `body` with an unretained pointer to `object`, keeping it alive for the call.
    /// (A bridged temporary passed as a raw pointer is otherwise freed before the call.)
    static func withPointer<R>(to object: AnyObject, _ body: (UnsafeRawPointer) -> R) -> R {
        withExtendedLifetime(object) { body(UnsafeRawPointer(Unmanaged.passUnretained(object).toOpaque())) }
    }

    func errorText(_ code: Int32) -> String? {
        guard let copyErrorText, let text: CFString = Self.takeCF(copyErrorText(code)) else { return nil }
        return text as String
    }

    func identifier(of device: Raw) -> String? {
        let id: CFString? = Self.takeCF(deviceCopyDeviceIdentifier(device))
        return id.map { $0 as String }
    }

    func interface(of device: Raw) -> DeviceInterface {
        DeviceInterface(rawValue: deviceGetInterfaceType(device)) ?? .other
    }

    /// `AMDeviceCopyValue` for a string key in the default domain. Requires a connection.
    func copyStringValue(_ device: Raw, key: String) -> String? {
        let keyCF = key as CFString
        let value: CFString? = Self.withPointer(to: keyCF) { Self.takeCF(deviceCopyValue(device, nil, $0)) }
        return value.map { $0 as String }
    }

    /// Throws `MobileDeviceError.callFailed` for a non-zero result.
    func check(_ function: String, _ code: Int32) throws {
        guard code != 0 else { return }
        throw MobileDeviceError.callFailed(function: function, code: code, text: errorText(code))
    }
}

/// `AMDeviceGetInterfaceType` values.
enum DeviceInterface: Int32, Sendable {
    case usb = 1
    case network = 2
    case other = -1
}

public enum MobileDeviceError: Error, Equatable, CustomStringConvertible {
    case frameworkUnavailable
    case deviceNotConnected
    case notPaired
    case callFailed(function: String, code: Int32, text: String?)
    case badStatusReply(String)
    case connectionClosed
    case receiveFailed(String)
    /// Opening a Wi-Fi connection failed for good and the Local Network check was refused
    /// (access off, or the prompt not answered yet).
    case localNetworkDenied
    /// A silent Wi-Fi connection to a device no longer reported on the network.
    case networkConnectionLost

    public var description: String {
        switch self {
        case .frameworkUnavailable:
            "MobileDevice.framework is not available on this Mac."
        case .deviceNotConnected:
            "The device is not connected."
        case .notPaired:
            "This device isn't paired with this Mac. Connect it in Finder and tap Trust on the device, then retry."
        case .callFailed(let function, let code, let text):
            "\(function) failed: \(text ?? "error") (0x\(String(UInt32(bitPattern: code), radix: 16)))."
        case .badStatusReply(let status):
            "The device refused the log stream (\(status))."
        case .connectionClosed:
            "The connection to the device was closed."
        case .receiveFailed(let reason):
            "Reading from the device failed: \(reason)."
        case .localNetworkDenied:
            "Couldn't connect over Wi-Fi: Local Network access looks off for BetterConsole. Allow it when macOS asks, or in System Settings ▸ Privacy & Security ▸ Local Network, then retry."
        case .networkConnectionLost:
            "The device is no longer reachable over Wi-Fi."
        }
    }
}
