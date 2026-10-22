import Foundation

/// Snapshot of the results grid view state for a tab.
struct ResultsGridState {
    var columnWidths: [String: CGFloat]
    var columnOrder: [String]?  // Column identifiers in display order (nil = default)
    var sortColumn: String?
    var sortAscending: Bool
    var columnFilters: [String: ColumnFilter]
    var scrollPosition: NSPoint
    var selectedRows: IndexSet
    /// Identifiers of the data columns the user hid from the header's context
    /// menu. A hidden column keeps its entry in `columnWidths`, so showing it
    /// again brings back the width it had.
    var hiddenColumns: Set<String> = []
}

/// A single query currently executing for a tab. `id` matches the `query_id`
/// registered in pharos-core's `running_queries` registry, so cancellation and
/// lookup are symmetric across FFI.
struct RunningQuery: Identifiable, Equatable {
    /// What the run is for.
    enum Kind: Equatable {
        /// A card's own run.
        case card
        /// "Load All Rows" for a card's result.
        case snapshot
        /// Pharos's own work for a card's result: a chart aggregation, the
        /// re-read after a cell edit.
        case aux
    }

    let id: String
    /// The card the run belongs to.
    let cardId: String?
    let kind: Kind
    /// What the running-queries list calls it: the card's name.
    let label: String
    let normalizedSQL: String       // trimmed + whitespace-collapsed, used for dedup
    let startTime: CFTimeInterval   // CACurrentMediaTime() at launch
}

/// Represents a single query editor tab.
struct QueryTab: Identifiable {
    let id: String
    var name: String
    /// True when the user chose `name`: a rename, a Session's name, a file's
    /// name. False while the name is automatic ("New Tab N", then
    /// "{connection} - {schema}"), which `WindowSession` keeps in step with the
    /// tab's connection and schema. Stored as `SessionTab.nameIsCustom`.
    var nameIsCustom: Bool = false
    /// The "{connection} - {schema}" the automatic name was last made from,
    /// before any " (2)". The name is renumbered only when this changes, so a
    /// tab keeps its number while the user types. Nil for a custom name and
    /// for a tab not yet named from a connection. Not stored: a restored tab
    /// is numbered again as it is put back.
    var automaticNameBase: String?
    var connectionId: String?
    var schemaName: String?
    /// The tab's query cards. Every keystroke lands here: session restore,
    /// the workspace snapshot, save and the unsaved-work check read it.
    var document: CardDocument
    var isDirty: Bool = false
    /// All in-flight queries launched from this tab, ordered by `startTime` ascending.
    var runningQueries: [RunningQuery] = []
    /// Computed: any in-flight query means this tab is executing.
    var isExecuting: Bool { !runningQueries.isEmpty }
    /// Failures from this tab, newest first. Replaces the old single `error`
    /// string: a failure now shows in a sheet and stays available from the tab's
    /// error button, instead of taking over the results grid.
    var failureLog = QueryFailureLog()
    var savedQueryId: String?
    /// Filesystem URL this tab was opened from, if any. Set when the tab is
    /// opened from a `.sql` or other plain-text file; ⌘S writes back here.
    var sourceURL: URL?
    /// The persisted workspace history record this tab is bound to. nil until
    /// the first query executes (or until reopened from history). When set,
    /// executed results associate to this workspace and appear as one history item.
    var workspaceId: String?

    init(id: String = UUID().uuidString, name: String = "New Tab 1", connectionId: String? = nil,
         schemaName: String? = nil, document: CardDocument = CardDocument()) {
        self.id = id
        self.name = name
        self.connectionId = connectionId
        self.schemaName = schemaName
        self.document = document
    }
}

extension QueryTab {
    /// An untouched blank tab: no SQL, no file, no saved query or workspace,
    /// nothing running, nothing unsaved, no name the user gave it. An item the
    /// user opens replaces it instead of opening beside it, the way a browser
    /// fills an empty tab.
    var isPristine: Bool {
        !isDirty && !nameIsCustom && runningQueries.isEmpty && sourceURL == nil && savedQueryId == nil && workspaceId == nil
            && document.cards.allSatisfy { $0.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.lastRun == nil }
    }
}
