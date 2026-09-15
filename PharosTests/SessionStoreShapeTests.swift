// Standalone test for the session store's wire shape — compiled by
// scripts/test-session-store-shape.sh.
//
// What this suite is FOR: `Session` crosses the FFI as JSON, and
// `JSONDecoder.pharos` applies NO key strategy, so each Swift property name IS
// the JSON key and must match the Rust mirror's `#[serde(rename_all =
// "camelCase")]` output exactly (tasks/lessons.md: an optional field's FFI key
// name fails SILENTLY — the field decodes as nil and the tabs come back blank).
//
// The fixture below is written the way pharos-core serialises it, by hand, so
// a rename on either side breaks this suite rather than the user's restore.
// It carries TWO windows because one window could not tell a per-window shape
// from the flat one it replaced.
//
// The frame is also exercised here: it is the one field the store keeps as
// text, and a damaged value must degrade to "no stored frame" rather than to a
// window at 0×0 on a screen that is no longer attached.
import Foundation

private var failures = 0

private func expect<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") }
    else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private func expectTrue(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") }
    else {
        failures += 1
        print("FAIL \(name)")
    }
}

/// Exactly what `pharos-core` writes for a two-window session.
private let rustJSON = """
{
  "windows": [
    {
      "windowId": "win-a",
      "windowIndex": 0,
      "frame": "100,200,1200,800",
      "tabs": [
        {
          "tabIndex": 0,
          "workspaceId": "ws-1",
          "name": "Orders",
          "nameIsCustom": true,
          "connectionId": "conn-1",
          "schemaName": "public",
          "sql": "select * from orders",
          "cursorPosition": 12,
          "variablesJson": "[]",
          "isActive": true
        },
        {
          "tabIndex": 1,
          "workspaceId": null,
          "name": "Query 2",
          "nameIsCustom": false,
          "connectionId": null,
          "schemaName": null,
          "sql": "",
          "cursorPosition": 0,
          "variablesJson": null,
          "isActive": false
        }
      ]
    },
    {
      "windowId": "win-b",
      "windowIndex": 1,
      "frame": null,
      "tabs": [
        {
          "tabIndex": 0,
          "workspaceId": null,
          "name": "Scratch",
          "nameIsCustom": true,
          "connectionId": "conn-2",
          "schemaName": "sales",
          "sql": "select 1",
          "cursorPosition": 3,
          "variablesJson": "[]",
          "isActive": true
        }
      ]
    }
  ]
}
"""

private func expectedSession() -> Session {
    Session(windows: [
        SessionWindow(
            windowId: "win-a", windowIndex: 0, frame: "100,200,1200,800",
            tabs: [
                SessionTab(tabIndex: 0, workspaceId: "ws-1", name: "Orders", nameIsCustom: true,
                           connectionId: "conn-1", schemaName: "public",
                           sql: "select * from orders", cursorPosition: 12,
                           variablesJson: "[]", isActive: true),
                SessionTab(tabIndex: 1, workspaceId: nil, name: "Query 2", nameIsCustom: false,
                           connectionId: nil, schemaName: nil, sql: "", cursorPosition: 0,
                           variablesJson: nil, isActive: false),
            ]),
        SessionWindow(
            windowId: "win-b", windowIndex: 1, frame: nil,
            tabs: [
                SessionTab(tabIndex: 0, workspaceId: nil, name: "Scratch", nameIsCustom: true,
                           connectionId: "conn-2", schemaName: "sales", sql: "select 1",
                           cursorPosition: 3, variablesJson: "[]", isActive: true),
            ]),
    ])
}

private func testDecodesTheRustShape() {
    guard let decoded = try? JSONDecoder().decode(Session.self, from: Data(rustJSON.utf8)) else {
        failures += 1
        print("FAIL the core's JSON decodes at all")
        return
    }
    expect(decoded, expectedSession(), "the core's JSON decodes to the expected session")
    expect(decoded.windows.count, 2, "both windows survive")
    expect(decoded.windows[1].tabs[0].name, "Scratch", "the second window keeps its own tabs")
    expect(decoded.windows[0].tabs.filter { $0.isActive }.count, 1,
           "each window names exactly one active tab")
}

private func testEncodesTheKeysTheCoreReads() {
    guard let data = try? JSONEncoder().encode(expectedSession()),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let windows = object["windows"] as? [[String: Any]] else {
        failures += 1
        print("FAIL the session encodes to a JSON object")
        return
    }
    expect(Set(object.keys), ["windows"], "the top level is exactly `windows`")
    expect(Set(windows[0].keys), ["windowId", "windowIndex", "frame", "tabs"],
           "a window's keys are the Rust mirror's four")

    guard let tabs = windows[0]["tabs"] as? [[String: Any]] else {
        failures += 1
        print("FAIL a window carries its tabs")
        return
    }
    // `workspaceId`, `connectionId`, `schemaName` and `variablesJson` are
    // OPTIONAL, so a misspelling of one of them decodes as nil instead of
    // throwing. They are asserted on the tab that HAS them.
    expect(Set(tabs[0].keys),
           ["tabIndex", "workspaceId", "name", "nameIsCustom", "connectionId",
            "schemaName", "sql", "cursorPosition", "variablesJson", "isActive"],
           "a tab's keys are the Rust mirror's ten")
}

private func testRoundTrip() {
    let original = expectedSession()
    guard let data = try? JSONEncoder().encode(original),
          let back = try? JSONDecoder().decode(Session.self, from: data) else {
        failures += 1
        print("FAIL the session survives an encode/decode round trip")
        return
    }
    expect(back, original, "encode then decode gives the same session")
}

private func testEmptySession() {
    guard let data = try? JSONEncoder().encode(Session()),
          let back = try? JSONDecoder().decode(Session.self, from: data) else {
        failures += 1
        print("FAIL an empty session round-trips")
        return
    }
    expect(back.windows.count, 0, "an empty session is a valid session")
}

private func testFrameText() {
    let rect = NSRect(x: 100, y: 200, width: 1200, height: 800)
    expect(SessionWindow.description(of: rect), "100.0,200.0,1200.0,800.0",
           "a frame writes as four numbers")
    expect(SessionWindow.rect(from: "100.0,200.0,1200.0,800.0"), rect,
           "and reads back to the same rect")
    expect(SessionWindow.rect(from: "100,200,1200,800"), rect,
           "integers without a decimal point read too")
    expect(SessionWindow.rect(from: " 100 , 200 , 1200 , 800 "), rect,
           "spaces around the numbers are ignored")

    // A file can hold anything. None of these may become a window.
    expectTrue(SessionWindow.rect(from: "") == nil, "an empty frame is no frame")
    expectTrue(SessionWindow.rect(from: "100,200,1200") == nil, "three numbers are no frame")
    expectTrue(SessionWindow.rect(from: "100,200,1200,800,1") == nil, "five numbers are no frame")
    expectTrue(SessionWindow.rect(from: "a,b,c,d") == nil, "words are no frame")
    expectTrue(SessionWindow.rect(from: "100,200,nan,800") == nil, "a NaN is no frame")
    expectTrue(SessionWindow.rect(from: "100,200,inf,800") == nil, "an infinity is no frame")
}

func runTests() {
    testDecodesTheRustShape()
    testEncodesTheKeysTheCoreReads()
    testRoundTrip()
    testEmptySession()
    testFrameText()

    if failures > 0 {
        print("\(failures) FAILURE(S)")
        exit(1)
    }
    print("All session store shape tests passed")
}
