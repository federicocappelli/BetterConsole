import BCModel
import Foundation

/// Decodes the entry frames of Apple's `com.apple.os_trace_relay` service (after the
/// `StartActivity` status reply) into `LogEntry` values. Bytes may arrive split at any point;
/// incomplete frames wait for more input.
///
/// Wire format (all integers little-endian), from the Task 0 spike:
/// frame = tag `0x02`, u32 payload length L, then L payload bytes. Payload offsets:
/// 1 flavor (u32, 8 or 2), 5 header length (u32, 129), 9 pid (u32), 21 process UUID (16),
/// 55 seconds (u64), 63 microseconds (u32), 67 label flag (u8), 68 level (u8),
/// 75 continuous time (u64), 83 thread id (u64), 91 sender UUID (16), 107 image size (u16),
/// 109 message size (u16), 117 subsystem size (u32), 121 category size (u32); then from the
/// header length: process path (NUL-terminated), image path, message, subsystem, category.
/// Subsystem and category sizes are only valid for flavor 8 with label flag 4: flavor 2
/// frames (~1.5% of info entries) hold garbage there.
///
/// Robustness: every size is bounds-checked against the payload. A frame whose outer length
/// is sane is always consumed whole, so a bad frame never desyncs the stream: bad inner
/// fields are dropped and a frame too short to hold the fixed header is skipped. An
/// unexpected tag or an insane outer length means the stream itself is broken: `error` is
/// set and all further input is ignored (the transport then fails).
public struct OSTraceDecoder {
    public enum DecodeError: Error, Equatable, CustomStringConvertible {
        case unexpectedTag(UInt8)
        case frameTooLarge(Int)

        public var description: String {
            switch self {
            case .unexpectedTag(let tag):
                "The device log stream is corrupt (unexpected frame tag 0x\(String(tag, radix: 16)))."
            case .frameTooLarge(let length):
                "The device log stream is corrupt (frame length \(length) bytes)."
            }
        }
    }

    static let frameTag: UInt8 = 0x02
    static let frameHeaderSize = 5
    /// Fixed payload header size observed on the wire (the header-length field's value).
    static let minimumHeaderLength = 129
    /// Real frames are a few hundred bytes; message and image sizes are u16. Anything larger
    /// than this is a corrupt length.
    static let maximumPayloadLength = 1 << 20

    /// The stream-level failure, if any. Once set, `feed` returns nothing.
    public private(set) var error: DecodeError?
    /// Frames consumed without producing an entry (payload too short or header length invalid).
    public private(set) var skippedFrames = 0

    private var buffer: [UInt8] = []
    private var start = 0
    private var nextID: UInt64 = 1

    public init() {}

    /// Appends `bytes` and returns the entries of every frame now complete.
    public mutating func feed(_ bytes: Data) -> [LogEntry] {
        guard error == nil else { return [] }
        buffer.append(contentsOf: bytes)
        var entries: [LogEntry] = []
        while buffer.count - start >= Self.frameHeaderSize {
            let tag = buffer[start]
            guard tag == Self.frameTag else {
                fail(.unexpectedTag(tag))
                return entries
            }
            let length = Int(Self.u32(buffer, start + 1))
            guard length <= Self.maximumPayloadLength else {
                fail(.frameTooLarge(length))
                return entries
            }
            let payloadStart = start + Self.frameHeaderSize
            guard buffer.count - payloadStart >= length else { break }
            let entry = buffer.withUnsafeBufferPointer { all in
                decodePayload(UnsafeBufferPointer(rebasing: all[payloadStart..<(payloadStart + length)]))
            }
            if let entry { entries.append(entry) } else { skippedFrames += 1 }
            start = payloadStart + length
        }
        compact()
        return entries
    }

    private mutating func fail(_ error: DecodeError) {
        self.error = error
        buffer = []
        start = 0
    }

    /// Drops consumed bytes once they make up most of the buffer (amortised O(1) per byte).
    private mutating func compact() {
        if start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            start = 0
        } else if start > 64 * 1024, start * 2 > buffer.count {
            buffer.removeSubrange(0..<start)
            start = 0
        }
    }

    // MARK: Payload

    private mutating func decodePayload(_ p: UnsafeBufferPointer<UInt8>) -> LogEntry? {
        let minimum = Self.minimumHeaderLength
        guard p.count >= minimum else { return nil }
        let headerLength = Int(Self.u32(p, 5))
        guard headerLength >= minimum, headerLength <= p.count else { return nil }

        let flavor = Self.u32(p, 1)
        let pid = Self.u32(p, 9)
        let seconds = Self.u64(p, 55)
        let microseconds = Self.u32(p, 63)
        let labelFlag = p[67]
        let levelByte = p[68]
        let continuousTime = Self.u64(p, 75)
        let threadID = Self.u64(p, 83)
        let imageSize = Int(Self.u16(p, 107))
        let messageSize = Int(Self.u16(p, 109))
        let labelsValid = flavor == 8 && labelFlag == 4

        var cursor = headerLength
        let processPath = Self.cString(p, from: cursor, upTo: p.count)
        cursor = min(p.count, cursor + Self.terminatedLength(p, from: cursor))
        let image = Self.field(p, &cursor, size: imageSize)
        let message = Self.field(p, &cursor, size: messageSize)
        var subsystem: String?
        var category: String?
        if labelsValid {
            // u32 sizes: compare as Int (64-bit), so garbage cannot overflow the cursor.
            subsystem = Self.field(p, &cursor, size: Int(Self.u32(p, 117)))
            category = Self.field(p, &cursor, size: Int(Self.u32(p, 121)))
        }

        let date = Date(timeIntervalSince1970: Double(seconds) + Double(min(microseconds, 999_999)) / 1_000_000)
        let entry = LogEntry(
            id: nextID,
            date: date,
            level: Self.level(levelByte),
            eventType: "logEvent",
            process: processPath.map { String($0.split(separator: "/").last ?? "") } ?? "",
            processImagePath: processPath,
            pid: Int32(exactly: pid),
            threadID: threadID,
            subsystem: subsystem,
            category: category,
            message: message ?? "",
            senderImagePath: image,
            extra: [
                "flavor": .number(Double(flavor)),
                "levelByte": .number(Double(levelByte)),
                // u64: kept as a string so no precision is lost in a Double.
                "continuousTime": .string(String(continuousTime)),
                "processUUID": .string(Self.uuid(p, 21)),
                "senderUUID": .string(Self.uuid(p, 91)),
            ]
        )
        nextID += 1
        return entry
    }

    /// Maps the wire level byte; unknown values (including 0x03 "user action") become default.
    static func level(_ byte: UInt8) -> LogLevel {
        switch byte {
        case 0x01: .info
        case 0x02: .debug
        case 0x10: .error
        case 0x11: .fault
        default: .default
        }
    }

    // MARK: Byte helpers

    /// Reads a sized, NUL-terminated string at `cursor` and advances it. A size that runs past
    /// the payload invalidates this and every later field (nil), leaving the cursor at the end.
    private static func field(_ p: UnsafeBufferPointer<UInt8>, _ cursor: inout Int, size: Int) -> String? {
        guard size > 0 else { return nil }
        guard size <= p.count - cursor else {
            cursor = p.count
            return nil
        }
        defer { cursor += size }
        return cString(p, from: cursor, upTo: cursor + size)
    }

    /// Bytes up to the first NUL (or `end`), decoded as UTF-8 with repair. Empty becomes nil.
    private static func cString(_ p: UnsafeBufferPointer<UInt8>, from: Int, upTo end: Int) -> String? {
        guard from < end else { return nil }
        let slice = UnsafeBufferPointer(rebasing: p[from..<end])
        let length = slice.firstIndex(of: 0) ?? slice.count
        guard length > 0 else { return nil }
        return String(decoding: UnsafeBufferPointer(rebasing: slice[0..<length]), as: UTF8.self)
    }

    /// Length of the NUL-terminated string at `from`, including the NUL if present.
    private static func terminatedLength(_ p: UnsafeBufferPointer<UInt8>, from: Int) -> Int {
        guard from < p.count else { return 0 }
        let slice = UnsafeBufferPointer(rebasing: p[from...])
        return slice.firstIndex(of: 0).map { $0 + 1 } ?? slice.count
    }

    private static func uuid(_ p: UnsafeBufferPointer<UInt8>, _ o: Int) -> String {
        let b = Array(p[o..<(o + 16)])
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])).uuidString
    }

    static func u16<C: RandomAccessCollection>(_ b: C, _ o: Int) -> UInt16 where C.Element == UInt8, C.Index == Int {
        UInt16(b[o]) | UInt16(b[o + 1]) << 8
    }

    static func u32<C: RandomAccessCollection>(_ b: C, _ o: Int) -> UInt32 where C.Element == UInt8, C.Index == Int {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }

    static func u64<C: RandomAccessCollection>(_ b: C, _ o: Int) -> UInt64 where C.Element == UInt8, C.Index == Int {
        UInt64(u32(b, o)) | UInt64(u32(b, o + 4)) << 32
    }
}
