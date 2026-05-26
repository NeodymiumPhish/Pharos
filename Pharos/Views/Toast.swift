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
}

/// Self-managed transient notification. Each call adds one toast view to the
/// host's view tree, fades it in/out, and removes it. Multiple concurrent
/// toasts stack upward from the bottom-center of the host.
enum Toast {

    static func show(in host: NSView,
                     message: String,
                     style: ToastStyle = .info,
                     duration: TimeInterval = 2.0) {
        let toast = ToastView(message: message, style: style)
        toast.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(toast)

        // Stack offset: count existing ToastView siblings already in host.
        let siblingCount = host.subviews.filter { $0 is ToastView && $0 !== toast }.count
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

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                toast.animator().alphaValue = 0
            }, completionHandler: {
                toast.removeFromSuperview()
            })
        }
    }
}

/// Visual view used by `Toast.show`. Outside callers should use `Toast.show`.
final class ToastView: NSVisualEffectView {

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
        icon.image = NSImage(systemSymbolName: style.symbolName, accessibilityDescription: nil)?
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 32)
    }
}
