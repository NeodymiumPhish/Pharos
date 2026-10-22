// Standalone test for VariableManagerVC and VariableConnectionsView —
// compiled by scripts/test-variable-manager.sh. Headless AppKit: a never-shown
// borderless window, two layout passes, as the panel harness does.
import AppKit

private var failures = 0
private func expect<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

@MainActor
private final class Host {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 560), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    let vc = VariableManagerVC()
    var written: [[QueryVariable]] = []

    init(_ variables: [QueryVariable]) {
        vc.onChange = { [unowned self] in self.written.append($0) }
        vc.choicesProvider = { _ in [
            .init(id: "prod", name: "Prod", place: "app on db:5432", kind: .server, state: .connected, missing: false),
            .init(id: "sales", name: "sales", place: "~/sales.duckdb", kind: .file, state: .disconnected, missing: false),
        ] }
        window.contentView = vc.view
        vc.setVariables(variables)
        layout()
    }

    func layout() {
        vc.view.layoutSubtreeIfNeeded()
        vc.view.needsLayout = true
        vc.view.layoutSubtreeIfNeeded()
    }

    var last: [QueryVariable] { written.last ?? vc.variables }
}

@MainActor
private func testManager() {
    let env = QueryVariable(name: "env", value: "prod")
    let limit = QueryVariable(name: "limit", value: "50", type: .number)
    let host = Host([env, limit])

    expect(host.vc.selectedId, nil, "nothing selected at first")
    host.vc.select(env.id)
    expect(host.vc.selectedId, env.id, "a row opens in the detail pane")
    expect(host.vc.detailVC?.variable.name, "env", "the detail shows that variable")

    // Linking: choosing "Only these" with nothing ticked keeps it global.
    host.vc.connectionsView.chooseSome()
    expect(host.vc.variables.first { $0.id == env.id }?.connectionIds, [], "no box ticked yet: still global")
    host.vc.connectionsView.tick("prod", true)
    expect(host.last.first { $0.id == env.id }?.connectionIds, ["prod"], "ticking a connection links the variable")
    host.vc.connectionsView.tick("sales", true)
    expect(host.last.first { $0.id == env.id }?.connectionIds, ["prod", "sales"], "and a second one")

    // A value edit in the detail pane keeps the links set since it opened.
    var edited = host.vc.detailVC!.variable
    edited.value = "staging"
    host.vc.detailVC!.onChange?(edited)
    let after = host.last.first { $0.id == env.id }
    expect(after?.value, "staging", "the value edit lands")
    expect(after?.connectionIds, ["prod", "sales"], "and the links are not lost to the detail pane's copy")

    host.vc.connectionsView.chooseAll()
    expect(host.last.first { $0.id == env.id }?.connectionIds, [], "All connections clears the links")
    expect(host.vc.connectionsView.isGlobalChosen, true, "and the radio says so")

    // Another row re-reads its own links.
    host.vc.select(limit.id)
    expect(host.vc.connectionsView.tickedIds, [], "a global variable has nothing ticked")

    // + adds a row and opens it; leaving it empty drops it.
    host.vc.addVariable()
    let added = host.vc.selectedId
    expect(added != nil && added != limit.id, true, "+ opens a new row")
    expect(host.vc.variables.count, 3, "with a third variable")
    host.vc.select(env.id)
    expect(host.vc.variables.count, 2, "an abandoned empty row is dropped on leaving it")

    // A token click: an existing name opens; a new one is made.
    host.vc.openVariable(named: "limit")
    expect(host.vc.selectedId, limit.id, "an existing name opens its variable")
    host.vc.openVariable(named: "region")
    expect(host.vc.detailVC?.variable.name, "region", "a new name makes a variable with it")
    expect(host.vc.variables.count, 3, "added to the list")

    // Delete: the detail pane closes.
    host.vc.deleteVariable(host.vc.selectedId!)
    expect(host.vc.selectedId, nil, "deleting the open variable closes the detail")
    expect(host.vc.variables.map(\.name), ["env", "limit"], "and removes it")

    // Another window's edit: the selection stays when its variable is still there.
    host.vc.select(limit.id)
    var external = host.vc.variables
    external[0].value = "changed elsewhere"
    host.vc.setVariables(external)
    expect(host.vc.selectedId, limit.id, "an outside edit keeps the selection")
    expect(host.vc.variables[0].value, "changed elsewhere", "and adopts the edit")
}

@MainActor
private func testMissingChoice() {
    let view = VariableConnectionsView(frame: NSRect(x: 0, y: 0, width: 400, height: 220))
    var heard: [[String]] = []
    view.onChange = { heard.append($0) }
    view.show(choices: [.init(id: "gone", name: "", place: "", kind: .file, state: .none, missing: true)], linked: ["gone"])
    expect(view.isGlobalChosen, false, "a linked variable shows Only these connections")
    expect(view.tickedIds, ["gone"], "its missing connection is ticked")
    view.tick("gone", false)
    expect(heard.last, [], "unticking the missing one removes the link (global again)")
}

func runTests() {
    _ = NSApplication.shared
    MainActor.assumeIsolated {
        testManager()
        testMissingChoice()
    }
    if failures == 0 { print("\nAll variable manager tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
