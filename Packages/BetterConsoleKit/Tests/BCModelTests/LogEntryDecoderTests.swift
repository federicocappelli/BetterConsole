import Foundation
import Testing
@testable import BCModel

@Suite struct LogEntryDecoderTests {
    private static func fixtureLines(_ name: String) throws -> [Data] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "ndjson", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        return data.split(separator: UInt8(ascii: "\n")).map { Data($0) }
    }

    private static func next(_ decoder: inout LogEntryDecoder, _ data: Data) throws -> LogEntry {
        let entry = decoder.decode(line: data)
        return try #require(entry)
    }

    private static func line(_ json: String) -> Data { Data(json.utf8) }

    private static let sample = """
    {"timestamp":"2026-11-13 15:55:22.273495+0000","messageType":"Fault","eventType":"logEvent",\
    "processImagePath":"/Users/x/.bun/bin/bun","processID":21345,"eventMessage":"hello","subsystem":"",\
    "category":"cat","threadID":99,"machTimestamp":12345,"userID":501,"activityIdentifier":7,\
    "parentActivityIdentifier":3,"traceID":42,"formatString":"hello %d","senderImagePath":"/usr/lib/x.dylib",\
    "launchPersonaName":"","backtrace":{"frames":[{"imageOffset":1}]}}
    """

    @Test func decodesAllMacFixtureLines() throws {
        var decoder = LogEntryDecoder()
        var decoded = 0
        var rejected: [String] = []
        for line in try Self.fixtureLines("mac") {
            if let entry = decoder.decode(line: line) {
                decoded += 1
                #expect(!entry.process.isEmpty || entry.processImagePath == nil)
            } else {
                rejected.append(String(decoding: line, as: UTF8.self))
            }
        }
        #expect(rejected.count == 1)
        #expect(rejected.first?.hasPrefix("Filtering the log data") == true)
        #expect(decoded > 100)
    }

    @Test func decodesAllSimulatorFixtureLines() throws {
        var decoder = LogEntryDecoder()
        var levels = Set<LogLevel>()
        for line in try Self.fixtureLines("simulator") {
            let entry = try Self.next(&decoder, line)
            levels.insert(entry.level)
        }
        #expect(levels == [.default, .info, .debug, .error, .fault])
    }

    @Test func parsesMicrosecondTimestamp() throws {
        var decoder = LogEntryDecoder()
        let entry = try Self.next(&decoder, Self.line(Self.sample))
        #expect(abs(entry.date.timeIntervalSince1970 - 1794585322.273495) < 5e-7)
    }

    @Test func roundingRecoversExactMicroseconds() throws {
        var decoder = LogEntryDecoder()
        let base: Int64 = 1_794_585_322_000_000
        let micros = Array(0...4999) + Array(995_000...999_999)
        for us in micros {
            let text = "2026-11-13 15:55:22." + String(format: "%06d", us) + "+0000"
            let entry = try Self.next(&decoder, Self.line(#"{"timestamp":"\#(text)","eventMessage":"x"}"#))
            let recovered = Int64((entry.date.timeIntervalSince1970 * 1_000_000).rounded())
            #expect(recovered == base + Int64(us), "\(text)")
        }
    }

    @Test func parsesTimestampOffset() throws {
        var decoder = LogEntryDecoder()
        let entry = try Self.next(&decoder, Self.line(
            #"{"timestamp":"2026-11-13 17:55:22.500000+0200","eventMessage":"x"}"#))
        #expect(abs(entry.date.timeIntervalSince1970 - 1794585322.5) < 1e-7)
    }

    @Test func mapsKnownFields() throws {
        var decoder = LogEntryDecoder()
        let e = try Self.next(&decoder, Self.line(Self.sample))
        #expect(e.process == "bun")
        #expect(e.processImagePath == "/Users/x/.bun/bin/bun")
        #expect(e.pid == 21345)
        #expect(e.message == "hello")
        #expect(e.level == .fault)
        #expect(e.eventType == "logEvent")
        #expect(e.category == "cat")
        #expect(e.threadID == 99)
        #expect(e.machTimestamp == 12345)
        #expect(e.userID == 501)
        #expect(e.activityID == 7)
        #expect(e.parentActivityID == 3)
        #expect(e.traceID == 42)
        #expect(e.formatString == "hello %d")
        #expect(e.senderImagePath == "/usr/lib/x.dylib")
    }

    @Test func unknownMessageTypeIsDefault() throws {
        var decoder = LogEntryDecoder()
        let e = try Self.next(&decoder, Self.line(#"{"messageType":"Weird","eventMessage":"x"}"#))
        #expect(e.level == .default)
        let missing = try Self.next(&decoder, Self.line(#"{"eventType":"activityCreateEvent"}"#))
        #expect(missing.level == .default)
        #expect(missing.message == "")
    }

    @Test func keepsUnknownFieldsInExtra() throws {
        var decoder = LogEntryDecoder()
        let e = try Self.next(&decoder, Self.line(Self.sample))
        #expect(e.extra["launchPersonaName"] == .string(""))
        #expect(e.extra["backtrace"] == .object(["frames": .array([.object(["imageOffset": .number(1)])])]))
        #expect(e.extra["messageType"] == nil)
        #expect(e.extra["timestamp"] == nil)
    }

    @Test func emptyStringsBecomeNil() throws {
        var decoder = LogEntryDecoder()
        let e = try Self.next(&decoder, Self.line(Self.sample))
        #expect(e.subsystem == nil)
        #expect(e.category == "cat")
    }

    @Test func skipsMalformedLines() throws {
        var decoder = LogEntryDecoder()
        #expect(decoder.decode(line: Data("{\"trunc".utf8)) == nil)
        #expect(decoder.decode(line: Data([0xFF, 0xFE])) == nil)
        #expect(decoder.decode(line: Data("[1,2]".utf8)) == nil)
        let e = try Self.next(&decoder, Self.line(Self.sample))
        #expect(e.id == 1)
    }

    @Test func idsIncrease() throws {
        var decoder = LogEntryDecoder()
        let ids = try (0..<3).map { _ in try Self.next(&decoder, Self.line(Self.sample)).id }
        #expect(ids == [1, 2, 3])
    }

    @Test func estimatedBytesCoversStringsExtraAndOverhead() throws {
        var decoder = LogEntryDecoder()
        let e = try Self.next(&decoder, Self.line(#"{"eventMessage":"abcd","eventType":"ev","processImagePath":"/a/b"}"#))
        // message 4 + eventType 2 + process 1 + path 4 + fixed overhead
        #expect(e.estimatedBytes == 4 + 2 + 1 + 4 + LogEntry.fixedOverheadBytes)
        let big = try Self.next(&decoder, Self.line(#"{"eventMessage":"abcd","blob":"0123456789"}"#))
        #expect(big.estimatedBytes > 4 + LogEntry.fixedOverheadBytes + 10)
    }

    @Test func setIDKeepsEverythingElse() throws {
        var decoder = LogEntryDecoder()
        var e = try Self.next(&decoder, Self.line(Self.floodLine))
        let size = e.estimatedBytes
        e.setID(42)
        #expect(e.id == 42)
        #expect(e.estimatedBytes == size)
        #expect(e.message == "request finished with status 200 in 12 ms")
        #expect(e.withID(7).id == 7)
    }

    @Test func processIsLastNonEmptyPathComponent() {
        #expect(LogEntryDecoder.lastPathComponent("/usr/libexec/logd") == "logd")
        #expect(LogEntryDecoder.lastPathComponent("/a/b/") == "b")
        #expect(LogEntryDecoder.lastPathComponent("plain") == "plain")
        #expect(LogEntryDecoder.lastPathComponent("/") == "")
        #expect(LogEntryDecoder.lastPathComponent("") == "")
        #expect(LogEntryDecoder.lastPathComponent("/Apps/Café 🎉.app/Café 🎉") == "Café 🎉")
    }

    @Test func estimatedBytesChargesEveryExtraNode() throws {
        var decoder = LogEntryDecoder()
        let e = try Self.next(&decoder, Self.line(
            #"{"eventMessage":"m","a":1,"backtrace":{"frames":[{"imageOffset":1,"imageUUID":"u"}]}}"#))
        // Nodes: a, backtrace, frames, the frame object, imageOffset, imageUUID.
        #expect(e.extraNodeCount == 6)
        let serialized = e.extra.reduce(0) { $0 + $1.key.utf8.count + $1.value.estimatedSerializedLength }
        #expect(e.estimatedBytes == 1 + LogEntry.fixedOverheadBytes + serialized + 6 * LogEntry.extraNodeOverheadBytes)
    }

    @Test func estimateOfATypicalMacEntryMatchesMeasuredFootprint() throws {
        // Task 11: at steady state under the 0.5 GB budget, resident memory per stored entry
        // of this shape (scripts/flood.swift output) was ~5,400 bytes.
        var decoder = LogEntryDecoder()
        let e = try Self.next(&decoder, Self.line(Self.floodLine))
        #expect((4_800...6_000).contains(e.estimatedBytes))
    }

    static let floodLine = #"{"timezoneName":"","messageType":"Debug","eventType":"logEvent","source":null,"launchPersonaName":"","formatString":"flood t%{public}ld #%{public}ld %{public}s","userID":501,"activityIdentifier":0,"subsystem":"app.betterconsole.flood","category":"storage","personaType":0,"threadID":1125507,"launchPersonaType":0,"senderImageUUID":"50017BF6-AAED-3C64-B7CB-DAB6DA5F6200","launchPersonaID":4294967295,"backtrace":{"frames":[{"imageOffset":8452,"imageUUID":"50017BF6-AAED-3C64-B7CB-DAB6DA5F6200"}]},"bootUUID":"","processImagePath":"\/private\/var\/folders\/xx\/T\/betterconsole-flood","senderImagePath":"\/private\/var\/folders\/xx\/T\/betterconsole-flood","personaID":4294967295,"timestamp":"2026-11-13 18:15:21.680386+0000","machTimestamp":1373394017328,"personaName":"","eventMessage":"request finished with status 200 in 12 ms","processImageUUID":"50017BF6-AAED-3C64-B7CB-DAB6DA5F6200","traceID":65558414492164,"processID":67329,"senderProgramCounter":8452,"parentActivityIdentifier":0}"#
}
