import Foundation

/// The content pane's split state: both areas, the editor alone, or the
/// results alone. `ContentViewController` drives the split view from it.
enum ContentExpandState { case normal, editorExpanded, resultsExpanded }

/// The two toggles on the results action bar — "Editor" and "Results" — as
/// Xcode's debug-area button works: lit while its area is on screen, pressing
/// it hides the area, pressing again brings it back. Both lit is the default
/// split. The last visible area cannot be hidden, so its toggle is disabled
/// rather than hiding everything.
///
/// Pure, so `scripts/test-content-pane-layout.sh` pins the rule without the
/// split view.
struct ContentPaneLayout: Equatable {
    let editorVisible: Bool
    let resultsVisible: Bool

    static let both = ContentPaneLayout(editorVisible: true, resultsVisible: true)

    init(editorVisible: Bool, resultsVisible: Bool) {
        // Never both hidden: that state has no button to come back from.
        if !editorVisible && !resultsVisible {
            self.editorVisible = true
            self.resultsVisible = true
        } else {
            self.editorVisible = editorVisible
            self.resultsVisible = resultsVisible
        }
    }

    init(_ state: ContentExpandState) {
        switch state {
        case .normal: self.init(editorVisible: true, resultsVisible: true)
        case .editorExpanded: self.init(editorVisible: true, resultsVisible: false)
        case .resultsExpanded: self.init(editorVisible: false, resultsVisible: true)
        }
    }

    var expandState: ContentExpandState {
        switch (editorVisible, resultsVisible) {
        case (true, false): return .editorExpanded
        case (false, true): return .resultsExpanded
        default: return .normal
        }
    }

    /// The editor toggle pressed. A no-op while the editor is the only area.
    func togglingEditor() -> ContentPaneLayout {
        guard editorToggleEnabled else { return self }
        return ContentPaneLayout(editorVisible: !editorVisible, resultsVisible: resultsVisible)
    }

    /// The results toggle pressed. A no-op while the results are the only area.
    func togglingResults() -> ContentPaneLayout {
        guard resultsToggleEnabled else { return self }
        return ContentPaneLayout(editorVisible: editorVisible, resultsVisible: !resultsVisible)
    }

    /// The editor can be hidden only while the results are showing; showing
    /// it again is always allowed.
    var editorToggleEnabled: Bool { !editorVisible || resultsVisible }
    var resultsToggleEnabled: Bool { !resultsVisible || editorVisible }

    var editorTooltip: String { editorVisible ? String(localized: "Hide Editor") : String(localized: "Show Editor") }
    var resultsTooltip: String { resultsVisible ? String(localized: "Hide Results") : String(localized: "Show Results") }
}
