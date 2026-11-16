import Foundation

/// The builder's four group kinds (ES §13.1).
public enum GroupKind: String, CaseIterable, Hashable, Sendable {
    /// `.all`
    case allOf
    /// `.any`
    case anyOf
    /// `.not(.any)`; with one condition or link, `.not(x)`.
    case noneOf
    /// `.not(.all)`
    case notAllOf

    public var title: String {
        switch self {
        case .allOf: "All of"
        case .anyOf: "Any of"
        case .noneOf: "None of"
        case .notAllOf: "Not all of"
        }
    }
}

/// A node of the editor's tree. Ids are stable across edits, so the builder can keep its
/// selection and the text pane can map ranges to rows.
public struct EditorNode: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case group(GroupKind, [EditorNode])
        case condition(FilterCondition)
        case link(UUID)

        public var groupKind: GroupKind? {
            if case .group(let kind, _) = self { kind } else { nil }
        }
    }

    public var id: UUID
    public var kind: Kind

    public init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }

    /// Only conditions can be switched off; groups and links (R7) are always on.
    public var isEnabled: Bool {
        if case .condition(let c) = kind { c.isEnabled } else { true }
    }

    public var children: [EditorNode] {
        if case .group(_, let xs) = kind { xs } else { [] }
    }

    public var isGroup: Bool { kind.groupKind != nil }

    // MARK: Reading and writing expressions

    /// The builder's root group for `expression`: nil is an empty All of, and anything that
    /// isn't a group sits alone in an All of.
    init(root expression: FilterExpression?) {
        guard let expression else {
            self.init(kind: .group(.allOf, []))
            return
        }
        let node = EditorNode(expression)
        self = node.isGroup ? node : EditorNode(kind: .group(.allOf, [node]))
    }

    /// ES §13.1: `NOT NOT x` reads as `x`; `NOT` of a condition or link is None of with one
    /// member.
    init(_ e: FilterExpression) {
        switch e {
        case .condition(let c): self.init(kind: .condition(c))
        case .link(let id): self.init(kind: .link(id))
        case .all(let xs): self.init(kind: .group(.allOf, xs.map(EditorNode.init)))
        case .any(let xs): self.init(kind: .group(.anyOf, xs.map(EditorNode.init)))
        case .not(let x):
            switch x {
            case .any(let xs): self.init(kind: .group(.noneOf, xs.map(EditorNode.init)))
            case .all(let xs): self.init(kind: .group(.notAllOf, xs.map(EditorNode.init)))
            case .not(let y): self.init(y)
            case .condition, .link: self.init(kind: .group(.noneOf, [EditorNode(x)]))
            }
        }
    }

    /// The tree as the root's expression: an empty root All of is nil, and a root All of
    /// holding one condition or link is that member. Nested one-member groups are kept (R5).
    /// `paths` gets each node's path in the result, as `PredicateText.nodeRanges` keys it.
    func rootExpression(paths: inout [UUID: NodePath]) -> FilterExpression? {
        if case .group(.allOf, let xs) = kind {
            if xs.isEmpty {
                paths[id] = []
                return nil
            }
            if xs.count == 1, !xs[0].isGroup {
                paths[id] = []
                return xs[0].expression(at: [], paths: &paths)
            }
        }
        return expression(at: [], paths: &paths)
    }

    var rootExpression: FilterExpression? {
        var paths: [UUID: NodePath] = [:]
        return rootExpression(paths: &paths)
    }

    private func expression(at path: NodePath, paths: inout [UUID: NodePath]) -> FilterExpression {
        paths[id] = path
        func members(_ xs: [EditorNode], under prefix: NodePath) -> [FilterExpression] {
            xs.enumerated().map { i, x in x.expression(at: prefix + [i], paths: &paths) }
        }
        switch kind {
        case .condition(let c): return .condition(c)
        case .link(let target): return .link(target)
        case .group(.allOf, let xs): return .all(members(xs, under: path))
        case .group(.anyOf, let xs): return .any(members(xs, under: path))
        case .group(.notAllOf, let xs): return .not(.all(members(xs, under: path + [0])))
        case .group(.noneOf, let xs):
            if xs.count == 1, !xs[0].isGroup {
                return .not(xs[0].expression(at: path + [0], paths: &paths))
            }
            return .not(.any(members(xs, under: path + [0])))
        }
    }

    // MARK: Tree operations

    func find(_ target: UUID) -> EditorNode? {
        if id == target { return self }
        for child in children {
            if let found = child.find(target) { return found }
        }
        return nil
    }

    /// The group holding `target` and its index there.
    func location(of target: UUID) -> (parent: UUID, index: Int)? {
        let xs = children
        if let i = xs.firstIndex(where: { $0.id == target }) { return (id, i) }
        for child in xs {
            if let found = child.location(of: target) { return found }
        }
        return nil
    }

    /// Applies `change` to the node `target`; false when there is no such node.
    @discardableResult
    mutating func modify(_ target: UUID, _ change: (inout EditorNode) -> Void) -> Bool {
        if id == target {
            change(&self)
            return true
        }
        guard case .group(let kind, var xs) = self.kind else { return false }
        for i in xs.indices where xs[i].modify(target, change) {
            self.kind = .group(kind, xs)
            return true
        }
        return false
    }

    /// Changes this group's members; does nothing to a condition or link.
    mutating func modifyMembers(_ change: (inout [EditorNode]) -> Void) {
        guard case .group(let kind, var xs) = self.kind else { return }
        change(&xs)
        self.kind = .group(kind, xs)
    }

    /// A copy with new ids throughout.
    func withFreshIDs() -> EditorNode {
        switch kind {
        case .group(let k, let xs): EditorNode(kind: .group(k, xs.map { $0.withFreshIDs() }))
        default: EditorNode(kind: kind)
        }
    }

    /// This tree with the ids of `old`'s nodes where they correspond, so a text edit doesn't
    /// reset the builder's rows. Within a group, a member takes the id of an old member with
    /// the same content first; the rest pair up in order among members of the same sort
    /// (condition, link, group). A condition never takes a link's id, nor the reverse.
    func reusingIDs(of old: EditorNode) -> EditorNode {
        guard sort == old.sort else { return self }
        var copy = self
        copy.id = old.id
        guard case .group(let k, let xs) = kind else { return copy }
        let olds = old.children
        var match = [Int?](repeating: nil, count: xs.count)
        var used = Set<Int>()
        for (i, x) in xs.enumerated() {
            let content = x.content
            if let j = olds.indices.first(where: { !used.contains($0) && olds[$0].content == content }) {
                match[i] = j
                used.insert(j)
            }
        }
        for (i, x) in xs.enumerated() where match[i] == nil {
            if let j = olds.indices.first(where: { !used.contains($0) && olds[$0].sort == x.sort }) {
                match[i] = j
                used.insert(j)
            }
        }
        copy.kind = .group(k, xs.enumerated().map { i, x in
            match[i].map { x.reusingIDs(of: olds[$0]) } ?? x
        })
        return copy
    }

    private enum Sort { case condition, link, group }

    private var sort: Sort {
        switch kind {
        case .condition: .condition
        case .link: .link
        case .group: .group
        }
    }

    /// The node's meaning, without ids.
    private var content: FilterExpression {
        var ignored: [UUID: NodePath] = [:]
        return expression(at: [], paths: &ignored)
    }
}
