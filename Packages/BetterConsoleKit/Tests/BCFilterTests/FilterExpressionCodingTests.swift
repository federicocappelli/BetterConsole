import Foundation
import Testing
@testable import BCFilter

@Suite struct FilterExpressionCodingTests {
    private func c(_ f: FilterField, _ m: MatchKind, _ v: String, _ on: Bool = true) -> FilterExpression {
        .condition(FilterCondition(field: f, match: m, value: v, isEnabled: on))
    }

    @Test func roundTrip() throws {
        let e: FilterExpression = .all([
            c(.process, .contains, "a"),
            .any([c(.message, .regex, "x+", false), .not(c(.type, .is, "debug"))]),
        ])
        let data = try JSONEncoder().encode(e)
        #expect(try JSONDecoder().decode(FilterExpression.self, from: data) == e)
    }

    private func json(_ e: FilterExpression) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return String(decoding: try enc.encode(e), as: UTF8.self)
    }

    @Test func shapeMatchesSpec() throws {
        #expect(
            try json(.not(c(.type, .is, "debug")))
                == #"{"not":{"condition":{"field":"type","match":"is","value":"debug"}}}"#)
        #expect(
            try json(.all([c(.pid, .is, "1")]))
                == #"{"all":[{"condition":{"field":"pid","match":"is","value":"1"}}]}"#)
    }

    @Test func isEnabledOmittedWhenTrue() throws {
        #expect(try !json(c(.pid, .is, "1")).contains("isEnabled"))
        #expect(try json(c(.pid, .is, "1", false)).contains(#""isEnabled":false"#))
    }

    @Test func missingIsEnabledDecodesTrue() throws {
        let d = Data(#"{"condition":{"field":"pid","match":"is","value":"1"}}"#.utf8)
        #expect(try JSONDecoder().decode(FilterExpression.self, from: d) == c(.pid, .is, "1"))
    }

    @Test func unknownFieldFailsDecoding() {
        let d = Data(#"{"condition":{"field":"zone","match":"is","value":"1"}}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(FilterExpression.self, from: d) }
    }
}
