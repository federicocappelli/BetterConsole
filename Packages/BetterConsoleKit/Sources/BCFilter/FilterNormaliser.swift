import Foundation

/// The tree `PredicateParser` reads back from `PredicateWriter`'s text, so
/// `parse(write(t)) == normalised(t)` (ES §13.1):
///
/// - one-member groups are unwrapped, and groups nested in a group of the same kind flattened;
/// - `NOT NOT x` is `x`, also through one-member groups (so `.not(.any([x]))` is `.not(x)`);
/// - a subtree with no condition or link anywhere below (written `TRUEPREDICATE`) is nil at the
///   root and `.all([])` when nested, and is never flattened away;
/// - conditions are written canonically: Type names lower-case, PID and Activity ID decimal,
///   (`0x…` hex read as decimal), Thread ID lower-case `0x` hex (a value the field can't use is kept as written), and only
///   Extra data keeps a key (`""` when missing), only `between` an end (`""` when missing).
public enum FilterNormaliser {
    public static func normalised(_ e: FilterExpression?) -> FilterExpression? {
        guard let e else { return nil }
        let n = normalise(e)
        return n == empty ? nil : n
    }

    /// The nested form of an empty subtree, as `TRUEPREDICATE` reads.
    private static let empty = FilterExpression.all([])

    private static func normalise(_ e: FilterExpression) -> FilterExpression {
        switch e {
        case .condition(let c): return .condition(canonical(c))
        case .link: return e
        case .all(let xs): return group(xs.map(normalise), isAll: true)
        case .any(let xs): return group(xs.map(normalise), isAll: false)
        case .not(let x):
            let y = normalise(x)
            if y == empty { return empty }
            if case .not(let z) = y { return z }
            return .not(y)
        }
    }

    /// `members` already normalised: empty when they all are, else flattened and unwrapped.
    private static func group(_ members: [FilterExpression], isAll: Bool) -> FilterExpression {
        if members.allSatisfy({ $0 == empty }) { return empty }
        var flat: [FilterExpression] = []
        for m in members {
            switch m {
            case .all(let xs) where isAll && !xs.isEmpty: flat += xs
            case .any(let xs) where !isAll && !xs.isEmpty: flat += xs
            default: flat.append(m)
            }
        }
        return flat.count == 1 ? flat[0] : isAll ? .all(flat) : .any(flat)
    }

    static func canonical(_ c: FilterCondition) -> FilterCondition {
        var c = c
        c.key = c.field == .extra ? (c.key ?? "") : nil
        c.upperValue = c.match == .between ? (c.upperValue ?? "") : nil
        switch c.match {
        case .is, .lessThan, .lessOrEqual, .greaterThan, .greaterOrEqual:
            if let literal = literal(c) { c.value = literal }
        default:
            break
        }
        return c
    }

    /// The canonical spelling of a numeric or Type value, as `PredicateWriter` writes it; nil
    /// for text fields and for a value the field can't use.
    static func literal(_ c: FilterCondition) -> String? {
        switch c.field {
        case .pid: FilterCondition.parseInteger(c.value, as: Int32.self).map { String($0) }
        case .activity: FilterCondition.parseInteger(c.value, as: UInt64.self).map { String($0) }
        case .thread: FilterCondition.parseInteger(c.value, as: UInt64.self).map { "0x" + String($0, radix: 16) }
        case .type: FilterCondition.parseLevel(c.value).map { $0.rawValue.lowercased() }
        default: nil
        }
    }
}
