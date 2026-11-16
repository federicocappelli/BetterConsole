import BCModel
import Foundation
import Testing
@testable import BCFilter

private func macEntry(activity: UInt64? = 0, subsystem: String? = "com.apple.defaults") -> LogEntry {
    LogEntry(
        id: 1, date: Date(timeIntervalSince1970: 1), level: .debug, eventType: "logEvent",
        process: "Console", pid: 20368, threadID: 0xa6fc7, subsystem: subsystem,
        category: "User Defaults", message: "m",
        senderImagePath: "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
        activityID: activity)
}

@Suite struct QuickFilterItemsTests {
    @Test func macRow() {
        let items = QuickFilterItems.items(for: macEntry())
        #expect(items.map(\.menuValue) == [
            "Console", "20368", "CoreFoundation", "0xa6fc7", "com.apple.defaults",
            "User Defaults", "debug", "0",
        ])
        #expect(items.map(\.condition.field) == [
            .process, .pid, .library, .thread, .subsystem, .category, .type, .activity,
        ])
        #expect(items.allSatisfy { $0.condition.match == .is })
        #expect(items.allSatisfy { $0.condition.valueProblem == nil })
    }

    @Test func iPhoneRowOmitsActivity() {
        #expect(QuickFilterItems.items(for: macEntry(activity: nil)).count == 7)
    }

    @Test func omitsMissingSubsystem() {
        let items = QuickFilterItems.items(for: macEntry(subsystem: nil))
        #expect(!items.contains { $0.condition.field == .subsystem })
        #expect(items.count == 7)
    }

    @Test func longValueTruncatedInMenuOnly() throws {
        let long = String(repeating: "a", count: 50) + String(repeating: "b", count: 50)
        let item = try #require(QuickFilterItems.items(for: macEntry(subsystem: long))
            .first { $0.condition.field == .subsystem })
        #expect(item.menuValue.count == 60)
        #expect(item.menuValue.contains("…"))
        #expect(item.menuValue.hasPrefix("aaa") && item.menuValue.hasSuffix("bbb"))
        #expect(item.condition.value == long)
    }

    @Test func libraryConditionMatchesItsEntry() throws {
        let entry = macEntry()
        let item = try #require(QuickFilterItems.items(for: entry)
            .first { $0.condition.field == .library })
        #expect(CompiledFilter(.condition(item.condition)).matches(entry))
    }
}
