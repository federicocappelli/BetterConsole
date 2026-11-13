import Foundation

/// One log record. Every source field is kept: typed if known, otherwise verbatim in `extra`.
public struct LogEntry: Sendable, Identifiable {
    /// Strictly increasing per session: `StreamSession` re-stamps entries as it stores them
    /// (decoders number each stream from 1, and a session spans many streams).
    public private(set) var id: UInt64
    public let date: Date
    public let machTimestamp: UInt64?
    public let level: LogLevel
    /// `logEvent`, `activityCreateEvent`, `signpostEvent`, ...
    public let eventType: String
    /// Last path component of `processImagePath`.
    public let process: String
    public let processImagePath: String?
    public let pid: Int32?
    public let threadID: UInt64?
    public let subsystem: String?
    public let category: String?
    public let message: String
    public let formatString: String?
    public let senderImagePath: String?
    public let activityID: UInt64?
    public let parentActivityID: UInt64?
    public let traceID: UInt64?
    public let userID: UInt32?
    public let extra: [String: JSONValue]

    public init(
        id: UInt64,
        date: Date,
        machTimestamp: UInt64? = nil,
        level: LogLevel,
        eventType: String,
        process: String,
        processImagePath: String? = nil,
        pid: Int32? = nil,
        threadID: UInt64? = nil,
        subsystem: String? = nil,
        category: String? = nil,
        message: String,
        formatString: String? = nil,
        senderImagePath: String? = nil,
        activityID: UInt64? = nil,
        parentActivityID: UInt64? = nil,
        traceID: UInt64? = nil,
        userID: UInt32? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.date = date
        self.machTimestamp = machTimestamp
        self.level = level
        self.eventType = eventType
        self.process = process
        self.processImagePath = processImagePath
        self.pid = pid
        self.threadID = threadID
        self.subsystem = subsystem
        self.category = category
        self.message = message
        self.formatString = formatString
        self.senderImagePath = senderImagePath
        self.activityID = activityID
        self.parentActivityID = parentActivityID
        self.traceID = traceID
        self.userID = userID
        self.extra = extra
        self.estimatedBytes = 0
        self.estimatedBytes = computeEstimatedBytes()
    }

    /// A copy with `id` replaced; every other field is kept.
    public func withID(_ id: UInt64) -> LogEntry {
        var copy = self
        copy.id = id
        return copy
    }

    /// Replaces `id` in place (the session re-stamps entries as it stores them).
    public mutating func setID(_ id: UInt64) {
        self.id = id
    }

    /// Per-entry cost that does not depend on field lengths: the ring-buffer slot (with the
    /// buffer's spare capacity) and the string objects behind the typed fields.
    public static let fixedOverheadBytes = 800
    /// Per key, array element or nested value in `extra`: dictionary/array storage plus the
    /// bridged key and value objects. Most of an entry's footprint is here: a `log stream`
    /// line has ~17 such nodes.
    public static let extraNodeOverheadBytes = 224

    /// Approximate memory footprint, computed once in `init` (on the decoding thread, not
    /// the main actor): UTF-8 length of all strings, the serialized length of `extra`, and the
    /// overheads above.
    ///
    /// Calibrated in Task 11 against resident memory: streaming this Mac under
    /// scripts/flood.sh at ~20k msgs/s with a 0.5 GB budget, the app held ~597k entries at
    /// ~3.2 GB resident (~5,400 bytes per entry; `heap` showed three `extra` dictionaries
    /// per entry at ~1.1 KB each), while the previous estimate (160 bytes fixed, no per-node
    /// cost) gave ~900 bytes per entry, 6x too little. This formula gives ~5,350 bytes for
    /// the same entries.
    public private(set) var estimatedBytes: Int

    private func computeEstimatedBytes() -> Int {
        var total = Self.fixedOverheadBytes
        total += eventType.utf8.count + process.utf8.count + message.utf8.count
        for s in [processImagePath, subsystem, category, formatString, senderImagePath] {
            total += s?.utf8.count ?? 0
        }
        for (key, value) in extra {
            total += key.utf8.count + value.estimatedSerializedLength
        }
        total += extraNodeCount * Self.extraNodeOverheadBytes
        return total
    }

    /// Keys, array elements and nested values in `extra`, counted recursively.
    public var extraNodeCount: Int {
        extra.values.reduce(extra.count) { $0 + $1.nestedNodeCount }
    }
}
