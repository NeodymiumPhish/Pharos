import AppKit

/// Settings ▸ Security & Privacy ▸ AI Apps: every app that has reached the
/// MCP server, by its signature, with how far the user trusts it.
///
/// A new app arrives Not approved and is refused until the user picks Local
/// (its model runs on this Mac) or Cloud. An unsigned launcher is known only
/// by its path, and says so: any program run with it would get its access.
@MainActor
final class MCPAppsListView: NSView {

    private let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        setAccessibilityIdentifier("settings.security.mcpApps")
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private var shown: [MCPAppRecord] = []

    /// Rebuild from the stored list, when it changed.
    func reload() {
        let apps = AppStateManager.shared.settings.security.mcpApps
        guard apps != shown || stack.arrangedSubviews.isEmpty else { return }
        shown = apps
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !apps.isEmpty else {
            stack.addArrangedSubview(caption(String(localized: "No AI app has used Pharos yet. An app appears here the first time it calls one of Pharos's tools, and is refused until you choose Local or Cloud for it.")))
            return
        }
        for app in apps { stack.addArrangedSubview(row(for: app)) }
        stack.addArrangedSubview(caption(String(localized: "Local: its model runs on this Mac, and it gets what you give local AI apps. Cloud: its model runs on another company's servers. Not approved and Blocked: refused.")))
    }

    private func row(for app: MCPAppRecord) -> NSView {
        let name = NSTextField(labelWithString: DisplayEscape.escaped(app.name))
        name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let detailText = app.signed
            ? DisplayEscape.escaped(app.detail)
            : String(localized: "Not signed: \(DisplayEscape.escaped(app.detail)). Any program run with it gets the same access.")
        let detail = caption(detailText)
        detail.textColor = app.signed ? .secondaryLabelColor : .systemOrange
        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let popup = NSPopUpButton()
        popup.addItems(withTitles: MCPTrust.allCases.map(\.displayLabel))
        popup.selectItem(at: MCPTrust.allCases.firstIndex(of: app.trust) ?? 0)
        popup.identifier = NSUserInterfaceItemIdentifier(app.id)
        popup.target = self
        popup.action = #selector(trustChanged(_:))
        popup.setAccessibilityLabel(String(localized: "Access for \(app.name)"))
        popup.setAccessibilityIdentifier("settings.security.mcpApp.\(app.id)")

        let forget = NSButton(title: String(localized: "Forget"), target: self, action: #selector(forget(_:)))
        forget.identifier = NSUserInterfaceItemIdentifier(app.id)
        forget.bezelStyle = .rounded
        forget.toolTip = String(localized: "Remove it from this list. If it uses Pharos again, it is Not approved until you choose.")

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [text, spacer, popup, forget])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return row
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 460
        return label
    }

    @objc private func trustChanged(_ sender: NSPopUpButton) {
        guard let id = sender.identifier?.rawValue, MCPTrust.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        let trust = MCPTrust.allCases[sender.indexOfSelectedItem]
        update { apps in
            if let i = apps.firstIndex(where: { $0.id == id }) { apps[i].trust = trust }
        }
    }

    @objc private func forget(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        update { $0.removeAll { $0.id == id } }
    }

    private func update(_ change: (inout [MCPAppRecord]) -> Void) {
        let manager = AppStateManager.shared
        var settings = manager.settings
        change(&settings.security.mcpApps)
        guard settings != manager.settings else { return }
        manager.saveSettings(settings)
    }
}
