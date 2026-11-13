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
}
