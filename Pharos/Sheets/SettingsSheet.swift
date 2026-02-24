import AppKit

/// Settings sheet with tabbed sections: General, Editor, Query.
class SettingsSheet: NSViewController {

    private var settings: AppSettings
    private let stateManager = AppStateManager.shared

    // General
    private let themeControl = NSSegmentedControl()
    private let nullDisplayPopup = NSPopUpButton()

    // Editor
    private let fontPopup = NSPopUpButton()
    private let fontSizeField = NSTextField()
    private let fontSizeStepper = NSStepper()
    private let tabSizePopup = NSPopUpButton()
    private let lineNumbersCheck = NSButton(checkboxWithTitle: "Show line numbers", target: nil, action: nil)
    private let wordWrapCheck = NSButton(checkboxWithTitle: "Wrap long lines", target: nil, action: nil)

    // Query
    private let defaultLimitField = NSTextField()
    private let timeoutField = NSTextField()
    private let autoCommitCheck = NSButton(checkboxWithTitle: "Auto-commit transactions", target: nil, action: nil)
    private let confirmDestructiveCheck = NSButton(checkboxWithTitle: "Confirm before DROP / DELETE / TRUNCATE", target: nil, action: nil)

    init() {
        self.settings = stateManager.settings
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 340))
        self.view = container

        // Title
        let titleLabel = NSTextField(labelWithString: "Settings")
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)

        // Tab view
        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.addTabViewItem(makeGeneralTab())
        tabView.addTabViewItem(makeEditorTab())
        tabView.addTabViewItem(makeQueryTab())

        // Buttons
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelSheet))
        cancelButton.keyEquivalent = "\u{1b}"

        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveSheet))
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded

        let buttonRow = NSStackView(views: [cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        // Layout
        let mainStack = NSStackView(views: [titleLabel, tabView, buttonRow])
        mainStack.orientation = .vertical
        mainStack.alignment = .centerX
        mainStack.spacing = 12
        mainStack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: container.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            tabView.widthAnchor.constraint(equalToConstant: 440),
            tabView.heightAnchor.constraint(equalToConstant: 220),
        ])

        populateFromSettings()
    }

    // MARK: - Tab Builders

    private func makeGeneralTab() -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = "General"

        themeControl.segmentCount = 3
        themeControl.setLabel("Auto", forSegment: 0)
        themeControl.setLabel("Light", forSegment: 1)
        themeControl.setLabel("Dark", forSegment: 2)
        themeControl.segmentStyle = .texturedSquare

        let themeLabel = makeLabel("Appearance")

        let nullLabel = makeLabel("NULL Display")
        for format in NullDisplay.allCases {
            nullDisplayPopup.addItem(withTitle: format.displayLabel)
        }

        let grid = NSGridView(views: [
            [themeLabel, themeControl],
            [nullLabel, nullDisplayPopup],
        ])
        configureGrid(grid)

        let wrapper = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor, constant: -16),
        ])

        item.view = wrapper
        return item
    }

    private func makeEditorTab() -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = "Editor"

        // Font popup
        let fontLabel = makeLabel("Font")
        populateFontPopup()

        // Font size
        let sizeLabel = makeLabel("Font Size")
        fontSizeField.integerValue = Int(settings.editor.fontSize)
        fontSizeField.formatter = numberFormatter(min: 9, max: 24)
        fontSizeField.alignment = .right
        fontSizeField.widthAnchor.constraint(equalToConstant: 50).isActive = true

        fontSizeStepper.minValue = 9
        fontSizeStepper.maxValue = 24
        fontSizeStepper.integerValue = Int(settings.editor.fontSize)
        fontSizeStepper.target = self
        fontSizeStepper.action = #selector(stepperChanged(_:))

        let sizeRow = NSStackView(views: [fontSizeField, fontSizeStepper])
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 4

        // Tab size
        let tabLabel = makeLabel("Tab Size")
        tabSizePopup.addItems(withTitles: ["2 spaces", "4 spaces", "8 spaces"])

        // Checkboxes
        let grid = NSGridView(views: [
            [fontLabel, fontPopup],
            [sizeLabel, sizeRow],
            [tabLabel, tabSizePopup],
            [NSGridCell.emptyContentView, lineNumbersCheck],
            [NSGridCell.emptyContentView, wordWrapCheck],
        ])
        configureGrid(grid)

        let wrapper = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor, constant: -16),
        ])

        item.view = wrapper
        return item
    }

    private func makeQueryTab() -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = "Query"

        let limitLabel = makeLabel("Row Limit")
        defaultLimitField.formatter = numberFormatter(min: 1, max: 100_000)
        defaultLimitField.alignment = .right
        defaultLimitField.widthAnchor.constraint(equalToConstant: 80).isActive = true

        let timeoutLabel = makeLabel("Timeout")
        timeoutField.formatter = numberFormatter(min: 1, max: 3600)
        timeoutField.alignment = .right
        timeoutField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let timeoutRow = NSStackView(views: [timeoutField, NSTextField(labelWithString: "seconds")])
        timeoutRow.orientation = .horizontal
        timeoutRow.spacing = 6

        let grid = NSGridView(views: [
            [limitLabel, defaultLimitField],
            [timeoutLabel, timeoutRow],
            [NSGridCell.emptyContentView, autoCommitCheck],
            [NSGridCell.emptyContentView, confirmDestructiveCheck],
        ])
        configureGrid(grid)

        let wrapper = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor, constant: -16),
        ])

        item.view = wrapper
        return item
    }

    // MARK: - Populate / Collect

    private func populateFromSettings() {
        // General
        switch settings.theme {
        case .auto: themeControl.selectedSegment = 0
        case .light: themeControl.selectedSegment = 1
        case .dark: themeControl.selectedSegment = 2
        }

        if let idx = NullDisplay.allCases.firstIndex(of: settings.nullDisplay) {
            nullDisplayPopup.selectItem(at: idx)
        }

        // Editor
        selectFont(settings.editor.fontFamily)
        fontSizeField.integerValue = Int(settings.editor.fontSize)
        fontSizeStepper.integerValue = Int(settings.editor.fontSize)

        switch settings.editor.tabSize {
        case 4: tabSizePopup.selectItem(at: 1)
        case 8: tabSizePopup.selectItem(at: 2)
        default: tabSizePopup.selectItem(at: 0) // 2
        }

        lineNumbersCheck.state = settings.editor.lineNumbers ? .on : .off
        wordWrapCheck.state = settings.editor.wordWrap ? .on : .off

        // Query
        defaultLimitField.integerValue = Int(settings.query.defaultLimit)
        timeoutField.integerValue = Int(settings.query.timeoutSeconds)
        autoCommitCheck.state = settings.query.autoCommit ? .on : .off
        confirmDestructiveCheck.state = settings.query.confirmDestructive ? .on : .off
    }

    private func collectSettings() -> AppSettings {
        var s = settings

        // General
        switch themeControl.selectedSegment {
        case 1: s.theme = .light
        case 2: s.theme = .dark
        default: s.theme = .auto
        }

        let allCases = NullDisplay.allCases
        let idx = nullDisplayPopup.indexOfSelectedItem
        s.nullDisplay = idx >= 0 && idx < allCases.count ? allCases[idx] : .uppercase

        // Editor
        if let selected = fontPopup.titleOfSelectedItem {
            s.editor.fontFamily = selected
        }
        s.editor.fontSize = UInt32(clamping: fontSizeField.integerValue)
        switch tabSizePopup.indexOfSelectedItem {
        case 1: s.editor.tabSize = 4
        case 2: s.editor.tabSize = 8
        default: s.editor.tabSize = 2
        }
        s.editor.lineNumbers = lineNumbersCheck.state == .on
        s.editor.wordWrap = wordWrapCheck.state == .on

        // Query
        s.query.defaultLimit = UInt32(clamping: defaultLimitField.integerValue)
        s.query.timeoutSeconds = UInt32(clamping: timeoutField.integerValue)
        s.query.autoCommit = autoCommitCheck.state == .on
        s.query.confirmDestructive = confirmDestructiveCheck.state == .on

        return s
    }

    // MARK: - Actions

    @objc private func cancelSheet() {
        dismiss(nil)
    }

    @objc private func saveSheet() {
        let newSettings = collectSettings()
        stateManager.saveSettings(newSettings)
        applyTheme(newSettings.theme)
        dismiss(nil)
    }

    @objc private func stepperChanged(_ sender: NSStepper) {
        fontSizeField.integerValue = sender.integerValue
    }

    // MARK: - Theme

    static func applyTheme(_ theme: ThemeMode) {
        switch theme {
        case .auto: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func applyTheme(_ theme: ThemeMode) {
        Self.applyTheme(theme)
    }

    // MARK: - Fonts

    private struct MonoFont {
        let displayName: String
        let postScriptName: String
    }

    private static let monoFonts: [MonoFont] = [
        MonoFont(displayName: "Menlo", postScriptName: "Menlo-Regular"),
        MonoFont(displayName: "Monaco", postScriptName: "Monaco"),
        MonoFont(displayName: "SF Mono", postScriptName: "SFMono-Regular"),
        MonoFont(displayName: "JetBrains Mono", postScriptName: "JetBrainsMono-Regular"),
        MonoFont(displayName: "Fira Code", postScriptName: "FiraCode-Regular"),
        MonoFont(displayName: "Source Code Pro", postScriptName: "SourceCodePro-Regular"),
        MonoFont(displayName: "Courier New", postScriptName: "CourierNewPSMT"),
    ]

    private func populateFontPopup() {
        fontPopup.removeAllItems()
        fontPopup.addItem(withTitle: "System Monospace")
        fontPopup.menu?.addItem(.separator())

        for mono in Self.monoFonts {
            // Only show fonts that are actually installed
            if NSFont(name: mono.postScriptName, size: 13) != nil {
                fontPopup.addItem(withTitle: mono.displayName)
            }
        }
    }

    private func selectFont(_ family: String) {
        let firstName = family.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? family
        // Try to match by display name
        for i in 0..<fontPopup.numberOfItems {
            if fontPopup.itemTitle(at: i) == firstName {
                fontPopup.selectItem(at: i)
                return
            }
        }
        // Fallback: select System Monospace
        fontPopup.selectItem(at: 0)
    }

    // MARK: - Helpers

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text + ":")
        label.alignment = .right
        label.font = .systemFont(ofSize: 13)
        return label
    }

    private func configureGrid(_ grid: NSGridView) {
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 100
        grid.column(at: 1).width = 280
        grid.rowSpacing = 8
        grid.columnSpacing = 8
    }

    private func numberFormatter(min: Int, max: Int) -> NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = NSNumber(value: min)
        f.maximum = NSNumber(value: max)
        f.allowsFloats = false
        return f
    }
}
