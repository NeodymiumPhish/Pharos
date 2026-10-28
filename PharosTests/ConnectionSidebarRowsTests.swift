// Standalone test for `ConnectionSidebarRows` — what each row of the
// Connections Manager's sidebar says: title, subtitle, engine badge, status
// dot and unsaved dot.
//
// `ConnectionsManagerVC` reaches `AppStateManager` and through it the whole
// FFI, so it cannot be compiled here. The row model is a pure function of the
// records and their states; the view controller only hands the result to
// `ManagerSidebarVC.setItems`, whose own behaviour `test-manager-sidebar.sh`
// covers.
import AppKit
import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }
func expectEqual<T: Equatable>(_ a: T, _ b: T, _ n: String) {
    if a == b { print("PASS \(n)") } else { failures += 1; print("FAIL \(n) — got \(a), wanted \(b)") }
}

func runTests() {
    let server = ConnectionConfig(id: "pg", name: "Production", host: "db.example.com", port: 5432,
                                  database: "app", username: "me")

    // MARK: Server row

    let row = ConnectionSidebarRows.item(for: server, status: .disconnected, isStub: false, isDirty: false)
    expectEqual(row.id, "pg", "the row keeps the record's id")
    expectEqual(row.title, "Production", "the title is the name")
    expect(!row.titleIsMonospaced, "a connection name is not monospaced")
    expectEqual(row.subtitle, "db.example.com:5432 · app", "a server's subtitle is host:port · database")
    expect(!row.subtitleTruncatesMiddle, "a server's subtitle truncates at its end")
    expectEqual(row.badge, .symbol(name: "server.rack", tint: .systemBlue),
                "a server's badge is the tab pop-up's server tile")
    expectEqual(row.trailing, [.statusDot(.tertiaryLabelColor, accessibilityLabel: "Not connected")],
                "a clean, disconnected record shows a grey status dot only")

    // MARK: Tunnel

    var tunnelled = server
    tunnelled.sshTunnel = SshTunnelConfig(host: "bastion.internal")
    let tunnelRow = ConnectionSidebarRows.item(for: tunnelled, status: .disconnected, isStub: false, isDirty: false)
    expectEqual(tunnelRow.subtitle, "db.example.com:5432 · app · via bastion.internal",
                "a tunnel names its bastion after the database")
    expect(tunnelRow.matches("bastion"), "the filter finds a record by its bastion")
    // A tunnel with no SSH host (saved before Save required one): the row
    // never ends in a dangling "via ".
    var hostless = server
    hostless.sshTunnel = SshTunnelConfig(host: "")
    let hostlessRow = ConnectionSidebarRows.item(for: hostless, status: .disconnected, isStub: false, isDirty: false)
    expectEqual(hostlessRow.subtitle, "db.example.com:5432 · app",
                "a tunnel with a blank SSH host adds no \"via\" to the subtitle")
    expect(!(hostlessRow.subtitle ?? "").hasSuffix("via "), "no subtitle ends in \"via \"")
    expect(row.matches("example"), "the filter finds a record by its host")

    // MARK: DuckDB

    let home = NSHomeDirectory()
    var file = ConnectionConfig.duckDB(path: home + "/Data/sales.duckdb", id: "f")
    file.name = "Sales"
    let fileRow = ConnectionSidebarRows.item(for: file, status: .disconnected, isStub: false, isDirty: false)
    expectEqual(fileRow.subtitle, "DuckDB · ~/Data/sales.duckdb", "a DuckDB file's subtitle is its path, with ~")
    expect(fileRow.subtitleTruncatesMiddle, "a file path truncates in the middle, keeping the file name")
    expectEqual(fileRow.badge, .symbol(name: "cylinder", tint: .systemOrange),
                "a DuckDB file's badge is the file tile")

    let memory = ConnectionConfig.duckDB(path: ConnectionConfig.duckDBInMemoryPath, id: "m")
    let memoryRow = ConnectionSidebarRows.item(for: memory, status: .connected, isStub: false, isDirty: false)
    expectEqual(memoryRow.subtitle, "DuckDB · In-memory", "an in-memory database says so")
    expectEqual(memoryRow.badge, .symbol(name: "memorychip", tint: .systemPurple),
                "an in-memory database's badge is the memory tile")

    // MARK: Title

    var blank = server
    blank.name = ""
    expectEqual(ConnectionSidebarRows.title(for: blank), "Untitled", "a blank name shows Untitled")
    blank.name = "   "
    expectEqual(ConnectionSidebarRows.title(for: blank), "Untitled",
                "a name of spaces shows Untitled (the placeholder is chosen after the trim)")
    var padded = server
    padded.name = "  prod  "
    expectEqual(ConnectionSidebarRows.title(for: padded), "prod", "the title is trimmed, as the save path trims")
    var hostile = server
    hostile.name = "safe\u{202E}gpj.exe"
    expect(!ConnectionSidebarRows.title(for: hostile).unicodeScalars.contains("\u{202E}"),
           "a bidi override in the name is escaped, so the row cannot lie")
    hostile.host = "10.0.0.1\u{200B}"
    let hostileSubtitle = ConnectionSidebarRows.subtitle(for: hostile, isStub: false)
    expect(!hostileSubtitle.unicodeScalars.contains("\u{200B}"),
           "an invisible character in the host is escaped in the subtitle")

    // MARK: Status dot

    let dots: [(ConnectionStatus, NSColor, String)] = [
        (.connected, .systemGreen, "Connected"),
        (.connecting, .systemYellow, "Connecting"),
        (.error, .systemRed, "Connection failed"),
        (.disconnected, .tertiaryLabelColor, "Not connected"),
    ]
    for (status, color, label) in dots {
        let r = ConnectionSidebarRows.item(for: server, status: status, isStub: false, isDirty: false)
        expectEqual(r.trailing, [.statusDot(color, accessibilityLabel: label)],
                    "\(status.rawValue): the dot's colour and its spoken label")
    }

    // MARK: Stub and dirty

    let stub = ConnectionSidebarRows.item(for: server, status: .disconnected, isStub: true, isDirty: true)
    expectEqual(stub.subtitle, "Not saved", "a record never saved says Not saved")
    expect(!stub.subtitleTruncatesMiddle, "Not saved is not a path")
    expectEqual(stub.trailing, [.statusDot(.systemOrange, accessibilityLabel: "Not saved")],
                "a stub shows the orange dot and no second unsaved dot")
    let dirty = ConnectionSidebarRows.item(for: server, status: .connected, isStub: false, isDirty: true)
    expectEqual(dirty.trailing, [.unsavedDot, .statusDot(.systemGreen, accessibilityLabel: "Connected")],
                "an edited saved record shows the unsaved dot, then the status dot last")
    var duckStub = file
    duckStub.id = "fs"
    let duckStubRow = ConnectionSidebarRows.item(for: duckStub, status: .disconnected, isStub: true, isDirty: false)
    expectEqual(duckStubRow.subtitle, "Not saved", "a DuckDB stub says Not saved too")

    // MARK: The list

    let items = ConnectionSidebarRows.items(for: [server, file, memory],
                                            statuses: ["m": .connected],
                                            stubIds: ["f"],
                                            dirtyId: "pg")
    expectEqual(items.map(\.id), ["pg", "f", "m"], "the rows keep the records' order")
    expectEqual(items[0].trailing, [.unsavedDot, .statusDot(.tertiaryLabelColor, accessibilityLabel: "Not connected")],
                "the dirty id gets the unsaved dot; no status entry means disconnected")
    expectEqual(items[1].subtitle, "Not saved", "the stub id is a stub")
    expectEqual(items[2].trailing, [.statusDot(.systemGreen, accessibilityLabel: "Connected")],
                "the status comes from the record's own entry")
    expect(ConnectionSidebarRows.items(for: [], statuses: [:], stubIds: [], dirtyId: nil).isEmpty,
           "no records, no rows")

    print(failures == 0 ? "\nAll tests passed" : "\n\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
