// Standalone test runner for QueryPlan. Not part of the app target — compiled
// together with the implementation by scripts/test-query-plan.sh.
//
// The fixtures are hand-written in the shape a real PostgreSQL server sends:
// a one-element array, keys with spaces and initial capitals, children under
// "Plans". Nothing here is a Swift model re-encoded — the point of the suite is
// the decode of the server's own document, and the arithmetic the plan view
// draws on top of it.
import Foundation

var failures = 0

func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition { print("PASS \(name)") } else {
        failures += 1
        let extra = detail()
        print("FAIL \(name)" + (extra.isEmpty ? "" : "\n  \(extra)"))
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    expect(actual == expected, name, "expected: \(expected)\n  actual:   \(actual)")
}

/// Doubles are compared with a tolerance: every number here comes out of a JSON
/// decimal, and an exact `==` on those would be testing IEEE754, not the plan.
func expectClose(_ actual: Double?, _ expected: Double, _ name: String, tolerance: Double = 1e-9) {
    guard let actual else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   nil")
        return
    }
    expect(abs(actual - expected) <= tolerance, name, "expected: \(expected)\n  actual:   \(actual)")
}

// MARK: - Fixtures

/// 1. A bare sequential scan, explained WITHOUT ANALYZE: costs and estimates
///    only, no children. The shape a plain ⇧⌘E produces most often.
private let seqScanPlan = """
[
  {
    "Plan": {
      "Node Type": "Seq Scan",
      "Parallel Aware": false,
      "Relation Name": "users",
      "Alias": "u",
      "Startup Cost": 0.00,
      "Total Cost": 18.10,
      "Plan Rows": 810,
      "Plan Width": 36,
      "Filter": "(active = true)",
      "Output": ["id", "email"]
    },
    "Planning Time": 0.123
  }
]
"""

/// 2. A hash join with two children (one of which has a child of its own),
///    explained WITH ANALYZE: actual times, actual rows, buffers.
private let hashJoinPlan = """
[
  {
    "Plan": {
      "Node Type": "Hash Join",
      "Join Type": "Inner",
      "Startup Cost": 1.09,
      "Total Cost": 39.55,
      "Plan Rows": 1200,
      "Plan Width": 68,
      "Actual Startup Time": 0.050,
      "Actual Total Time": 10.000,
      "Actual Rows": 1187,
      "Actual Loops": 1,
      "Hash Cond": "(o.user_id = u.id)",
      "Shared Hit Blocks": 40,
      "Shared Read Blocks": 2,
      "Plans": [
        {
          "Node Type": "Seq Scan",
          "Parent Relationship": "Outer",
          "Relation Name": "orders",
          "Alias": "o",
          "Startup Cost": 0.00,
          "Total Cost": 25.00,
          "Plan Rows": 1200,
          "Plan Width": 40,
          "Actual Startup Time": 0.010,
          "Actual Total Time": 6.000,
          "Actual Rows": 1200,
          "Actual Loops": 1
        },
        {
          "Node Type": "Hash",
          "Parent Relationship": "Inner",
          "Startup Cost": 1.04,
          "Total Cost": 1.04,
          "Plan Rows": 4,
          "Plan Width": 32,
          "Actual Startup Time": 0.020,
          "Actual Total Time": 1.000,
          "Actual Rows": 4,
          "Actual Loops": 1,
          "Plans": [
            {
              "Node Type": "Seq Scan",
              "Parent Relationship": "Outer",
              "Relation Name": "users",
              "Alias": "u",
              "Startup Cost": 0.00,
              "Total Cost": 1.04,
              "Plan Rows": 4,
              "Plan Width": 32,
              "Actual Startup Time": 0.005,
              "Actual Total Time": 0.500,
              "Actual Rows": 4,
              "Actual Loops": 1
            }
          ]
        }
      ]
    },
    "Planning Time": 0.250,
    "Execution Time": 10.500
  }
]
"""

/// 3. A nested loop whose inner Index Scan ran 100 times. This is the fixture
///    that separates "actual total time" from "time this node really spent":
///    the index scan reports 0.150 ms per loop, so the honest figure is 15 ms —
///    three quarters of the whole plan and by far the slowest node. Read
///    per-loop instead, it would look like the cheapest node in the tree and
///    the Nested Loop would be reported as the slowest, so no assertion below
///    can pass under both rules.
private let nestedLoopPlan = """
[
  {
    "Plan": {
      "Node Type": "Nested Loop",
      "Join Type": "Inner",
      "Startup Cost": 0.29,
      "Total Cost": 120.50,
      "Plan Rows": 300,
      "Plan Width": 44,
      "Actual Startup Time": 0.040,
      "Actual Total Time": 20.000,
      "Actual Rows": 300,
      "Actual Loops": 1,
      "Plans": [
        {
          "Node Type": "Seq Scan",
          "Parent Relationship": "Outer",
          "Relation Name": "teams",
          "Alias": "t",
          "Startup Cost": 0.00,
          "Total Cost": 4.00,
          "Plan Rows": 100,
          "Plan Width": 8,
          "Actual Startup Time": 0.008,
          "Actual Total Time": 2.000,
          "Actual Rows": 100,
          "Actual Loops": 1
        },
        {
          "Node Type": "Index Scan",
          "Parent Relationship": "Inner",
          "Relation Name": "members",
          "Alias": "m",
          "Index Name": "members_team_id_idx",
          "Index Cond": "(m.team_id = t.id)",
          "Startup Cost": 0.29,
          "Total Cost": 1.10,
          "Plan Rows": 3,
          "Plan Width": 36,
          "Actual Startup Time": 0.005,
          "Actual Total Time": 0.150,
          "Actual Rows": 3,
          "Actual Loops": 100
        }
      ]
    },
    "Planning Time": 0.300,
    "Execution Time": 20.800
  }
]
"""

/// 4. A two-node plan with no ANALYZE numbers at all, so the ranking has only
///    costs to work with. The single-node fixture above cannot tell a working
///    fallback from a broken one — with one node every rule names the same
///    "slowest" — so the fallback gets a tree of its own, with the larger self
///    cost deliberately on the CHILD.
private let costOnlyPlan = """
[
  {
    "Plan": {
      "Node Type": "Sort",
      "Startup Cost": 30.00,
      "Total Cost": 32.00,
      "Plan Rows": 810,
      "Plan Width": 36,
      "Sort Key": ["u.email", "u.id"],
      "Plans": [
        {
          "Node Type": "Seq Scan",
          "Parent Relationship": "Outer",
          "Relation Name": "users",
          "Alias": "u",
          "Startup Cost": 0.00,
          "Total Cost": 25.00,
          "Plan Rows": 810,
          "Plan Width": 36
        }
      ]
    },
    "Planning Time": 0.080
  }
]
"""

// MARK: - Helpers

private func decode(_ json: String, _ name: String) -> QueryPlan? {
    do {
        return try QueryPlan(json: json)
    } catch {
        failures += 1
        print("FAIL \(name) did not decode\n  \(error)")
        return nil
    }
}

/// Every node's share must add up to the whole, or the bar column is lying
/// about proportions.
private func expectSharesSumToOne(_ plan: QueryPlan, _ name: String) {
    let total = plan.totalWeight
    let sum = plan.allNodes.reduce(0.0) { $0 + $1.share(of: total) }
    expectClose(sum, 1.0, name, tolerance: 1e-9)
}

func runTests() {

    // MARK: 1. A seq scan with estimates only

    if let plan = decode(seqScanPlan, "seq scan") {
        expectEqual(plan.nodeCount, 1, "a bare seq scan is one node")
        expectEqual(plan.root.nodeType, "Seq Scan", "the node type is read from `Node Type`")
        expectEqual(plan.root.relationName, "users", "the relation name is read")
        expectEqual(plan.root.alias, "u", "the alias is read")
        expectEqual(plan.root.displayName, "Seq Scan on users u", "the display name names the relation and its alias")
        expectEqual(plan.root.filter, "(active = true)", "the filter is read")
        expectClose(plan.root.totalCost, 18.10, "the total cost is read")
        expectClose(plan.root.planRows, 810, "the estimated rows are read")
        expectEqual(plan.root.planWidth, 36, "the plan width is read")
        expectClose(plan.planningTimeMs, 0.123, "planning time is read")
        expect(plan.executionTimeMs == nil, "no ANALYZE means no execution time")
        expect(!plan.hasActuals, "no ANALYZE means no actuals")
        expect(plan.root.actualTotalTime == nil, "the node carries no measured time")
        expect(plan.root.selfTimeMs == nil, "self time is unavailable without actuals")

        // Unmodelled keys survive; modelled ones do not appear twice.
        expectEqual(plan.root.extra["Parallel Aware"], "false", "a boolean extra reads as true/false, not 1/0")
        expectEqual(plan.root.extra["Output"], "id, email", "an array extra is joined")
        expect(plan.root.extra["Node Type"] == nil, "a mapped key is not repeated in `extra`")
        expect(plan.root.extra["Filter"] == nil, "a mapped key is not repeated in `extra`")

        // With one node, that node is the whole plan.
        expect(plan.slowestNode === plan.root, "the only node is the slowest node")
        expectClose(plan.totalWeight, 18.10, "the weight of a lone node is its cost")
        expectClose(plan.root.share(of: plan.totalWeight), 1.0, "a lone node is the whole plan")
        expectSharesSumToOne(plan, "seq scan shares sum to 1")

        // The tooltip line.
        expectEqual(plan.root.conditions.count, 1, "one condition on this node")
        expectEqual(plan.root.conditions.first?.text, "(active = true)", "and it is the filter")
    }

    // MARK: 2. A hash join with actuals

    if let plan = decode(hashJoinPlan, "hash join") {
        expectEqual(plan.nodeCount, 4, "the join, its two children, and the hash's own child")
        expect(plan.hasActuals, "ANALYZE means actuals")
        expectClose(plan.executionTimeMs, 10.500, "execution time is read")
        expectClose(plan.planningTimeMs, 0.250, "planning time is read")

        // Pre-order is the order a fully expanded outline shows.
        expectEqual(plan.allNodes.map(\.path), ["0", "0.0", "0.1", "0.1.0"], "pre-order paths")
        expectEqual(plan.allNodes.map(\.nodeType),
                    ["Hash Join", "Seq Scan", "Hash", "Seq Scan"],
                    "pre-order node types")

        let root = plan.root
        let orders = plan.allNodes[1]
        let hash = plan.allNodes[2]
        let usersScan = plan.allNodes[3]

        expectEqual(root.hashCond, "(o.user_id = u.id)", "the hash condition is read")
        expectEqual(root.joinType, "Inner", "the join type is read")
        expectEqual(root.sharedHitBlocks, 40, "shared hit blocks are read")
        expectEqual(root.sharedReadBlocks, 2, "shared read blocks are read")
        expectClose(root.actualRows, 1187, "actual rows are read")
        expectEqual(root.actualLoops, 1, "actual loops are read")

        // Self time = own total, less what the children took.
        expectClose(root.selfTimeMs, 3.0, "the join's own time is 10 less its children's 6 + 1")
        expectClose(orders.selfTimeMs, 6.0, "a leaf's self time is its total")
        expectClose(hash.selfTimeMs, 0.5, "the hash node's own time is 1 less its child's 0.5")
        expectClose(usersScan.selfTimeMs, 0.5, "the inner leaf's self time is its total")

        expectClose(plan.totalWeight, 10.0, "the self times add up to the root's total")
        expect(plan.slowestNode === orders, "the outer Seq Scan is the slowest node by self time")
        expectClose(orders.share(of: plan.totalWeight), 0.6, "and it is 60% of the plan")
        expectClose(root.share(of: plan.totalWeight), 0.3, "the join itself is 30%")
        expectSharesSumToOne(plan, "hash join shares sum to 1")

        // The rule being excluded is "rank by the reported total". By that rule
        // the join (10 ms, the whole plan) would be named the slowest node, so
        // the fixture separates it from "rank by self time".
        expect((root.totalTimeMs ?? 0) > (orders.totalTimeMs ?? 0),
               "the join's TOTAL time is the largest, so naming the scan proves the rank is by SELF time")
    }

    // MARK: 3. A nested loop whose inner scan ran many times

    if let plan = decode(nestedLoopPlan, "nested loop") {
        expectEqual(plan.nodeCount, 3, "the loop and its two children")
        let root = plan.root
        let teams = plan.allNodes[1]
        let members = plan.allNodes[2]

        expectEqual(members.nodeType, "Index Scan", "the inner node is an index scan")
        expectEqual(members.indexName, "members_team_id_idx", "the index name is read")
        expectEqual(members.displayName, "Index Scan using members_team_id_idx on members m",
                    "the display name names the index, the relation and the alias")
        expectEqual(members.indexCond, "(m.team_id = t.id)", "the index condition is read")
        expectEqual(members.loops, 100, "the loop count is read")

        // The whole point of the fixture: per-loop times are multiplied out.
        expectClose(members.actualTotalTime, 0.150, "the server reports time PER LOOP")
        expectClose(members.totalTimeMs, 15.0, "which is 15 ms across 100 loops")
        expectClose(members.selfTimeMs, 15.0, "a leaf's self time is that same total")
        expectClose(teams.selfTimeMs, 2.0, "the outer scan ran once")
        expectClose(root.selfTimeMs, 3.0, "the loop's own time is 20 less 2 + 15")

        expectClose(plan.totalWeight, 20.0, "the self times add up to the root's total")
        expect(plan.slowestNode === members, "the index scan is the slowest node once its loops are counted")
        expectClose(members.share(of: plan.totalWeight), 0.75, "and it is three quarters of the plan")
        expectSharesSumToOne(plan, "nested loop shares sum to 1")

        // Under the per-loop reading the loop node would take 20 - 2 - 0.15 =
        // 17.85 and be named the slowest. Assert the number that rule produces
        // is NOT what came out, so the test cannot pass under it.
        expect(abs((root.selfTimeMs ?? 0) - 17.85) > 1e-6,
               "the loop's self time must not be computed from a per-loop child figure")
    }

    // MARK: 4. Cost-only fallback, with a tree to rank

    if let plan = decode(costOnlyPlan, "cost only") {
        expectEqual(plan.nodeCount, 2, "a sort over a scan")
        expect(!plan.hasActuals, "no ANALYZE anywhere in the tree")
        let sort = plan.root
        let scan = plan.allNodes[1]

        expectClose(sort.selfCost, 7.0, "the sort's own cost is 32 less the scan's 25")
        expectClose(scan.selfCost, 25.0, "the scan's own cost is its total")
        expectClose(sort.selfWeight, 7.0, "with no actuals the weight IS the self cost")
        expectClose(scan.selfWeight, 25.0, "with no actuals the weight IS the self cost")

        expectClose(plan.totalWeight, 32.0, "the self costs add up to the root's cost")
        expect(plan.slowestNode === scan, "the child wins on self cost, even though the root's TOTAL is larger")
        expectClose(scan.share(of: plan.totalWeight), 25.0 / 32.0, "its share is its cost over the whole")
        expectSharesSumToOne(plan, "cost-only shares sum to 1")

        expectEqual(sort.extra["Sort Key"], "u.email, u.id", "the sort key survives as an extra")
    }

    // MARK: Malformed input

    expect((try? QueryPlan(json: "not json at all")) == nil, "text that is not JSON is refused")
    expect((try? QueryPlan(json: "[]")) == nil, "an empty array carries no plan")
    expect((try? QueryPlan(json: "[{\"Planning Time\": 1.0}]")) == nil, "an envelope with no Plan is refused")
    // The bare-object form a tool may have unwrapped still opens.
    expect((try? QueryPlan(json: "{\"Plan\":{\"Node Type\":\"Result\",\"Total Cost\":0.01}}")) != nil,
           "a bare envelope object is accepted")

    print(failures == 0 ? "\nAll tests passed." : "\n\(failures) test(s) failed.")
    if failures > 0 { exit(1) }
}
