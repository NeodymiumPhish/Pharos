import AppKit

/// Turns `[SettingsSection]` into the furniture — headers, group boxes, rows,
/// controls — and owns the two-way traffic between controls and bindings.
///
/// One action for every control: `controlChanged(_:)` finds the writer for
/// the sender, asks the `isPopulating` hook whether writes are allowed, writes
/// the value, then re-evaluates the rows that depend on it. `refreshAll()`
/// pulls every binding into its control and re-evaluates availability and
/// dependency dimming. AppKit only, so it is tested standalone by
/// `scripts/test-settings-form-builder.sh`.
@MainActor
final class SettingsFormBuilder: NSObject, NSTextFieldDelegate, NSComboBoxDelegate {

    /// Hook: while this returns true, control actions do not write. The pane
    /// sets it to its own `isPopulating` flag.
    var isPopulating: () -> Bool = { false }

    /// Live typing is written after this long a pause. Editing ending (Tab,
    /// Return, focus loss) writes at once.
    var textCommitDelay: TimeInterval = 0.3

    private(set) var paneId = ""
    private var items: [String: SettingsItem] = [:]
    private var order: [String] = []
    private var rows: [String: SettingsRow] = [:]
    private var controls: [String: NSView] = [:]
    private var refreshers: [String: () -> Void] = [:]
    /// Combo boxes only: reload the list. Kept apart from `refreshers`
    /// because a refresher is skipped while its field is being edited, and
    /// a list that has just arrived must show even then.
    private var listRefreshers: [String: () -> Void] = [:]
    private var writers: [ObjectIdentifier: (NSControl) -> Void] = [:]
    private var textCommitters: [ObjectIdentifier: (NSTextField) -> Void] = [:]
    private var controlItemIds: [ObjectIdentifier: String] = [:]
    /// Number fields only: what is wrong with the typed text, or nil.
    private var rangeProblems: [ObjectIdentifier: (String) -> String?] = [:]
    private var toggleBindings: [String: SettingsBinding<Bool>] = [:]
    private var pendingCommits: [ObjectIdentifier: Timer] = [:]
    private var actionHandlers: [ObjectIdentifier: () -> Void] = [:]
    private var pathBindings: [ObjectIdentifier: (binding: SettingsBinding<String>, directories: Bool, label: NSTextField)] = [:]

    // MARK: - Building

    /// The section views, top to bottom, ready for `SettingsFormScroll.makePane`.
    func buildSectionViews(_ sections: [SettingsSection], paneId: String) -> [NSView] {
        self.paneId = paneId
        return sections.map(buildSection)
    }

    /// The sections stacked in one vertical view (no outer insets).
    func build(_ sections: [SettingsSection], paneId: String) -> NSView {
        let stack = NSStackView(views: buildSectionViews(sections, paneId: paneId))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = SettingsMetrics.sectionSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.spanArrangedSubviewsFullWidth()
        return stack
    }

    private func buildSection(_ section: SettingsSection) -> NSView {
        var parts: [NSView] = []
        if let title = section.title, !title.isEmpty {
            parts.append(SettingsSectionHeader.make(title))
        }
        let rowViews = section.items.map(buildRow)
        let box = SettingsGroupBox(title: section.title, rows: rowViews)
        if section.items.contains(where: { $0.icon != nil }) {
            box.separatorLeadingInset = SettingsMetrics.rowInsetH + SettingsMetrics.rowIconSize + SettingsMetrics.iconTextGap
        }
        parts.append(box)
        if !section.footerButtons.isEmpty {
            let buttons = section.footerButtons.map { footer -> NSButton in
                let button = SettingsControlFactory.actionButton(title: footer.title, destructive: footer.destructive)
                button.target = self
                button.action = #selector(controlChanged(_:))
                button.setAccessibilityIdentifier("settings.\(paneId).\(footer.id)")
                actionHandlers[ObjectIdentifier(button)] = footer.handler
                return button
            }
            parts.append(SettingsFooterButtonRow(buttons: buttons))
        }
        let stack = NSStackView(views: parts)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = SettingsMetrics.headerToBoxGap
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.spanArrangedSubviewsFullWidth()
        return stack
    }

    private func buildRow(_ item: SettingsItem) -> NSView {
        items[item.id] = item
        order.append(item.id)

        if case .empty(let text) = item.kind {
            return SettingsEmptyRow(text: text)
        }

        let icon = item.icon.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        let indent: CGFloat = item.dependsOn == nil ? 0 : SettingsMetrics.dependentIndent
        var placement: SettingsRow.ControlPlacement = .trailing
        let control = makeControl(for: item, placement: &placement)

        var slot: NSView? = control
        if let help = item.help {
            let info = SettingsInfoButton(help: help)
            if let control {
                let pair = NSStackView(views: [control, info])
                pair.orientation = .horizontal
                pair.spacing = 6
                pair.translatesAutoresizingMaskIntoConstraints = false
                slot = pair
            } else {
                // A row with no control still gets its ⓘ. This used to be
                // dropped on the floor: `.display` rows report rather than
                // ask, so they have no control, and they are exactly the rows
                // whose caption is most likely to need the long version.
                slot = info
            }
        }

        let row = SettingsRow(icon: icon, title: item.title, caption: item.caption, control: slot,
                              placement: placement, indent: indent)
        if let control {
            control.setAccessibilityIdentifier("settings.\(paneId).\(item.id)")
            control.setAccessibilityTitleUIElement(row.titleLabel)
            if let caption = item.caption { control.setAccessibilityHelp(caption) }
            controls[item.id] = control
            controlItemIds[ObjectIdentifier(control)] = item.id
        }
        rows[item.id] = row
        return row
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func makeControl(for item: SettingsItem, placement: inout SettingsRow.ControlPlacement) -> NSView? {
        switch item.kind {
        case .toggle(let binding):
            let toggle = SettingsControlFactory.toggle()
            wire(toggle)
            toggleBindings[item.id] = binding
            writers[ObjectIdentifier(toggle)] = { control in
                binding.set((control as? NSSwitch)?.state == .on)
            }
            refreshers[item.id] = { toggle.state = binding.get() ? .on : .off }
            return toggle

        case .popup(let choice):
            let popup = SettingsControlFactory.popup(titles: choice.options.map(\.title))
            wire(popup)
            writers[ObjectIdentifier(popup)] = { control in
                guard let popup = control as? NSPopUpButton else { return }
                let index = popup.indexOfSelectedItem
                guard choice.options.indices.contains(index) else { return }
                choice.binding.set(choice.options[index].value)
            }
            refreshers[item.id] = {
                let value = choice.binding.get()
                let index = choice.options.firstIndex { $0.value == value } ?? 0
                popup.selectItem(at: index)
            }
            return popup

        case .segmented(let choice):
            let segmented = SettingsControlFactory.segmented(labels: choice.options.map(\.title))
            wire(segmented)
            writers[ObjectIdentifier(segmented)] = { control in
                guard let segmented = control as? NSSegmentedControl else { return }
                let index = segmented.selectedSegment
                guard choice.options.indices.contains(index) else { return }
                choice.binding.set(choice.options[index].value)
            }
            refreshers[item.id] = {
                let value = choice.binding.get()
                segmented.selectedSegment = choice.options.firstIndex { $0.value == value } ?? 0
            }
            return segmented

        case .tiles(let choice, let art):
            let size = SettingsTilePicker.tileSize
            let picker = SettingsTilePicker(
                tiles: choice.options.map { .init(title: $0.title, image: art($0, size)) })
            wire(picker)
            writers[ObjectIdentifier(picker)] = { control in
                guard let picker = control as? SettingsTilePicker else { return }
                let index = picker.selectedIndex
                guard choice.options.indices.contains(index) else { return }
                choice.binding.set(choice.options[index].value)
            }
            refreshers[item.id] = {
                let value = choice.binding.get()
                picker.selectedIndex = choice.options.firstIndex { $0.value == value } ?? 0
            }
            return picker

        case .stepper(let binding, let range, let unit):
            let group = SettingsControlFactory.stepperGroup(range: range, unit: unit)
            let field = group.field
            let stepper = group.stepper
            field.delegate = self
            wire(stepper)
            writers[ObjectIdentifier(stepper)] = { control in
                guard let stepper = control as? NSStepper else { return }
                let value = stepper.integerValue
                field.integerValue = value
                binding.set(value)
            }
            textCommitters[ObjectIdentifier(field)] = { field in
                // Read the field editor, not `stringValue`: mid-edit that
                // validates through the range formatter, which CLEARS the
                // text when it is out of range — and a number on its way to
                // the range ("2" of "20000") is out of range.
                let typed = (field.currentEditor()?.string ?? field.stringValue)
                    .trimmingCharacters(in: .whitespaces)
                guard let value = Int(typed), range.contains(value) else { return }
                stepper.integerValue = value
                binding.set(value)
            }
            rangeProblems[ObjectIdentifier(field)] = { text in
                let typed = text.trimmingCharacters(in: .whitespaces)
                // Nothing typed yet is not a mistake to point at.
                if typed.isEmpty { return nil }
                if let value = Int(typed), range.contains(value) { return nil }
                return String(localized: "Enter a number from \(range.lowerBound.formatted()) to \(range.upperBound.formatted()).")
            }
            refreshers[item.id] = { [weak self] in
                let value = binding.get()
                field.integerValue = value
                stepper.integerValue = value
                // The field shows a stored value again, which is in range.
                self?.rows[item.id]?.captionProblems = []
            }
            controlItemIds[ObjectIdentifier(field)] = item.id
            controlItemIds[ObjectIdentifier(stepper)] = item.id
            field.setAccessibilityIdentifier("settings.\(paneId).\(item.id)")
            stepper.setAccessibilityIdentifier("settings.\(paneId).\(item.id).stepper")
            return group.container

        case .text(let binding, let width, let placeholder, let below):
            let field = SettingsControlFactory.textField(width: below ? nil : width, placeholder: placeholder)
            if below { placement = .below }
            field.delegate = self
            textCommitters[ObjectIdentifier(field)] = { field in binding.set(field.stringValue) }
            refreshers[item.id] = { field.stringValue = binding.get() }
            return field

        case .combo(let binding, let width, let placeholder, let options, let reload):
            let combo = SettingsControlFactory.comboBox(width: width, placeholder: placeholder)
            combo.delegate = self
            // The action fires when an item is picked from the list (and on
            // Return), with `stringValue` already the picked item.
            wire(combo)
            writers[ObjectIdentifier(combo)] = { control in binding.set(control.stringValue) }
            textCommitters[ObjectIdentifier(combo)] = { field in binding.set(field.stringValue) }
            controlItemIds[ObjectIdentifier(combo)] = item.id
            refreshers[item.id] = { combo.stringValue = binding.get() }
            listRefreshers[item.id] = {
                let wanted = options()
                guard (combo.objectValues as? [String]) != wanted else { return }
                combo.removeAllItems()
                combo.addItems(withObjectValues: wanted)
            }
            guard let reload else { return combo }
            let button = SettingsControlFactory.symbolButton(symbol: "arrow.clockwise", title: reload.title)
            wire(button)
            actionHandlers[ObjectIdentifier(button)] = reload.handler
            let group = NSStackView(views: [combo, button])
            group.orientation = .horizontal
            group.alignment = .centerY
            group.spacing = 4
            group.translatesAutoresizingMaskIntoConstraints = false
            combo.setAccessibilityIdentifier("settings.\(paneId).\(item.id)")
            button.setAccessibilityIdentifier("settings.\(paneId).\(item.id).reload")
            return group

        case .slider(let binding, let range):
            let slider = SettingsControlFactory.slider(range: range)
            wire(slider)
            placement = .below
            writers[ObjectIdentifier(slider)] = { control in binding.set((control as? NSSlider)?.doubleValue ?? range.lowerBound) }
            refreshers[item.id] = { slider.doubleValue = binding.get() }
            return slider

        case .path(let binding, let directories):
            let chooser = SettingsControlFactory.pathChooser(directories: directories)
            wire(chooser.button)
            pathBindings[ObjectIdentifier(chooser.button)] = (binding, directories, chooser.label)
            refreshers[item.id] = {
                let path = binding.get()
                chooser.label.stringValue = path.isEmpty ? "—" : (path as NSString).abbreviatingWithTildeInPath
                chooser.label.toolTip = path.isEmpty ? nil : path
            }
            return chooser.container

        case .action(let title, let destructive, let handler):
            let button = SettingsControlFactory.actionButton(title: title, destructive: destructive)
            wire(button)
            actionHandlers[ObjectIdentifier(button)] = handler
            return button

        case .custom(let make):
            placement = .below
            let view = make()
            view.translatesAutoresizingMaskIntoConstraints = false
            return view

        case .display, .empty:
            return nil
        }
    }

    private func wire(_ control: NSControl) {
        control.target = self
        control.action = #selector(controlChanged(_:))
    }

    // MARK: - Lookup

    func row(for itemId: String) -> SettingsRow? { rows[itemId] }
    func control(for itemId: String) -> NSView? { controls[itemId] }
    var itemIds: [String] { order }

    // MARK: - Writing

    @objc func controlChanged(_ sender: NSControl) {
        let key = ObjectIdentifier(sender)
        if let handler = actionHandlers[key] {
            handler()
            return
        }
        if let path = pathBindings[key] {
            choosePath(path.binding, directories: path.directories, from: sender)
            return
        }
        guard !isPopulating(), let write = writers[key] else { return }
        write(sender)
        if let itemId = controlItemIds[key] { refreshDependents(of: itemId) }
    }

    private func choosePath(_ binding: SettingsBinding<String>, directories: Bool, from sender: NSControl) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directories
        panel.canChooseFiles = !directories
        panel.canCreateDirectories = directories
        panel.allowsMultipleSelection = false
        let current = binding.get()
        if !current.isEmpty { panel.directoryURL = URL(fileURLWithPath: current) }
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            binding.set(url.path)
            self?.refreshAll()
        }
        if let window = sender.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    // MARK: - Text fields

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        cancelCommit(field)
        guard !isPopulating(), textCommitters[ObjectIdentifier(field)] != nil else { return }
        showRangeProblem(for: field)
        let timer = Timer.scheduledTimer(withTimeInterval: textCommitDelay, repeats: false) { [weak self, weak field] _ in
            Task { @MainActor in
                guard let self, let field else { return }
                self.pendingCommits[ObjectIdentifier(field)] = nil
                self.commit(field)
            }
        }
        pendingCommits[ObjectIdentifier(field)] = timer
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        cancelCommit(field)
        guard !isPopulating() else { return }
        commit(field)
        // Whatever was typed, the field now shows what is stored — an
        // out-of-range number is put back rather than left on screen.
        if let itemId = controlItemIds[ObjectIdentifier(field)] { refreshers[itemId]?() }
    }

    /// Write a text field's value now. Public so a test can drive it without
    /// a field editor.
    func commit(_ field: NSTextField) {
        guard let committer = textCommitters[ObjectIdentifier(field)] else { return }
        committer(field)
        if let itemId = controlItemIds[ObjectIdentifier(field)] { refreshDependents(of: itemId) }
    }

    /// Say so under the row's title while a number field holds text that will
    /// not be saved. At once rather than with the debounced commit: the
    /// warning is about what is on screen, not about what was written.
    /// Public so a test can drive it without typing.
    func showRangeProblem(for field: NSTextField) {
        let key = ObjectIdentifier(field)
        guard let problem = rangeProblems[key], let itemId = controlItemIds[key] else { return }
        // The field editor, not `stringValue`: see the stepper's committer.
        let text = field.currentEditor()?.string ?? field.stringValue
        rows[itemId]?.captionProblems = problem(text).map { [$0] } ?? []
    }

    private func cancelCommit(_ field: NSTextField) {
        pendingCommits.removeValue(forKey: ObjectIdentifier(field))?.invalidate()
    }

    // MARK: - Refreshing

    /// Pull every binding into its control and re-evaluate availability and
    /// dependency dimming. A text field that is being edited is left alone.
    func refreshAll() {
        for itemId in order {
            listRefreshers[itemId]?()
            if let field = editingField(for: itemId), field.currentEditor() != nil { continue }
            refreshers[itemId]?()
        }
        refreshStates()
    }

    private func editingField(for itemId: String) -> NSTextField? {
        if let field = controls[itemId] as? NSTextField { return field }
        if let container = controls[itemId], let field = container.subviews.compactMap({ $0 as? NSTextField }).first,
           textCommitters[ObjectIdentifier(field)] != nil {
            return field
        }
        return nil
    }

    private func refreshStates() {
        for itemId in order { refreshState(of: itemId) }
    }

    private func refreshState(of itemId: String) {
        guard let item = items[itemId], let row = rows[itemId] else { return }
        var enabled = true
        var caption = item.dynamicCaption?() ?? item.caption
        switch item.availability() {
        case .available:
            break
        case .unavailable(let reason):
            enabled = false
            caption = reason
        }
        if let parent = item.dependsOn, let parentBinding = toggleBindings[parent] {
            enabled = enabled && parentBinding.get()
        }
        row.isEnabled = enabled
        row.caption = caption
    }

    private func refreshDependents(of itemId: String) {
        for (id, item) in items where item.dependsOn == itemId {
            refreshState(of: id)
        }
    }

    deinit {
        for (_, timer) in pendingCommits { timer.invalidate() }
    }
}
