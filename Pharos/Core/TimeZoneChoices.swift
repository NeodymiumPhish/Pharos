import Foundation

/// The zones a time-zone pop-up offers: a short pinned group (UTC, then this
/// Mac's zone), and below it every IANA zone this Mac knows. Pure Foundation,
/// so a harness can compile it alone.
///
/// The Connection form's own list (`SessionTimeZone.identifiers`) is not
/// reused: it lives in `Settings.swift`, which every settings harness compiles,
/// and it has no "local zone" group.
enum TimeZoneChoices {

    /// The zone ids pinned above the full list: `UTC`, then `local`'s id when
    /// it is a different zone. Foundation names UTC both `UTC` and `GMT`, so a
    /// Mac set to either gets only the one `UTC` entry.
    static func pinned(local: TimeZone = .current) -> [String] {
        let utc = "UTC"
        let localId = local.identifier
        if isUTCAlias(localId) { return [utc] }
        return [utc, localId]
    }

    /// Every zone id this Mac knows, sorted, with `UTC` added when the system
    /// list leaves it out. Computed once: the list holds about 600 ids.
    static let all: [String] = {
        var known = Set(TimeZone.knownTimeZoneIdentifiers)
        known.insert("UTC")
        return known.sorted()
    }()

    /// The pinned group, then the full list, for a pop-up that shows a
    /// separator between the two. `selected` is added to the pinned group when
    /// it is in neither, so a stored id this Mac does not list still shows.
    static func groups(local: TimeZone = .current, selected: String? = nil) -> (pinned: [String], all: [String]) {
        var pinned = pinned(local: local)
        if let selected, !selected.isEmpty, !pinned.contains(selected), !all.contains(selected) {
            pinned.append(selected)
        }
        return (pinned, all)
    }

    private static func isUTCAlias(_ id: String) -> Bool {
        ["GMT", "UTC", "Etc/UTC", "Etc/GMT", "Etc/Universal", "Universal", "Zulu", "Etc/Zulu"].contains(id)
    }
}
