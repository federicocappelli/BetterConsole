import Foundation
import Testing
import BCModel
import BCTransport
@testable import BCFiles

@Suite struct FileLogTransportTests {
    static func tempFile(_ text: String, name: String = "sample.log") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func deviceForAFile() {
        let url = URL(fileURLWithPath: "/tmp/dir/My App.log")
        let device = FileLogTransport.device(for: url)
        #expect(device.id == "file:/private/tmp/dir/My App.log")  // /tmp is a link
        #expect(device.name == "My App.log")
        #expect(device.kind == .file)
        let transport = FileLogTransport(url: url)
        #expect(transport.isFinite)
        #expect(transport.supports(device))
        #expect(!transport.supports(LogDevice(id: "local", name: "Mac", kind: .thisMac)))
    }

    @Test func readsEveryEntryThenEnds() async throws {
        var text = ""
        for i in 0..<5_000 { text += "2026-11-16T10:00:00Z INFO p[1]: message \(i)\n" }
        text += "  continuation of the last"  // no final line break
        let url = try Self.tempFile(text)
        let transport = FileLogTransport(url: url, chunkSize: 4_096)
        var entries: [LogEntry] = []
        var batches = 0
        for try await batch in transport.stream(from: transport.device) {
            entries += batch
            batches += 1
        }
        #expect(batches > 1)
        #expect(entries.count == 5_000)
        #expect(entries.first?.message == "message 0")
        #expect(entries.last?.message == "message 4999\n  continuation of the last")
        #expect(entries.first?.level == .info)
        #expect(transport.progress == 1)
    }

    /// The file is read as the consumer asks for batches, not all at once.
    @Test func readsLazily() async throws {
        var text = ""
        for i in 0..<20_000 { text += "2026-11-16T10:00:00Z message \(i)\n" }
        let url = try Self.tempFile(text)
        let transport = FileLogTransport(url: url, chunkSize: 4_096)
        var iterator = transport.stream(from: transport.device).makeAsyncIterator()
        let first = try await iterator.next()
        #expect(first?.isEmpty == false)
        try await Task.sleep(for: .milliseconds(50))
        #expect(transport.progress > 0)
        #expect(transport.progress < 0.5)
    }

    @Test func savedFormatReadsBack() async throws {
        let entry = LogEntry(
            id: 1, date: Date(timeIntervalSince1970: 1_763_325_931.5), level: .fault,
            eventType: "logEvent", process: "p", pid: 3, subsystem: "s", category: "c",
            message: "a\tb\nc")
        let data = BetterConsoleLogFormat.fileData([BetterConsoleLogFormat.lines(for: [entry])])
        let url = try Self.tempFile(String(decoding: data, as: UTF8.self))
        let transport = FileLogTransport(url: url)
        var entries: [LogEntry] = []
        for try await batch in transport.stream(from: transport.device) { entries += batch }
        try #require(entries.count == 1)
        expectSameFields(entries[0], entry)
    }

    @Test func missingFileThrowsAReadableError() async throws {
        let url = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/gone.log")
        let transport = FileLogTransport(url: url)
        await #expect {
            for try await _ in transport.stream(from: transport.device) {}
        } throws: { error in
            String(describing: error).contains("gone.log")
                && !String(describing: error).contains("Domain=")
        }
    }

    @Test func emptyFileEndsWithNothing() async throws {
        let url = try Self.tempFile("")
        let transport = FileLogTransport(url: url)
        var count = 0
        for try await batch in transport.stream(from: transport.device) { count += batch.count }
        #expect(count == 0)
        #expect(transport.progress == 1)
    }
}
