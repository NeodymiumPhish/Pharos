import AppKit

/// The card stack's Find and Replace bar (Edit ▸ Find ▸ Find…, ⌘F; Find and
/// Replace…, ⌥⌘F). It sits in the stack's scroll view as its `findBarView`
/// (`NSScrollView` is an `NSTextFinderBarContainer`), where AppKit's own find
/// bar sat, and it owns no search logic: `CardStackVC` reads the fields and
/// answers with the count.
///
/// Row 1: Find / Replace pop-up, search field (its magnifier menu holds the
/// options — the `FindMode` terms Settings ▸ Results ▸ Find uses — and Match
/// Case), "3 of 12", previous / next, Done. Row 2, for Replace: the
/// replacement, where Replace All works (All Cards or This Card), Replace and
/// Replace All.
final class CardFindBar: NSView, NSSearchFieldDelegate, NSTextFieldDelegate {

    enum Scope: Int {
        case allCards
        case thisCard
    }

    /// The pattern or an option changed.
    var onSearchChange: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onDone: (() -> Void)?
    var onReplace: (() -> Void)?
    var onReplaceAll: (() -> Void)?
    /// Replace was shown or hidden: the bar's height changed.
    var onHeightChange: (() -> Void)?

    private static let rowHeight: CGFloat = 30

    let findField = NSSearchField()
    let replaceField = NSTextField()
    private let modePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let countLabel = NSTextField(labelWithString: "")
    private let stepControl = NSSegmentedControl()
    private let doneButton = NSButton()
    private let scopePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let replaceButton = NSButton()
    private let replaceAllButton = NSButton()
    private let replaceRow = NSStackView()

    private(set) var mode: FindMode = .contains
    private(set) var matchCase = false

    var pattern: String { findField.stringValue }
    var template: String { replaceField.stringValue }
    var scope: Scope { Scope(rawValue: scopePopUp.indexOfSelectedItem) ?? .allCards }

    var showsReplace = false {
        didSet {
            guard showsReplace != oldValue else { return }
            modePopUp.selectItem(at: showsReplace ? 1 : 0)
            replaceRow.isHidden = !showsReplace
            setFrameSize(NSSize(width: frame.width, height: Self.rowHeight * (showsReplace ? 2 : 1) + 1))
            onHeightChange?()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: Self.rowHeight + 1))
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override var isFlipped: Bool { true }

    private func build() {
        setAccessibilityIdentifier("editor.findBar")
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Find in Query Cards"))

        modePopUp.addItems(withTitles: [String(localized: "Find"), String(localized: "Replace")])
        modePopUp.controlSize = .small
        modePopUp.bezelStyle = .recessed
        modePopUp.target = self
        modePopUp.action = #selector(modeChosen)
        modePopUp.setAccessibilityLabel(String(localized: "Find or Replace"))

        findField.controlSize = .small
        findField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        findField.placeholderString = String(localized: "Find in Cards")
        findField.sendsSearchStringImmediately = true
        findField.sendsWholeSearchString = false
        findField.delegate = self
        findField.target = self
        findField.action = #selector(findFieldChanged)
        findField.setAccessibilityIdentifier("editor.findField")
        rebuildOptionsMenu()

        countLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        countLabel.setAccessibilityIdentifier("editor.findCount")

        stepControl.segmentCount = 2
        stepControl.trackingMode = .momentary
        stepControl.controlSize = .small
        stepControl.segmentStyle = .separated
        stepControl.setImage(NSImage(systemSymbolName: "chevron.left", accessibilityDescription: String(localized: "Previous Match")), forSegment: 0)
        stepControl.setImage(NSImage(systemSymbolName: "chevron.right", accessibilityDescription: String(localized: "Next Match")), forSegment: 1)
        stepControl.setToolTip(String(localized: "Previous Match (⇧⌘G)"), forSegment: 0)
        stepControl.setToolTip(String(localized: "Next Match (⌘G)"), forSegment: 1)
        stepControl.target = self
        stepControl.action = #selector(stepClicked)

        doneButton.title = String(localized: "Done")
        doneButton.bezelStyle = .rounded
        doneButton.controlSize = .small
        doneButton.target = self
        doneButton.action = #selector(doneClicked)

        let findRow = NSStackView(views: [modePopUp, findField, countLabel, stepControl, doneButton])
        findRow.orientation = .horizontal
        findRow.spacing = 6
        findRow.alignment = .centerY

        replaceField.controlSize = .small
        replaceField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        replaceField.placeholderString = String(localized: "Replace With")
        replaceField.delegate = self
        replaceField.lineBreakMode = .byTruncatingTail
        replaceField.cell?.isScrollable = true
        replaceField.setAccessibilityIdentifier("editor.replaceField")

        scopePopUp.addItems(withTitles: [String(localized: "All Cards"), String(localized: "This Card")])
        scopePopUp.controlSize = .small
        scopePopUp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        scopePopUp.toolTip = String(localized: "Where Replace All replaces")
        scopePopUp.setAccessibilityLabel(String(localized: "Replace All In"))

        replaceButton.title = String(localized: "Replace")
        replaceButton.bezelStyle = .rounded
        replaceButton.controlSize = .small
        replaceButton.toolTip = String(localized: "Replace the current match and go to the next one")
        replaceButton.target = self
        replaceButton.action = #selector(replaceClicked)

        replaceAllButton.title = String(localized: "Replace All")
        replaceAllButton.bezelStyle = .rounded
        replaceAllButton.controlSize = .small
        replaceAllButton.target = self
        replaceAllButton.action = #selector(replaceAllClicked)

        // The replace field lines up under the search field.
        let spacer = NSView()
        replaceRow.setViews([spacer, replaceField, scopePopUp, replaceButton, replaceAllButton], in: .leading)
        replaceRow.orientation = .horizontal
        replaceRow.spacing = 6
        replaceRow.alignment = .centerY
        replaceRow.isHidden = true

        let separator = NSBox()
        separator.boxType = .separator

        for v in [findRow, replaceRow, separator] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        spacer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            findRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            findRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            findRow.topAnchor.constraint(equalTo: topAnchor),
            findRow.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            replaceRow.leadingAnchor.constraint(equalTo: findRow.leadingAnchor),
            replaceRow.trailingAnchor.constraint(lessThanOrEqualTo: findRow.trailingAnchor),
            replaceRow.topAnchor.constraint(equalTo: findRow.bottomAnchor),
            replaceRow.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            spacer.widthAnchor.constraint(equalTo: modePopUp.widthAnchor),
            replaceField.leadingAnchor.constraint(equalTo: findField.leadingAnchor),
            replaceField.widthAnchor.constraint(equalTo: findField.widthAnchor),
            { let w = findField.widthAnchor.constraint(equalToConstant: 260)
              w.priority = .defaultHigh
              return w }(),
            findField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // The count label takes the slack, so Done stays at the trailing edge.
        countLabel.setContentHuggingPriority(.init(1), for: .horizontal)
    }

    // MARK: - State from the stack

    /// "3 of 12", "12 matches", "Not found", or "Invalid pattern" in red.
    /// A `note` (what Replace All did) is said instead of the count.
    func setCount(current: Int?, total: Int, isInvalid: Bool, note: String? = nil) {
        let text: String
        if let note {
            text = note
        } else if isInvalid {
            text = String(localized: "Invalid pattern")
        } else if pattern.isEmpty {
            text = ""
        } else if total == 0 {
            text = String(localized: "Not found")
        } else if let current {
            text = String(localized: "\(current) of \(total)")
        } else {
            text = CountedNounText.phrase(total, "match")
        }
        countLabel.stringValue = text
        countLabel.textColor = isInvalid ? .systemRed : .secondaryLabelColor
        let canStep = !isInvalid && total > 0
        stepControl.setEnabled(canStep, forSegment: 0)
        stepControl.setEnabled(canStep, forSegment: 1)
        replaceButton.isEnabled = canStep && current != nil
        replaceAllButton.isEnabled = canStep
    }

    /// Give the search field the keyboard, its text selected.
    func focusFind() {
        window?.makeFirstResponder(findField)
        findField.currentEditor()?.selectAll(nil)
    }

    func focusReplace() {
        window?.makeFirstResponder(replaceField)
        replaceField.currentEditor()?.selectAll(nil)
    }

    /// Edit ▸ Find ▸ Use Selection for Find.
    func setPattern(_ text: String) {
        findField.stringValue = text
        onSearchChange?()
    }

    // MARK: - Options

    private func rebuildOptionsMenu() {
        let menu = NSMenu(title: String(localized: "Find Options"))
        for m in FindMode.allCases {
            let item = NSMenuItem(title: m.displayLabel, action: #selector(modeOptionChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = m.rawValue
            item.state = m == mode ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let caseItem = NSMenuItem(title: String(localized: "Match Case"), action: #selector(matchCaseChosen), keyEquivalent: "")
        caseItem.target = self
        caseItem.state = matchCase ? .on : .off
        menu.addItem(caseItem)
        // The field copies the template, so a new template carries the new
        // check marks.
        (findField.cell as? NSSearchFieldCell)?.searchMenuTemplate = menu
    }

    @objc private func modeOptionChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = FindMode(rawValue: raw), m != mode else { return }
        mode = m
        rebuildOptionsMenu()
        onSearchChange?()
    }

    @objc private func matchCaseChosen() {
        matchCase.toggle()
        rebuildOptionsMenu()
        onSearchChange?()
    }

    // MARK: - Actions

    @objc private func modeChosen() {
        showsReplace = modePopUp.indexOfSelectedItem == 1
        if showsReplace { focusReplace() } else { focusFind() }
    }

    @objc private func findFieldChanged() { onSearchChange?() }

    @objc private func stepClicked() {
        if stepControl.selectedSegment == 0 { onPrevious?() } else { onNext?() }
    }

    @objc private func doneClicked() { onDone?() }
    @objc private func replaceClicked() { onReplace?() }
    @objc private func replaceAllClicked() { onReplaceAll?() }

    /// Return finds the next match (⇧Return the previous) in the search
    /// field and replaces in the replace field; Esc closes the bar.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if control === replaceField {
                onReplace?()
            } else if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                onPrevious?()
            } else {
                onNext?()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onDone?()
            return true
        default:
            return false
        }
    }
}
