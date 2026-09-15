import Foundation

/// A decoded PostgreSQL `EXPLAIN (FORMAT JSON)` plan.
///
/// PostgreSQL answers `FORMAT JSON` with a one-element array:
///
/// ```json
/// [ { "Plan": { "Node Type": "Seq Scan", … }, "Planning Time": 0.1, "Execution Time": 3.4 } ]
/// ```
///
/// The keys carry spaces and initial capitals, and the set of them changes with
/// the server version and with the options the statement was explained under —
/// so the fields this app shows are read by name and everything else is kept
/// verbatim in `PlanNode.extra` rather than being dropped. Nothing here imports
/// AppKit: the arithmetic the plan view draws is tested on its own in
/// `scripts/test-query-plan.sh`.
struct QueryPlan {

    /// The top node of the tree. Every other node is one of its descendants.
    let root: PlanNode

    /// Milliseconds the planner spent. Present on any modern server.
    let planningTimeMs: Double?

    /// Milliseconds the execution took. `nil` unless the statement was
    /// explained with ANALYZE — which is the same thing as "this plan has no
    /// measured numbers, only estimates".
    let executionTimeMs: Double?

    // MARK: - Decoding

    enum DecodeError: LocalizedError {
        /// The text is not JSON at all.
        case notJSON
        /// The text is JSON, but carries no `Plan` object.
        case noPlan

        var errorDescription: String? {
            switch self {
            case .notJSON: return String(localized: "The server's plan could not be read as JSON.")
            case .noPlan: return String(localized: "The server's reply carried no query plan.")
            }
        }
    }

    /// Decode the text `PharosCore.explainQuery` returns.
    init(json: String) throws {
        guard let data = json.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data) else {
            throw DecodeError.notJSON
        }
        // The array form is what a server sends. The bare-object form is
        // accepted too, so a plan pasted out of a tool that unwrapped it still
        // opens.
        let envelope: [String: Any]
        if let array = any as? [Any], let first = array.first as? [String: Any] {
            envelope = first
        } else if let object = any as? [String: Any] {
            envelope = object
        } else {
            throw DecodeError.noPlan
        }
        guard let plan = envelope["Plan"] as? [String: Any] else { throw DecodeError.noPlan }

        root = PlanNode(plan, path: "0")
        planningTimeMs = PlanNode.double(envelope["Planning Time"])
        executionTimeMs = PlanNode.double(envelope["Execution Time"])
    }

    // MARK: - The tree

    /// Every node, the root first, each node before its children (pre-order).
    /// This is the order the outline view shows fully expanded, so an index
    /// into it and a row on screen mean the same thing.
    var allNodes: [PlanNode] { root.allNodes }

    var nodeCount: Int { allNodes.count }

    /// Whether the plan carries measured numbers, not only estimates.
    var hasActuals: Bool { root.actualTotalTime != nil }

    /// The denominator for `PlanNode.share(of:)` — the sum of every node's own
    /// weight, so the shares of a whole plan add up to exactly 1. Taking the
    /// root's total instead would leave a remainder whenever a nested-loop
    /// inner node ran more than once, because that node's real cost is its
    /// per-loop figure multiplied by its loop count.
    var totalWeight: Double { allNodes.reduce(0) { $0 + $1.selfWeight } }

    /// The node that accounts for the most work on its own: the largest self
    /// time, or — for a plan with no ANALYZE numbers — the largest self cost.
    ///
    /// A tie is broken by position: the FIRST node in pre-order wins, so the
    /// same plan always selects the same row. `max(by:)` would return the last
    /// of several equal maxima, which makes the choice depend on sibling order.
    var slowestNode: PlanNode? {
        var best: PlanNode?
        for node in allNodes {
            if let current = best, node.selfWeight <= current.selfWeight { continue }
            best = node
        }
        return best
    }
}

/// One node of a query plan.
///
/// A class, not a struct: `NSOutlineView` addresses its items by identity, and
/// a tree of value types would have to be boxed for every row. Identity also
/// gives `QueryPlan.slowestNode` something the view can compare with `===`.
final class PlanNode {

    /// Position in the tree, as dot-separated child indexes from the root
    /// (`0`, `0.1`, `0.1.0`). Stable for as long as the plan exists, so it can
    /// name a node in a test or a log line without relying on the node's text.
    let path: String

    let nodeType: String
    let relationName: String?
    let alias: String?
    let indexName: String?
    let joinType: String?

    let startupCost: Double
    let totalCost: Double
    /// Estimated rows this node produces per loop.
    let planRows: Double
    let planWidth: Int

    /// Measured numbers. All `nil` without ANALYZE.
    let actualStartupTime: Double?
    /// Milliseconds for ONE loop. Multiply by `loops` for the real total.
    let actualTotalTime: Double?
    /// Measured rows produced per loop.
    let actualRows: Double?
    let actualLoops: Int?

    let sharedHitBlocks: Int?
    let sharedReadBlocks: Int?

    let filter: String?
    let indexCond: String?
    let hashCond: String?

    /// Every other key the server sent, as text — `Parallel Aware`, `Sort Key`,
    /// `Rows Removed by Filter`, whatever a newer server adds. Kept so the
    /// detail the app does not model is still visible instead of being lost.
    let extra: [String: String]

    let children: [PlanNode]

    /// Keys read into a named field above, plus the child list. Everything not
    /// in here lands in `extra`.
    private static let mappedKeys: Set<String> = [
        "Node Type", "Relation Name", "Alias", "Index Name", "Join Type",
        "Startup Cost", "Total Cost", "Plan Rows", "Plan Width",
        "Actual Startup Time", "Actual Total Time", "Actual Rows", "Actual Loops",
        "Shared Hit Blocks", "Shared Read Blocks",
        "Filter", "Index Cond", "Hash Cond",
        "Plans",
    ]

    init(_ object: [String: Any], path: String) {
        self.path = path
        nodeType = object["Node Type"] as? String ?? "Node"
        relationName = object["Relation Name"] as? String
        alias = object["Alias"] as? String
        indexName = object["Index Name"] as? String
        joinType = object["Join Type"] as? String

        startupCost = PlanNode.double(object["Startup Cost"]) ?? 0
        totalCost = PlanNode.double(object["Total Cost"]) ?? 0
        planRows = PlanNode.double(object["Plan Rows"]) ?? 0
        planWidth = PlanNode.int(object["Plan Width"]) ?? 0

        actualStartupTime = PlanNode.double(object["Actual Startup Time"])
        actualTotalTime = PlanNode.double(object["Actual Total Time"])
        actualRows = PlanNode.double(object["Actual Rows"])
        actualLoops = PlanNode.int(object["Actual Loops"])

        sharedHitBlocks = PlanNode.int(object["Shared Hit Blocks"])
        sharedReadBlocks = PlanNode.int(object["Shared Read Blocks"])

        filter = object["Filter"] as? String
        indexCond = object["Index Cond"] as? String
        hashCond = object["Hash Cond"] as? String

        var rest: [String: String] = [:]
        for (key, value) in object where !PlanNode.mappedKeys.contains(key) {
            if let text = PlanNode.text(value) { rest[key] = text }
        }
        extra = rest

        let subplans = object["Plans"] as? [Any] ?? []
        children = subplans.enumerated().compactMap { index, child in
            guard let child = child as? [String: Any] else { return nil }
            return PlanNode(child, path: "\(path).\(index)")
        }
    }

    // MARK: - Arithmetic

    /// How many times this node ran. `1` when the server did not say, which is
    /// also the right multiplier for a node that ran once.
    var loops: Int { actualLoops ?? 1 }

    /// Measured milliseconds for this node AND its subtree, across every loop.
    /// `nil` without ANALYZE.
    var totalTimeMs: Double? {
        guard let actualTotalTime else { return nil }
        return actualTotalTime * Double(loops)
    }

    /// Measured milliseconds spent in this node alone: its own total across
    /// every loop, less what its children took. `nil` without ANALYZE.
    var selfTimeMs: Double? {
        guard let total = totalTimeMs else { return nil }
        let childTime = children.reduce(0.0) { $0 + ($1.totalTimeMs ?? 0) }
        // A child can be reported as costing marginally more than its parent
        // (rounding, or a parallel worker's clock). Clamping keeps a share
        // non-negative instead of letting one node's noise subtract from the
        // whole plan.
        return max(0, total - childTime)
    }

    /// Estimated cost of this node alone, the same subtraction as `selfTimeMs`.
    var selfCost: Double {
        let childCost = children.reduce(0.0) { $0 + $1.totalCost }
        return max(0, totalCost - childCost)
    }

    /// What `share(of:)` measures: self time when the plan was analyzed, and
    /// self cost when it was not. One number so a plan with estimates only
    /// still ranks its nodes.
    var selfWeight: Double { selfTimeMs ?? selfCost }

    /// This node's fraction of the whole plan, in `0...1`.
    /// `total` is `QueryPlan.totalWeight`.
    func share(of total: Double) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, selfWeight / total))
    }

    /// This node and all its descendants, this node first (pre-order).
    var allNodes: [PlanNode] { [self] + children.flatMap(\.allNodes) }

    // MARK: - Display

    /// "Index Scan using users_pkey on users u" — the node type, then whatever
    /// of the index, the relation and a differing alias the node carries.
    var displayName: String {
        var text = nodeType
        if let indexName, !indexName.isEmpty { text += " using \(indexName)" }
        if let relationName, !relationName.isEmpty {
            text += " on \(relationName)"
            if let alias, !alias.isEmpty, alias != relationName { text += " \(alias)" }
        } else if let alias, !alias.isEmpty {
            text += " on \(alias)"
        }
        return text
    }

    /// The conditions worth showing in a tooltip, labelled, in a fixed order.
    var conditions: [(label: String, text: String)] {
        var out: [(label: String, text: String)] = []
        if let indexCond, !indexCond.isEmpty { out.append((String(localized: "Index Cond"), indexCond)) }
        if let hashCond, !hashCond.isEmpty { out.append((String(localized: "Hash Cond"), hashCond)) }
        if let filter, !filter.isEmpty { out.append((String(localized: "Filter"), filter)) }
        return out
    }

    // MARK: - JSON scalars

    /// A JSON number as a `Double`. `NSNumber` covers both the integer and the
    /// fractional forms `JSONSerialization` produces; a numeric string is
    /// accepted too, because some tools quote these values.
    static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    /// One `extra` value as text. Scalars and arrays of scalars only — a nested
    /// object is skipped rather than printed as a Swift dictionary description.
    private static func text(_ value: Any) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber {
            // `JSONSerialization` returns booleans as NSNumber too; tell them
            // apart by the underlying ObjC type so `true` does not read as `1`.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            if number.doubleValue == number.doubleValue.rounded(), abs(number.doubleValue) < 1e15 {
                return String(number.intValue)
            }
            return String(number.doubleValue)
        }
        if let array = value as? [Any] {
            let parts = array.compactMap { text($0) }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
        return nil
    }
}
