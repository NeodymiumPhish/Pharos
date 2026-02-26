import AppKit

class SidebarActionBar: NSView {
    enum Mode {
        case library   // New, Save, Save As, Delete
        case history   // Delete only
    }

    var mode: Mode = .library { didSet { updateButtons() } }

    // Callbacks set by SidebarViewController
    var onNew: (() -> Void)?
    var onSave: (() -> Void)?
    var onSaveAs: (() -> Void)?
    var onDelete: (() -> Void)?

    private let stackView = NSStackView()
    private var newButton: NSButton!
    private var saveButton: NSButton!
    private var saveAsButton: NSButton!
    private var deleteButton: NSButton!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 28)
    }

    private func setup() {
        // Buttons
        newButton = makeButton(symbolName: "plus", tooltip: "New Query", action: #selector(newTapped))
        saveButton = makeButton(symbolName: "square.and.arrow.down", tooltip: "Save", action: #selector(saveTapped))
        saveAsButton = makeButton(symbolName: "square.and.arrow.down.on.square", tooltip: "Save As", action: #selector(saveAsTapped))
        deleteButton = makeButton(symbolName: "trash", tooltip: "Delete", action: #selector(deleteTapped))

        stackView.orientation = .horizontal
        stackView.spacing = 2
        stackView.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stackView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 28),
        ])

        updateButtons()
    }

    private func makeButton(symbolName: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)
        button.toolTip = tooltip
        button.isBordered = false
        button.bezelStyle = .toolbar
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    private func updateButtons() {
        stackView.arrangedSubviews.forEach { stackView.removeArrangedSubview($0); $0.removeFromSuperview() }

        switch mode {
        case .library:
            stackView.addArrangedSubview(newButton)
            stackView.addArrangedSubview(saveButton)
            stackView.addArrangedSubview(saveAsButton)
            // Flexible spacer pushes delete to the right
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            stackView.addArrangedSubview(spacer)
            stackView.addArrangedSubview(deleteButton)
        case .history:
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            stackView.addArrangedSubview(spacer)
            stackView.addArrangedSubview(deleteButton)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Top border line
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 0.5, width: bounds.width, height: 0.5).fill()
    }

    // MARK: - Button State

    /// Enable/disable Save button (when active tab has linked savedQueryId)
    var isSaveEnabled: Bool = false { didSet { saveButton.isEnabled = isSaveEnabled } }

    /// Enable/disable Save As button (when any active tab exists)
    var isSaveAsEnabled: Bool = false { didSet { saveAsButton.isEnabled = isSaveAsEnabled } }

    /// Enable/disable Delete button (when item(s) selected)
    var isDeleteEnabled: Bool = false { didSet { deleteButton.isEnabled = isDeleteEnabled } }

    // MARK: - Actions

    @objc private func newTapped() { onNew?() }
    @objc private func saveTapped() { onSave?() }
    @objc private func saveAsTapped() { onSaveAs?() }
    @objc private func deleteTapped() { onDelete?() }
}
