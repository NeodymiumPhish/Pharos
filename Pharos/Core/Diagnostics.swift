import Foundation
import MetricKit

/// Writes the daily MetricKit payloads to disk so a performance or hang report
/// can be read after the fact, without a debugger attached.
///
/// MetricKit delivers at most once a day, and only for a build the system has
/// been watching — so this yields nothing in a session, and everything in a
/// week of real use. The payloads land beside the crash logs
/// (`~/Library/Logs/Pharos/`), as `metrickit-<timestamp>.json`, because that is
/// where a user is already asked to look when they report a problem.
///
/// Nothing is uploaded anywhere: the files stay on the user's own disk.
enum Diagnostics {

    /// Subscribe to MetricKit. Safe to call twice — the second call does
    /// nothing, rather than adding a second subscriber that writes every
    /// payload to a second file.
    static func start() {
        guard subscriber == nil else { return }
        let sub = PayloadWriter()
        subscriber = sub
        MXMetricManager.shared.add(sub)
    }

    /// Unsubscribe from MetricKit. Safe to call twice, and safe to call
    /// having never started — both do nothing.
    ///
    /// The subscriber is removed AND released: `MXMetricManager` does not
    /// retain it, so holding it after removing it would keep an object alive
    /// that receives nothing, and `start()` could not tell it apart from a
    /// live one.
    static func stop() {
        guard let sub = subscriber else { return }
        MXMetricManager.shared.remove(sub)
        subscriber = nil
    }

    /// Whether payloads are being collected right now.
    static var isRunning: Bool { subscriber != nil }

    /// Held for the app's life: `MXMetricManager` does not retain its
    /// subscribers, and a released one silently stops receiving payloads.
    private static var subscriber: PayloadWriter?

    // MARK: - Writing

    private static let timestampFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        return df
    }()

    /// `~/Library/Logs/Pharos`, created if it is not there yet. Nil only when
    /// the Library directory itself cannot be found.
    static func logsDirectory() -> URL? {
        let fm = FileManager.default
        guard let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let dir = library.appendingPathComponent("Logs/Pharos", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write one payload's JSON. `kind` separates the metric payloads from the
    /// diagnostic ones in the file name, since both arrive on the same day.
    fileprivate static func write(_ json: Data, kind: String) {
        guard let dir = logsDirectory() else { return }
        let name = "metrickit-\(kind)-\(timestampFormatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).json"
        let url = dir.appendingPathComponent(name)
        do {
            try json.write(to: url, options: .atomic)
            Log.ui.info("Wrote a MetricKit payload to \(name, privacy: .public)")
        } catch {
            Log.ui.error("Could not write a MetricKit payload: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The subscriber itself. `NSObject` because `MXMetricManagerSubscriber`
    /// inherits from `NSObjectProtocol`.
    private final class PayloadWriter: NSObject, MXMetricManagerSubscriber {

        func didReceive(_ payloads: [MXMetricPayload]) {
            for payload in payloads {
                Diagnostics.write(payload.jsonRepresentation(), kind: "metrics")
            }
        }

        func didReceive(_ payloads: [MXDiagnosticPayload]) {
            for payload in payloads {
                Diagnostics.write(payload.jsonRepresentation(), kind: "diagnostics")
            }
        }
    }
}
