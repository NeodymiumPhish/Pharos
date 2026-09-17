import AppKit

/// Settings ▸ General. Appearance, the NULL and boolean renderings, and the
/// application-wide switches.
final class GeneralSettingsPaneVC: SettingsPaneVC {

    private let themeControl = NSSegmentedControl()
    private let nullDisplayPopup = NSPopUpButton()
    private let boolDisplayPopup = NSPopUpButton()
    private let checkForUpdatesCheck = NSButton(
        checkboxWithTitle: String(localized: "Check for updates in the background"), target: nil, action: nil)
    private let showLeafPartitionsCheck = NSButton(
        checkboxWithTitle: String(localized: "Show leaf partitions in the Database Navigator"), target: nil, action: nil)
    /// Names both states on purpose. Its neighbours only add or remove
    /// something when switched off, but this one swaps between two layouts, and
    /// "Show result tabs…" alone reads as though clearing it takes the result
    /// tabs away.
    private let verticalResultTabsCheck = NSButton(
        checkboxWithTitle: String(localized: "Show result tabs in a vertical panel, not a horizontal bar"), target: nil, action: nil)
    private let alwaysShowScrollBarsCheck = NSButton(
        checkboxWithTitle: String(localized: "Always show scroll bars in the editor and results"), target: nil, action: nil)
    private let appleIntelligenceCheck = NSButton(
        checkboxWithTitle: String(localized: "Use Apple Intelligence features"), target: nil, action: nil)
    /// Says what the switch buys and, when the model cannot run here, why the
    /// checkbox above it is greyed out. The second sentence is the promise the
    /// whole feature rests on, so it is on screen beside the switch rather
    /// than only in the documentation.
    private let appleIntelligenceCaption: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.setAccessibilityIdentifier("settings.general.appleIntelligence.caption")
        return label
    }()

    override func loadView() {
        themeControl.segmentCount = 3
        themeControl.setLabel(String(localized: "Auto"), forSegment: 0)
        themeControl.setLabel(String(localized: "Light"), forSegment: 1)
        themeControl.setLabel(String(localized: "Dark"), forSegment: 2)
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

        alwaysShowScrollBarsCheck.target = self
        alwaysShowScrollBarsCheck.action = #selector(alwaysShowScrollBarsChanged)
        alwaysShowScrollBarsCheck.setAccessibilityIdentifier("settings.general.alwaysShowScrollBars")

        appleIntelligenceCheck.target = self
        appleIntelligenceCheck.action = #selector(appleIntelligenceChanged)
        appleIntelligenceCheck.setAccessibilityIdentifier("settings.general.appleIntelligence")

        let grid = NSGridView(views: [
            [NSTextField.formLabel(String(localized: "Appearance")), themeControl],
            [NSTextField.formLabel(String(localized: "NULL Display")), nullDisplayPopup],
            [NSTextField.formLabel(String(localized: "Bool Display")), boolDisplayPopup],
            [NSGridCell.emptyContentView, checkForUpdatesCheck],
            [NSGridCell.emptyContentView, showLeafPartitionsCheck],
            [NSGridCell.emptyContentView, verticalResultTabsCheck],
            [NSGridCell.emptyContentView, alwaysShowScrollBarsCheck],
            [NSGridCell.emptyContentView, appleIntelligenceCheck],
            [NSGridCell.emptyContentView, appleIntelligenceCaption],
        ])
        SettingsForm.configureGrid(grid)

        // A wrapping label has no natural width, so without this it would set
        // the pane's width to the length of the whole sentence.
        appleIntelligenceCaption.preferredMaxLayoutWidth = 380
        appleIntelligenceCaption.widthAnchor.constraint(lessThanOrEqualToConstant: 380).isActive = true

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
            alwaysShowScrollBarsCheck.state = s.alwaysShowScrollBars ? .on : .off
            appleIntelligenceCheck.state = s.useAppleIntelligence ? .on : .off
        }
        updateAppleIntelligenceAvailability()
    }

    /// The checkbox is only clickable where the model can actually run. When
    /// it cannot, the caption says why instead of describing features the user
    /// cannot have.
    ///
    /// It asks `systemModelIsAvailable`, not `isAvailable`: a user who cleared
    /// the checkbox must still be able to set it again.
    private func updateAppleIntelligenceAvailability() {
        let availability = ModelAvailability.shared
        availability.refresh()
        appleIntelligenceCheck.isEnabled = availability.systemModelIsAvailable
        if availability.systemModelIsAvailable {
            appleIntelligenceCaption.stringValue = String(
                localized: "Explain errors, suggest names, draft SQL and summarise plans with the on-device model. Nothing leaves this Mac.")
        } else {
            appleIntelligenceCaption.stringValue =
                availability.unavailableReason
                ?? String(localized: "Apple Intelligence is not available on this Mac right now.")
        }
    }

    override func wireKeyLoop() {
        view.window?.initialFirstResponder = themeControl
        themeControl.nextKeyView = nullDisplayPopup
        nullDisplayPopup.nextKeyView = boolDisplayPopup
        boolDisplayPopup.nextKeyView = checkForUpdatesCheck
        checkForUpdatesCheck.nextKeyView = showLeafPartitionsCheck
        showLeafPartitionsCheck.nextKeyView = verticalResultTabsCheck
        verticalResultTabsCheck.nextKeyView = alwaysShowScrollBarsCheck
        alwaysShowScrollBarsCheck.nextKeyView = appleIntelligenceCheck
        // Closes the loop: the last control leads back to the first.
        appleIntelligenceCheck.nextKeyView = themeControl
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

    @objc private func alwaysShowScrollBarsChanged() {
        apply { $0.alwaysShowScrollBars = alwaysShowScrollBarsCheck.state == .on }
    }

    @objc private func appleIntelligenceChanged() {
        apply { $0.useAppleIntelligence = appleIntelligenceCheck.state == .on }
    }
}
