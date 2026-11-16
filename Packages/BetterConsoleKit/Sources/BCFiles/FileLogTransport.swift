import Foundation
import Synchronization
import BCModel
import BCTransport

/// Reads one log file into a session: chunks are read and parsed off the main actor as the
/// session asks for batches (so a session waiting for room holds the reading back), and the
/// stream ends once the file is read.
public final class FileLogTransport: LogTransport, Sendable {
    public let url: URL
    public let device: LogDevice
    private let chunkSize: Int
    private let read = Progress()

    /// `chunkSize`: bytes read at a time (each chunk's complete lines make one batch).
    public init(url: URL, chunkSize: Int = 1 << 20) {
        self.url = url
        self.device = Self.device(for: url)
        self.chunkSize = max(1, chunkSize)
    }

    /// The synthetic device of a file: id `file:<absolute path>` with symbolic links resolved
    /// (so `/var/…` and `/private/var/…`, or a link and its file, are one file), named after
    /// the file as opened.
    public static func device(for url: URL) -> LogDevice {
        let path = canonicalPath(url.standardizedFileURL.path)
        return LogDevice(id: "file:" + path, name: url.lastPathComponent, kind: .file)
    }

    /// `path` with every symbolic link resolved (`realpath`), as far as it exists: `/var/x`
    /// and `/private/var/x` give the same path even before `x` exists. (Foundation's
    /// `resolvingSymlinksInPath` keeps `/var` and `/private/var` apart.)
    static func canonicalPath(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != path else { return path }
        return (canonicalPath(parent) as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }

    public var isFinite: Bool { true }

    /// Share of the file read and parsed so far, 0...1.
    public var progress: Double { read.value.withLock { $0 } }

    public func supports(_ device: LogDevice) -> Bool { device.id == self.device.id }

    public func stream(from device: LogDevice) -> AsyncThrowingStream<[LogEntry], Error> {
        read.value.withLock { $0 = 0 }
        let reader = Reader(url: url, chunkSize: chunkSize, progress: read)
        return AsyncThrowingStream { try reader.next() }
    }

    private final class Progress: Sendable {
        let value = Mutex<Double>(0)
    }

    /// A file that could not be read; the banner shows `description` as is.
    public struct ReadError: Error, CustomStringConvertible, LocalizedError {
        public let description: String
        public var errorDescription: String? { description }
    }

    /// The reading state, used by one stream's iterations in turn.
    private final class Reader: Sendable {
        private struct State {
            var handle: FileHandle?
            var parser: LogFileParser
            var size: UInt64 = 0
            var offset: UInt64 = 0
            /// Bytes after the last line break read so far.
            var partial = Data()
            var opened = false
            var sawLineFeed = false
            var done = false
        }

        private let url: URL
        private let chunkSize: Int
        private let progress: Progress
        private let state: Mutex<State>

        init(url: URL, chunkSize: Int, progress: Progress) {
            self.url = url
            self.chunkSize = chunkSize
            self.progress = progress
            state = Mutex(State(parser: LogFileParser(fileName: url.lastPathComponent)))
        }

        /// The next non-empty batch, or nil once the file is read.
        func next() throws -> [LogEntry]? {
            try state.withLock { s in
                if s.done { return nil }
                if !s.opened { try open(&s) }
                while true {
                    let chunk: Data
                    do {
                        chunk = try s.handle?.read(upToCount: chunkSize) ?? Data()
                    } catch {
                        s.done = true
                        try? s.handle?.close()
                        throw ReadError(
                            description: "Couldn't read “\(url.lastPathComponent)”: \(error.localizedDescription)")
                    }
                    if chunk.isEmpty {
                        s.done = true
                        try? s.handle?.close()
                        s.handle = nil
                        var entries = s.partial.isEmpty ? [] : feed(s.partial, into: &s.parser)
                        s.partial = Data()
                        entries += s.parser.finish()
                        report(1)
                        return entries.isEmpty ? nil : entries
                    }
                    s.offset += UInt64(chunk.count)
                    var entries: [LogEntry] = []
                    // Lines end at LF; in a file with no LF so far, at a bare CR.
                    if !s.sawLineFeed, chunk.contains(0x0A) { s.sawLineFeed = true }
                    if let lastBreak = chunk.lastIndex(of: s.sawLineFeed ? 0x0A : 0x0D) {
                        var lines = s.partial
                        lines.append(chunk[chunk.startIndex...lastBreak])
                        s.partial = Data(chunk[(lastBreak + 1)...])
                        entries = feed(lines, into: &s.parser)
                    } else {
                        s.partial.append(chunk)
                    }
                    if s.size > 0 { report(min(0.999, Double(s.offset) / Double(s.size))) }
                    if !entries.isEmpty { return entries }
                }
            }
        }

        private func open(_ s: inout State) throws {
            s.opened = true
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                s.size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                let modified = attributes[.modificationDate] as? Date ?? .now
                s.parser = LogFileParser(fileName: url.lastPathComponent, modificationDate: modified)
                s.handle = try FileHandle(forReadingFrom: url)
            } catch {
                s.done = true
                throw ReadError(description: Self.message(for: error, url: url))
            }
        }

        private func feed(_ data: Data, into parser: inout LogFileParser) -> [LogEntry] {
            data.withUnsafeBytes { raw in parser.feed(raw.bindMemory(to: UInt8.self)) }
        }

        private func report(_ value: Double) { progress.value.withLock { $0 = value } }

        static func message(for error: Error, url: URL) -> String {
            let name = url.lastPathComponent
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
                nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError
            {
                return "“\(name)” couldn't be opened because it no longer exists."
            }
            if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError {
                return "“\(name)” couldn't be opened because you don't have permission to read it."
            }
            return "Couldn't read “\(name)”: \(error.localizedDescription)"
        }
    }
}
