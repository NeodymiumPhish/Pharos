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

    /// Item tags: 20 = "Tag Row" submenu holder, 21 = "Remove Tag",
    /// 30+ = label items inside the submenu (30 + palette index).
    private static let tagSubmenuTag = 20
    private static let removeTag = 21

    init(grid: ResultsGridVC, copyExport: ResultsCopyExport) {
        self.grid = grid
        self.copyExport = copyExport
        super.init()
    }

    func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        let tagItem = menu.addItem(withTitle: "Tag Row", action: nil, keyEquivalent: "")
        tagItem.tag = Self.tagSubmenuTag
        let submenu = NSMenu()
        // One enablement regime for both menus: the parent is manual, so the
        // submenu is too — otherwise a future NSMenuItemValidation conformance
        // would silently start gating the label items.
        submenu.autoenablesItems = false
        tagItem.submenu = submenu

        let remove = menu.addItem(withTitle: "Remove Tag", action: #selector(removeTagAction), keyEquivalent: "")
        remove.tag = Self.removeTag
        remove.target = self

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
        let canTag = grid.rowIdentity != nil && !targets.isEmpty
        let existing = targets.compactMap { grid.tagsByRow[$0] }

        if let tagItem = menu.item(withTag: Self.tagSubmenuTag), let sub = tagItem.submenu {
            tagItem.isEnabled = canTag
            tagItem.title = targets.count > 1 ? "Tag Rows" : "Tag Row"
            // Scope decision 1: a disabled item must say why.
            tagItem.toolTip = grid.rowIdentity == nil
                ? "This result has no source table."
                : nil
            sub.removeAllItems()
            for label in TagStore.shared.labels {
                let item = sub.addItem(withTitle: label.name, action: #selector(tagWithLabel(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = label.id
                item.image = swatch(for: label)
                // A tick when every target already carries this label.
                let carriesIt = !targets.isEmpty && targets.allSatisfy { grid.tagsByRow[$0]?.labelId == label.id }
                item.state = carriesIt ? .on : .off
            }
            if !TagStore.shared.labels.isEmpty { sub.addItem(.separator()) }
            let newLabel = sub.addItem(withTitle: "New Label…", action: #selector(newLabelAction), keyEquivalent: "")
            newLabel.target = self
        }
        if let remove = menu.item(withTag: Self.removeTag) {
            remove.isEnabled = !existing.isEmpty
            remove.title = existing.count > 1 ? "Remove Tags" : "Remove Tag"
        }
    }

    // MARK: Actions

    @objc private func tagWithLabel(_ sender: NSMenuItem) {
        guard let grid, let labelId = sender.representedObject as? String else { return }
        grid.toggleTag(labelId: labelId, on: grid.tagTargetDataRows())
    }

    @objc private func newLabelAction() {
        guard let grid else { return }
        let targets = grid.tagTargetDataRows()
        grid.promptForNewLabel { label in
            grid.toggleTag(labelId: label.id, on: targets)
        }
    }

    @objc private func removeTagAction() {
        guard let grid,
              let connectionId = AppStateManager.shared.activeConnectionId else { return }
        let ids = grid.tagTargetDataRows().compactMap { grid.tagsByRow[$0]?.id }
        do { try TagStore.shared.removeTags(ids: ids, connectionId: connectionId) }
        catch { NSLog("Tag remove failed: \(error)"); NSSound.beep() }
    }

    /// A 10 pt colour dot for the label's menu item.
    private func swatch(for label: TagLabel) -> NSImage {
        let size = NSSize(width: 10, height: 10)
        return NSImage(size: size, flipped: false) { rect in
            TagLabelPalette.color(at: label.colorIndex).setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
    }
}
