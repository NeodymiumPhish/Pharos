import AppKit

/// A borderless ⓘ button that pops a short explanation over itself.
final class SettingsInfoButton: NSButton {

    let help: String

    init(help: String) {
        self.help = help
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        imagePosition = .imageOnly
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        contentTintColor = .secondaryLabelColor
        target = self
        action = #selector(showPopover(_:))
        setAccessibilityLabel(String(localized: "More Information"))
        setAccessibilityHelp(help)
        toolTip = help
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SettingsInfoButton is built in code") }

    private(set) var popover: NSPopover?

    /// Test seam: pop the help without a mouse.
    func presentHelp() { showPopover(nil) }

    @objc private func showPopover(_ sender: Any?) {
        if let popover, popover.isShown {
            popover.performClose(sender)
            return
        }
        let label = NSTextField(wrappingLabelWithString: help)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.preferredMaxLayoutWidth = 260
        label.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: label.bottomAnchor, constant: 12),
            // A FIXED width, not a ceiling. A wrapping label resists
            // horizontal compression only weakly, so the layout pass the
            // popover runs on its own content view after `show` squeezed the
            // label down to a few points wide — the popover kept the height
            // measured here and lost the text, which is the blank popover
            // every ⓘ used to give.
            label.widthAnchor.constraint(equalToConstant: 260),
        ])
        let vc = NSViewController()
        vc.view = content

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = vc
        popover.contentSize = content.fittingSize
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        self.popover = popover
    }
}
