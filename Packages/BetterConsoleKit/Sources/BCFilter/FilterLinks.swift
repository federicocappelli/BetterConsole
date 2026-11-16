import Foundation

/// The link graph between saved filters (ES §9, §13.4). Links are stored by id, so a link
/// whose filter is gone is simply missing: it is skipped here and ignored at evaluation.
public enum FilterLinks {
    /// The ids `expression` links directly, at any depth of its own tree.
    public static func links(in expression: FilterExpression?) -> Set<UUID> {
        var found = Set<UUID>()
        expression.map { collect($0, into: &found) }
        return found
    }

    /// Every saved filter that links `id`, directly or indirectly. `id` itself is never
    /// listed, even when it is already part of a loop.
    public static func dependents(of id: UUID, in library: [SavedFilter]) -> Set<UUID> {
        var linkedBy: [UUID: Set<UUID>] = [:]
        for filter in library {
            for target in links(in: filter.expression) { linkedBy[target, default: []].insert(filter.id) }
        }
        var found = Set<UUID>()
        var pending = [id]
        while let next = pending.popLast() {
            for user in linkedBy[next] ?? [] where user != id && found.insert(user).inserted {
                pending.append(user)
            }
        }
        return found
    }

    /// The saved filters that link `id` themselves (not through another filter), for the
    /// delete prompt. `id` itself is never listed.
    public static func directDependents(of id: UUID, in library: [SavedFilter]) -> Set<UUID> {
        Set(library.filter { $0.id != id && links(in: $0.expression).contains(id) }.map(\.id))
    }

    /// Whether `owner` linking `target` would close a loop: `target` is `owner`, or links it
    /// directly or indirectly. An Untitled owner (nil) has no identity, so it never loops.
    public static func wouldLoop(
        linking target: UUID, from owner: UUID?, in library: [SavedFilter]
    ) -> Bool {
        guard let owner else { return false }
        return target == owner || dependents(of: owner, in: library).contains(target)
    }

    /// Every saved filter `expression` reaches through links, each once, in the order a
    /// depth-first walk first reaches it (each link's own links before the next link).
    /// Missing links are skipped.
    public static func closure(
        of expression: FilterExpression?, in library: [SavedFilter]
    ) -> [SavedFilter] {
        let byID = Dictionary(library.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<UUID>()
        var result: [SavedFilter] = []
        func visit(_ e: FilterExpression) {
            for id in orderedLinks(in: e) where !seen.contains(id) {
                seen.insert(id)
                guard let filter = byID[id] else { continue }
                result.append(filter)
                filter.expression.map(visit)
            }
        }
        expression.map(visit)
        return result
    }

    // MARK: - Private

    private static func collect(_ e: FilterExpression, into found: inout Set<UUID>) {
        switch e {
        case .condition: break
        case .all(let xs), .any(let xs): xs.forEach { collect($0, into: &found) }
        case .not(let x): collect(x, into: &found)
        case .link(let id): found.insert(id)
        }
    }

    /// Direct links in tree order, with repeats.
    private static func orderedLinks(in e: FilterExpression) -> [UUID] {
        switch e {
        case .condition: []
        case .all(let xs), .any(let xs): xs.flatMap(orderedLinks)
        case .not(let x): orderedLinks(in: x)
        case .link(let id): [id]
        }
    }
}
