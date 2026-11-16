import Foundation

/// One chip in the filter bar: a plain condition (include or exclude) or an "Advanced rule"
/// holding a subtree the bar cannot edit.
public struct Bubble: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var content: Content

    public enum Content: Hashable, Sendable {
        case condition(FilterCondition, include: Bool)
        case advanced(FilterExpression)
        /// A link to a saved filter (`.link`), or its exclusion (`.not(.link)`).
        case link(UUID, include: Bool)
    }

    public init(id: UUID = UUID(), content: Content) {
        self.id = id
        self.content = content
    }
}

public enum Connector: Sendable { case and, or }

/// Display order and connector words for a bubble list. The order is the same order
/// `BubbleCodec` writes, so what the bar shows is what the tree applies.
public enum BubbleLayout {
    /// Advanced bubbles (in order), then include bubbles grouped by field in first-appearance
    /// order, then include links, then exclude bubbles, then exclude links (each in order).
    /// Disabled conditions keep their place like any other.
    public static func ordered(_ bubbles: [Bubble]) -> [Bubble] {
        var advanced: [Bubble] = []
        var fields: [FilterField] = []
        var includes: [FilterField: [Bubble]] = [:]
        var excludes: [Bubble] = []
        var includeLinks: [Bubble] = []
        var excludeLinks: [Bubble] = []
        for b in bubbles {
            switch b.content {
            case .advanced: advanced.append(b)
            case .link(_, let include):
                if include { includeLinks.append(b) } else { excludeLinks.append(b) }
            case .condition(let c, let include):
                if include {
                    if includes[c.field] == nil { fields.append(c.field) }
                    includes[c.field, default: []].append(b)
                } else {
                    excludes.append(b)
                }
            }
        }
        return advanced + fields.flatMap { includes[$0] ?? [] } + includeLinks + excludes + excludeLinks
    }

    /// `.or` only between two include bubbles on the same field. Whether a condition is
    /// enabled does not matter.
    public static func connector(between left: Bubble, and right: Bubble) -> Connector {
        if case .condition(let l, true) = left.content,
           case .condition(let r, true) = right.content, l.field == r.field {
            return .or
        }
        return .and
    }
}

/// Maps bubble lists to and from the canonical "bar shape" tree (spec §5.2).
public enum BubbleCodec {
    /// Reads any tree leniently; the result is already in display order.
    public static func bubbles(from expression: FilterExpression?) -> [Bubble] {
        guard let expression else { return [] }
        var read: [Bubble] = []
        // Each root child forms one include group; a later child on a field that already has
        // one stays Advanced, because separate children are ANDed, not ORed.
        var includeFields: Set<FilterField> = []
        for child in rootChildren(expression) {
            if let cs = includeGroup(child) {
                let field = cs[0].field
                if includeFields.insert(field).inserted {
                    read += cs.map { Bubble(content: .condition($0, include: true)) }
                } else {
                    read.append(Bubble(content: .advanced(child)))
                }
            } else if case .link(let id) = child {
                read.append(Bubble(content: .link(id, include: true)))
            } else if case .not(.link(let id)) = child {
                read.append(Bubble(content: .link(id, include: false)))
            } else if case .not(.condition(let c)) = child {
                read.append(Bubble(content: .condition(c, include: false)))
            } else {
                read.append(Bubble(content: .advanced(child)))
            }
        }
        return BubbleLayout.ordered(read)
    }

    /// `all(advanced…, any(includes of F1), any(includes of F2)…, include links…,
    /// not(exclude)…, not(link)…)`;
    /// an empty list is `nil` (no filter).
    public static func expression(from bubbles: [Bubble]) -> FilterExpression? {
        var front: [FilterExpression] = []
        var shapedAdvanced: [FilterExpression] = []
        var includeGroups: [[FilterCondition]] = []
        var groupIndex: [FilterField: Int] = [:]
        var excludes: [FilterExpression] = []
        var includeLinks: [FilterExpression] = []
        var excludeLinks: [FilterExpression] = []
        for b in bubbles {
            switch b.content {
            case .advanced(let e): front.append(e)
            case .link(let id, true): includeLinks.append(.link(id))
            case .link(let id, false): excludeLinks.append(.not(.link(id)))
            case .condition(let c, true):
                if let i = groupIndex[c.field] {
                    includeGroups[i].append(c)
                } else {
                    groupIndex[c.field] = includeGroups.count
                    includeGroups.append([c])
                }
            case .condition(let c, false): excludes.append(.not(.condition(c)))
            }
        }
        // An Advanced subtree shaped like an include group on a field that already has one
        // must be written after it, or reading would swap which of the two is the include.
        var children: [FilterExpression] = []
        for e in front {
            if let field = includeGroup(e)?[0].field, groupIndex[field] != nil {
                shapedAdvanced.append(e)
            } else {
                children.append(e)
            }
        }
        children += includeGroups.map { .any($0.map(FilterExpression.condition)) }
        children += shapedAdvanced
        children += includeLinks
        children += excludes
        children += excludeLinks
        return children.isEmpty ? nil : .all(children)
    }

    private static func rootChildren(_ e: FilterExpression) -> [FilterExpression] {
        guard case .all(let xs) = e else { return [e] }
        return xs.flatMap(rootChildren)
    }

    /// The conditions when `e` is a bare condition or an `any` of conditions on one field.
    private static func includeGroup(_ e: FilterExpression) -> [FilterCondition]? {
        switch e {
        case .condition(let c): return [c]
        case .any(let xs):
            var cs: [FilterCondition] = []
            for x in xs {
                guard case .condition(let c) = x else { return nil }
                cs.append(c)
            }
            guard let field = cs.first?.field, cs.allSatisfy({ $0.field == field }) else { return nil }
            return cs
        default: return nil
        }
    }
}

public enum BubbleEditing {
    /// Identical bubble: unchanged. Same condition with the opposite include: replaced in
    /// place. Otherwise appended. Link and disabled bubbles are never matched or replaced
    /// (a disabled twin does not count as a duplicate).
    public static func adding(_ condition: FilterCondition, include: Bool, to bubbles: [Bubble])
        -> [Bubble]
    {
        var result = bubbles
        for (i, b) in bubbles.enumerated() {
            guard case .condition(let existing, let existingInclude) = b.content,
                  existing.isEnabled, condition.isEnabled, existing == condition else { continue }
            if existingInclude == include { return bubbles }
            result[i].content = .condition(condition, include: include)
            return result
        }
        result.append(Bubble(content: .condition(condition, include: include)))
        return result
    }

    /// The bubble with `isEnabled` flipped when it is a condition; links and Advanced rules
    /// come back unchanged. The id is kept.
    public static func toggled(_ bubble: Bubble) -> Bubble {
        guard case .condition(var c, let include) = bubble.content else { return bubble }
        c.isEnabled.toggle()
        return Bubble(id: bubble.id, content: .condition(c, include: include))
    }
}

/// A one-line description of a tree, for the Advanced rule tooltip. An empty group reads
/// "(no condition)": like `CompiledFilter`, it imposes no constraint.
public enum ExpressionSummary {
    public static func text(_ e: FilterExpression) -> String {
        switch e {
        case .condition(let c):
            conditionText(c)
        case .link:
            "linked filter"
        case .all(let xs):
            xs.isEmpty ? "(no condition)" : xs.map(nested).joined(separator: " and ")
        case .any(let xs):
            xs.isEmpty ? "(no condition)" : xs.map(nested).joined(separator: " or ")
        case .not(let x):
            "not \(nested(x))"
        }
    }

    private static func conditionText(_ c: FilterCondition) -> String {
        let field = c.field == .extra ? "\(c.field.title) \"\(c.key ?? "")\"" : c.field.title
        let value = c.match == .between
            ? "\"\(c.value)\" and \"\(c.upperValue ?? "")\"" : "\"\(c.value)\""
        return "\(field) \(c.match.title(for: c.field)) \(value)"
    }

    private static func nested(_ e: FilterExpression) -> String {
        switch e {
        case .all(let xs) where xs.count > 1, .any(let xs) where xs.count > 1: "(\(text(e)))"
        default: text(e)
        }
    }
}
