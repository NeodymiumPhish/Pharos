import SwiftUI

/// `GeneratedContentLabel` for a SwiftUI host — the chart rail.
///
/// The AppKit label is the one users already know from the error sheet and
/// the plan tab; wrapping it keeps the badge, the words and the thumbs the
/// same, and the rating goes to the same store.
struct GeneratedContentLabelView: NSViewRepresentable {
    let feature: String
    let promptHash: String?

    func makeNSView(context: Context) -> GeneratedContentLabel {
        let label = GeneratedContentLabel(feature: feature)
        label.promptHash = promptHash
        return label
    }

    func updateNSView(_ label: GeneratedContentLabel, context: Context) {
        label.promptHash = promptHash
    }
}
