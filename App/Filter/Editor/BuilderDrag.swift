import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// The drag payload for reordering builder rows (ES §8.2): the node's id, as a private type
/// (declared in the app's Info.plist) so the predicate text view, which takes text, ignores
/// it instead of inserting it.
struct BuilderDrag: Codable, Transferable {
    static let contentType = UTType(exportedAs: "app.betterconsole.builder-node", conformingTo: .data)

    var id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: contentType)
    }
}
