import Foundation

// The three enums this file used to declare — `ObjectSortMode`,
// `SchemaSortMode` and `NavigatorDoubleClickAction` — live in
// `Pharos/Models/Settings.swift`, beside every other type `AppSettings`
// names. A settings enum declared anywhere else breaks the standalone
// harnesses that compile `Settings.swift` on its own, the FFI contract test
// among them. Only the ORDERING logic belongs here.

/// The ordering rules of the Database Navigator, away from the view
/// controller so they can be tested without an outline view or a database.
///
/// Every mode is a TOTAL order: two objects that tie on the chosen key are
/// ordered by name, so a rebuild of the tree cannot shuffle equal rows and
/// make the list look unstable.
enum NavigatorOrdering {

    /// The fields of a schema object this ordering needs. `TableInfo` is
    /// mapped onto it by the caller, which is what keeps this file free of
    /// the model layer.
    struct Object: Equatable {
        let name: String
        /// Lower sorts first under `kindThenName`: a table is 0, a view is 1.
        let kindRank: Int
        /// Total bytes, or nil when the size is not known.
        let sizeBytes: Int64?
        /// The planner's row estimate, or nil when it is not known.
        let rowEstimate: Int64?

        init(name: String, kindRank: Int, sizeBytes: Int64? = nil, rowEstimate: Int64? = nil) {
            self.name = name
            self.kindRank = kindRank
            self.sizeBytes = sizeBytes
            self.rowEstimate = rowEstimate
        }
    }

    static func sorted(_ objects: [Object], by mode: ObjectSortMode) -> [Object] {
        switch mode {
        case .kindThenName:
            return objects.sorted { a, b in
                if a.kindRank != b.kindRank { return a.kindRank < b.kindRank }
                return byName(a, b)
            }
        case .name:
            return objects.sorted(by: byName)
        case .size:
            return objects.sorted { descending($0.sizeBytes, $1.sizeBytes, $0, $1) }
        case .rowEstimate:
            return objects.sorted { descending($0.rowEstimate, $1.rowEstimate, $0, $1) }
        }
    }

    /// Largest first, with the unknowns last. An unknown must NOT sort as
    /// zero: a table whose size has not been measured yet would then claim
    /// to be the smallest, and the list would reshuffle as the measurements
    /// arrived.
    private static func descending(_ lhs: Int64?, _ rhs: Int64?, _ a: Object, _ b: Object) -> Bool {
        switch (lhs, rhs) {
        case let (l?, r?):
            if l != r { return l > r }
            return byName(a, b)
        case (nil, _?): return false
        case (_?, nil): return true
        case (nil, nil): return byName(a, b)
        }
    }

    private static func byName(_ a: Object, _ b: Object) -> Bool {
        let order = a.name.localizedCaseInsensitiveCompare(b.name)
        if order != .orderedSame { return order == .orderedAscending }
        // Two objects of the same name in one schema can only differ by kind.
        return a.kindRank < b.kindRank
    }

    /// Schema names in the chosen order.
    static func sortedSchemas(_ names: [String], by mode: SchemaSortMode, defaultSchema: String?) -> [String] {
        let byName = names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        switch mode {
        case .name:
            return byName
        case .defaultFirst:
            guard let defaultSchema, byName.contains(defaultSchema) else { return byName }
            return [defaultSchema] + byName.filter { $0 != defaultSchema }
        }
    }

    /// Whether a schema with `childCount` children is expanded for the user
    /// when the tree is built.
    ///
    /// The ceiling is not a preference for tidiness: expanding one
    /// `NSOutlineView` item with thousands of children blocks the main
    /// thread for seconds, which is why the Navigator has always had a
    /// threshold. The setting moves the number, not the rule.
    static func shouldAutoExpand(childCount: Int, enabled: Bool, threshold: UInt32) -> Bool {
        guard enabled else { return false }
        return childCount <= Int(threshold)
    }
}
