import BCModel
import Foundation
import Testing
@testable import BCMobileDevice

/// Fixtures are real `os_trace_relay` frames captured over USB by the Task 0 spike
/// (iOS 27.2.1). Expected values are the spike's printout (Spikes/OSTraceSpike/RESULT.md).
struct OSTraceDecoderTests {
    struct Expected: Sendable, CustomTestStringConvertible {
        let fixture: String
        let pid: Int32
        let seconds: Double
        let microseconds: Double
        let level: LogLevel
        let processPath: String
        let image: String
        let subsystem: String?
        let category: String?
        let message: String
        var testDescription: String { fixture }
    }

    static let expected: [Expected] = [
        Expected(fixture: "ostrace-default-1", pid: 101, seconds: 1794587622, microseconds: 79683, level: .default,
                 processPath: "/usr/sbin/bluetoothd",
                 image: "/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit",
                 subsystem: "com.apple.iokit", category: "assertions", message: "Resuming timer"),
        Expected(fixture: "ostrace-default-2", pid: 73, seconds: 1794587616, microseconds: 763393, level: .default,
                 processPath: "/usr/libexec/backboardd",
                 image: "/System/Library/PrivateFrameworks/libEDR.framework/libEDR",
                 subsystem: nil, category: nil,
                 message: "ScheduleSetBrightnessIn_block_invoke: enter WaitUntil late 0.015666 millisecond (22709 / 22709)"),
        Expected(fixture: "ostrace-info-1", pid: 173, seconds: 1794587619, microseconds: 480056, level: .info,
                 processPath: "/usr/libexec/cameraispd", image: "/usr/libexec/cameraispd",
                 subsystem: "com.apple.isp", category: "daemon", message: "getProperty - 100"),
        // Flavor 2: the subsystem/category size fields hold garbage and must be ignored.
        Expected(fixture: "ostrace-info-2", pid: 36, seconds: 1794587616, microseconds: 818771, level: .info,
                 processPath: "/usr/libexec/runningboardd",
                 image: "/System/Library/PrivateFrameworks/RunningBoard.framework/RunningBoard",
                 subsystem: nil, category: nil, message: "lookupHandleForPredicate"),
        Expected(fixture: "ostrace-debug-1", pid: 73, seconds: 1794587616, microseconds: 763525, level: .debug,
                 processPath: "/usr/libexec/backboardd",
                 image: "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
                 subsystem: "com.apple.CoreBrightness.Display.1", category: "default", message: "S=0.546697"),
        Expected(fixture: "ostrace-debug-2", pid: 73, seconds: 1794587616, microseconds: 763355, level: .debug,
                 processPath: "/usr/libexec/backboardd",
                 image: "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
                 subsystem: nil, category: nil,
                 message: "CBEDRServerDisplayBrightness: display: 0 | target: 129.276886 | max: 1600.000000 | ambient: 130.855133 | boost=1.352498"),
        Expected(fixture: "ostrace-error-1", pid: 0, seconds: 1794587619, microseconds: 624967, level: .error,
                 processPath: "/kernel", image: "/kernel",
                 subsystem: nil, category: nil, message: "Extensible paniclog not supported"),
        // Subsystem set with an empty category.
        Expected(fixture: "ostrace-error-2", pid: 1187, seconds: 1794587621, microseconds: 519150, level: .error,
                 processPath: "/usr/sbin/wifid",
                 image: "/System/Library/PrivateFrameworks/WiFiPolicy.framework/WiFiPolicy",
                 subsystem: "com.apple.WiFiPolicy", category: nil, message: "LQM-WiFi: rxMulti=0 rxUndec=0"),
    ]

    static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "bin", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// Frame offset of the level byte: 5-byte frame header + payload offset 68.
    static let levelOffset = 5 + 68

    // MARK: Fixture frames

    @Test(arguments: expected)
    func decodesFixtureFrames(_ e: Expected) throws {
        var decoder = OSTraceDecoder()
        let entries = decoder.feed(try Self.fixture(e.fixture))
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(decoder.error == nil)
        #expect(entry.id == 1)
        #expect(entry.pid == e.pid)
        #expect(entry.level == e.level)
        #expect(entry.process == URL(fileURLWithPath: e.processPath).lastPathComponent)
        #expect(entry.processImagePath == e.processPath)
        #expect(entry.senderImagePath == e.image)
        #expect(entry.subsystem == e.subsystem)
        #expect(entry.category == e.category)
        #expect(entry.message == e.message)
        #expect(entry.eventType == "logEvent")
        #expect(entry.date == Date(timeIntervalSince1970: e.seconds + e.microseconds / 1_000_000))
    }

    @Test func decodesStreamOfFiftyFrames() throws {
        var decoder = OSTraceDecoder()
        let entries = decoder.feed(try Self.fixture("ostrace-stream"))
        #expect(entries.count == 50)
        #expect(decoder.error == nil)
        #expect(entries.map(\.id) == Array(1...50))
        #expect(entries[0].pid == 312)
        #expect(entries[0].subsystem == "com.apple.powerlog")
        #expect(entries[0].category == "ClientLogging")
        #expect(entries[0].message == "buildMessageForClientID: 110 message:<private>")
        #expect(entries[8].category == "User Defaults")
        #expect(entries[40].level == .info)
        #expect(entries[40].subsystem == nil)
        #expect(entries[42].level == .default)
        #expect(entries[49].message == "S=0.546697")
    }

    @Test func keepsUnmappedWireFieldsInExtra() throws {
        var decoder = OSTraceDecoder()
        let entry = try #require(decoder.feed(try Self.fixture("ostrace-info-2")).first)
        #expect(entry.extra["flavor"] == .number(2))
        #expect(entry.extra["levelByte"] == .number(1))
        #expect(entry.extra["processUUID"] != nil)
        #expect(entry.extra["senderUUID"] != nil)
    }

    // MARK: Framing

    @Test func handlesFrameSplitAcrossFeeds() throws {
        let bytes = try Self.fixture("ostrace-stream")
        var whole = OSTraceDecoder()
        let expected = whole.feed(bytes)

        var decoder = OSTraceDecoder()
        var entries: [LogEntry] = []
        for byte in bytes { entries += decoder.feed(Data([byte])) }
        #expect(decoder.error == nil)
        #expect(entries.count == expected.count)
        #expect(entries.map(\.message) == expected.map(\.message))
        #expect(entries.map(\.id) == expected.map(\.id))
        #expect(entries.map(\.subsystem) == expected.map(\.subsystem))
    }

    @Test func handlesIrregularChunks() throws {
        let bytes = try Self.fixture("ostrace-stream")
        var decoder = OSTraceDecoder()
        var entries: [LogEntry] = []
        var offset = 0
        var size = 1
        while offset < bytes.count {
            let end = min(offset + size, bytes.count)
            entries += decoder.feed(bytes.subdata(in: offset..<end))
            offset = end
            size = size * 7 % 997 + 1
        }
        #expect(entries.count == 50)
    }

    @Test func truncatedFrameWaitsForMore() throws {
        let frame = try Self.fixture("ostrace-default-1")
        var decoder = OSTraceDecoder()
        #expect(decoder.feed(frame.prefix(3)).isEmpty)          // inside the 5-byte header
        #expect(decoder.feed(frame.subdata(in: 3..<200)).isEmpty) // inside the payload
        #expect(decoder.error == nil)
        let entries = decoder.feed(frame.subdata(in: 200..<frame.count))
        #expect(entries.count == 1)
        #expect(entries.first?.message == "Resuming timer")
    }

    // MARK: Levels

    @Test func unknownLevelMapsToDefault() throws {
        var frame = try Self.fixture("ostrace-error-2")
        frame[Self.levelOffset] = 0x7f
        var decoder = OSTraceDecoder()
        let entry = try #require(decoder.feed(frame).first)
        #expect(entry.level == .default)
        #expect(entry.extra["levelByte"] == .number(0x7f))
    }

    /// SYNTHETIC: no fault (0x11) frame was ever observed on the wire (RESULT.md). This is a
    /// real error frame with its level byte patched to 0x11 (pymobiledevice3's fault value).
    @Test func syntheticFaultFrameMapsToFault() throws {
        var frame = try Self.fixture("ostrace-error-2")
        frame[Self.levelOffset] = 0x11
        var decoder = OSTraceDecoder()
        #expect(decoder.feed(frame).first?.level == .fault)
    }

    // MARK: Malformed input

    /// A frame with a sane outer length but garbage inner sizes is decoded as far as its
    /// fields allow and never desyncs the stream: the next frame decodes normally.
    @Test func garbageInnerSizesDoNotDesync() throws {
        var bad = try Self.fixture("ostrace-default-1")
        // Image size (payload 107) and message size (payload 109) far beyond the payload.
        bad[5 + 107] = 0xff; bad[5 + 108] = 0xff
        bad[5 + 109] = 0xff; bad[5 + 110] = 0xff
        // Subsystem size (payload 117) = 0xFFFFFFFF.
        for i in 0..<4 { bad[5 + 117 + i] = 0xff }
        let good = try Self.fixture("ostrace-info-1")
        var decoder = OSTraceDecoder()
        let entries = decoder.feed(bad + good)
        #expect(decoder.error == nil)
        #expect(entries.count == 2)
        #expect(entries.first?.pid == 101)
        #expect(entries.first?.subsystem == nil)
        #expect(entries.last?.message == "getProperty - 100")
    }

    @Test func headerLengthOutOfRangeSkipsJustThatFrame() throws {
        var bad = try Self.fixture("ostrace-default-1")
        for i in 0..<4 { bad[5 + 5 + i] = 0xff }  // header length (payload 5)
        let good = try Self.fixture("ostrace-info-1")
        var decoder = OSTraceDecoder()
        let entries = decoder.feed(bad + good)
        #expect(decoder.error == nil)
        #expect(entries.map(\.message) == ["getProperty - 100"])
        #expect(decoder.skippedFrames == 1)
    }

    @Test func payloadShorterThanHeaderIsSkipped() throws {
        let short = Data([0x02, 0x04, 0x00, 0x00, 0x00, 0x02, 0x08, 0x00, 0x00])
        let good = try Self.fixture("ostrace-info-1")
        var decoder = OSTraceDecoder()
        let entries = decoder.feed(short + good)
        #expect(entries.count == 1)
        #expect(decoder.skippedFrames == 1)
        #expect(decoder.error == nil)
    }

    @Test func insaneOuterLengthIsAnError() throws {
        var decoder = OSTraceDecoder()
        let entries = decoder.feed(Data([0x02, 0xff, 0xff, 0xff, 0x7f]))
        #expect(entries.isEmpty)
        #expect(decoder.error == .frameTooLarge(0x7fff_ffff))
        // Once failed, further input is ignored.
        #expect(decoder.feed(try Self.fixture("ostrace-info-1")).isEmpty)
    }

    @Test func unexpectedTagIsAnError() throws {
        var decoder = OSTraceDecoder()
        let good = try Self.fixture("ostrace-info-1")
        let entries = decoder.feed(good + Data([0x07, 0, 0, 0, 0]))
        #expect(entries.count == 1)
        #expect(decoder.error == .unexpectedTag(0x07))
    }

    @Test func messageWithoutTerminatorAndInvalidUTF8DoesNotCrash() throws {
        var frame = try Self.fixture("ostrace-default-1")
        // Overwrite the whole variable part with 0xff bytes: no NUL, invalid UTF-8.
        for i in (5 + 129)..<frame.count { frame[i] = 0xff }
        var decoder = OSTraceDecoder()
        let entries = decoder.feed(frame)
        #expect(entries.count == 1)
        #expect(decoder.error == nil)
    }
}
