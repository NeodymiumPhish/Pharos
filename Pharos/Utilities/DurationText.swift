import Foundation

/// Locale-aware short duration text for a query's elapsed time: "850 ms",
/// "1.2 s", "1m 5s", "1h 5m".
///
/// The tier boundaries (1 s, 60 s, 1 h) and the minutes/hours composition
/// match the legacy `ResultsGridVC.formatDuration` / `QueryNotifier.formatDuration`
/// bodies this replaces exactly. Only the number itself becomes locale-aware
/// (decimal separator: "1.2 s" in en_US, "1,2 s" in de_DE) — the unit suffixes
/// stay the app's own compact "ms"/"s"/"m"/"h", not `Duration.UnitsFormatStyle`'s
/// built-in words ("sec", "min", "hr"), which don't match this app's format and
/// aren't worth reshaping the display around.
enum DurationText {
    /// - Parameters:
    ///   - ms: elapsed time in whole milliseconds.
    ///   - locale: defaults to the live system locale; pass an explicit locale
    ///     (e.g. for a test) to pin the decimal separator.
    static func short(milliseconds ms: UInt64, locale: Locale = .autoupdatingCurrent) -> String {
        if ms < 1_000 {
            return "\(ms) ms"
        }
        if ms < 60_000 {
            return "\(number(Double(ms) / 1000, fractionDigits: 1, locale: locale)) s"
        }
        let totalSeconds = Double(ms) / 1000
        let minutes = Int(totalSeconds) / 60
        let seconds = totalSeconds.truncatingRemainder(dividingBy: 60)
        if ms < 3_600_000 {
            return seconds >= 0.5
                ? "\(minutes)m \(Int(seconds.rounded()))s"
                : "\(minutes)m"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes > 0 ? "\(hours)h \(remainingMinutes)m" : "\(hours)h"
    }

    private static func number(_ value: Double, fractionDigits: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.\(fractionDigits)f", value)
    }
}
