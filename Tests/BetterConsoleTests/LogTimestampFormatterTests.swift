import Foundation
import Testing

@Suite struct LogTimestampFormatterTests {
    private let utc = TimeZone(identifier: "UTC")!

    /// 2025-11-13 15:55:22 UTC.
    private let base: TimeInterval = 1_763_049_322

    @Test func formatsMicrosecondsByRounding() {
        let formatter = LogTimestampFormatter(timeZone: utc)
        let date = Date(timeIntervalSince1970: base + 0.273495)
        #expect(formatter.string(from: date) == "15:55:22.273495")
        // This one lands just below .273496 in the Date's Double; truncating prints .273495.
        let below = Date(timeIntervalSince1970: base + 0.273496)
        #expect(formatter.string(from: below) == "15:55:22.273496")
    }

    @Test func usesTheGivenTimeZone() {
        let date = Date(timeIntervalSince1970: base + 0.273495)
        let plusOne = TimeZone(secondsFromGMT: 3600)!
        #expect(LogTimestampFormatter(timeZone: plusOne).string(from: date) == "16:55:22.273495")
    }

    @Test func roundingCarriesIntoTheNextSecond() {
        let date = Date(timeIntervalSince1970: base + 0.9999996)
        #expect(LogTimestampFormatter(timeZone: utc).string(from: date) == "15:55:23.000000")
    }

    @Test func roundsHalfMicrosecondBoundary() {
        let formatter = LogTimestampFormatter(timeZone: utc)
        // Near the reference date the Double is precise enough to resolve 0.0001 µs.
        #expect(formatter.string(from: Date(timeIntervalSinceReferenceDate: 0.0000004999))
            == "00:00:00.000000")
        #expect(formatter.string(from: Date(timeIntervalSinceReferenceDate: 0.0000005001))
            == "00:00:00.000001")
        #expect(formatter.string(from: Date(timeIntervalSinceReferenceDate: 1.0000014999))
            == "00:00:01.000001")
    }

    @Test func floorsBeforeTheReferenceDate() {
        let date = Date(timeIntervalSinceReferenceDate: -0.25)
        #expect(LogTimestampFormatter(timeZone: utc).string(from: date) == "23:59:59.750000")
        let split = LogTimestampFormatter.split(date)
        #expect(split.seconds == -1)
        #expect(split.micros == 750_000)
    }

    @Test func cachedSecondDoesNotLeakAcrossSeconds() {
        let formatter = LogTimestampFormatter(timeZone: utc)
        #expect(formatter.string(from: Date(timeIntervalSince1970: base + 0.5)) == "15:55:22.500000")
        #expect(formatter.string(from: Date(timeIntervalSince1970: base + 1.5)) == "15:55:23.500000")
        #expect(formatter.string(from: Date(timeIntervalSince1970: base + 0.25)) == "15:55:22.250000")
    }
}
