import Foundation
import Testing
import BCModel
@testable import BCFilter

/// The user's case: typing `21:45:30` – `21:46:00` in the editor must keep matching messages
/// inside that half minute, through the editor model, the predicate text and the parser.
@MainActor @Suite struct TimeOfDayEditorTests {
    private func at(_ h: Int, _ m: Int, _ s: Double) -> LogEntry {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let d = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: h, minute: m))!
        return makeEntry(level: .error, date: d.addingTimeInterval(s))
    }

    private var range: FilterExpression {
        .condition(FilterCondition(field: .timeOfDay, match: .between, value: "21:45:30", upperValue: "21:46:00"))
    }

    @Test func compiledRangeMatchesInside() {
        let f = CompiledFilter(range)
        #expect(f.matches(at(21, 45, 45)))
        #expect(f.matches(at(21, 46, 0.5)))
        #expect(!f.matches(at(21, 45, 29)))
        #expect(!f.matches(at(21, 46, 1)))
    }

    @Test func predicateRoundTripKeepsSeconds() throws {
        let text = PredicateWriter.write(range, nameForLink: { _ in nil }).text
        let parsed = try PredicateParser.parse(text, linkForName: { _ in .notFound }).get()
        #expect(CompiledFilter(parsed).matches(at(21, 45, 45)))
    }

    @Test func typingInTheEditorKeepsTheRange() {
        let library = FilterLibrary(storage: FakeStorage())
        let workspace = FilterWorkspace(library: library, persistence: MemoryPersistence())
        workspace.setExpression(
            .all([.condition(FilterCondition(field: .type, match: .is, value: "error")),
                  .condition(FilterCondition(field: .timeOfDay, match: .between, value: "21:45", upperValue: "21:46"))]),
            for: "mac")
        let model = FilterEditorModel(deviceID: "mac", workspace: workspace, library: library)
        let timeNode = model.root.children.first { if case .condition(let c) = $0.kind { c.field == .timeOfDay } else { false } }
        guard let timeNode, case .condition(var c) = timeNode.kind else { Issue.record("no time node"); return }
        for prefix in ["21:45:", "21:45:3", "21:45:30"] {
            c.value = prefix
            model.update(timeNode.id, condition: c, coalescing: true)
        }
        for value in ["21:46:", "21:46:0", "21:46:00"] {
            c.upperValue = value
            model.update(timeNode.id, condition: c, coalescing: true)
        }
        model.endCoalescing()
        model.apply()
        let resolved = workspace.resolvedExpression(for: "mac")
        let f = CompiledFilter(resolved)
        #expect(f.matches(at(21, 45, 45)), "applied: \(String(describing: resolved))")
        #expect(f.matches(at(21, 46, 0.5)))
        #expect(!f.matches(at(21, 46, 30)))
    }
}
