import AppKit

/// Styling categories for `Toast.show`. Drives the leading-stripe color and icon.
enum ToastStyle {
    case info, success, warning, error

    var color: NSColor {
        switch self {
        case .info:    return .controlAccentColor
        case .success: return .systemGreen
        case .warning: return .systemOrange
        case .error:   return .systemRed
        }
    }

    var symbolName: String {
        switch self {
        case .info:    return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.octagon.fill"
        }
    }

    /// What the icon MEANS. The symbol carries the severity and the message
    /// text usually does not repeat it, so without this a screen reader hears
    /// "Connection closed" for a failure and a success alike.
    var accessibilityDescription: String {
        switch self {
        case .info:    return "Information"
        case .success: return "Success"
        case .warning: return "Warning"
        case .error:   return "Error"
        }
    }
}

/// Self-managed transient notification. Each call adds one toast view to the
/// host's view tree, fades it in/out, and removes it. Multiple concurrent
/// toasts stack upward from the bottom-center of the host.
enum Toast {

    /// How long a toast raised with no explicit duration stays on screen.
    ///
    /// A settable value rather than a read of `AppStateManager`: this file
    /// compiles on its own in `scripts/test-toast-click.sh`, and the settings
    /// store does not. `SettingsEffects` points it at
    /// `NotificationSettings.toastDuration` at launch and follows every later
    /// change. 2 seconds is what this parameter defaulted to before the
    /// setting existed, so a toast raised before the settings load — and the
    /// harness — behave exactly as they always did.
    nonisolated(unsafe) static var defaultDuration: TimeInterval = 2.0

    /// - Parameter duration: how long it stays. Omitted, the user's
    ///   Settings ▸ Notifications preference decides.
    /// - Parameter onClick: run when the user clicks the toast. A toast with a
    ///   handler fades out at once on the click; a toast without one ignores
    ///   clicks. Used by the query-failure banner to open the error sheet.
    static func show(in host: NSView,
                     message: String,
                     style: ToastStyle = .info,
                     duration: TimeInterval? = nil,
                     onClick: (() -> Void)? = nil) {
        let duration = duration ?? defaultDuration
        let toast = ToastView(message: message, style: style)
        toast.onClick = onClick
        toast.updateAccessibilityHelp()
        toast.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(toast)

        // Stack offset: count existing ToastView siblings already in host, excluding any that are fading out.
        let siblingCount = host.subviews.compactMap { $0 as? ToastView }
            .filter { $0 !== toast && !$0.isFadingOut }
            .count
        let bottomInset: CGFloat = 12 + CGFloat(siblingCount) * (toast.intrinsicContentSize.height + 6)

        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -bottomInset),
        ])

        toast.alphaValue = 0
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            toast.animator().alphaValue = 1.0
        })

        // A toast is the app telling the user something and then taking it away
        // again. Nothing moves the focus to it, so a screen reader would never
        // reach it before it faded: the message has to be ANNOUNCED, at high
        // priority so a queued low-priority announcement cannot outlive it.
        NSAccessibility.post(
            element: host.window ?? host,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            toast.fadeOut()
        }
    }

    /// Dismiss the newest toast at or under `host`, and say whether there was
    /// one. This is what Escape means before it means anything else.
    ///
    /// The newest is the LAST subview, because `show` appends. The search
    /// descends the whole tree rather than reading `host.subviews`, because the
    /// caller that owns Escape and the view a toast was raised in are rarely
    /// the same: `ResultsGridVC` handles the key, `ContentViewController` hosts
    /// the toast. Toasts do all live in one host in practice, so "last in a
    /// reverse depth-first walk" and "last raised" agree.
    ///
    /// A toast already on its way out is skipped — dismissing it again would
    /// report a dismissal the user cannot see, and would swallow the Escape
    /// that was meant for whatever is behind it.
    @discardableResult
    static func dismissNewest(in host: NSView) -> Bool {
        guard let toast = newestToast(in: host) else { return false }
        toast.fadeOut()
        return true
    }

    private static func newestToast(in view: NSView) -> ToastView? {
        for subview in view.subviews.reversed() {
            if let toast = subview as? ToastView, !toast.isFadingOut { return toast }
            if let found = newestToast(in: subview) { return found }
        }
        return nil
    }
}

/// Visual view used by `Toast.show`. Outside callers should use `Toast.show`.
final class ToastView: NSVisualEffectView {

    /// Set once the toast starts to leave, so a later click and the stack offset
    /// both ignore it. Internal (not fileprivate) so the standalone test reads it.
    var isFadingOut = false

    /// Run when the user clicks. Nil means the toast ignores clicks.
    var onClick: (() -> Void)?

    var hasClickHandler: Bool { onClick != nil }

    private let style: ToastStyle

    init(message: String, style: ToastStyle) {
        self.style = style
        super.init(frame: .zero)
        self.material = .hudWindow
        self.state = .active
        self.blendingMode = .withinWindow
        self.wantsLayer = true
        self.layer?.cornerRadius = 8
        self.layer?.masksToBounds = true

        let stripe = NSView()
        stripe.translatesAutoresizingMaskIntoConstraints = false
        stripe.wantsLayer = true
        stripe.layer?.backgroundColor = style.color.cgColor
        addSubview(stripe)

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        icon.image = NSImage(systemSymbolName: style.symbolName,
                             accessibilityDescription: style.accessibilityDescription)?
            .withSymbolConfiguration(config)
        icon.contentTintColor = style.color
        addSubview(icon)

        let label = NSTextField(labelWithString: message)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)

        NSLayoutConstraint.activate([
            stripe.leadingAnchor.constraint(equalTo: leadingAnchor),
            stripe.topAnchor.constraint(equalTo: topAnchor),
            stripe.bottomAnchor.constraint(equalTo: bottomAnchor),
            stripe.widthAnchor.constraint(equalToConstant: 3),

            icon.leadingAnchor.constraint(equalTo: stripe.trailingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            heightAnchor.constraint(equalToConstant: 32),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])

        // One element, not a group of three: the stripe and the icon say the
        // same thing the style already put in front of the message, and a
        // screen reader stepping through a view that is about to vanish is not
        // a thing anyone wants. The severity is spoken with the text.
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(style.accessibilityDescription): \(message)")
        setAccessibilityValue(message)
    }

    /// Set by `Toast.show` once the click handler is attached, so the help
    /// reflects whether there is anything to click.
    func updateAccessibilityHelp() {
        setAccessibilityHelp(onClick != nil ? "Click to open" : nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 32)
    }

    override func mouseDown(with event: NSEvent) {
        guard let onClick, !isFadingOut else { return }
        onClick()
        fadeOut()
    }

    /// Fade out and leave the view tree. Called by the timer in `Toast.show` and
    /// by a click.
    func fadeOut() {
        guard !isFadingOut else { return }
        isFadingOut = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.removeFromSuperview()
        })
    }
}
