import AppKit

/// Settings ▸ Query. Row limit, timeout, the destructive-statement guard, and
/// the completion notifications.
final class QuerySettingsPaneVC: SettingsPaneVC {

    private let defaultLimitField = NSTextField()
    private let timeoutField = NSTextField()
    private let confirmDestructiveCheck = NSButton(
        checkboxWithTitle: String(localized: "Confirm queries that change the database"), target: nil, action: nil)
    private let showCancelledDialogCheck = NSButton(
        checkboxWithTitle: String(localized: "Show details when you cancel a query"), target: nil, action: nil)
    private let notifyAppInactiveCheck = NSButton(
        checkboxWithTitle: String(localized: "Notify when query completes and app is in background"), target: nil, action: nil)
    private let notifyBackgroundTabCheck = NSButton(
        checkboxWithTitle: String(localized: "Notify when query completes in a background tab"), target: nil, action: nil)
    private let notifyMinDurationField = NSTextField()
    private let restoreOpenTabsCheck = NSButton(
        checkboxWithTitle: String(localized: "Restore open tabs at launch"), target: nil, action: nil)

    private static let limitRange = (min: 1, max: 100_000)
    private static let timeoutRange = (min: 1, max: 3600)
    private static let notifyRange = (min: 0, max: 3600)

    override func loadView() {
        configureNumberField(defaultLimitField, range: Self.limitRange, width: 80,
                             identifier: "settings.query.defaultLimit")
        configureNumberField(timeoutField, range: Self.timeoutRange, width: 60,
                             identifier: "settings.query.timeout")
        configureNumberField(notifyMinDurationField, range: Self.notifyRange, width: 60,
                             identifier: "settings.query.notifyMinDuration")

        confirmDestructiveCheck.target = self
        confirmDestructiveCheck.action = #selector(confirmDestructiveChanged)
        confirmDestructiveCheck.setAccessibilityIdentifier("settings.query.confirmDestructive")

        showCancelledDialogCheck.target = self
        showCancelledDialogCheck.action = #selector(showCancelledDialogChanged)
        showCancelledDialogCheck.setAccessibilityIdentifier("settings.query.showCancelledDialog")

        notifyAppInactiveCheck.target = self
        notifyAppInactiveCheck.action = #selector(notifyAppInactiveChanged)
        notifyAppInactiveCheck.setAccessibilityIdentifier("settings.query.notifyAppInactive")

        notifyBackgroundTabCheck.target = self
        notifyBackgroundTabCheck.action = #selector(notifyBackgroundTabChanged)
        notifyBackgroundTabCheck.setAccessibilityIdentifier("settings.query.notifyBackgroundTab")

        restoreOpenTabsCheck.target = self
        restoreOpenTabsCheck.action = #selector(restoreOpenTabsChanged)
        restoreOpenTabsCheck.setAccessibilityIdentifier("settings.query.restoreOpenTabs")

        let grid = NSGridView(views: [
            [NSTextField.formLabel(String(localized: "Row Limit")), defaultLimitField],
            [NSTextField.formLabel(String(localized: "Timeout")), secondsRow(timeoutField)],
            [NSGridCell.emptyContentView, confirmDestructiveCheck],
            [NSGridCell.emptyContentView, showCancelledDialogCheck],
            [NSGridCell.emptyContentView, notifyAppInactiveCheck],
            [NSGridCell.emptyContentView, notifyBackgroundTabCheck],
            [NSTextField.formLabel(String(localized: "Notification minimum")), secondsRow(notifyMinDurationField)],
            [NSGridCell.emptyContentView, restoreOpenTabsCheck],
        ])
        SettingsForm.configureGrid(grid)

        view = SettingsForm.wrap(grid)
        populate()
        preferredContentSize = SettingsWindowController.paneSize(for: view)
    }

    private func configureNumberField(_ field: NSTextField, range: (min: Int, max: Int),
                                      width: CGFloat, identifier: String) {
        field.formatter = SettingsForm.numberFormatter(min: range.min, max: range.max)
        field.alignment = .right
        field.delegate = self
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        field.setAccessibilityIdentifier(identifier)
    }

    private func secondsRow(_ field: NSTextField) -> NSStackView {
        let row = NSStackView(views: [field, NSTextField(labelWithString: String(localized: "seconds"))])
        row.orientation = .horizontal
        row.spacing = 6
        return row
    }

    override func reloadFromSettings() { populate() }

    private func populate() {
        let q = stateManager.settings.query
        populating {
            defaultLimitField.integerValue = Int(q.defaultLimit)
            timeoutField.integerValue = Int(q.timeoutSeconds)
            confirmDestructiveCheck.state = q.confirmDestructive ? .on : .off
            showCancelledDialogCheck.state = q.showCancelledQueryDialog ? .on : .off
            notifyAppInactiveCheck.state = q.notifyWhenAppInactive ? .on : .off
            notifyBackgroundTabCheck.state = q.notifyWhenBackgroundTab ? .on : .off
            notifyMinDurationField.integerValue = Int(q.notifyMinDurationSeconds)
            restoreOpenTabsCheck.state = q.restoreOpenTabs ? .on : .off
        }
    }

    override func wireKeyLoop() {
        view.window?.initialFirstResponder = defaultLimitField
        defaultLimitField.nextKeyView = timeoutField
        timeoutField.nextKeyView = confirmDestructiveCheck
        confirmDestructiveCheck.nextKeyView = showCancelledDialogCheck
        showCancelledDialogCheck.nextKeyView = notifyAppInactiveCheck
        notifyAppInactiveCheck.nextKeyView = notifyBackgroundTabCheck
        notifyBackgroundTabCheck.nextKeyView = notifyMinDurationField
        notifyMinDurationField.nextKeyView = restoreOpenTabsCheck
        restoreOpenTabsCheck.nextKeyView = defaultLimitField
    }

    // MARK: - Actions

    @objc private func confirmDestructiveChanged() {
        apply { $0.query.confirmDestructive = confirmDestructiveCheck.state == .on }
    }

    @objc private func showCancelledDialogChanged() {
        apply { $0.query.showCancelledQueryDialog = showCancelledDialogCheck.state == .on }
    }

    @objc private func notifyAppInactiveChanged() {
        apply { $0.query.notifyWhenAppInactive = notifyAppInactiveCheck.state == .on }
    }

    @objc private func notifyBackgroundTabChanged() {
        apply { $0.query.notifyWhenBackgroundTab = notifyBackgroundTabCheck.state == .on }
    }

    @objc private func restoreOpenTabsChanged() {
        apply { $0.query.restoreOpenTabs = restoreOpenTabsCheck.state == .on }
    }

    /// The formatter only rejects an out-of-range value when editing ends, so
    /// each field is range-checked here too: half-typed digits are ignored
    /// rather than stored.
    override func commitTextField(_ field: NSTextField) {
        let typed = field.integerValue
        if field === defaultLimitField {
            guard inRange(typed, Self.limitRange) else { return }
            apply { $0.query.defaultLimit = UInt32(typed) }
        } else if field === timeoutField {
            guard inRange(typed, Self.timeoutRange) else { return }
            apply { $0.query.timeoutSeconds = UInt32(typed) }
        } else if field === notifyMinDurationField {
            guard inRange(typed, Self.notifyRange) else { return }
            apply { $0.query.notifyMinDurationSeconds = UInt32(typed) }
        }
    }

    private func inRange(_ value: Int, _ range: (min: Int, max: Int)) -> Bool {
        value >= range.min && value <= range.max
    }
}
