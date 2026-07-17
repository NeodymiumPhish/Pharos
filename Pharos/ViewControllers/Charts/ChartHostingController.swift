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

    override func loadView() { view = NSView() }

    /// Configure (or reconfigure) for a result.
    func present(result: QueryResult, initialConfig: ChartConfig?, banner: ChartBannerInfo) {
        let vm = ChartViewModel(result: result, columns: result.columns, initialConfig: initialConfig)
        vm.onConfigChanged = { [weak self] cfg in self?.onConfigChanged?(cfg) }
        self.model = vm

        let root = ChartRootView(model: vm, bannerInfo: banner, onLoadAll: { [weak self] in self?.onLoadAll?() })
        let host = NSHostingController(rootView: AnyView(root))
        embed(host)
        self.hosting = host
    }

    /// The current config (for persistence on teardown/tab-switch).
    var currentConfig: ChartConfig? { model?.config }

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
