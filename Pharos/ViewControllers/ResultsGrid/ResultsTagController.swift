import AppKit

// MARK: - ResultsTagController

/// Owns the results-grid context menu: the tag section first, then the copy
/// section supplied by `ResultsCopyExport`. One helper, one job — this class
/// decides tag items; it never composes or writes a tag itself (the grid's
/// creation flow does).
@MainActor
final class ResultsTagController: NSObject, NSMenuDelegate {

    private weak var grid: ResultsGridVC?
    private let copyExport: ResultsCopyExport

    /// Item tags: 20 = "Add Tag…", 21 = "Remove From Tag", 22 = "Manage Tags…".
    private static let addTag = 20
    private static let removeTag = 21
    private static let manageTags = 22

    init(grid: ResultsGridVC, copyExport: ResultsCopyExport) {
        self.grid = grid
        self.copyExport = copyExport
        super.init()
    }

    func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        let add = menu.addItem(withTitle: "Add Tag…", action: #selector(addTagAction),
                               keyEquivalent: "")
        add.tag = Self.addTag
        add.target = self

        let remove = menu.addItem(withTitle: "Remove From Tag\u{2026}",
                                  action: #selector(removeTagAction), keyEquivalent: "")
        remove.tag = Self.removeTag
        remove.target = self

        let manage = menu.addItem(withTitle: "Manage Tags…",
                                  action: #selector(manageTagsAction), keyEquivalent: "")
        manage.tag = Self.manageTags
        manage.target = self

        menu.addItem(.separator())
        copyExport.addCopyItems(to: menu)
        return menu
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Copy section first: it must refresh even if the grid is gone.
        copyExport.updateCopyItems(in: menu)
        guard let grid else { return }

        let targets = grid.tagTargetDataRows()
        if let add = menu.item(withTag: Self.addTag) {
            // Any row can be tagged: matching needs columns and values only, so
            // a result with no source table is no longer refused.
            add.isEnabled = !targets.isEmpty
            add.title = targets.count > 1 ? "Add Tag to \(targets.count) Rows…" : "Add Tag…"
        }
        if let remove = menu.item(withTag: Self.removeTag) {
            // Only a row that COMPLETES a tuple can have one removed; a partial
            // match names no single tuple to drop.
            let removable = targets.contains { row in
                grid.matchesByRow[row]?.contains { !$0.solidTupleIds.isEmpty } ?? false
            }
            remove.isEnabled = removable
        }
        if let manage = menu.item(withTag: Self.manageTags) {
            // Needs a tag to manage, not a row: enabled off-selection too.
            manage.isEnabled = !TagStore.shared.tags.isEmpty
        }
    }

    // MARK: Actions

    @objc private func addTagAction() {
        guard let grid else { return }
        grid.presentTagSheet(on: grid.tagTargetDataRows())
    }

    @objc private func removeTagAction() {
        guard let grid else { return }
        grid.presentTagRemovalSheet(on: grid.tagTargetDataRows())
    }

    @objc private func manageTagsAction() {
        guard let grid else { return }
        grid.presentTagManageSheet(preselect: nil)
    }
}
