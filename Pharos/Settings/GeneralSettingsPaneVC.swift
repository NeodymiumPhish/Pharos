import AppKit

/// Settings ▸ General. Appearance, the NULL and boolean renderings, and the
/// three application-wide switches.
final class GeneralSettingsPaneVC: SettingsPaneVC {

    private let themeControl = NSSegmentedControl()
    private let nullDisplayPopup = NSPopUpButton()
    private let boolDisplayPopup = NSPopUpButton()
    private let checkForUpdatesCheck = NSButton(
        checkboxWithTitle: "Check for updates in the background", target: nil, action: nil)
    private let showLeafPartitionsCheck = NSButton(
        checkboxWithTitle: "Show leaf partitions in the Database Navigator", target: nil, action: nil)
    /// Names both states on purpose. Its neighbours only add or remove
    /// something when switched off, but this one swaps between two layouts, and
    /// "Show result tabs…" alone reads as though clearing it takes the result
    /// tabs away.
    private let verticalResultTabsCheck = NSButton(
        checkboxWithTitle: "Show result tabs in a vertical panel, not a horizontal bar", target: nil, action: nil)

    override func loadView() {
        themeControl.segmentCount = 3
        themeControl.setLabel("Auto", forSegment: 0)
        themeControl.setLabel("Light", forSegment: 1)
        themeControl.setLabel("Dark", forSegment: 2)
        themeControl.segmentStyle = .texturedSquare
        themeControl.target = self
        themeControl.action = #selector(themeChanged)
        themeControl.setAccessibilityIdentifier("settings.general.appearance")

        for format in NullDisplay.allCases {
            nullDisplayPopup.addItem(withTitle: format.displayLabel)
        }
        nullDisplayPopup.target = self
        nullDisplayPopup.action = #selector(nullDisplayChanged)
        nullDisplayPopup.setAccessibilityIdentifier("settings.general.nullDisplay")

        for format in BoolDisplay.allCases {
            boolDisplayPopup.addItem(withTitle: format.displayLabel)
        }
        boolDisplayPopup.target = self
        boolDisplayPopup.action = #selector(boolDisplayChanged)
        boolDisplayPopup.setAccessibilityIdentifier("settings.general.boolDisplay")

        checkForUpdatesCheck.target = self
        checkForUpdatesCheck.action = #selector(checkForUpdatesChanged)
        checkForUpdatesCheck.setAccessibilityIdentifier("settings.general.checkForUpdates")

        showLeafPartitionsCheck.target = self
        showLeafPartitionsCheck.action = #selector(showLeafPartitionsChanged)
        showLeafPartitionsCheck.setAccessibilityIdentifier("settings.general.showLeafPartitions")

        verticalResultTabsCheck.target = self
        verticalResultTabsCheck.action = #selector(verticalResultTabsChanged)
        verticalResultTabsCheck.setAccessibilityIdentifier("settings.general.verticalResultTabs")

        let grid = NSGridView(views: [
            [NSTextField.formLabel("Appearance"), themeControl],
            [NSTextField.formLabel("NULL Display"), nullDisplayPopup],
            [NSTextField.formLabel("Bool Display"), boolDisplayPopup],
            [NSGridCell.emptyContentView, checkForUpdatesCheck],
            [NSGridCell.emptyContentView, showLeafPartitionsCheck],
            [NSGridCell.emptyContentView, verticalResultTabsCheck],
        ])
        SettingsForm.configureGrid(grid)

        view = SettingsForm.wrap(grid)
        populate()
        preferredContentSize = SettingsWindowController.paneSize(for: view)
    }

    override func reloadFromSettings() { populate() }

    private func populate() {
        let s = stateManager.settings
        populating {
            switch s.theme {
            case .auto: themeControl.selectedSegment = 0
            case .light: themeControl.selectedSegment = 1
            case .dark: themeControl.selectedSegment = 2
            }
            if let idx = NullDisplay.allCases.firstIndex(of: s.nullDisplay) {
                nullDisplayPopup.selectItem(at: idx)
            }
            if let idx = BoolDisplay.allCases.firstIndex(of: s.boolDisplay) {
                boolDisplayPopup.selectItem(at: idx)
            }
            checkForUpdatesCheck.state = s.checkForUpdates ? .on : .off
            showLeafPartitionsCheck.state = s.showLeafPartitions ? .on : .off
            verticalResultTabsCheck.state = s.verticalResultTabs ? .on : .off
        }
    }

    override func wireKeyLoop() {
        view.window?.initialFirstResponder = themeControl
        themeControl.nextKeyView = nullDisplayPopup
        nullDisplayPopup.nextKeyView = boolDisplayPopup
        boolDisplayPopup.nextKeyView = checkForUpdatesCheck
        checkForUpdatesCheck.nextKeyView = showLeafPartitionsCheck
        showLeafPartitionsCheck.nextKeyView = verticalResultTabsCheck
        // Closes the loop: the last control leads back to the first.
        verticalResultTabsCheck.nextKeyView = themeControl
    }

    // MARK: - Actions

    @objc private func themeChanged() {
        apply { s in
            switch themeControl.selectedSegment {
            case 1: s.theme = .light
            case 2: s.theme = .dark
            default: s.theme = .auto
            }
        }
    }

    @objc private func nullDisplayChanged() {
        let cases = NullDisplay.allCases
        let idx = nullDisplayPopup.indexOfSelectedItem
        apply { $0.nullDisplay = idx >= 0 && idx < cases.count ? cases[idx] : .uppercase }
    }

    @objc private func boolDisplayChanged() {
        let cases = BoolDisplay.allCases
        let idx = boolDisplayPopup.indexOfSelectedItem
        apply { $0.boolDisplay = idx >= 0 && idx < cases.count ? cases[idx] : .trueFalse }
    }

    @objc private func checkForUpdatesChanged() {
        apply { $0.checkForUpdates = checkForUpdatesCheck.state == .on }
    }

    @objc private func showLeafPartitionsChanged() {
        apply { $0.showLeafPartitions = showLeafPartitionsCheck.state == .on }
    }

    @objc private func verticalResultTabsChanged() {
        apply { $0.verticalResultTabs = verticalResultTabsCheck.state == .on }
    }
}
