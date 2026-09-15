import AppKit

/// Settings ▸ Editor. The SQL editor's font, its tab width, and the two
/// display switches.
final class EditorSettingsPaneVC: SettingsPaneVC {

    private let fontPopup = NSPopUpButton()
    private let fontSizeField = NSTextField()
    private let fontSizeStepper = NSStepper()
    private let tabSizePopup = NSPopUpButton()
    private let lineNumbersCheck = NSButton(checkboxWithTitle: "Show line numbers", target: nil, action: nil)
    private let wordWrapCheck = NSButton(checkboxWithTitle: "Wrap long lines", target: nil, action: nil)

    private static let fontSizeRange = (min: 9, max: 24)

    override func loadView() {
        populateFontPopup()
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged)
        fontPopup.setAccessibilityIdentifier("settings.editor.font")

        fontSizeField.formatter = SettingsForm.numberFormatter(
            min: Self.fontSizeRange.min, max: Self.fontSizeRange.max)
        fontSizeField.alignment = .right
        fontSizeField.delegate = self
        fontSizeField.widthAnchor.constraint(equalToConstant: 50).isActive = true
        fontSizeField.setAccessibilityIdentifier("settings.editor.fontSize")

        fontSizeStepper.minValue = Double(Self.fontSizeRange.min)
        fontSizeStepper.maxValue = Double(Self.fontSizeRange.max)
        fontSizeStepper.target = self
        fontSizeStepper.action = #selector(stepperChanged)
        fontSizeStepper.setAccessibilityIdentifier("settings.editor.fontSizeStepper")

        let sizeRow = NSStackView(views: [fontSizeField, fontSizeStepper])
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 4

        tabSizePopup.addItems(withTitles: ["2 spaces", "4 spaces", "8 spaces"])
        tabSizePopup.target = self
        tabSizePopup.action = #selector(tabSizeChanged)
        tabSizePopup.setAccessibilityIdentifier("settings.editor.tabSize")

        lineNumbersCheck.target = self
        lineNumbersCheck.action = #selector(lineNumbersChanged)
        lineNumbersCheck.setAccessibilityIdentifier("settings.editor.lineNumbers")

        wordWrapCheck.target = self
        wordWrapCheck.action = #selector(wordWrapChanged)
        wordWrapCheck.setAccessibilityIdentifier("settings.editor.wordWrap")

        let grid = NSGridView(views: [
            [NSTextField.formLabel("Font"), fontPopup],
            [NSTextField.formLabel("Font Size"), sizeRow],
            [NSTextField.formLabel("Tab Size"), tabSizePopup],
            [NSGridCell.emptyContentView, lineNumbersCheck],
            [NSGridCell.emptyContentView, wordWrapCheck],
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
            selectFont(s.editor.fontFamily)
            fontSizeField.integerValue = Int(s.editor.fontSize)
            fontSizeStepper.integerValue = Int(s.editor.fontSize)
            switch s.editor.tabSize {
            case 4: tabSizePopup.selectItem(at: 1)
            case 8: tabSizePopup.selectItem(at: 2)
            default: tabSizePopup.selectItem(at: 0)
            }
            lineNumbersCheck.state = s.editor.lineNumbers ? .on : .off
            wordWrapCheck.state = s.editor.wordWrap ? .on : .off
        }
    }

    override func wireKeyLoop() {
        view.window?.initialFirstResponder = fontPopup
        fontPopup.nextKeyView = fontSizeField
        fontSizeField.nextKeyView = fontSizeStepper
        fontSizeStepper.nextKeyView = tabSizePopup
        tabSizePopup.nextKeyView = lineNumbersCheck
        lineNumbersCheck.nextKeyView = wordWrapCheck
        wordWrapCheck.nextKeyView = fontPopup
    }

    // MARK: - Actions

    @objc private func fontChanged() {
        guard let selected = fontPopup.titleOfSelectedItem else { return }
        apply { $0.editor.fontFamily = selected }
    }

    @objc private func stepperChanged() {
        fontSizeField.integerValue = fontSizeStepper.integerValue
        commitFontSize()
    }

    @objc private func tabSizeChanged() {
        apply { s in
            switch tabSizePopup.indexOfSelectedItem {
            case 1: s.editor.tabSize = 4
            case 2: s.editor.tabSize = 8
            default: s.editor.tabSize = 2
            }
        }
    }

    @objc private func lineNumbersChanged() {
        apply { $0.editor.lineNumbers = lineNumbersCheck.state == .on }
    }

    @objc private func wordWrapChanged() {
        apply { $0.editor.wordWrap = wordWrapCheck.state == .on }
    }

    override func commitTextField(_ field: NSTextField) {
        guard field === fontSizeField else { return }
        commitFontSize()
    }

    /// The field's formatter rejects an out-of-range value only when editing
    /// ends, so the size is clamped here as well — mid-typing "1" must not be
    /// stored as a 1pt editor font.
    private func commitFontSize() {
        let typed = fontSizeField.integerValue
        guard typed >= Self.fontSizeRange.min, typed <= Self.fontSizeRange.max else { return }
        fontSizeStepper.integerValue = typed
        apply { $0.editor.fontSize = UInt32(typed) }
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

        for mono in Self.monoFonts where NSFont(name: mono.postScriptName, size: 13) != nil {
            fontPopup.addItem(withTitle: mono.displayName)
        }
    }

    private func selectFont(_ family: String) {
        let firstName = family.components(separatedBy: ",").first?
            .trimmingCharacters(in: .whitespaces) ?? family
        for i in 0..<fontPopup.numberOfItems where fontPopup.itemTitle(at: i) == firstName {
            fontPopup.selectItem(at: i)
            return
        }
        fontPopup.selectItem(at: 0)
    }
}
