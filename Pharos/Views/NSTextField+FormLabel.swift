import AppKit

extension NSTextField {
    /// Creates a right-aligned form label (e.g. "Name:") for use in grid/form layouts.
    static func formLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text + ":")
        label.alignment = .right
        label.font = .systemFont(ofSize: 13)
        return label
    }
}
