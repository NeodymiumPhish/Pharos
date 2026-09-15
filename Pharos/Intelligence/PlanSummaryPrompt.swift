import Foundation

/// Turns a decoded query plan into the text the model is given.
///
/// Pure Foundation, and the only part of the plan-summary feature that can be
/// tested without the model — which is where the two things that matter live:
/// WHICH nodes are sent, and WHAT of each node is sent.
///
/// A plan of a few hundred nodes would fill the context window with the cheap
/// end of the tree, where nothing interesting happens, so only the twenty most
/// expensive go in. "Most expensive" is measured the way the plan view measures
/// it — self time where the statement was run under ANALYZE, self cost where it
/// was only estimated — so the list the model reads is ordered the same way the
/// outline's share bars are drawn.
///
/// Each line carries names and numbers and nothing else: the node type, the
/// relation, the index, the row counts, the time, the cost and the conditions
/// the planner printed. Every other key the server sent is held in
/// `PlanNode.extra` and is deliberately left out — a plan is metadata, but
/// there is no reason to spend context on `Parallel Aware`.
enum PlanSummaryPrompt {

    /// How many nodes are described. Twenty covers the expensive end of every
    /// plan anyone reads by hand.
    static let maxNodes = 20

    /// The instructions this feature appends after
    /// `IntelligenceInstructions.sqlSafety`.
    static let instructions = """
        Explain a PostgreSQL query plan to the analyst who ran it. Say where \
        the time or the cost went, in plain sentences. Name a step by its node \
        type and its relation. Do not invent numbers that are not in the plan.
        """

    /// The prompt for one plan.
    static func build(plan: QueryPlan) -> String {
        var lines: [String] = []

        var head = "A PostgreSQL query plan, \(plan.nodeCount) nodes."
        if let planning = plan.planningTimeMs {
            head += " Planning \(number(planning)) ms."
        }
        if let execution = plan.executionTimeMs {
            head += " Execution \(number(execution)) ms."
        }
        head += plan.hasActuals
            ? " The plan was run, so the times are measured."
            : " The plan was not run, so there are estimates and costs only."
        lines.append(head)

        let ranked = rankedNodes(of: plan)
        lines.append("The \(ranked.count) most expensive steps, the most expensive first:")
        for (index, node) in ranked.enumerated() {
            lines.append("\(index + 1). \(line(for: node, hasActuals: plan.hasActuals))")
        }
        return lines.joined(separator: "\n")
    }

    /// The nodes that go in the prompt: heaviest first, at most `maxNodes`.
    ///
    /// The sort is made stable by hand. `sorted(by:)` is not stable, and a plan
    /// where several nodes weigh exactly the same — which is every
    /// estimate-only plan with repeated scans — would otherwise put them in an
    /// order that changes between runs, so the same plan would produce two
    /// different prompts.
    static func rankedNodes(of plan: QueryPlan) -> [PlanNode] {
        plan.allNodes.enumerated()
            .sorted { left, right in
                if left.element.selfWeight != right.element.selfWeight {
                    return left.element.selfWeight > right.element.selfWeight
                }
                return left.offset < right.offset
            }
            .prefix(maxNodes)
            .map(\.element)
    }

    /// One node, as "Seq Scan on pg_class: rows 400 est, 1.20 ms, cost
    /// 0.00..18.10, Filter: (relkind = 'r')".
    static func line(for node: PlanNode, hasActuals: Bool) -> String {
        var parts: [String] = []

        var rows = "rows \(number(node.planRows)) est"
        if let actual = node.actualRows {
            rows += "/\(number(actual)) actual"
            if node.loops > 1 { rows += " ×\(node.loops)" }
        }
        parts.append(rows)

        // Self time, not total: the list is ranked by what the node itself
        // cost, so the number beside it must be the same measure or the order
        // reads as wrong.
        if hasActuals, let selfTime = node.selfTimeMs {
            parts.append("\(number(selfTime)) ms")
        }

        parts.append("cost \(cost(node.startupCost))..\(cost(node.totalCost))")

        // The server's own key names, not `PlanNode.conditions` — those are
        // localised for the outline's tooltip, and a prompt written in English
        // must not carry three labels in the user's language.
        for (label, text) in [
            ("Index Cond", node.indexCond),
            ("Hash Cond", node.hashCond),
            ("Filter", node.filter),
        ] {
            if let text, !text.isEmpty { parts.append("\(label): \(text)") }
        }

        return "\(node.displayName): \(parts.joined(separator: ", "))"
    }

    // MARK: - Numbers

    /// Plain ASCII digits with a fixed number of places. Not
    /// `FormatStyle.number`: a prompt is not display text, and a locale that
    /// groups with a thin space or writes the decimal with a comma would make
    /// two of the model's numbers out of one.
    private static func number(_ value: Double) -> String {
        String(format: value < 10 ? "%.2f" : "%.0f", value)
    }

    private static func cost(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
