import AppKit

// MARK: - Form building


/// The bits of form furniture every pane uses.
enum SettingsForm {

    /// Integer-only formatter with hard bounds, as the old sheet had.
    static func numberFormatter(min: Int, max: Int) -> NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = NSNumber(value: min)
        f.maximum = NSNumber(value: max)
        f.allowsFloats = false
        return f
    }

    static func configureGrid(_ grid: NSGridView) {
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
    }

    /// Insets `content` inside a fresh view, and CENTRES it when the pane is
    /// wider than the content needs.
    ///
    /// The side insets are deliberately breakable. `paneSize(for:)` floors
    /// every pane at `minimumPaneWidth` so the window does not jump between
    /// tabs — so a pane whose form is narrower than that gets stretched. With
    /// both side insets required, the grid stretched with it, and since its
    /// label column is `.trailing`, all of the slack landed in that column:
    /// the whole form slid to the right-hand side of the window, which is what
    /// the Editor pane looked like. Centring puts the slack on both sides.
    ///
    /// All four edges are still constrained, and the side pair still holds at
    /// the natural size: the pane's `fittingSize` is what sizes the window for
    /// this tab, so an unpinned edge would size it to nothing.
    static func wrap(_ content: NSView, inset: CGFloat = 20) -> NSView {
        let wrapper = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(content)

        // Load-bearing, and the whole reason the first attempt at this did not
        // work. `NSGridView` hugs horizontally at 249 — just under
        // `.defaultLow` — so with breakable side insets at 250 the solver
        // happily STRETCHED the grid to satisfy them instead of centring it,
        // and the slack went straight into the trailing label column again.
        // Raising the content's hugging above any constraint here is what makes
        // "stay your natural width, and let the wrapper centre you" the answer.
        // A pane that genuinely wants to fill can lower this after wrapping.
        content.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: inset),
            wrapper.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: inset),
            // The insets are MINIMA at any width, and together they are also
            // what gives `fittingSize` the right answer: the narrowest wrapper
            // satisfying both is the content plus two insets.
            content.leadingAnchor.constraint(
                greaterThanOrEqualTo: wrapper.leadingAnchor, constant: inset),
            wrapper.trailingAnchor.constraint(
                greaterThanOrEqualTo: content.trailingAnchor, constant: inset),
            content.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
        ])
        return wrapper
    }

    /// Every pane is at least this wide, so the window does not jump in width
    /// between tabs the way it would if each pane were sized to its own text.
    static let minimumPaneWidth: CGFloat = 540
}
