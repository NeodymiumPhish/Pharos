// Standalone test for the native tab's connection dot and the window subtitle.
// Compiled by scripts/test-tab-connection-dot.sh.
import AppKit

private var failures = 0

private func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition { print("PASS \(name)") } else {
        failures += 1
        let d = detail()
        print("FAIL \(name)" + (d.isEmpty ? "" : "\n  \(d)"))
    }
}

@MainActor
private func testState() {
    expect(TabConnectionState(connectionId: nil, status: .connected) == .none, "no connection chosen")
    expect(TabConnectionState(connectionId: "c", status: nil) == .disconnected, "never connected reads as not connected")
    expect(TabConnectionState(connectionId: "c", status: .disconnected) == .disconnected, "disconnected")
    expect(TabConnectionState(connectionId: "c", status: .connecting) == .connecting, "connecting")
    expect(TabConnectionState(connectionId: "c", status: .connected) == .connected, "connected")
    expect(TabConnectionState(connectionId: "c", status: .error) == .error, "error")

    expect(TabConnectionState.connected.fill == .systemGreen, "connected is green")
    expect(TabConnectionState.connecting.fill == .systemOrange, "connecting is orange")
    expect(TabConnectionState.error.fill == .systemRed, "error is red")
    expect(TabConnectionState.disconnected.fill == nil && TabConnectionState.none.fill == nil,
           "not connected and no connection draw an empty ring")
    let labels = [TabConnectionState.none, .disconnected, .connecting, .connected, .error].map(\.label)
    expect(Set(labels).count == 5, "every state has its own spoken label", "\(labels)")
}

@MainActor
private func testSubtitle() {
    expect(TabConnectionState.subtitle(connectionName: "Coda", schema: "public") == "Coda · public", "connection · schema")
    expect(TabConnectionState.subtitle(connectionName: "Coda", schema: nil) == "Coda", "no schema: the connection alone")
    expect(TabConnectionState.subtitle(connectionName: "Coda", schema: "") == "Coda", "an empty schema reads as none")
    expect(TabConnectionState.subtitle(connectionName: nil, schema: "public") == "No connection", "no connection")
}

@MainActor
private func testDot() {
    let dot = TabConnectionDot()
    dot.state = .connected
    expect(dot.accessibilityLabel() == TabConnectionState.connected.label, "VoiceOver reads the state")
    expect(dot.accessibilityIdentifier() == "window.tab.connectionDot", "AX id")
    expect(dot.drawnAlpha == 1, "solid at rest")
    dot.isRunning = true
    PulseClock.shared.value.send(0)
    expect(dot.drawnAlpha < 0.5, "while running it breathes with the pulse clock", "alpha \(dot.drawnAlpha)")
    PulseClock.shared.value.send(1)
    expect(dot.drawnAlpha == 1, "and peaks at full", "alpha \(dot.drawnAlpha)")
    dot.isRunning = false
    PulseClock.shared.value.send(0)
    expect(dot.drawnAlpha == 1, "stopping returns it to solid and stops following the clock")
    expect(dot.intrinsicContentSize.width >= TabConnectionDot.diameter, "it has a size for the tab to lay out")
}

func runTests() {
    MainActor.assumeIsolated {
        testState()
        testSubtitle()
        testDot()
    }
    if failures == 0 { print("\nAll tab connection dot tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
