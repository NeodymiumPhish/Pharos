import AppKit

extension NSStackView {

    /// Hold every arranged subview of this VERTICAL stack at the stack's own
    /// width, so each starts at the same leading edge and none hugs its
    /// content. Pair it with `alignment = .leading`, which pins where a row
    /// STARTS; this is what makes the row span.
    ///
    /// # Why the obvious spelling does not work
    ///
    /// This is the job `alignment = .width` reads as doing, and does not do. An
    /// NSStackView refuses `.width`: assign it and the property reads back as
    /// `.notAnAttribute` — no alignment at all. Each arranged subview is then
    /// left with only the two weak edge constraints AppKit adds regardless,
    /// `Edge.Min.Leading` at priority 250 and `Edge.Min.Trailing` at 260.
    /// Trailing wins by those ten points, so every subview narrower than the
    /// stack is pushed to the RIGHT — and nothing constrains its width, so how
    /// wide it ends up is the solver's choice. Rows with identical content can
    /// land differently, which is why the drift this fixed in `TagRemovalSheet`
    /// read as a repeating cycle rather than as one broken row.
    ///
    /// A stack whose content happens to fill it looks correct under `.width`
    /// anyway, which is the trap: the defect is latent until a row that hugs
    /// its content is added, and then it appears somewhere nobody edited.
    ///
    /// Call it AFTER every arranged subview has been added — it constrains what
    /// is there when it runs, not what arrives later. `.leading` is what
    /// catches a row that arrives later anyway: a row this pin reached is the
    /// stack's width and so starts at the stack's edge whatever the alignment
    /// says, but a row added afterwards has only the alignment to hold it.
    ///
    /// `edgeInsets` is subtracted, because "the stack's width" is not the width
    /// a row may occupy on a stack that pads its sides: pinning to the raw
    /// `widthAnchor` there widens every row over its own padding and the
    /// content reaches the container's edge. `ColumnFilterPopoverVC` pads by
    /// 12pt each side and lost exactly that when this was written without the
    /// subtraction.
    ///
    /// `scripts/test-stack-span.sh` measures all three states — the rejected
    /// alignment, `.leading` alone, and `.leading` with this pin — plus the
    /// padded case, and `scripts/test-tag-removal-sheet.sh` measures the real
    /// sheet.
    func spanArrangedSubviewsFullWidth() {
        let padding = edgeInsets.left + edgeInsets.right
        for child in arrangedSubviews {
            child.widthAnchor.constraint(equalTo: widthAnchor, constant: -padding).isActive = true
        }
    }
}
