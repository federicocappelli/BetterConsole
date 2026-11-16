import Foundation
import Testing
@testable import BCFilter

@Suite struct FilterSuggestionsTests {
    @Test func whitespaceOnlyGivesNothing() {
        #expect(FilterSuggestions.make(for: "   ", seen: SeenValues()).isEmpty)
        #expect(FilterSuggestions.make(for: "", seen: SeenValues()).isEmpty)
    }

    @Test func trimsTypedText() {
        let s = FilterSuggestions.make(for: "  cfnet  ", seen: SeenValues())
        #expect(s.first?.title == "Message contains \"cfnet\"")
        #expect(s.first?.condition == FilterCondition(field: .message, match: .contains, value: "cfnet"))
    }

    @Test func orderAndCaps() {
        var seen = SeenValues()
        for p in ["cfnetworkagent", "cfnet", "cfnetx", "CFNetworkDiagnostics", "cfnetwork", "other"] {
            seen.insert(makeEntry(process: p))
        }
        seen.insert(makeEntry(process: "zzz", sender: "/usr/lib/libcfnet.dylib",
                              subsystem: "com.apple.cfnet", category: "cfnetcat"))
        let titles = FilterSuggestions.make(for: "cfnet", seen: seen).map(\.title)
        #expect(titles == [
            "Message contains \"cfnet\"",
            "Process is \"cfnet\"", "Process is \"cfnetx\"", "Process is \"cfnetwork\"",
            "Subsystem is \"com.apple.cfnet\"",
            "Category is \"cfnetcat\"",
            "Library is \"libcfnet.dylib\"",
            "Subsystem contains \"cfnet\"",
            "Category contains \"cfnet\"",
            "Process contains \"cfnet\"",
        ])
        let first = FilterSuggestions.make(for: "cfnet", seen: seen)[1]
        #expect(first.condition == FilterCondition(field: .process, match: .is, value: "cfnet"))
    }

    @Test func seenValuesCap() {
        var seen = SeenValues()
        for i in 0...5_000 { seen.insert(makeEntry(process: "p\(i)")) }
        #expect(SeenValues.capPerField == 5_000)
        #expect(seen.values(for: .process).count == 5_000)
        #expect(!seen.values(for: .process).contains("p5000"))
    }

    @Test func seenTracksFourFieldsOnly() {
        var seen = SeenValues()
        seen.insert(makeEntry(process: "P", pid: 1, sender: "/a/b/Lib", subsystem: "S", category: "C"))
        #expect(seen.values(for: .process) == ["P"])
        #expect(seen.values(for: .subsystem) == ["S"])
        #expect(seen.values(for: .category) == ["C"])
        #expect(seen.values(for: .library) == ["Lib"])
        #expect(seen.values(for: .pid).isEmpty)
    }
}
