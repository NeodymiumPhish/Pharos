import AppKit
import SwiftUI

/// Hosts the SwiftUI chart in the AppKit result area. Owns the view model and
/// exposes an AppKit-facing API for the ContentViewController.
final class ChartHostingController: NSViewController {
    private var model: ChartViewModel?
    private var hosting: NSHostingController<AnyView>?

    /// Reports a config change (debounced by the caller) for persistence.
    var onConfigChanged: ((ChartConfig) -> Void)?
    /// Requests loading all remaining rows for the current result.
    var onLoadAll: (() -> Void)?
    /// Reports the chart's current staged selection (post-merge keys; `[]` clears).
    var onSelectionChanged: (([DrillKey]) -> Void)?
    /// Fired when a config change lands while server aggregation is on (a
    /// mapping/agg/bin tweak or the toggle flipping on) — the VC (re-)runs the
    /// debounced push-down query. Distinct from `onConfigChanged` (persistence),
    /// which fires for every change regardless of mode.
    var onServerConfigChanged: (() -> Void)?
    /// Put the current generated push-down SQL on the pasteboard (VC-owned).
    var onCopySQL: (() -> Void)?
    /// Explicitly run a server aggregation (the reopen "Run…" affordance).
    var onRunServerAggregation: (() -> Void)?

    override func loadView() { view = NSView() }

    /// Configure (or reconfigure) for a result.
    func present(result: QueryResult, initialConfig: ChartConfig?, banner: ChartBannerInfo) {
        let vm = ChartViewModel(result: result, columns: result.columns, initialConfig: initialConfig)
        vm.onConfigChanged = { [weak self] cfg in
            self?.onConfigChanged?(cfg)
            // A change while server mode is on triggers a (debounced) re-run.
            if cfg.serverAggregation { self?.onServerConfigChanged?() }
        }
        vm.onSelectionChanged = { [weak self] keys in self?.onSelectionChanged?(keys) }
        self.model = vm

        let root = ChartRootView(
            model: vm,
            bannerInfo: banner,
            onLoadAll: { [weak self] in self?.onLoadAll?() },
            onCopySQL: { [weak self] in self?.onCopySQL?() },
            onRunServerAggregation: { [weak self] in self?.onRunServerAggregation?() }
        )
        let host = NSHostingController(rootView: AnyView(root))
        embed(host)
        self.hosting = host
    }

    /// The current config (for persistence on teardown/tab-switch).
    var currentConfig: ChartConfig? { model?.config }

    // MARK: Staged-selection forwarding (VC-driven)

    /// Push the committed chart-filter keys down so marks can light up.
    func setCommittedKeys(_ keys: [DrillKey]) { model?.committedKeys = keys }
    /// Clear the chart's staged selection (post-commit / Esc).
    func clearSelection() { model?.clearToken += 1 }

    // MARK: Server-aggregation view-model forwarding (VC-driven)

    /// Toggle the in-flight spinner state in the banner.
    func setServerLoading(_ loading: Bool) { model?.serverLoading = loading }

    /// Show a DB error in the banner (also clears loading).
    func setServerError(_ message: String?) {
        model?.serverError = message
        model?.serverLoading = false
    }

    /// Push push-down availability + the disabled-reason into the view model so
    /// the rail can show/hide the toggle.
    func setPushdownAvailability(_ available: Bool, reason: String?) {
        model?.pushdownUnavailableReason = reason
        model?.pushdownAvailable = available
    }

    /// Inject a completed server-aggregation run: the built data plus its
    /// provenance (`lastServerRun`), updating the config so the banner reflects
    /// the as-of time without re-triggering a run.
    func applyServerRun(_ data: ChartData, lastRun: LastServerRun) {
        model?.config.lastServerRun = lastRun
        model?.setServerData(data)
    }

    /// Everything `ChartExporter` needs to render one export: the chart snapshot
    /// view (sized to the on-screen chart region) and a timestamp for the PNG's
    /// generic creation-time metadata. No caption/SQL provenance.
    struct ExportSnapshot {
        let view: AnyView
        let size: CGSize
        let timestamp: String
    }

    /// Builds an export snapshot for the chart currently on screen, or nil
    /// when there's nothing to export (no result presented yet, or the chart
    /// is in an empty state — no columns mapped / all-null value / demoted
    /// rows needing a re-run).
    func buildExportSnapshot() -> ExportSnapshot? {
        guard let model, model.data.emptyReason == nil else { return nil }
        let cfg = model.config
        let data = model.data
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let exportView = ChartExportView(
            data: data, config: cfg,
            globalPalette: AppStateManager.shared.settings.charts.palette
        )
        // Match the on-screen chart canvas size when available (the hosting view
        // includes the config rail, but that's a small, roughly-constant offset
        // — good enough for an export whose exact pixel dimensions aren't
        // load-bearing); fall back to a sensible default before layout.
        let onScreen = view.bounds.size
        var size = (onScreen.width > 200 && onScreen.height > 200) ? onScreen : CGSize(width: 900, height: 560)
        // Gantt exports render every row (non-scrolling), so size to the full
        // content height + padding rather than the on-screen viewport (which
        // would clip all but the visible rows).
        if cfg.chartType == .gantt {
            let width = max(onScreen.width, 900)
            size = CGSize(width: width, height: ChartCanvas.ganttContentHeight(rowCount: data.ganttBars.count) + 64)
        }
        return ExportSnapshot(view: AnyView(exportView), size: size, timestamp: timestamp)
    }

    private func embed(_ child: NSHostingController<AnyView>) {
        hosting?.view.removeFromSuperview()
        hosting?.removeFromParent()
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}
