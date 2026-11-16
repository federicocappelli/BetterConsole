/// Severity of a log entry. Raw values are the `messageType` strings emitted by `log`.
public enum LogLevel: String, Sendable {
    case `default` = "Default"
    case info = "Info"
    case debug = "Debug"
    case error = "Error"
    case fault = "Fault"

    /// Maps a `messageType` string; unknown or missing values become `.default`.
    public init(messageType: String?) {
        self = messageType.flatMap(LogLevel.init(rawValue:)) ?? .default
    }

    /// `log`'s numeric `messageType` order, used by Type comparisons (ES §5.3).
    public var logOrder: Int {
        switch self {
        case .default: 0
        case .info: 1
        case .debug: 2
        case .error: 16
        case .fault: 17
        }
    }
}
