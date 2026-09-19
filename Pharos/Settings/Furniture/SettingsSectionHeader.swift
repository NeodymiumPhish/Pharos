import AppKit

/// The bold label above a `SettingsGroupBox`.
enum SettingsSectionHeader {

    /// A 13pt bold label carrying the identifier `settings.section.<slug>`,
    /// where the slug is the lowercased title with every run of
    /// non-alphanumerics folded to one `-`.
    static func make(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: SettingsMetrics.headerFontSize)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityRole(.staticText)
        label.setAccessibilityIdentifier("settings.section.\(slug(title))")
        return label
    }

    static func slug(_ title: String) -> String {
        var out = ""
        var pendingDash = false
        for scalar in title.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return out
    }
}
