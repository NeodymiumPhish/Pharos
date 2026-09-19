import AppKit

/// The controls a `SettingsRow` carries, each sized and configured the one
/// way the Settings window wants it. Every factory returns a view with
/// `translatesAutoresizingMaskIntoConstraints = false`; none wires a target,
/// that is the form builder's job.
enum SettingsControlFactory {

    static func toggle() -> NSSwitch {
        let s = NSSwitch()
        s.controlSize = .regular
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    static func popup(titles: [String]) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.controlSize = .regular
        p.addItems(withTitles: titles)
        p.translatesAutoresizingMaskIntoConstraints = false
        p.widthAnchor.constraint(greaterThanOrEqualToConstant: SettingsMetrics.controlMinWidth).isActive = true
        return p
    }

    /// Integer-only formatter with hard bounds. Moved here from
    /// `SettingsForm`, which a later phase removes.
    static func numberFormatter(min: Int, max: Int) -> NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = NSNumber(value: min)
        f.maximum = NSNumber(value: max)
        f.allowsFloats = false
        return f
    }

    static func numberField(range: ClosedRange<Int>) -> NSTextField {
        let field = NSTextField()
        field.formatter = numberFormatter(min: range.lowerBound, max: range.upperBound)
        field.alignment = .right
        field.controlSize = .regular
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: SettingsMetrics.numberFieldWidth).isActive = true
        return field
    }

    /// A number field, a stepper and an optional unit label side by side.
    /// The field and stepper are NOT bound to each other here; the form
    /// builder binds both to the setting.
    static func stepperGroup(range: ClosedRange<Int>, unit: String?)
        -> (container: NSView, field: NSTextField, stepper: NSStepper) {
        let field = numberField(range: range)
        let stepper = NSStepper()
        stepper.minValue = Double(range.lowerBound)
        stepper.maxValue = Double(range.upperBound)
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.translatesAutoresizingMaskIntoConstraints = false

        var views: [NSView] = [field, stepper]
        if let unit, !unit.isEmpty {
            let label = NSTextField(labelWithString: unit)
            label.font = .systemFont(ofSize: SettingsMetrics.titleFontSize)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            views.append(label)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.setCustomSpacing(2, after: field)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return (stack, field, stepper)
    }

    static func textField(width: CGFloat = SettingsMetrics.textFieldWidth,
                          placeholder: String? = nil) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.controlSize = .regular
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    static func slider(range: ClosedRange<Double>) -> NSSlider {
        let slider = NSSlider()
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.isContinuous = true
        slider.controlSize = .regular
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: SettingsMetrics.sliderWidth).isActive = true
        return slider
    }

    static func segmented(labels: [String]) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: nil, action: nil)
        control.segmentStyle = .automatic
        control.controlSize = .regular
        control.translatesAutoresizingMaskIntoConstraints = false
        return control
    }

    /// A truncating path label and a "Choose…" button. The button's action is
    /// the caller's; `directories` only records what the chooser is for.
    static func pathChooser(directories: Bool)
        -> (container: NSView, label: NSTextField, button: NSButton) {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: SettingsMetrics.titleFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.usesSingleLineMode = true
        label.cell?.truncatesLastVisibleLine = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        label.setAccessibilityLabel(directories
            ? String(localized: "Chosen folder")
            : String(localized: "Chosen file"))

        let button = NSButton(title: String(localized: "Choose…"), target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView(views: [label, button])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return (stack, label, button)
    }

    static func actionButton(title: String, destructive: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.hasDestructiveAction = destructive
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }
}
