import Foundation

/// Pure helper that locates the SQL segment in the current editor parse
/// corresponding to a previously-executed result tab.
///
/// Match rule: a candidate segment matches when its `.sql` (already trimmed
/// by the parser) equals the result tab's stored SQL after the same
/// trim-whitespace normalization on both sides. On multiple candidates,
/// pick the one whose line midpoint is closest to the previous line range.
/// Ties go to the smaller `index` for deterministic behavior.
enum ResultTabResolver {

    struct Outcome: Equatable {
        let segmentIndex: Int
        let lineRange: ClosedRange<Int>
    }

    static func resolve(
        sql: String,
        previousLineRange: ClosedRange<Int>,
        in segments: [SQLSegment]
    ) -> Outcome? {
        let needle = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }

        let matches = segments.filter {
            $0.sql.trimmingCharacters(in: .whitespacesAndNewlines) == needle
        }
        guard !matches.isEmpty else { return nil }

        if matches.count == 1 {
            let m = matches[0]
            return Outcome(segmentIndex: m.index, lineRange: m.startLine...m.endLine)
        }

        let prevMid = Double(previousLineRange.lowerBound + previousLineRange.upperBound) / 2.0

        let chosen = matches.min { a, b in
            let aMid = Double(a.startLine + a.endLine) / 2.0
            let bMid = Double(b.startLine + b.endLine) / 2.0
            let aDist = abs(aMid - prevMid)
            let bDist = abs(bMid - prevMid)
            if aDist != bDist { return aDist < bDist }
            return a.index < b.index
        }!

        return Outcome(segmentIndex: chosen.index, lineRange: chosen.startLine...chosen.endLine)
    }
}
