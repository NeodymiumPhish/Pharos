import AppKit

/// The Variable Manager's Connections section: whether a variable applies to
/// every connection (global, the default) or only to some, and which.
///
/// A view only: the owner gives it the choices (`VariableScope.linkTargets`,
/// with names and tiles) and the linked ids, and hears every change through
/// `onChange` — an empty array means global. Choosing "Only these
/// connections" with no box ticked yet changes nothing: a variable linked to no
/// connection would apply nowhere, so it stays global until one is ticked.
final class VariableConnectionsView: NSView {

    struct Choice: Equatable {
        let id: String
        let name: String
        let place: String
        let kind: ConnectionTile.Kind
        let state: TabConnectionState
        let missing: Bool
    }

    var onChange: (([String]) -> Void)?

    private let titleLabel = NSTextField(labelWithString: String(localized: "Connections"))
    private let allButton = NSButton(radioButtonWithTitle: String(localized: "All connections"), target: nil, action: nil)
    private let someButton = NSButton(radioButtonWithTitle: String(localized: "Only these connections"),
                                      target: nil, action: nil)
    private let hintLabel = NSTextField(labelWithString: "")
    private let listStack = NSStackView()
    private let scrollView = NSScrollView()
    private var boxes: [(id: String, box: NSButton)] = []
    private var linked: [String] = []
    private var choosingSome = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func build() {
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        for button in [allButton, someButton] {
            button.target = self
            button.action = #selector(scopeChosen(_:))
        }
        allButton.setAccessibilityIdentifier("variables.scope.all")
        someButton.setAccessibilityIdentifier("variables.scope.some")
        hintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hintLabel.textColor = .secondaryLabelColor

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 4
        listStack.edgeInsets = NSEdgeInsets(top: 4, left: 20, bottom: 4, right: 4)
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        listStack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(listStack)
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let column = NSStackView(views: [titleLabel, allButton, someButton, scrollView, hintLabel])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            scrollView.widthAnchor.constraint(equalTo: column.widthAnchor),
            listStack.topAnchor.constraint(equalTo: document.topAnchor),
            listStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            listStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
    }

    /// Show `choices`, with `linked` ticked; empty `linked` is global.
    func show(choices: [Choice], linked: [String]) {
        self.linked = linked
        choosingSome = !linked.isEmpty
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        boxes.removeAll()
        for choice in choices {
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(boxToggled(_:)))
            box.state = linked.contains(choice.id) ? .on : .off
            box.setAccessibilityLabel(choice.missing ? String(localized: "Missing connection") : choice.name)
            let tile = NSImageView(image: ConnectionTile.image(kind: choice.kind, state: choice.state, size: 20))
            let name = NSTextField(labelWithString: choice.missing ? String(localized: "Missing connection") : choice.name)
            name.textColor = choice.missing ? .secondaryLabelColor : .labelColor
            let place = NSTextField(labelWithString: choice.missing
                                    ? String(localized: "The connection was removed. Untick it to remove the link.")
                                    : choice.place)
            place.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            place.textColor = .secondaryLabelColor
            place.lineBreakMode = .byTruncatingMiddle
            let text = NSStackView(views: [name, place])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 0
            let row = NSStackView(views: [box, tile, text])
            row.orientation = .horizontal
            row.spacing = 6
            row.alignment = .centerY
            listStack.addArrangedSubview(row)
            boxes.append((choice.id, box))
        }
        applyEnabledState()
    }

    private func applyEnabledState() {
        allButton.state = choosingSome ? .off : .on
        someButton.state = choosingSome ? .on : .off
        for (_, box) in boxes { box.isEnabled = choosingSome }
        hintLabel.stringValue = !choosingSome
            ? String(localized: "Every tab can use this variable.")
            : linked.isEmpty
                ? String(localized: "Tick at least one connection. Until then the variable stays global.")
                : String(localized: "Only tabs on the ticked connections can use this variable.")
    }

    @objc private func scopeChosen(_ sender: NSButton) {
        choosingSome = sender === someButton
        if !choosingSome, !linked.isEmpty {
            linked = []
            for (_, box) in boxes { box.state = .off }
            onChange?([])
        }
        applyEnabledState()
    }

    @objc private func boxToggled(_ sender: NSButton) {
        linked = boxes.filter { $0.box.state == .on }.map(\.id)
        onChange?(linked)
        applyEnabledState()
    }

    /// Test seams.
    var tickedIds: [String] { boxes.filter { $0.box.state == .on }.map(\.id) }
    func tick(_ id: String, _ on: Bool) {
        guard let box = boxes.first(where: { $0.id == id })?.box else { return }
        box.state = on ? .on : .off
        boxToggled(box)
    }
    func chooseSome() { scopeChosen(someButton) }
    func chooseAll() { scopeChosen(allButton) }
    var isGlobalChosen: Bool { allButton.state == .on }
}

/// A document view whose origin is at the top, so a short list sits at the
/// top of its scroll view.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
