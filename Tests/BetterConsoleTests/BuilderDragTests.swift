import CoreTransferable
import Foundation
import Testing
import UniformTypeIdentifiers

/// The builder's row drag (ES §8.2): a private type, so a text view (the predicate pane)
/// doesn't take it as text and insert it.
@Suite struct BuilderDragTests {
    @Test func payloadIsAPrivateTypeNotText() {
        let type = BuilderDrag.contentType
        #expect(type.identifier == "app.betterconsole.builder-node")
        #expect(!type.conforms(to: .text))
        #expect(!type.conforms(to: .plainText))
        #expect(!type.conforms(to: .url))
        #expect(type.conforms(to: .data))
    }

    @Test func payloadRoundTrips() async throws {
        let id = UUID()
        let data = try await BuilderDrag(id: id).exported(as: BuilderDrag.contentType)
        let back = try await BuilderDrag(importing: data, contentType: BuilderDrag.contentType)
        #expect(back.id == id)
    }
}
