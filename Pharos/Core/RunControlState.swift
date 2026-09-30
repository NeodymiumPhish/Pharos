import CoreGraphics
import Foundation

/// What the toolbar's Run | Cancel control shows, from whether the active tab
/// can run and how many of its queries are running.
///
/// Pure, so the rule can be pinned without a toolbar (`MainToolbarController`
/// pulls in the FFI and cannot be hosted by a harness). `RunControl` applies it.
///
/// "Running" is said the way the rest of the app says it: the Cancel glyph
/// breathes in the accent colour on `PulseClock`, with the tab dot's alpha
/// formula (`PaneTabBar`). Red stays for the per-query cancel buttons in the
/// running-queries list; there is no count badge.
struct RunControlState: Equatable {

    enum CancelAction: Equatable {
        case none
        /// One query is running: Cancel stops it.
        case cancelOne
        /// Two or more: Cancel opens the running-queries list.
        case showList
    }

    /// The pulse is drawn as one of this many pre-built tints of the Cancel
    /// glyph. A segmented control in the toolbar draws its images through a
    /// SwiftUI host that rasterises an image once, so the glyph cannot be
    /// redrawn per frame; swapping images can, and a step is only set when it
    /// changes.
    static let tintSteps = 12

    let runEnabled: Bool
    let cancelEnabled: Bool
    /// nil when nothing runs (the plain template glyph); else 0 … tintSteps-1.
    let tintStep: Int?
    let cancelToolTip: String
    let cancelAccessibilityLabel: String
    let cancelAction: CancelAction

    static let runToolTip = String(localized: "Run Query (⌘↩)")
    static let runAccessibilityLabel = String(localized: "Run Query")

    /// - Parameter pulse: `PulseClock`'s value in [0, 1]; 1.0 under Reduce Motion.
    init(canRun: Bool, runningCount: Int, pulse: CGFloat) {
        let count = max(0, runningCount)
        runEnabled = canRun
        cancelEnabled = count > 0
        if count > 0 {
            let clamped = min(max(pulse, 0), 1)
            tintStep = Int((clamped * CGFloat(Self.tintSteps - 1)).rounded())
        } else {
            tintStep = nil
        }
        switch count {
        case 0:
            cancelToolTip = String(localized: "Cancel Query (⌘.)")
            cancelAccessibilityLabel = String(localized: "Cancel Query")
            cancelAction = .none
        case 1:
            cancelToolTip = String(localized: "Cancel Query (⌘.)")
            cancelAccessibilityLabel = String(localized: "Cancel Query")
            cancelAction = .cancelOne
        default:
            cancelToolTip = String(localized: "\(count) queries running — click to manage")
            cancelAccessibilityLabel = String(localized: "Cancel \(count) Queries")
            cancelAction = .showList
        }
    }

    /// The accent alpha of a tint step: `0.55 + 0.45 · pulse`, the tab dot's
    /// formula, so the two breathe the same.
    static func alpha(forStep step: Int) -> CGFloat {
        let clamped = min(max(step, 0), tintSteps - 1)
        return 0.55 + 0.45 * CGFloat(clamped) / CGFloat(tintSteps - 1)
    }
}
