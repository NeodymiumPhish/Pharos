// Standalone test runner for AppSettings' decode of what pharos-core sends.
//
// `AppSettings` uses Swift's synthesized `init(from:)`, which THROWS on a
// missing key. The core re-serializes its own `AppSettings` struct on every
// load, so the contract is: every Swift field has a camelCase key on the wire.
// The JSON below is `AppSettings::default()` as serde writes it (see
// pharos-core/src/models/settings.rs); a Swift field added without its Rust
// mirror fails here instead of at the user's next launch.
import Foundation

var failures = 0

func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

let coreDefaultJSON = """
{"theme":"auto",
 "editor":{"fontSize":13,"fontFamily":"JetBrains Mono, Monaco, Menlo, monospace","tabSize":2,"wordWrap":false,"lineNumbers":true},
 "query":{"defaultLimit":1000,"timeoutSeconds":300,"confirmDestructive":true,"notifyWhenAppInactive":true,
          "notifyWhenBackgroundTab":true,"notifyMinDurationSeconds":5,"showCancelledQueryDialog":true,"restoreOpenTabs":true},
 "emptyFolders":[],
 "nullDisplay":"NULL",
 "boolDisplay":"trueFalse",
 "checkForUpdates":true,
 "showLeafPartitions":false,
 "verticalResultTabs":true,
 "useAppleIntelligence":true,
 "charts":{"palette":["#E12D48","#3E7CC4","#C9820E","#2A9C81","#9B57C9","#E05525"]},
 "alwaysShowScrollBars":false}
"""

func runTests() {
    do {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(coreDefaultJSON.utf8))
        expectTrue(decoded == AppSettings(), "the core's default blob decodes to Swift's default AppSettings")
        expectTrue(decoded.alwaysShowScrollBars == false, "alwaysShowScrollBars arrives off by default")
    } catch {
        failures += 1
        print("FAIL the core's default blob must decode: \(error)")
    }

    // The key really is read, not defaulted: a stored `true` comes through.
    let on = coreDefaultJSON.replacingOccurrences(of: "\"alwaysShowScrollBars\":false", with: "\"alwaysShowScrollBars\":true")
    let decodedOn = try? JSONDecoder().decode(AppSettings.self, from: Data(on.utf8))
    expectTrue(decodedOn?.alwaysShowScrollBars == true, "a stored on is honoured")

    // And the failure this suite exists to catch: the key missing throws.
    let missing = coreDefaultJSON.replacingOccurrences(of: ",\n \"alwaysShowScrollBars\":false", with: "")
    let decodedMissing = try? JSONDecoder().decode(AppSettings.self, from: Data(missing.utf8))
    expectTrue(decodedMissing == nil, "a blob without the key does not decode — so the Rust mirror is load-bearing")

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
