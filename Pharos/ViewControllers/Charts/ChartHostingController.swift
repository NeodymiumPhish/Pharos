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
    /// Reports a drill request from a chart gesture (tap/brush/pie selection).
    var onDrill: (([DrillKey]) -> Void)?

    override func loadView() { view = NSView() }

    /// Configure (or reconfigure) for a result.
    func present(result: QueryResult, initialConfig: ChartConfig?, banner: ChartBannerInfo) {
        let vm = ChartViewModel(result: result, columns: result.columns, initialConfig: initialConfig)
        vm.onConfigChanged = { [weak self] cfg in self?.onConfigChanged?(cfg) }
        vm.onDrill = { [weak self] keys in self?.onDrill?(keys) }
        self.model = vm

        let root = ChartRootView(model: vm, bannerInfo: banner, onLoadAll: { [weak self] in self?.onLoadAll?() })
        let host = NSHostingController(rootView: AnyView(root))
        embed(host)
        self.hosting = host
    }

    /// The current config (for persistence on teardown/tab-switch).
    var currentConfig: ChartConfig? { model?.config }

    /// Everything `ChartExporter` needs to render + tag one export: a
    /// caption-annotated snapshot view (chart + provenance footer, sized to
    /// the on-screen chart region), the same caption text, and the
    /// generating context to embed as file metadata (the push-down SQL when
    /// server aggregation produced the current data, else nil).
    struct ExportSnapshot {
        let view: AnyView
        let size: CGSize
        let caption: String
        let sql: String?
        let timestamp: String
    }

    /// Builds an export snapshot for the chart currently on screen, or nil
    /// when there's nothing to export (no result presented yet, or the chart
    /// is in an empty state — no columns mapped / all-null value / demoted
    /// rows needing a re-run).
    func buildExportSnapshot(connectionName: String) -> ExportSnapshot? {
        guard let model, model.data.emptyReason == nil else { return nil }
        let cfg = model.config
        let data = model.data
        let mode = cfg.serverAggregation ? "Server" : "Client"
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let caption = ChartExportCaption.text(
            mode: mode,
            connection: connectionName,
            plotted: data.plottedRowCount,
            total: data.totalLoadedRowCount,
            truncated: data.wasTruncated,
            timestamp: timestamp
        )
        let exportView = ChartExportView(data: data, config: cfg, caption: caption)
        // Match the on-screen chart canvas size when available (the hosting
        // view includes the config rail, but that's a small, roughly-constant
        // offset — good enough for an export whose exact pixel dimensions
        // aren't load-bearing); fall back to a sensible default before layout.
        let onScreen = view.bounds.size
        let size = (onScreen.width > 200 && onScreen.height > 200) ? onScreen : CGSize(width: 900, height: 560)
        return ExportSnapshot(
            view: AnyView(exportView),
            size: size,
            caption: caption,
            sql: cfg.serverAggregation ? cfg.lastServerRun?.sql : nil,
            timestamp: timestamp
        )
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
