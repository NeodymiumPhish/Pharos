import AppKit
import Combine

/// What a query tab's connection is doing, as its native tab shows it.
enum TabConnectionState: Equatable {
    /// The tab has no connection chosen.
    case none
    case disconnected
    case connecting
    case connected
    case error

    init(connectionId: String?, status: ConnectionStatus?) {
        guard connectionId != nil else { self = .none; return }
        switch status {
        case .connected: self = .connected
        case .connecting: self = .connecting
        case .error: self = .error
        case .disconnected, nil: self = .disconnected
        }
    }

    /// Filled dot colour; nil draws an empty ring.
    var fill: NSColor? {
        switch self {
        case .connected: return .systemGreen
        case .connecting: return .systemOrange
        case .error: return .systemRed
        case .disconnected, .none: return nil
        }
    }

    /// The window subtitle under the tab's name: "Coda · public", "Coda", or
    /// "No connection".
    static func subtitle(connectionName: String?, schema: String?) -> String {
        guard let connectionName else { return String(localized: "No connection") }
        guard let schema, !schema.isEmpty else { return connectionName }
        return "\(connectionName) · \(schema)"
    }

    /// What VoiceOver reads, and the tab tooltip's last part.
    var label: String {
        switch self {
        case .none: return String(localized: "No connection")
        case .disconnected: return String(localized: "Not connected")
        case .connecting: return String(localized: "Connecting")
        case .connected: return String(localized: "Connected")
        case .error: return String(localized: "Connection failed")
        }
    }
}

/// The dot on a native window tab (`NSWindowTab.accessoryView`): the tab's
/// connection state, in colour, and a pulse while the tab runs queries — the
/// same breathing `PulseClock` value as the rest of the app.
final class TabConnectionDot: NSView {
    static let diameter: CGFloat = 8

    var state: TabConnectionState = .none {
        didSet {
            guard state != oldValue else { return }
            setAccessibilityLabel(state.label)
            needsDisplay = true
        }
    }

    var isRunning = false {
        didSet {
            guard isRunning != oldValue else { return }
            if isRunning {
                let token = PulseClock.shared.observe()
                let sink = PulseClock.shared.value.sink { [weak self] v in
                    self?.pulse = v
                    self?.needsDisplay = true
                }
                pulseSubscription = AnyCancellable {
                    sink.cancel()
                    token.cancel()
                }
            } else {
                // At once, so the clock's observer count drops right away.
                pulseSubscription = nil
                pulse = 1
            }
            needsDisplay = true
        }
    }

    /// The opacity the dot is drawn at: solid at rest, breathing while running.
    var drawnAlpha: CGFloat { isRunning ? 0.45 + 0.55 * pulse : 1 }

    private var pulse: CGFloat = 1
    private var pulseSubscription: AnyCancellable?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(state.label)
        setAccessibilityIdentifier("window.tab.connectionDot")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.diameter + 4, height: Self.diameter + 4)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(x: bounds.midX - Self.diameter / 2, y: bounds.midY - Self.diameter / 2,
                          width: Self.diameter, height: Self.diameter)
        if let fill = state.fill {
            fill.withAlphaComponent(drawnAlpha).setFill()
            NSBezierPath(ovalIn: rect).fill()
        } else {
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            NSColor.tertiaryLabelColor.withAlphaComponent(drawnAlpha).setStroke()
            ring.stroke()
        }
    }
}
