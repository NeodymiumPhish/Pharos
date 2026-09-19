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

    private var popover: NSPopover?

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
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
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
