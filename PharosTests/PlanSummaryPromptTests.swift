// Standalone test runner for PlanSummaryPrompt — the text a query plan is
// turned into before the on-device model reads it.
//
// Compiled with QueryPlan only: pure Foundation, no AppKit and no
// FoundationModels. What the model answers cannot be tested; WHICH nodes it is
// shown and WHAT of each node it is shown can be, and those are the two things
// that decide whether the summary is about the right steps — and the two that
// would silently leak a key nobody meant to send.
//
// The fixtures are hand-written in the shape a real server sends, in the style
// of PharosTests/QueryPlanTests.swift: a one-element array, keys with spaces
// and initial capitals, children under "Plans".
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

// MARK: - Fixtures

/// 25 nodes: a Limit over a Sort over 23 leaf scans.
///
/// Every self cost is distinct and known by construction, so the expected
/// ranking can be written down rather than computed by the same arithmetic the
/// code under test uses:
///
///   Sort        30000 − 27600 = 2400   (the heaviest)
///   scan_23 … scan_01   2300 … 100
///   Limit       30100 − 30000 = 100
///
/// The top twenty are therefore Sort and scan_23 … scan_05. Limit and
/// scan_01 … scan_04 are the five left out.
///
/// Two of the leaves carry keys the app does not model — `Parallel Aware`,
/// `Rows Removed by Filter` — and the Sort carries `Sort Key`. All three land
/// in `PlanNode.extra`, and none of them may appear in the prompt.
private let twentyFiveNodePlan: String = {
    var leaves: [String] = []
    for index in 1...23 {
        let cost = Double(index) * 100
        let extra = index == 7
            ? #""Parallel Aware": true, "Rows Removed by Filter": 4321,"#
            : ""
        leaves.append("""
            {
              "Node Type": "Seq Scan",
              "Relation Name": "scan_\(String(format: "%02d", index))",
              \(extra)
              "Startup Cost": 0.00,
              "Total Cost": \(String(format: "%.2f", cost)),
              "Plan Rows": \(index * 10),
              "Plan Width": 8
            }
            """)
    }
    return """
        [
          {
            "Plan": {
              "Node Type": "Limit",
              "Startup Cost": 0.00,
              "Total Cost": 30100.00,
              "Plan Rows": 100,
              "Plan Width": 8,
              "Plans": [
                {
                  "Node Type": "Sort",
                  "Sort Key": ["scan_01.id"],
                  "Startup Cost": 100.00,
                  "Total Cost": 30000.00,
                  "Plan Rows": 1000,
                  "Plan Width": 8,
                  "Plans": [\(leaves.joined(separator: ",\n"))]
                }
              ]
            },
            "Planning Time": 0.42
          }
        ]
        """
}()

/// Three nodes, explained WITH ANALYZE, built so cost and time disagree.
///
/// `slow_by_time` took 90 ms but costs 10; `cheap_by_time` took 1 ms but costs
/// 5000. Ranked by cost the expensive-but-fast scan would come first. Ranked
/// by the measured self time — which is what a plan with actuals must be
/// ranked by — `slow_by_time` comes first.
private let analyzedPlan = """
    [
      {
        "Plan": {
          "Node Type": "Hash Join",
          "Join Type": "Inner",
          "Startup Cost": 10.00,
          "Total Cost": 6000.00,
          "Plan Rows": 500,
          "Plan Width": 16,
          "Actual Startup Time": 1.00,
          "Actual Total Time": 100.00,
          "Actual Rows": 480,
          "Actual Loops": 1,
          "Hash Cond": "(a.id = b.a_id)",
          "Plans": [
            {
              "Node Type": "Seq Scan",
              "Relation Name": "slow_by_time",
              "Startup Cost": 0.00,
              "Total Cost": 10.00,
              "Plan Rows": 100,
              "Plan Width": 8,
              "Actual Startup Time": 0.01,
              "Actual Total Time": 90.00,
              "Actual Rows": 104,
              "Actual Loops": 1,
              "Filter": "(state = 'open'::text)"
            },
            {
              "Node Type": "Seq Scan",
              "Relation Name": "cheap_by_time",
              "Startup Cost": 0.00,
              "Total Cost": 5000.00,
              "Plan Rows": 900,
              "Plan Width": 8,
              "Actual Startup Time": 0.01,
              "Actual Total Time": 1.00,
              "Actual Rows": 880,
              "Actual Loops": 1
            }
          ]
        },
        "Planning Time": 0.30,
        "Execution Time": 101.20
      }
    ]
    """

// MARK: - Helpers

private func decode(_ json: String, _ name: String) -> QueryPlan? {
    do { return try QueryPlan(json: json) } catch {
        failures += 1
        print("FAIL \(name) — the fixture did not decode: \(error)")
        return nil
    }
}

/// The numbered node lines of a prompt, in order.
private func nodeLines(of prompt: String) -> [String] {
    prompt.split(separator: "\n").map(String.init).filter { line in
        guard let dot = line.firstIndex(of: ".") else { return false }
        let head = line[line.startIndex..<dot]
        return !head.isEmpty && head.allSatisfy(\.isNumber)
    }
}

// MARK: - Tests

private func testOnlyTwentyNodesAppear() {
    guard let plan = decode(twentyFiveNodePlan, "25-node fixture") else { return }
    expectEqual(plan.nodeCount, 25, "the fixture really has 25 nodes")

    let prompt = PlanSummaryPrompt.build(plan: plan)
    let lines = nodeLines(of: prompt)
    expectEqual(lines.count, 20, "only twenty node lines appear")
    expectEqual(PlanSummaryPrompt.rankedNodes(of: plan).count, 20, "only twenty nodes are ranked")
    expect(prompt.contains("25 nodes"), "the head still states the real node count")
}

private func testTheSlowestNodeIsFirst() {
    guard let plan = decode(twentyFiveNodePlan, "25-node fixture") else { return }
    let lines = nodeLines(of: PlanSummaryPrompt.build(plan: plan))
    guard let first = lines.first else { return }

    expect(first.hasPrefix("1. Sort:"), "the heaviest node is first", first)
    expect(lines.count > 1 && lines[1].contains("scan_23"), "the next heaviest is second",
           lines.count > 1 ? lines[1] : "")
    expect(lines.last?.contains("scan_05") ?? false, "the twentieth is the lightest one kept",
           lines.last ?? "")
}

private func testTheOrderIsByWeightDescending() {
    guard let plan = decode(twentyFiveNodePlan, "25-node fixture") else { return }
    let ranked = PlanSummaryPrompt.rankedNodes(of: plan)
    let weights = ranked.map(\.selfWeight)
    expect(zip(weights, weights.dropFirst()).allSatisfy { $0 >= $1 },
           "the nodes are ordered heaviest first", "\(weights)")
}

private func testTheCheapNodesAreLeftOut() {
    guard let plan = decode(twentyFiveNodePlan, "25-node fixture") else { return }
    let prompt = PlanSummaryPrompt.build(plan: plan)
    for index in 1...4 {
        let name = "scan_\(String(format: "%02d", index))"
        expect(!prompt.contains("\(name):"), "\(name) is below the cut and is not sent")
    }
    expect(!prompt.contains("Limit:"), "the root is below the cut too and is not sent")
}

private func testNoUnmodelledKeyReachesThePrompt() {
    guard let plan = decode(twentyFiveNodePlan, "25-node fixture") else { return }
    let prompt = PlanSummaryPrompt.build(plan: plan)

    // These three are in the fixture and are held in `PlanNode.extra`. A
    // prompt builder that printed `extra` would carry all of them.
    for key in ["Parallel Aware", "Sort Key", "Rows Removed by Filter", "4321"] {
        expect(!prompt.contains(key), "\(key) does not reach the prompt")
    }

    // And what IS allowed is there, so the test above is not passing because
    // the prompt is empty.
    expect(prompt.contains("Seq Scan on scan_23"), "the node type and relation are sent")
    expect(prompt.contains("cost 0.00..2300.00"), "the costs are sent")
    expect(prompt.contains("rows 230 est"), "the row estimate is sent")
}

private func testAnalyzedPlanUsesActualTime() {
    guard let plan = decode(analyzedPlan, "analyzed fixture") else { return }
    expect(plan.hasActuals, "the fixture carries measured numbers")

    let prompt = PlanSummaryPrompt.build(plan: plan)
    expect(prompt.contains("measured"), "the head says the plan was run")
    expect(prompt.contains("Execution 101.20 ms") || prompt.contains("Execution 101 ms"),
           "the head carries the execution time", prompt.split(separator: "\n").first.map(String.init) ?? "")

    let lines = nodeLines(of: prompt)
    expectEqual(lines.count, 3, "all three nodes fit under the cap")
    expect(lines.first?.contains("slow_by_time") ?? false,
           "the slowest BY TIME is first, although it is the cheapest by cost", lines.first ?? "")
    expect(lines.first?.contains("90 ms") ?? false,
           "the node's own measured time is on its line", lines.first ?? "")
    expect(lines.contains { $0.contains("cheap_by_time") && $0.contains("cost 0.00..5000.00") },
           "the expensive-by-cost node is still described, further down")
}

private func testConditionsAreSentWithTheServersOwnLabels() {
    guard let plan = decode(analyzedPlan, "analyzed fixture") else { return }
    let prompt = PlanSummaryPrompt.build(plan: plan)
    expect(prompt.contains("Filter: (state = 'open'::text)"), "a filter is sent, labelled")
    expect(prompt.contains("Hash Cond: (a.id = b.a_id)"), "a hash condition is sent, labelled")
}

private func testEstimateOnlyPlanSaysSo() {
    guard let plan = decode(twentyFiveNodePlan, "25-node fixture") else { return }
    let prompt = PlanSummaryPrompt.build(plan: plan)
    expect(!plan.hasActuals, "the fixture has estimates only")
    expect(prompt.contains("estimates and costs only"), "the head says the plan was not run")
    expect(!prompt.contains(" ms,"), "no node line claims a time it does not have")
}

// MARK: - Entry point

func runTests() {
    testOnlyTwentyNodesAppear()
    testTheSlowestNodeIsFirst()
    testTheOrderIsByWeightDescending()
    testTheCheapNodesAreLeftOut()
    testNoUnmodelledKeyReachesThePrompt()
    testAnalyzedPlanUsesActualTime()
    testConditionsAreSentWithTheServersOwnLabels()
    testEstimateOnlyPlanSaysSo()

    print(failures == 0 ? "\nAll tests passed." : "\n\(failures) test(s) failed.")
    exit(failures == 0 ? 0 : 1)
}
