import AppKit

/// The three lists the sidebar can show. The raw value is the persisted
/// preference and the menu item's tag, so the order must not be rearranged.
enum Navigator: Int, CaseIterable, Sendable {
    case library
    case history
    case schema

    var symbolName: String {
        switch self {
        case .library: return "folder"
        case .history: return "clock.arrow.circlepath"
        case .schema: return "cylinder.split.1x2"
        }
    }

    var title: String {
        switch self {
        case .library: return String(localized: "Query Library")
        case .history: return String(localized: "Results History")
        case .schema: return String(localized: "Database Navigation")
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .library: return "sidebar.navigator.library"
        case .history: return "sidebar.navigator.history"
        case .schema: return "sidebar.navigator.schema"
        }
    }
}

/// The flat, icon-only row at the top of the sidebar that picks which
/// navigator is on screen — Xcode's navigator selector.
///
/// Why hand-built buttons and not `NSSegmentedControl`: a segmented control
/// draws a bezel (`.capsule`, `.separated`, …) or, when told to draw none,
/// loses its selected state too. The look Xcode has — nothing at all around
/// an unselected icon, a neutral rounded fill behind the selected one, no
/// accent tint — comes from `NSButton` with `bezelStyle = .accessoryBar`,
/// `setButtonType(.pushOnPushOff)` and `showsBorderOnlyWhileMouseInside`.
/// That combination was measured in both appearances; `isBordered = false`
/// breaks the on-state, and turning the mouse-inside flag off puts a faint
/// bezel back under every unselected icon.
final class NavigatorSelector: NSView {

    /// Height of the row.
    static let height: CGFloat = 28

    /// Fires only when the selection actually changes — never when the user
    /// clicks the navigator that is already showing.
    var onChange: ((Navigator) -> Void)?

    private var buttons: [Navigator: NSButton] = [:]
    private let stack = NSStackView()

    var selected: Navigator = .library {
        didSet { syncButtons() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func build() {
        // A plain NSView is an IGNORED accessibility element: without this the
        // role, the label and the identifier below would all be set and none
        // of them would appear in the tree.
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(String(localized: "Navigators"))
        setAccessibilityIdentifier("sidebar.navigator")

        stack.orientation = .horizontal
        stack.distribution = .equalCentering
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)

        for navigator in Navigator.allCases {
            let button = NSButton()
            button.bezelStyle = .accessoryBar
            button.setButtonType(.pushOnPushOff)
            button.imagePosition = .imageOnly
            button.showsBorderOnlyWhileMouseInside = true
            button.image = NSImage(systemSymbolName: navigator.symbolName,
                                   accessibilityDescription: navigator.title)?
                .withSymbolConfiguration(config)
            button.toolTip = navigator.title
            button.target = self
            button.action = #selector(buttonClicked(_:))
            button.tag = navigator.rawValue
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setAccessibilityRole(.radioButton)
            button.setAccessibilityLabel(navigator.title)
            button.setAccessibilityIdentifier(navigator.accessibilityIdentifier)

            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 28),
                button.heightAnchor.constraint(equalToConstant: 24),
            ])

            buttons[navigator] = button
            stack.addArrangedSubview(button)
        }

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])

        syncButtons()
    }

    /// Exactly one button is `.on`. Re-asserted after every click, so clicking
    /// the selected navigator cannot switch it off — a radio group, not three
    /// independent toggles.
    private func syncButtons() {
        for (navigator, button) in buttons {
            button.state = (navigator == selected) ? .on : .off
        }
    }

    @objc private func buttonClicked(_ sender: NSButton) {
        guard let navigator = Navigator(rawValue: sender.tag) else { return }
        guard navigator != selected else {
            // A push-on/push-off button toggled itself to .off on the way in.
            syncButtons()
            return
        }
        selected = navigator
        onChange?(navigator)
    }

    /// The button for a navigator — for tests and for anyone needing to point
    /// a popover at one.
    func button(for navigator: Navigator) -> NSButton? { buttons[navigator] }
}
