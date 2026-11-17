import Foundation
import Testing
import BCModel
@testable import BCFiles

/// Tab-separated table columns (Copy's layout, and Save Logs' layout before the BetterConsole
/// log format): time, type, process, subsystem, category, message.
@Suite struct ColumnsStyleTests {
    typealias T = LogFileParserTests

    @Test func tableColumnsAreReadFieldByField() {
        let text = """
            22:40:20.913098\tInfo\trunningboardd\tcom.apple.runningboard\tassertion\tProcessing invalidation queue with 1 assertions
            22:40:20.913239\tDefault\trunningboardd\t\t\tstate update
            22:40:22.747305\tDebug\tPerfPowerServices\tcom.apple.powerlog\tLocation\ttype=Location, timeStarted=(null)
            """
        let e = T.parse(text, name: "Someone's MacBook Pro 2026-11-16 22-40.log")
        #expect(e.count == 3)
        #expect(e[0].process == "runningboardd")
        #expect(e[0].level == .info)
        #expect(e[0].subsystem == "com.apple.runningboard")
        #expect(e[0].category == "assertion")
        #expect(e[0].message == "Processing invalidation queue with 1 assertions")
        // Time of day only: dated on the file's modification day.
        #expect(T.micros(e[0].date) == T.micros(T.date(2026, 11, 16, 22, 40, 20, micros: 913_098)))
        #expect(e[1].level == .default)
        #expect(e[1].subsystem == nil && e[1].category == nil)
        #expect(e[1].message == "state update")
        #expect(e[2].level == .debug)
        #expect(e[2].process == "PerfPowerServices")
        #expect(e[2].category == "Location")
        #expect(e[2].message == "type=Location, timeStarted=(null)")
    }

    @Test func fullTimestampsAndEmptyMessage() {
        let e = T.parse("2026-11-16 22:40:20.5\tError\tapp\tcom.x\tnet\t")
        #expect(e.count == 1)
        #expect(e[0].level == .error)
        #expect(e[0].message == "")
        #expect(T.micros(e[0].date) == T.micros(T.date(2026, 11, 16, 22, 40, 20, micros: 500_000)))
    }

    @Test func notColumnsFallsThrough() {
        // Wrong field count or an unknown type word: not this style.
        let e = T.parse("22:40:20\tWarning\tapp\tsub\tcat\tmsg\n22:40:21\tInfo\tapp\tmsg")
        #expect(e.count == 2)
        #expect(e[0].subsystem == nil)
        #expect(e[1].subsystem == nil)
    }
}
