import AppKit

/// The Variables pull-down in the editor's header row, and Change Variable.
///
/// The pull-down lists every `{{name}}` the tab's cards use. Each has
/// Change To ▸ (the variables this tab's connection can use, `VariableScope`)
/// and Show in Variable Manager. Change To writes every `{{name}}` in the
/// tab as the chosen variable, as one undo step (`CardStackVC.changeVariable`).
/// A right-click on a `{{name}}` chip offers the same Change To list
/// (`SQLTextView.changeVariableMenu`).
extension EditorPaneVC: NSMenuDelegate {

    func setUpVariablesDropdown() {
        let button = variablesDropdown
        button.bezelStyle = .recessed
        button.isBordered = false
        button.translatesAutoresizingMaskIntoConstraints = false
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        let title = String(localized: "Variables in This Tab")
        // Pull-down: the first item is the button's face.
        button.addItem(withTitle: "")
        button.item(at: 0)?.image = NSImage(systemSymbolName: "curlybraces", accessibilityDescription: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        button.toolTip = title
        button.setAccessibilityIdentifier("editor.variables")
        button.setAccessibilityLabel(title)
        button.menu?.delegate = self
        button.isHidden = true
        cardStack.changeVariableMenu = { [weak self] name in self?.changeVariableMenu(from: name) }
    }

    /// Shown only while the tab's cards use a variable.
    func updateVariablesDropdown() {
        variablesDropdown.isHidden = !VariableSubstitutor.containsTokens(cardStack.allText)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === variablesDropdown.menu else { return }
        while menu.numberOfItems > 1 { menu.removeItem(at: 1) }
        menu.addItem(.sectionHeader(title: String(localized: "Variables in This Tab")))
        let defined = QueryVariableStore.shared.definedNames(for: session.tab?.connectionId)
        for name in VariableSubstitutor.referencedNames(in: cardStack.allText).sorted() {
            let item = NSMenuItem(title: "{{\(name)}}", action: nil, keyEquivalent: "")
            if !defined.contains(name) {
                item.subtitle = String(localized: "Undefined")
                item.image = NSImage(systemSymbolName: "exclamationmark.triangle",
                                     accessibilityDescription: String(localized: "Undefined"))
            }
            item.submenu = variableActionsMenu(for: name)
            menu.addItem(item)
        }
    }

    private func variableActionsMenu(for name: String) -> NSMenu {
        let menu = NSMenu()
        let change = NSMenuItem(title: String(localized: "Change To"), action: nil, keyEquivalent: "")
        change.submenu = changeVariableMenu(from: name)
        menu.addItem(change)
        menu.addItem(.separator())
        // What `{{name}}` puts into the query when it runs.
        let preview = VariableMenuPreview.preview(
            for: name, variables: QueryVariableStore.shared.available(for: session.tab?.connectionId))
        let renders = NSMenuItem(title: VariableMenuPreview.text(preview), action: nil, keyEquivalent: "")
        renders.isEnabled = false
        switch preview {
        case .undefined, .invalid, .empty:
            renders.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        case .value:
            break
        }
        menu.addItem(renders)
        menu.addItem(ClosureMenuItem(title: String(localized: "Show in Variable Manager")) { [weak self] in
            guard let self else { return }
            self.delegate?.editorPane(self, didChooseVariable: name)
        })
        return menu
    }

    /// The variables `{{name}}` can become: those this tab's connection can
    /// use, by name, each with what it renders as (`VariableMenuPreview`).
    func changeVariableMenu(from name: String) -> NSMenu {
        let menu = NSMenu()
        // One row per name; a repeated name resolves to its last definition,
        // as `VariableSubstitutor.render` does.
        var byName: [String: QueryVariable] = [:]
        for variable in QueryVariableStore.shared.available(for: session.tab?.connectionId)
        where variable.name != name && VariableSubstitutor.isValidName(variable.name) {
            byName[variable.name] = variable
        }
        guard !byName.isEmpty else {
            let none = NSMenuItem(title: String(localized: "No Other Variables"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return menu
        }
        for variable in byName.values.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            let item = ClosureMenuItem(title: variable.name) { [weak self] in
                self?.changeVariable(from: name, to: variable.name)
            }
            if case let .value(text, truncated) = VariableMenuPreview.preview(for: variable.name, variables: [variable]) {
                item.subtitle = text + (truncated ? "…" : "")
            }
            menu.addItem(item)
        }
        return menu
    }

    /// Write every `{{from}}` in the tab as `{{to}}`. Locked versions keep
    /// the SQL their results came from; when one is left as it was, say so.
    func changeVariable(from: String, to: String) {
        let plan = cardStack.changeVariable(from: from, to: to)
        updateVariablesDropdown()
        guard plan.lockedCardsSkipped > 0, let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = plan.isEmpty
            ? String(localized: "No cards were changed")
            : String(localized: "Some versions still use {{\(from)}}")
        alert.informativeText = String(localized: "Locked versions keep the SQL their results came from. \(CountedNounText.phrase(plan.lockedCardsSkipped, "version")) not changed.")
        alert.beginSheetModal(for: window)
    }
}
