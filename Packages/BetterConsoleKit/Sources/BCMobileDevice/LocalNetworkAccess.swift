import Foundation
import Network
import Synchronization

/// Tells whether macOS seems to deny this app Local Network access, for explaining a Wi-Fi
/// connection that failed for good. There is no API to read the setting, so this browses for
/// the service Wi-Fi sync devices advertise: with access off the browse is refused with
/// `kDNSServiceErr_PolicyDenied`. That is also what an unanswered prompt looks like, so the
/// resulting message is worded as likely, not certain. Run once per failed open, after the
/// last retry (the Wi-Fi open itself has already been a Local Network action by then).
enum LocalNetworkAccess {
    /// `kDNSServiceErr_PolicyDenied`.
    static let policyDenied: DNSServiceErrorType = -65570

    /// true: refused by policy (access off, or the prompt not yet answered); false: ready
    /// (access on) or failed for another reason; nil: keep waiting.
    static func verdict(for state: NWBrowser.State) -> Bool? {
        switch state {
        case .ready:
            return false
        case .waiting(let error):
            if case .dns(let code) = error, code == policyDenied { return true }
            return nil
        case .failed(let error):
            if case .dns(let code) = error, code == policyDenied { return true }
            return false
        default:
            return nil
        }
    }

    /// Blocks until ready or refused, at most `timeout`; true only when refused by policy.
    static func isDenied(timeout: DispatchTimeInterval = .milliseconds(1500)) -> Bool {
        let browser = NWBrowser(
            for: .bonjour(type: "_apple-mobdev2._tcp", domain: "local."), using: NWParameters())
        let denied = Mutex(false)
        let done = DispatchSemaphore(value: 0)
        browser.stateUpdateHandler = { state in
            guard let verdict = verdict(for: state) else { return }
            denied.withLock { $0 = verdict }
            done.signal()
        }
        browser.start(queue: DispatchQueue(label: "BCMobileDevice.localNetworkProbe"))
        _ = done.wait(timeout: .now() + timeout)
        browser.cancel()
        return denied.withLock { $0 }
    }

    /// The error to report for a failed Wi-Fi open: `localNetworkDenied` when access is denied
    /// (asked only for failures that could be caused by it), else `error` unchanged.
    static func explain(_ error: any Error, isDenied: () -> Bool) -> any Error {
        switch error as? MobileDeviceError {
        case .notPaired, .deviceNotConnected, .frameworkUnavailable, .localNetworkDenied:
            return error
        default:
            return isDenied() ? MobileDeviceError.localNetworkDenied : error
        }
    }
}
