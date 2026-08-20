import AppKit

/// Stands beside a field whose contents must NEVER be altered, and says that an
/// invisible character is in there.
///
/// Connection host, database, username and password are round-trip data: they go
/// to libpq and must come back byte-identical, so they can be neither escaped
/// nor sanitised. That leaves disclosure as the only honest option — the field
/// keeps the exact bytes, and this says what the field cannot.
///
/// The password field is included on purpose. A password pasted with a stray
/// zero-width character fails authentication with no explanation and no way to
/// see why; this badge is the only route by which a user could find out. It
/// reveals nothing secret — only that an invisible character is present.
final class HostileTextBadge: NSImageView {

    init() {
        super.init(frame: .zero)
        let symbol = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                        accessibilityDescription: "This field contains an invisible character")?
            .withSymbolConfiguration(symbol)
        contentTintColor = .systemOrange
        isHidden = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Raises or lowers the badge for `text`.
    ///
    /// Both directions are assigned every time: a badge that is only ever
    /// raised outlives the value that caused it, and these fields are reused
    /// across connections.
    func update(for text: String) {
        guard DisplayEscape.needsEscaping(text) else {
            isHidden = true
            toolTip = nil
            return
        }
        isHidden = false
        toolTip = "This field contains an invisible character: \(DisplayEscape.escaped(text))"
    }
}
