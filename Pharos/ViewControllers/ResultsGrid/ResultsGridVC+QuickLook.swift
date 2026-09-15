import AppKit
import Quartz

// MARK: - Quick Look Session

/// The temporary files behind one showing of the Quick Look panel, and which
/// cell each of them came from.
///
/// One session lives for as long as the panel is previewing THIS grid: opening
/// the panel makes it, closing the panel deletes its folder. Re-selecting while
/// the panel is up appends to the same session rather than making a new one, so
/// the panel never reads a file that has just been removed under it; the whole
/// folder goes at the end, in one call.
final class QuickLookPreviewSession {

    /// One previewed cell: the file, plus the grid coordinates it came from, so
    /// the zoom animation can find the cell again.
    struct Item {
        let url: URL
        /// Index into `displayRows`, i.e. a row of the table as shown.
        let displayRow: Int
        /// Index into `tableView.tableColumns`, so a reordered grid still lands
        /// on the right one.
        let tableColumn: Int
    }

    private let builder = QuickLookItemBuilder()
    private(set) var items: [Item] = []
    /// Never reset: a file name is unique for the session's life, so a refresh
    /// cannot overwrite a file the panel may still be reading.
    private var nextFileIndex = 0

    func replaceItems(_ cells: [(value: String?, columnName: String, typeName: String,
                                 displayRow: Int, tableColumn: Int)]) {
        var built: [Item] = []
        for cell in cells {
            do {
                let url = try builder.makeItem(value: cell.value, columnName: cell.columnName,
                                               typeName: cell.typeName, index: nextFileIndex)
                nextFileIndex += 1
                built.append(Item(url: url, displayRow: cell.displayRow,
                                  tableColumn: cell.tableColumn))
            } catch {
                Log.ui.error("Quick Look could not write a preview file: \(error.localizedDescription, privacy: .public)")
            }
        }
        items = built
    }

    func cleanUp() {
        items = []
        builder.cleanUp()
    }
}

// MARK: - Quick Look

extension ResultsGridVC: QLPreviewPanelDataSource, QLPreviewPanelDelegate, ResultsQuickLookToggling {

    /// Ceiling on one preview. The panel's index bar is unusable long before
    /// this, and each item is a file write; a Select All on a 100 000-row result
    /// must not try to write a hundred thousand files.
    static let quickLookItemCap = 200

    /// True when there is something to preview. Also what decides whether this
    /// grid takes control of the shared panel at all.
    var hasQuickLookSelection: Bool {
        guard let state = cellSelectionController?.state else { return false }
        return state.isRowMode || state.selectedRange != nil
    }

    // MARK: - Space

    /// Space, and the context menu's "Quick Look" item. Reached from the table
    /// through the responder chain, so the table never has to know this class.
    @objc func toggleQuickLook(_ sender: Any?) {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        } else {
            QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Panel control (NSResponder)

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        hasQuickLookSelection
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
        let session = QuickLookPreviewSession()
        quickLookSession = session
        session.replaceItems(quickLookCells())
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        if (panel.dataSource as AnyObject?) === self { panel.dataSource = nil }
        if (panel.delegate as AnyObject?) === self { panel.delegate = nil }
        quickLookSession?.cleanUp()
        quickLookSession = nil
        // The panel was its own key window; hand the keyboard back to the grid
        // so the next arrow key moves the selection rather than going nowhere.
        view.window?.makeFirstResponder(tableView)
    }

    /// Re-reads the selection into the open panel. Called after every selection
    /// change; does nothing unless the panel is up and showing THIS grid.
    func refreshQuickLookIfNeeded() {
        guard QLPreviewPanel.sharedPreviewPanelExists() else { return }
        let panel = QLPreviewPanel.shared()!
        guard panel.isVisible, (panel.dataSource as AnyObject?) === self,
              let session = quickLookSession else { return }
        session.replaceItems(quickLookCells())
        panel.reloadData()
    }

    // MARK: - Data source

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        quickLookSession?.items.count ?? 0
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard let items = quickLookSession?.items, index >= 0, index < items.count else { return nil }
        // NSURL, not URL: `QLPreviewItem` is an @objc protocol that NSURL
        // conforms to and the Swift value type does not.
        return items[index].url as NSURL
    }

    // MARK: - Delegate

    /// Where the panel zooms from and back to: the cell on screen that the
    /// current item was built from.
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        let index = panel.currentPreviewItemIndex
        guard let items = quickLookSession?.items, index >= 0, index < items.count else { return .zero }
        let cell = items[index]
        guard cell.displayRow >= 0, cell.displayRow < tableView.numberOfRows,
              cell.tableColumn >= 0, cell.tableColumn < tableView.numberOfColumns else { return .zero }
        let rect = tableView.frameOfCell(atColumn: cell.tableColumn, row: cell.displayRow)
        // A cell scrolled out of view has no place to zoom from; the panel
        // fades in instead, which is the documented meaning of `.zero`.
        guard tableView.visibleRect.intersects(rect), let window = tableView.window else { return .zero }
        return window.convertToScreen(tableView.convert(rect, to: nil))
    }

    /// Arrow keys keep driving the grid while the panel is up, so a user can
    /// walk a column and watch each value. Everything else — Space, Escape, the
    /// panel's own index bar — stays with the panel.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, (123...126).contains(Int(event.keyCode)) else { return false }
        tableView.keyDown(with: event)
        return true
    }

    // MARK: - The cells to preview

    /// The selected cells in row-major order, capped. Cell mode previews the
    /// chosen block; row mode previews every data column of the chosen rows,
    /// which is what "the row" means everywhere else in the grid.
    private func quickLookCells() -> [(value: String?, columnName: String, typeName: String,
                                       displayRow: Int, tableColumn: Int)] {
        guard let state = cellSelectionController?.state else { return [] }
        let tableCols = tableView.tableColumns

        let rowIndices: [Int]
        let columnIndices: [Int]
        if state.isRowMode {
            rowIndices = Array(state.selectedRows)
            columnIndices = Array(0..<tableCols.count)
        } else if let range = state.selectedRange {
            rowIndices = Array(range.topLeft.row...range.bottomRight.row)
            columnIndices = Array(range.topLeft.column...range.bottomRight.column)
        } else {
            return []
        }

        // Resolve the table columns to DATA columns once, through the
        // identifier — a reordered grid must preview the column the user chose,
        // not the one that happens to sit at that position in the model.
        let resolved: [(tableColumn: Int, dataColumn: Int)] = columnIndices.compactMap { idx in
            guard idx >= 0, idx < tableCols.count else { return nil }
            let id = tableCols[idx].identifier.rawValue
            guard id != "__rownum__", let dataIdx = colIndex(from: id),
                  dataIdx < columns.count else { return nil }
            return (idx, dataIdx)
        }
        guard !resolved.isEmpty else { return [] }

        var cells: [(value: String?, columnName: String, typeName: String,
                     displayRow: Int, tableColumn: Int)] = []
        for displayRow in rowIndices {
            guard displayRow >= 0, displayRow < displayRows.count else { continue }
            let dataRow = displayRows[displayRow]
            guard dataRow >= 0, dataRow < rows.count else { continue }
            let rowValues = rows[dataRow]
            for column in resolved {
                guard column.dataColumn < rowValues.count else { continue }
                let value = rowValues[column.dataColumn]
                cells.append((value: value.isNull ? nil : value.displayString,
                              columnName: columns[column.dataColumn].name,
                              typeName: columns[column.dataColumn].dataType,
                              displayRow: displayRow,
                              tableColumn: column.tableColumn))
                if cells.count >= Self.quickLookItemCap { return cells }
            }
        }
        return cells
    }
}
