import AppKit
import Combine

/// The per-tab error indicator in the editor toolbar.
///
/// Three states: hidden with no entries, quiet grey when the user has read them
/// all, and red and breathing while one entry is unread. The breathing comes
/// from the shared `PulseClock`, so it stays in step with the query-running
/// animation elsewhere, and it holds a static red under Reduce Motion.
final class ErrorBadgeButton: NSButton {

    /// Whether the pulse subscription is live. Read by the tests.
    private(set) var isPulsing = false

    /// The alpha the pulse last computed. Held as a number rather than read back
    /// off `contentTintColor`, because a dynamic system colour needs a
    /// colour-space conversion before its components can be read.
    private(set) var pulseAlpha: CGFloat = 1.0

    private var pulseSubscription: AnyCancellable?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    convenience init() {
        self.init(frame: .zero)
    }

    private func configure() {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                        accessibilityDescription: "Query Errors")?
            .withSymbolConfiguration(config)
        imagePosition = .imageLeading
        bezelStyle = .recessed
        isBordered = false
        font = .systemFont(ofSize: 11, weight: .medium)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
    }

    /// Push the log state of the pane's active tab.
    func setState(total: Int, unread: Int) {
        isHidden = total == 0
        // A single entry needs no number; the symbol alone says everything.
        title = total > 1 ? "\(total)" : ""
        toolTip = unread > 0 ? "Query Errors (\(total), \(unread) new)" : "Query Errors (\(total))"
        setPulsing(total > 0 && unread > 0)
    }

    private func setPulsing(_ pulsing: Bool) {
        guard pulsing != isPulsing else { return }
        isPulsing = pulsing
        if pulsing {
            startPulse()
        } else {
            pulseSubscription = nil
            pulseAlpha = 1.0
            applyTint()
        }
    }

    private func startPulse() {
        guard pulseSubscription == nil else { return }
        // The token keeps the display link running; the sink delivers the value.
        // Both must be cancelled together, which is why they are wrapped as one.
        let token = PulseClock.shared.observe()
        let sink = PulseClock.shared.value.sink { [weak self] value in
            guard let self, self.isPulsing else { return }
            self.pulseAlpha = 0.55 + 0.45 * value
            self.applyTint()
        }
        pulseSubscription = AnyCancellable {
            sink.cancel()
            token.cancel()
        }
        applyTint()
    }

    private func applyTint() {
        contentTintColor = isPulsing
            ? NSColor.systemRed.withAlphaComponent(pulseAlpha)
            : .secondaryLabelColor
    }

    /// The right-aligned group at the trailing edge of the editor toolbar. The
    /// error button goes to the left of the variables toggle, and the toggle
    /// keeps the position and the size it had before this button existed.
    static func makeToolbarTrailingGroup(
        errorButton: ErrorBadgeButton, variablesToggle: NSButton
    ) -> NSStackView {
        variablesToggle.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            variablesToggle.widthAnchor.constraint(equalToConstant: 28),
            variablesToggle.heightAnchor.constraint(equalToConstant: 28),
            errorButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 28),
            errorButton.heightAnchor.constraint(equalToConstant: 28),
        ])
        let stack = NSStackView(views: [errorButton, variablesToggle])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }
}
