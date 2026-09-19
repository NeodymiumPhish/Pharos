import AppKit
import Combine

// MARK: - Find Match Address

struct CellAddress: Hashable {
    let row: Int
    let colId: String
}

// MARK: - Data Source Delegate

protocol ResultsDataSourceDelegate: AnyObject {
    func dataSourceSortDescriptorsDidChange(_ oldDescriptors: [NSSortDescriptor])
    func dataSourceSelectionDidChange()
    /// The Settings ▸ Results fields that belong to the grid's CHROME — row
    /// height, stripes, rules, column widths, the `#` column, find, copy and
    /// editing — have changed.
    ///
    /// Pushed from the data source's one settings sink rather than a second
    /// sink of the VC's own: two sinks on the same publisher would apply
    /// halves of one change in an order nobody controls, and the column widths
    /// depend on the fonts the data source has just taken.
    func dataSourceGridSettingsDidChange(_ settings: ResultsGridSettings)
}

/// The Settings ▸ Results values the grid's chrome reads, snapshotted off one
/// delivered `AppSettings` so nothing downstream has to re-read the store.
struct ResultsGridSettings: Equatable {
    var style: ResultsGridStyle = .default
    var alternatingRowColors = true
    var gridLines: ResultsGridLines = .both
    var showRowNumbers = true
    var showColumnTypeIcons = false
    var columnWidthMode: ColumnWidthMode = .fitContent
    var maximumColumnWidth: CGFloat = 1000
    var fixedColumnWidth: CGFloat = 200
    var allowInlineEditing = true
    var findMode: FindMode = .contains
    var findMatchCase = false
    var defaultCopyFormat: CopyFormat = .tsv
    var copyIncludeHeaders = true
    var copyRichText = true
    var maximumResultTabs: UInt32 = 0

    init() {}

    init(_ settings: AppSettings) {
        let r = settings.results
        style = ResultsGridStyle(r)
        alternatingRowColors = r.alternatingRowColors
        gridLines = r.gridLines
        showRowNumbers = r.showRowNumbers
        showColumnTypeIcons = r.showColumnTypeIcons
        columnWidthMode = r.columnWidthMode
        maximumColumnWidth = CGFloat(max(1, r.maximumColumnWidth))
        fixedColumnWidth = CGFloat(max(1, r.fixedColumnWidth))
        allowInlineEditing = r.allowInlineEditing
        findMode = r.findMode
        findMatchCase = r.findMatchCase
        defaultCopyFormat = r.defaultCopyFormat
        copyIncludeHeaders = r.copyIncludeHeaders
        copyRichText = r.copyRichText
        maximumResultTabs = r.maximumResultTabs
    }
}

// MARK: - ResultCellView

/// The cell's label, with one extra: an accessibility value the data source
/// can override for a cell holding an uncommitted edit.
///
/// A subclass is needed rather than a plain `setAccessibilityValue(_:)` call.
/// An `NSTextField`'s AXValue is served by its `NSTextFieldCell` and is always
/// the displayed string, so a value set on the view never reaches the
/// accessibility tree — reading it back through the AX API on a live grid is
/// what showed that, and it is the only way to tell.
final class ResultCellLabel: NSTextField {
    /// Replaces the AXValue while set. nil restores the displayed text.
    var accessibilityValueOverride: String? {
        didSet { NSAccessibility.post(element: self, notification: .valueChanged) }
    }

    // No `override`: AppKit declares `accessibilityValue()` on NSObject
    // through the NSAccessibility protocol, not as a method of NSTextField, so
    // Swift sees nothing to override. Declaring it here still replaces the
    // Objective-C implementation for this class, which is what the
    // accessibility server asks.
    @objc func accessibilityValue() -> Any? {
        accessibilityValueOverride ?? stringValue
    }
}

/// Internal, not private: `ResultsGridVC+Editing` has to reach the cell's
/// editor field to give it the keyboard once the table has realized the view.
final class ResultCellView: NSTableCellView {
    /// Type-appropriate unselected text color (purple for temporal, tertiary
    /// for NULL, blue for numeric, etc.). Setter keeps `textField.textColor` in
    /// sync when not selected — callers no longer assign textField directly.
    var normalTextColor: NSColor = .labelColor {
        didSet { updateTextColor() }
    }

    // MARK: - Pending-edit marker

    /// Width of the accent rule down the leading edge of a cell holding an
    /// uncommitted edit. 2pt: visible beside the 6pt text inset without
    /// touching the glyphs.
    static let pendingRuleWidth: CGFloat = 2

    private var pendingRuleLayer: CALayer?

    /// Whether this cell carries an uncommitted edit. Assigned on EVERY
    /// realize, including false, so a recycled cell cannot keep another row's
    /// marker — the same rule the find border and the tag tint follow.
    var showsPendingRule: Bool = false {
        didSet {
            guard oldValue != showsPendingRule else { return }
            updatePendingRule()
        }
    }

    private func updatePendingRule() {
        if showsPendingRule {
            let rule = pendingRuleLayer ?? {
                let fresh = CALayer()
                // No implicit animation: the rule appears the instant the edit
                // commits, and a fade would read as the grid still thinking.
                fresh.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
                layer?.addSublayer(fresh)
                pendingRuleLayer = fresh
                return fresh
            }()
            rule.backgroundColor = NSColor.controlAccentColor.cgColor
            rule.isHidden = false
            layoutPendingRule()
        } else {
            pendingRuleLayer?.isHidden = true
        }
    }

    private func layoutPendingRule() {
        guard let rule = pendingRuleLayer, !rule.isHidden else { return }
        rule.frame = NSRect(x: 0, y: 0, width: Self.pendingRuleWidth, height: bounds.height)
    }

    // MARK: - Inline editor

    /// The real editable field, made only for the cell being edited and kept
    /// afterwards (cells are recycled, and rebuilding a field per edit would
    /// churn the field editor). Hidden whenever `endEditing()` has run.
    private(set) var editorField: NSTextField?

    /// Swap the label for an editable field seeded with `text`.
    func beginEditing(text: String, font: NSFont, delegate: NSTextFieldDelegate?) {
        let field = editorField ?? {
            let fresh = NSTextField(string: "")
            fresh.isBordered = true
            fresh.bezelStyle = .squareBezel
            fresh.isEditable = true
            fresh.isSelectable = true
            fresh.drawsBackground = true
            fresh.usesSingleLineMode = true
            fresh.lineBreakMode = .byClipping
            fresh.cell?.wraps = false
            fresh.cell?.isScrollable = true
            fresh.focusRingType = .default
            fresh.translatesAutoresizingMaskIntoConstraints = false
            addSubview(fresh)
            NSLayoutConstraint.activate([
                fresh.leadingAnchor.constraint(equalTo: leadingAnchor),
                fresh.trailingAnchor.constraint(equalTo: trailingAnchor),
                fresh.topAnchor.constraint(equalTo: topAnchor),
                fresh.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            editorField = fresh
            return fresh
        }()
        // The same face as the cell, so the text does not jump on the way in.
        field.font = font
        field.textColor = .labelColor
        field.delegate = delegate
        field.stringValue = text
        field.isHidden = false
        field.setAccessibilityIdentifier("results.cellEditor")
        textField?.isHidden = true
    }

    /// Put the label back. Safe to call on a cell that was never edited.
    func endEditing() {
        guard let field = editorField, !field.isHidden else { return }
        field.isHidden = true
        field.delegate = nil
        textField?.isHidden = false
    }

    /// True while this cell is showing its editor.
    var isEditing: Bool { editorField.map { !$0.isHidden } ?? false }

    override func layout() {
        super.layout()
        layoutPendingRule()
    }

    /// True when this cell is part of the active cell-mode selection. Setter
    /// flips text color between white (selected) and `normalTextColor`. The
    /// background fill is managed externally by the data source so it can
    /// coordinate precedence with find-match highlighting.
    var isSelected: Bool = false {
        didSet {
            guard oldValue != isSelected else { return }
            updateTextColor()
        }
    }

    /// True while the grid's window is key. A selected cell in a non-key
    /// window paints the system's unemphasized (grey) selection, and its
    /// text must stay readable on that grey, so the text colour follows.
    var selectionEmphasized: Bool = true {
        didSet {
            guard oldValue != selectionEmphasized else { return }
            updateTextColor()
        }
    }

    private func updateTextColor() {
        // Row-emphasis (.emphasized) wins when NSTableView sets it via
        // selectRowIndexes (row-number-column selection). Cell-mode selection
        // never sets .emphasized, so isSelected drives the color.
        if backgroundStyle == .emphasized {
            textField?.textColor = .alternateSelectedControlTextColor
        } else if isSelected {
            // The system's own pair for selected content: white on the accent
            // fill, label-ish grey on the unemphasized fill. `.white` was hard
            // coded here, and stayed white on the grey fill of a non-key window.
            textField?.textColor = selectionEmphasized
                ? .alternateSelectedControlTextColor : .unemphasizedSelectedTextColor
        } else {
            textField?.textColor = normalTextColor
        }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateTextColor() }
    }
}


// MARK: - ResultsDataSource

@MainActor
class ResultsDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let tableView: NSTableView

    // Data state (pushed by VC)
    var columns: [ColumnDef] = [] {
        didSet { rebuildColumnIndex() }
    }
    var rows: [[AnyCodable]] = []
    var displayRows: [Int] = []
    var columnCategories: [PGTypeCategory] = []

    // MARK: - Baked Tag Render State
    //
    // All four are pushed by `ResultsGridVC.applyTagMap` from ONE
    // `TagPalette.bake`, and all three row-keyed ones are keyed by DATA row
    // index. Nothing here is derived per row or per cell: the render paths do
    // dictionary lookups and nothing else, the same rule the cached
    // find/selection backgrounds below already follow.

    /// data row → the bar's bands, strongest first, already capped.
    var segmentsByRow: [Int: [(color: NSColor, isPartial: Bool)]] = [:]

    /// data row → the row's tooltip, listing every matching tag UNCAPPED.
    var tooltipByRow: [Int: String] = [:]

    /// data row → (data column index → tag id) for matched-cell tints.
    var tintByRow: [Int: [Int: String]] = [:]

    /// Matched-cell tint per tag id, pre-baked as CGColor at
    /// `TagPalette.cellTintAlpha` so the per-cell render path never allocates
    /// a colour — same reasoning as the cached find/selection backgrounds.
    var tagTints: [String: CGColor] = [:]

    // MARK: - Hot-path Caches

    /// Map of column identifier (raw) → tableColumn index. Rebuilt when
    /// `columns` changes. Replaces a per-cell O(N) scan via
    /// `tableView.column(withIdentifier:)` in viewFor.
    private var columnIdToIndex: [String: Int] = [:]

    /// Map of column identifier (raw) → DATA column index, i.e. what
    /// `colIndex(from:)` parses out of a "col_N" identifier. Rebuilt beside
    /// `columnIdToIndex` and for the same reason: the tint path would
    /// otherwise re-parse that string for every visible cell on realize and
    /// for every dirty cell of every drag frame. `__rownum__` has no entry.
    private var colIdToDataIndex: [String: Int] = [:]

    /// Cached display strings + fonts so the per-cell render path doesn't
    /// re-read `AppStateManager.shared.settings` and rebuild fonts on every
    /// cell realization. Refreshed via a single Combine sink on the settings
    /// publisher.
    private var nullDisplayString: String = NullDisplay.uppercase.rawValue
    private var boolTrueString: String = BoolDisplay.trueFalse.trueString
    private var boolFalseString: String = BoolDisplay.trueFalse.falseString

    // Read-only accessors so column-width measurement in ResultsGridVC uses the
    // SAME strings styleCell renders (single source of truth).
    var boolDisplayTrue: String { boolTrueString }
    var boolDisplayFalse: String { boolFalseString }
    var nullDisplay: String { nullDisplayString }
    /// The one style value the fonts come from. The column-width measurer in
    /// `ResultsGridVC` reads the SAME value (through `gridSettings`), so what
    /// is measured is drawn in the font it was measured in.
    private(set) var gridStyle: ResultsGridStyle = .default
    private var regularFont: NSFont = ResultsGridStyle.default.cellFont
    private var italicFont: NSFont = ResultsGridStyle.default.cellItalicFont

    /// How a NULL is set apart from a real value (Settings ▸ Appearance).
    private var nullStyle: NullStyle = .italic

    /// The font a NULL cell takes.
    ///
    /// Differentiate Without Color forces the italic face whatever the
    /// setting says: with that accessibility option on, a colour-only
    /// difference is no difference at all, and the slant is the only cue
    /// left. The same rule already governs a pending edit below.
    private var nullFont: NSFont {
        if AccessibilityDisplay.shared.differentiateWithoutColor { return italicFont }
        return nullStyle == .italic ? italicFont : regularFont
    }

    /// The colour a NULL cell takes. Plain reads like any other value.
    private var nullTextColor: NSColor {
        nullStyle == .plain ? .labelColor : .tertiaryLabelColor
    }
    private var rownumFont: NSFont = ResultsGridStyle.default.rowNumberFont

    private var settingsCancellable: AnyCancellable?

    // Highlight backgrounds — cached as CGColor to dodge the per-cell
    // NSColor.withAlphaComponent + .cgColor allocations that were showing up
    // in Instruments during scroll. `selectedContentBackgroundColor` is
    // appearance-dependent (light vs. dark), so refresh the cgColor whenever
    // effectiveAppearance flips. The yellow find fills are static accent
    // overlays and don't need to track appearance; the find BORDER does,
    // because `FindMatchDecoration.borderColor` shades the hue toward the
    // opposite of the ground it draws on.
    private static let findCurrentBg: CGColor = findFill(.current)
    private static let findOtherBg: CGColor = findFill(.other)

    /// One find fill, baked once at class-init. Force-unwraps the alpha
    /// because both call sites pass a matched state, and `fillAlpha` only
    /// returns nil for `.none`.
    private static func findFill(_ state: FindMatchDecoration.State) -> CGColor {
        FindMatchDecoration.hue
            .withAlphaComponent(FindMatchDecoration.fillAlpha(state)!).cgColor
    }

    private var cachedSelectionBg: CGColor = NSColor.selectedContentBackgroundColor.cgColor
    private var cachedFindBorder: CGColor = FindMatchDecoration.borderColor(isDark: false).cgColor
    private var cachedAppearanceName: NSAppearance.Name?
    /// Key-window state the cached selection colour was resolved for. Part of
    /// the cache key beside the appearance name: the system paints a selection
    /// in a non-key window with the unemphasized grey, and so does this grid.
    private var cachedIsKey: Bool = true

    /// Refresh the appearance-dependent cgColors — the selection background
    /// and the find border — when the effective appearance or the key-window
    /// state changes. Called from viewFor and
    /// updateVisibleCellSelectionAppearance — both run after AppKit has
    /// resolved effectiveAppearance on the table view.
    private func refreshAppearanceColorsIfNeeded() {
        let name = tableView.effectiveAppearance.name
        let isKey = tableView.window?.isKeyWindow ?? true
        guard name != cachedAppearanceName || isKey != cachedIsKey else { return }
        cachedAppearanceName = name
        cachedIsKey = isKey
        let isDark = tableView.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let selectionColor: NSColor = isKey
            ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor
        var selection: CGColor = selectionColor.cgColor
        var border: CGColor = FindMatchDecoration.borderColor(isDark: isDark).cgColor
        tableView.effectiveAppearance.performAsCurrentDrawingAppearance {
            selection = selectionColor.cgColor
            border = FindMatchDecoration.borderColor(isDark: isDark).cgColor
        }
        cachedSelectionBg = selection
        cachedFindBorder = border
    }

    /// Drop the colour cache and repaint the selected cells. For the accent
    /// colour changing in System Settings and for the window gaining or
    /// losing key — neither flips `effectiveAppearance.name`, which was the
    /// cache's only key, so the old accent stayed on screen until light/dark
    /// happened to change.
    func invalidateAppearanceColors() {
        cachedAppearanceName = nil
        // Forget the last-applied rect so the whole current selection counts
        // as dirty, not just its difference from the previous drag tick.
        lastAppliedSelectionRect = nil
        updateVisibleCellSelectionAppearance()
    }

    /// The one writer of a cell's selected look, for both realize sites.
    private func applySelection(_ selected: Bool, to cell: ResultCellView) {
        cell.selectionEmphasized = cachedIsKey
        cell.isSelected = selected
    }

    /// Paint (or clear) one cell's find border. Shared by the realize path
    /// (`viewFor`) and the drag fast path
    /// (`updateVisibleCellSelectionAppearance`), for the same reason
    /// `tagTintBackground` is shared: a border owned by only one of the two
    /// write sites is one edit away from disagreeing with the other.
    ///
    /// Assigned UNCONDITIONALLY, including the zero width for a non-match.
    /// `NSTableView` recycles cell views, so a cell that scrolls out of a
    /// match and back in as an ordinary cell would otherwise keep the
    /// outline and smear find onto a row that never matched.
    ///
    /// No allocation: the width is a switch over an enum and the colour is the
    /// cached cgColor.
    private func applyFindBorder(_ state: FindMatchDecoration.State, to cell: NSTableCellView) {
        let width = FindMatchDecoration.borderWidth(state)
        cell.layer?.borderWidth = width
        cell.layer?.borderColor = width > 0 ? cachedFindBorder : nil
    }

    /// The tag tint for one visible cell, or nil. Row is a DISPLAY index;
    /// colId is the table column's raw identifier. Shared by the realize path
    /// (`viewFor`) and the drag fast path
    /// (`updateVisibleCellSelectionAppearance`) so the two cannot disagree.
    ///
    /// Dictionary lookups only. It runs for every visible cell on realize AND
    /// for every dirty cell of every drag frame, so `colIdToDataIndex` stands
    /// in for a `colIndex(from:)` string parse per cell. The row-number column
    /// needs no guard of its own: only "col_N" identifiers are in that dict.
    private func tagTintBackground(displayRow: Int, colId: String) -> CGColor? {
        guard let columnIndex = colIdToDataIndex[colId],
              let tagId = TagPalette.tintTag(
                row: displayRow, displayRows: displayRows,
                tintByRow: tintByRow, column: columnIndex)
        else { return nil }
        return tagTints[tagId]
    }

    private func rebuildColumnIndex() {
        // Note: this is keyed by column NAME, but viewFor receives the
        // tableColumn whose identifier is also the column name. The dict's
        // values are the index into tableView.tableColumns — which always
        // includes the leading __rownum__ column. We build by reading the
        // live tableColumns rather than `columns` so the indexing matches
        // what viewFor needs.
        var map: [String: Int] = [:]
        var dataMap: [String: Int] = [:]
        for (i, col) in tableView.tableColumns.enumerated() {
            let raw = col.identifier.rawValue
            map[raw] = i
            // Only "col_N" identifiers parse, so `__rownum__` is left out and
            // the tint path can never resolve a data column for it.
            if let dataIndex = colIndex(from: raw) { dataMap[raw] = dataIndex }
        }
        columnIdToIndex = map
        colIdToDataIndex = dataMap
    }

    /// Signature of the AppSettings fields that actually drive grid cell
    /// rendering. Used to skip the full tableView.reloadData() when an
    /// unrelated setting (editor font, history retention, etc.) republishes.
    private struct DisplaySignature: Equatable {
        let nullDisplay: String
        let boolTrue: String
        let boolFalse: String
        let nullStyle: NullStyle
        /// Fonts: a size, a density or the monospaced switch changes every
        /// realized cell, so it belongs in the reload trigger.
        let style: ResultsGridStyle
        let maximumCellCharacters: UInt32
        let escapeControlCharacters: Bool
    }
    private var lastDisplaySignature: DisplaySignature?

    /// The chrome half of the same snapshot. Readable so a helper built after
    /// `loadView()` (`ResultsCopyExport`, `ResultsFindController`) can take the
    /// current values at birth instead of waiting for the next change.
    private(set) var gridSettings = ResultsGridSettings()
    private var hasGridSettings = false

    /// Settings ▸ Results ▸ Cells, read by `styleCell` and by the VC's width
    /// measurer through `renderedText(...)`.
    private(set) var maximumCellCharacters: UInt32 = 0
    private(set) var escapeControlCharacters = true

    /// Apply the AppSettings snapshot to local caches. Returns true if any
    /// field that affects already-rendered cells actually changed.
    @discardableResult
    private func applySettingsSnapshot(_ settings: AppSettings) -> Bool {
        let next = DisplaySignature(
            nullDisplay: settings.nullDisplay.rawValue,
            boolTrue: settings.boolDisplay.trueString,
            boolFalse: settings.boolDisplay.falseString,
            nullStyle: settings.results.nullStyle,
            style: ResultsGridStyle(settings.results),
            maximumCellCharacters: settings.results.maximumCellCharacters,
            escapeControlCharacters: settings.results.escapeControlCharacters
        )
        nullDisplayString = next.nullDisplay
        boolTrueString = next.boolTrue
        boolFalseString = next.boolFalse
        nullStyle = next.nullStyle
        gridStyle = next.style
        regularFont = next.style.cellFont
        italicFont = next.style.cellItalicFont
        rownumFont = next.style.rowNumberFont
        maximumCellCharacters = next.maximumCellCharacters
        escapeControlCharacters = next.escapeControlCharacters
        let changed = next != lastDisplaySignature
        lastDisplaySignature = next
        return changed
    }

    /// The chrome half. Returns the snapshot when it moved, nil when it did
    /// not, so the caller pushes only real changes.
    private func applyChromeSnapshot(_ settings: AppSettings) -> ResultsGridSettings? {
        let next = ResultsGridSettings(settings)
        guard !hasGridSettings || next != gridSettings else { return nil }
        hasGridSettings = true
        gridSettings = next
        return next
    }

    /// The display string for a value under the CURRENT cell settings. The
    /// single entry point for both the cell and the column-width measurer —
    /// neither may call `ResultCellText.rendered` with its own options.
    func renderedText(value: AnyCodable, category: PGTypeCategory) -> String {
        ResultCellText.rendered(
            value: value, category: category,
            boolTrue: boolTrueString, boolFalse: boolFalseString, nullString: nullDisplayString,
            maximumCharacters: maximumCellCharacters, escapeControls: escapeControlCharacters)
    }

    // Find highlight state (pushed by VC after find operations)
    var isFindVisible = false
    var findMatchSet: Set<CellAddress> = Set()
    var currentMatchRow: Int = -1
    var currentMatchColId: String?

    // Cell selection state (pushed by VC)
    var cellSelection: CellSelectionState?

    // MARK: - Inline Editing State (pushed by VC)

    /// Uncommitted cell edits, keyed by DATA row and DATA column. Pushed by
    /// `ResultsGridVC` whenever the set changes; the render path only reads it.
    var pendingEdits = PendingCellEdits()

    /// The cell currently showing an editable field, as a DISPLAY row and a
    /// TABLE column index — the same address space `cellSelection` uses, so
    /// both survive a column reorder the same way.
    var editingCell: CellPosition?

    /// Delegate of the inline editor field. `ResultsGridVC` handles Return,
    /// Tab and Escape through `control(_:textView:doCommandBy:)`.
    weak var cellEditorDelegate: NSTextFieldDelegate?

    weak var delegate: ResultsDataSourceDelegate?

    init(tableView: NSTableView) {
        self.tableView = tableView
        super.init()
        tableView.dataSource = self
        tableView.delegate = self

        // Prime the display-string caches from current settings and subscribe
        // to future changes (deduped at the publisher so unrelated settings
        // mutations don't refire). Single sink, single source of truth.
        applySettingsSnapshot(AppStateManager.shared.settings)
        _ = applyChromeSnapshot(AppStateManager.shared.settings)
        settingsCancellable = AppStateManager.shared.$settings
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] settings in
                guard let self else { return }
                // The DELIVERED value only. Re-reading the store here would
                // make this sink answer a different question than the one it
                // was woken for.
                //
                // Only reloadData when a field that affects grid rendering
                // actually changed; editor-only settings (font, line numbers,
                // word wrap) used to trigger full reloads of 10k-row grids.
                let changed = self.applySettingsSnapshot(settings)
                // Chrome first: the VC sets the row height and re-measures the
                // columns, and both of those need the fonts this object has
                // just taken from the same snapshot.
                if let chrome = self.applyChromeSnapshot(settings) {
                    self.delegate?.dataSourceGridSettingsDidChange(chrome)
                }
                if changed {
                    self.tableView.reloadData()
                }
            }

        // User-driven column reorder doesn't go through pushDataToHelpers, so
        // refresh the colId → index dict on the notification too.
        NotificationCenter.default.addObserver(
            self, selector: #selector(columnDidMove(_:)),
            name: NSTableView.columnDidMoveNotification, object: tableView
        )
    }

    @objc private func columnDidMove(_ notification: Notification) {
        rebuildColumnIndex()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        displayRows.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let colId = tableColumn?.identifier, row < displayRows.count else { return nil }
        refreshAppearanceColorsIfNeeded()
        let colIdRaw = colId.rawValue

        let cellId = NSUserInterfaceItemIdentifier("ResultCell_\(colIdRaw)")
        let cell: ResultCellView

        if let existing = tableView.makeView(withIdentifier: cellId, owner: self) as? ResultCellView {
            cell = existing
        } else {
            cell = ResultCellView()
            cell.identifier = cellId
            cell.wantsLayer = true
            let textField = ResultCellLabel(labelWithString: "")
            textField.lineBreakMode = .byTruncatingTail
            textField.maximumNumberOfLines = 1
            textField.cell?.wraps = false
            textField.cell?.isScrollable = false
            textField.font = regularFont
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(
                    equalTo: cell.leadingAnchor,
                    // One inset for every column. A tag puts no TEXT in a cell:
                    // its bar is the row view's 4pt band in the grid's leading
                    // gutter, and a matched cell's tint is a background. Neither
                    // needs room, so nothing here varies per row or per column,
                    // and the row numbers cannot go ragged. The header draws its
                    // text at the same `ResultsGridMetrics.cellInset`.
                    constant: ResultsGridMetrics.cellInset),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor,
                                                    constant: -ResultsGridMetrics.cellInset),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        let dataRowIdx = displayRows[row]

        if colIdRaw == "__rownum__" {
            cell.textField?.stringValue = "\(row + 1)"
            cell.textField?.font = rownumFont
            cell.normalTextColor = .tertiaryLabelColor
            cell.showsPendingRule = false
            (cell.textField as? ResultCellLabel)?.accessibilityValueOverride = nil

        } else {
            let rowData = rows[dataRowIdx]
            // Cache lookup, not a `colIndex(from:)` string parse: this runs for
            // every visible non-rownum cell on realize and on every scroll tick.
            // Identical result — `colIdToDataIndex` is built by running the same
            // parse over the live `tableView.tableColumns`, and AppKit only ever
            // passes a column that is in that array. Both branches of this `if`
            // are unreachable for `__rownum__`: the enclosing `else` already
            // excluded it, and it has no cache entry either way.
            if let idx = colIdToDataIndex[colIdRaw], idx < rowData.count {
                let category = idx < columnCategories.count ? columnCategories[idx] : .string
                let value = rowData[idx]
                styleCell(cell, value: value, category: category)
                // A pending edit repaints what `styleCell` just drew: the text
                // becomes the value that WILL be written, not the one that was
                // loaded. Applied after, not instead of, so the type colour and
                // the numeric alignment still come from the column.
                applyPendingEdit(to: cell, dataRow: dataRowIdx, columnIndex: idx)
            } else {
                cell.textField?.stringValue = ""
                cell.textField?.font = regularFont
                cell.normalTextColor = .labelColor
                cell.showsPendingRule = false
                (cell.textField as? ResultCellLabel)?.accessibilityValueOverride = nil
            }
        }

        // The row's tag tooltip goes on the CELL, not on the row view: the
        // cells cover the row view, and AppKit shows the tooltip of the view
        // under the pointer. Assigned unconditionally — nil for an untagged
        // row — so a recycled cell cannot keep a previous row's tag list, the
        // same rule as the background assignment below.
        cell.toolTip = tooltipByRow[dataRowIdx]

        // Find + selection state. Compute once, share both branches — the old
        // path recomputed isFindHighlighted (and the contains-checks behind it)
        // in two places per cell render.
        let cellColumnIndex = columnIdToIndex[colIdRaw] ?? -1
        let isCurrentMatch = isFindVisible && currentMatchRow == row && currentMatchColId == colIdRaw
        let isOtherMatch: Bool
        if isFindVisible && !findMatchSet.isEmpty && !isCurrentMatch {
            isOtherMatch = findMatchSet.contains(CellAddress(row: row, colId: colIdRaw))
        } else {
            isOtherMatch = false
        }
        let isFindHighlighted = isCurrentMatch || isOtherMatch
        let isInSelection = cellSelection?.contains(CellPosition(row: row, column: cellColumnIndex)) ?? false

        // Background precedence: current find match > other find match >
        // selection > tag tint > clear. Assigned exactly once. CGColors are
        // cached on the data source so scroll/realize doesn't re-allocate per
        // cell. The tag tint sits UNDER find and selection by spec: "find
        // highlight and cell selection stay above tints".
        let findState = FindMatchDecoration.state(isCurrent: isCurrentMatch, isOther: isOtherMatch)
        if isCurrentMatch {
            cell.layer?.backgroundColor = Self.findCurrentBg
        } else if isOtherMatch {
            cell.layer?.backgroundColor = Self.findOtherBg
        } else if isInSelection {
            cell.layer?.backgroundColor = cachedSelectionBg
        } else if let tint = tagTintBackground(displayRow: row, colId: colIdRaw) {
            cell.layer?.backgroundColor = tint
        } else {
            cell.layer?.backgroundColor = nil
        }

        // The border is what tells a find result apart from a tag's matched-cell
        // tint, which is a fill and only a fill. Assigned for every cell, so a
        // recycled one cannot keep an outline it no longer earns.
        applyFindBorder(findState, to: cell)

        // Always assign so a recycled cell can't carry stale selected-state
        // into a non-selected slot. Find-match cells suppress the white text
        // override even when within the selection rectangle.
        applySelection(isInSelection && !isFindHighlighted, to: cell)

        // The editor, last: it covers the cell, so nothing above needs to know
        // about it. Assigned unconditionally in both directions — a recycled
        // cell that once held the editor must not scroll back in still showing
        // a field over a row nobody is editing.
        if let editing = editingCell, editing.row == row, editing.column == cellColumnIndex {
            cell.beginEditing(text: cell.textField?.stringValue ?? "",
                              font: regularFont, delegate: cellEditorDelegate)
        } else {
            cell.endEditing()
        }

        return cell
    }

    /// Repaint one cell to show the value an uncommitted edit will write.
    ///
    /// Two channels, never colour alone. The 2pt accent rule down the leading
    /// edge is the colour one; the italic face is the shape one, and it is on
    /// whenever the user has asked to differentiate without colour — or when
    /// the pending value is NULL, which the grid already renders italic, so a
    /// pending NULL looks exactly like a loaded one plus the rule.
    ///
    /// The accessibility VALUE carries both halves of the change, because a
    /// rule and a slant are invisible to a screen reader: "edited, was alice".
    private func applyPendingEdit(to cell: ResultCellView, dataRow: Int, columnIndex: Int) {
        guard let edit = pendingEdits.edit(at: dataRow, columnIndex: columnIndex) else {
            cell.showsPendingRule = false
            (cell.textField as? ResultCellLabel)?.accessibilityValueOverride = nil
            return
        }
        let isNull = edit.newText == nil
        cell.textField?.stringValue = isNull ? nullDisplayString : (edit.newText ?? "")
        if isNull {
            cell.textField?.font = nullFont
            cell.normalTextColor = nullTextColor
        } else {
            cell.textField?.font = AccessibilityDisplay.shared.differentiateWithoutColor
                ? italicFont : regularFont
            cell.normalTextColor = .controlAccentColor
        }
        cell.showsPendingRule = true

        // On the LABEL, not on the cell view. An NSTableCellView is not itself
        // an accessibility element, so a value set on it never reaches the
        // tree — the text field is what VoiceOver actually lands on, and
        // reading it back through the AX API is what showed this.
        //
        // The new value stays at the front: replacing it outright with the
        // note would announce the history and hide the value the user is
        // looking at.
        let shown = cell.textField?.stringValue ?? ""
        let wasText = edit.oldText ?? nullDisplayString
        (cell.textField as? ResultCellLabel)?.accessibilityValueOverride =
            String(localized: "\(shown), edited, was \(wasText)")
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("TaggedRow")
        let view = tableView.makeView(withIdentifier: identifier, owner: self) as? TaggedRowView
            ?? {
                let fresh = TaggedRowView()
                fresh.identifier = identifier
                return fresh
            }()

        // A lookup, not a computation: the bands were baked when the tag map
        // landed. The row's tooltip is NOT set here — it belongs on the cells,
        // which cover this view; see `viewFor`. The row view does take the same
        // text as its accessibility VALUE: a tooltip needs a pointer, and the
        // bands carry their identity in colour alone.
        guard let dataRow = TagPalette.dataRow(displayRow: row, displayRows: displayRows),
              let bands = segmentsByRow[dataRow]
        else {
            view.clearTag()
            return view
        }
        view.configure(segments: bands, tagDescription: tooltipByRow[dataRow])
        return view
    }

    // MARK: - Cell Selection Fast Path

    /// Cells inside this rectangle were assigned selection styling by the
    /// previous `updateVisibleCellSelectionAppearance` call. Tracking it lets
    /// each drag tick repaint only `prev ∪ current` instead of every visible
    /// cell — the old code did ~visibleRows × allColumns lookups per frame
    /// during drag, which choked on wide result sets.
    private var lastAppliedSelectionRect: (rowLo: Int, rowHi: Int, colLo: Int, colHi: Int)?

    /// Iterates visible cells and updates fill + text color for cell selection
    /// without calling reloadData(). Used during drag for smooth updates.
    func updateVisibleCellSelectionAppearance() {
        let visibleRows = tableView.rows(in: tableView.visibleRect)
        guard visibleRows.length > 0 else { return }
        refreshAppearanceColorsIfNeeded()

        let visRowLo = visibleRows.location
        let visRowHi = visibleRows.location + visibleRows.length - 1
        let colCount = tableView.numberOfColumns
        guard colCount > 0 else { return }

        // Current selection rect, clipped to the visible rows.
        let newRect: (rowLo: Int, rowHi: Int, colLo: Int, colHi: Int)?
        if let range = cellSelection?.selectedRange {
            let rLo = max(range.topLeft.row, visRowLo)
            let rHi = min(range.bottomRight.row, visRowHi)
            let cLo = max(range.topLeft.column, 0)
            let cHi = min(range.bottomRight.column, colCount - 1)
            newRect = (rLo <= rHi && cLo <= cHi) ? (rLo, rHi, cLo, cHi) : nil
        } else {
            newRect = nil
        }

        // Build the dirty rectangle = previous-applied ∪ current. Cells in the
        // intersection are touched too — cheap relative to the original
        // visible-rect sweep, and avoids any staleness if prev coords no
        // longer point to the same data (column reorder, reloadData, etc.).
        let prev = lastAppliedSelectionRect
        let dirty: (rowLo: Int, rowHi: Int, colLo: Int, colHi: Int)?
        switch (prev, newRect) {
        case (nil, nil):
            dirty = nil
        case let (.some(p), nil):
            dirty = (max(p.rowLo, visRowLo), min(p.rowHi, visRowHi), p.colLo, min(p.colHi, colCount - 1))
        case let (nil, .some(n)):
            dirty = n
        case let (.some(p), .some(n)):
            dirty = (
                max(min(p.rowLo, n.rowLo), visRowLo),
                min(max(p.rowHi, n.rowHi), visRowHi),
                max(0, min(p.colLo, n.colLo)),
                min(max(p.colHi, n.colHi), colCount - 1)
            )
        }

        if let d = dirty, d.rowLo <= d.rowHi, d.colLo <= d.colHi {
            CATransaction.begin()
            CATransaction.setDisableActions(true)

            for row in d.rowLo...d.rowHi {
                for colIdx in d.colLo...d.colHi {
                    guard let cell = tableView.view(atColumn: colIdx, row: row, makeIfNecessary: false) as? ResultCellView else { continue }
                    let colId = tableView.tableColumns[colIdx].identifier.rawValue
                    // Split current from other the same way `viewFor` does, so
                    // the two write sites can hand `applyFindBorder` the same
                    // state for the same cell. `isFindHighlighted` alone would
                    // not say which border a match earns.
                    let isCurrentMatch = isFindVisible
                        && currentMatchRow == row && currentMatchColId == colId
                    let isOtherMatch = isFindVisible && !findMatchSet.isEmpty && !isCurrentMatch
                        && findMatchSet.contains(CellAddress(row: row, colId: colId))
                    let findState = FindMatchDecoration.state(
                        isCurrent: isCurrentMatch, isOther: isOtherMatch)
                    let isFindHighlighted = findState != .none

                    let isInSelection = cellSelection?.contains(CellPosition(row: row, column: colIdx)) ?? false
                    // Deselect must fall back to the TAG TINT, not to clear —
                    // this path writes cells `viewFor` already painted, and a
                    // bare nil here erases a matched cell's tint during a
                    // drag-select.
                    if !isFindHighlighted {
                        cell.layer?.backgroundColor = isInSelection
                            ? cachedSelectionBg
                            : tagTintBackground(displayRow: row, colId: colId)
                    }
                    // Re-asserts what `viewFor` already set: find state cannot
                    // change while a drag is in flight. It runs here anyway so
                    // the border has ONE owner across both write sites, the
                    // same rule the tint background follows.
                    applyFindBorder(findState, to: cell)
                    applySelection(isInSelection && !isFindHighlighted, to: cell)
                }
            }

            CATransaction.commit()
        }

        lastAppliedSelectionRect = newRect
    }

    /// The `#` column stays at index 0. The selection controller and the
    /// row-number click path locate it there, and a saved column order is
    /// restored by position.
    func tableView(_ tableView: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
        columnIndex != 0 && newColumnIndex != 0
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        delegate?.dataSourceSortDescriptorsDidChange(oldDescriptors)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        delegate?.dataSourceSelectionDidChange()
    }

    // MARK: - Cell Styling

    private func styleCell(_ cell: ResultCellView, value: AnyCodable, category: PGTypeCategory) {
        guard let textField = cell.textField else { return }
        textField.stringValue = renderedText(value: value, category: category)

        // Numbers line up on their last digit; everything else reads from the
        // left. Assigned on EVERY realize so a recycled cell cannot keep the
        // alignment of the column it last served.
        textField.alignment = category == .numeric ? .right : .left

        if value.isNull {
            textField.font = nullFont
            cell.normalTextColor = nullTextColor
            return
        }
        textField.font = regularFont
        let color: NSColor
        switch category {
        case .numeric: color = .systemBlue
        case .boolean:
            let low = value.displayString.lowercased()
            color = (low == "t" || low == "true") ? .systemGreen
                  : (low == "f" || low == "false") ? .systemRed : .labelColor
        case .temporal: color = .systemPurple
        case .json: color = .systemOrange
        case .array: color = .secondaryLabelColor
        case .string: color = .labelColor
        }
        cell.normalTextColor = color
    }
}
