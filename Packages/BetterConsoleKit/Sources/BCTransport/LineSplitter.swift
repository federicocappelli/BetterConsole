import Foundation

/// Turns arbitrary stdout chunks into complete lines.
///
/// Holds at most one partial line between calls. Each `feed` scans only the bytes
/// appended by that call, so the cost is linear in the input. Empty lines are dropped.
///
/// With `maxLineLength`, a partial line that grows past the limit without a newline is
/// discarded, along with the rest of that line up to its newline, so a misbehaving
/// producer cannot grow memory without bound.
public struct LineSplitter: Sendable {
    private static let newline: UInt8 = 0x0A

    /// Bytes after the last newline seen so far.
    private var buffer = Data()
    private let maxLineLength: Int?
    /// True after an overlong partial was discarded, until the newline that ends it.
    private var discarding = false

    public init(maxLineLength: Int? = nil) {
        self.maxLineLength = maxLineLength
    }

    /// Appends `chunk` and returns every line it completes, without the trailing `\n`.
    public mutating func feed(_ chunk: Data) -> [Data] {
        guard !chunk.isEmpty else { return [] }
        let scanFrom = buffer.count
        buffer.append(chunk)

        var lines: [Data] = []
        var lineStart = 0
        var discard = discarding
        buffer.withUnsafeBytes { raw in
            var index = scanFrom
            while index < raw.count {
                if raw[index] == Self.newline {
                    if discard {
                        discard = false
                    } else if index > lineStart {
                        lines.append(Data(raw[lineStart..<index]))
                    }
                    lineStart = index + 1
                }
                index += 1
            }
        }
        discarding = discard
        if lineStart > 0 {
            // Copy the partial line into fresh storage. `removeFirst` would only re-slice, and
            // the storage would keep every byte ever fed.
            buffer = lineStart < buffer.count ? Data(buffer.dropFirst(lineStart)) : Data()
        }
        if let maxLineLength, buffer.count > maxLineLength {
            buffer = Data()
            discarding = true
        }
        return lines
    }

    /// Where the buffered bytes start in the buffer's storage; 0 unless consumed bytes are
    /// still held (for tests).
    var bufferStorageOffset: Int { buffer.startIndex }

    /// Returns the buffered partial line, if any, and clears the buffer.
    public mutating func finish() -> Data? {
        discarding = false
        guard !buffer.isEmpty else { return nil }
        let rest = buffer
        buffer = Data()
        return rest
    }
}
