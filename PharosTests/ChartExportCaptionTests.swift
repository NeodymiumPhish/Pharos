// Standalone test for ChartExportCaption. Compiled with ChartExportCaption.swift
// alone — the pure/Foundation-only half of chart export (see ChartExporter.swift
// for the SwiftUI/ImageRenderer half, which is build-gated + manually verified).
import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

func runTests() {
    // Client mode, not truncated.
    let client = ChartExportCaption.text(
        mode: "Client", connection: "mydb", plotted: 42, total: 100,
        truncated: false, timestamp: "2026-07-17T12:00:00Z"
    )
    expect(client == "Client · mydb · 42 of 100 rows · 2026-07-17T12:00:00Z", "client caption format")

    // Server mode, truncated: " · truncated" appended.
    let serverTruncated = ChartExportCaption.text(
        mode: "Server", connection: "prod", plotted: 1000, total: 5000,
        truncated: true, timestamp: "2026-07-17T12:05:00Z"
    )
    expect(
        serverTruncated == "Server · prod · 1000 of 5000 rows · 2026-07-17T12:05:00Z · truncated",
        "server truncated caption appends suffix"
    )

    // Server mode, not truncated: no suffix, ends at the timestamp.
    let serverNotTruncated = ChartExportCaption.text(
        mode: "Server", connection: "prod", plotted: 20, total: 20,
        truncated: false, timestamp: "2026-07-17T12:10:00Z"
    )
    expect(!serverNotTruncated.contains("truncated"), "non-truncated caption omits suffix")
    expect(serverNotTruncated.hasSuffix("rows · 2026-07-17T12:10:00Z"), "non-truncated caption ends at timestamp")

    // plotted == total (whole result charted, no truncation note either way).
    let whole = ChartExportCaption.text(
        mode: "Client", connection: "local", plotted: 7, total: 7,
        truncated: false, timestamp: "2026-07-17T12:15:00Z"
    )
    expect(whole == "Client · local · 7 of 7 rows · 2026-07-17T12:15:00Z", "plotted == total still reads naturally")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
