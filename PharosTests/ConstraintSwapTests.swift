// Standalone test for NSLayoutConstraint.swap and the views that switch
// layouts with it. Compiled by scripts/test-constraint-swap.sh.
//
// A transient conflict leaves no trace in the final frames (AppKit breaks a
// constraint, then the layout settles the same), and its report goes to the
// unified log, not stderr. With the default
// NSConstraintBasedLayoutVisualizeMutuallyExclusiveConstraints on, AppKit
// also calls the window's `visualizeConstraints(_:)` when it finds a conflict;
// `SpyWindow` counts those calls. AppKit reports one conflict once, so every
// case builds fresh views.
import AppKit

private var failures = 0

private func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition { print("PASS \(name)") } else {
        failures += 1
        let d = detail()
        print("FAIL \(name)" + (d.isEmpty ? "" : "\n  \(d)"))
    }
}

private final class SpyWindow: NSWindow {
    static var conflicts = 0
    override func visualizeConstraints(_ constraints: [NSLayoutConstraint]?) {
        if !(constraints ?? []).isEmpty { Self.conflicts += 1 }
    }
}

private func hostWindow(holding view: NSView) -> SpyWindow {
    let w = SpyWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 400), styleMask: [.titled],
                      backing: .buffered, defer: false)
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 400))
    w.contentView = root
    view.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(view)
    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
        view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        view.topAnchor.constraint(equalTo: root.topAnchor),
        view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])
    root.layoutSubtreeIfNeeded()
    return w
}

/// The results grid's case: a scroll view whose bottom sits on the container
/// or on a 32 pt Load More bar.
private final class GridLike {
    let container = NSView()
    let toEdge: NSLayoutConstraint
    let toBar: NSLayoutConstraint
    let bar = NSView()
    let window: SpyWindow

    init() {
        let scroll = NSView()
        for v in [scroll, bar] { v.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(v) }
        toEdge = scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        toBar = scroll.bottomAnchor.constraint(equalTo: bar.topAnchor)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toEdge,
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 32),
        ])
        window = hostWindow(holding: container)
    }
}

private func testTheDetectorSeesTheOldOrder() {
    let g = GridLike()
    let before = SpyWindow.conflicts
    g.toBar.isActive = true
    g.toEdge.isActive = false
    expect(SpyWindow.conflicts > before, "control: activating before deactivating is reported as a conflict")
}

private func testSwap() {
    let g = GridLike()
    let before = SpyWindow.conflicts
    NSLayoutConstraint.swap(activate: [g.toBar], deactivate: [g.toEdge])
    g.container.layoutSubtreeIfNeeded()
    expect(g.toBar.isActive && !g.toEdge.isActive, "swap: the new constraint is active, the old one is not")
    expect(abs(g.bar.frame.height - 32) < 0.5, "swap: the bar keeps its height", "got \(g.bar.frame.height)")
    NSLayoutConstraint.swap(activate: [g.toEdge], deactivate: [g.toBar])
    g.container.layoutSubtreeIfNeeded()
    expect(SpyWindow.conflicts == before, "swap: no conflict either way", "\(SpyWindow.conflicts - before) reported")
}

private func testVariableListHeader() {
    let list = VariableListView()
    let w = hostWindow(holding: list)
    let before = SpyWindow.conflicts
    list.showsHeader = false
    w.contentView?.layoutSubtreeIfNeeded()
    list.showsHeader = true
    w.contentView?.layoutSubtreeIfNeeded()
    expect(SpyWindow.conflicts == before, "variables list: hiding and showing the header makes no conflict",
           "\(SpyWindow.conflicts - before) reported")
}

private func testSettingsRowCaption() {
    let row = SettingsRow(title: "Row limit", caption: nil, control: NSButton(checkboxWithTitle: "", target: nil, action: nil))
    let w = hostWindow(holding: row)
    let before = SpyWindow.conflicts
    row.caption = "Rows to fetch before Load More."
    w.contentView?.layoutSubtreeIfNeeded()
    row.caption = nil
    w.contentView?.layoutSubtreeIfNeeded()
    expect(SpyWindow.conflicts == before, "settings row: adding and removing a caption makes no conflict",
           "\(SpyWindow.conflicts - before) reported")
}

func runTests() {
    UserDefaults.standard.set(true, forKey: "NSConstraintBasedLayoutVisualizeMutuallyExclusiveConstraints")
    testTheDetectorSeesTheOldOrder()
    testSwap()
    testVariableListHeader()
    testSettingsRowCaption()
    if failures == 0 { print("\nAll constraint swap tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
