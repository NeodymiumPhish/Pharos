import SwiftUI

/// Owns the live ChartConfig, recomputes ChartData, and reports config changes.
final class ChartViewModel: ObservableObject {
    @Published var config: ChartConfig
    @Published private(set) var data: ChartData = ChartData()

    // MARK: Server-aggregation (push-down) state
    /// A server-aggregation query is in flight for this chart.
    @Published var serverLoading = false
    /// The DB error text from the last failed server-aggregation run, if any.
    @Published var serverError: String?
    /// Whether push-down is available for the current config (chart type +
    /// wrappable SQL + resolvable mappings). Computed by the VC and pushed in.
    @Published var pushdownAvailable = false
    /// Whether a server-aggregation run has completed this session — distinguishes
    /// the reopen "Run…" state (false) from the "aggregated as of …" state (true).
    @Published var serverHasRun = false
    /// Human explanation shown when the toggle is disabled (push-down unavailable).
    var pushdownUnavailableReason: String?

    let columns: [ColumnDef]
    private let result: QueryResult
    /// Called (debounced by the host) whenever config changes, for persistence.
    var onConfigChanged: ((ChartConfig) -> Void)?
    /// Called when the chart's staged selection changes (post-merge keys; `[]`
    /// clears). The VC commits it when the action-bar button is pressed.
    var onSelectionChanged: (([DrillKey]) -> Void)?
    /// The committed chart filter's keys, pushed down so marks can light up.
    @Published var committedKeys: [DrillKey] = []
    /// Bumped by the VC to clear the chart's staged selection (post-commit / Esc).
    @Published var clearToken: Int = 0

    /// Stable identity of the current config; when it changes the chart drops its
    /// staged selection (marks no longer refer to the same data).
    var configFingerprint: String {
        let m = config.mappings.map { "\($0.key.rawValue):\($0.value.index)" }.sorted().joined(separator: ",")
        let ab = config.axisBins.map { "\($0.key.rawValue):\($0.value.temporal.rawValue)/\($0.value.numeric.rawValue)" }.sorted().joined(separator: ",")
        return "\(config.chartType.rawValue)|\(m)|\(config.temporalBin.rawValue)|\(config.numericBin.rawValue)|\(ab)"
    }

    init(result: QueryResult, columns: [ColumnDef], initialConfig: ChartConfig?) {
        self.result = result
        self.columns = columns
        self.config = initialConfig ?? ChartConfig.infer(from: columns)
        recompute()
    }

    /// Whether the chart type can use server mode: aggregating types, plus
    /// scatter (a deterministic sample). Gantt never pushes down.
    var chartTypeSupportsServer: Bool {
        config.chartType != .gantt
    }

    func recompute() {
        // A restored result whose cached rows were demoted arrives with no
        // columns; surface the "re-run to chart" state rather than "pick columns".
        if columns.isEmpty { data = .empty(.noData); return }
        // In server-aggregation mode the VC supplies `data` via setServerData;
        // don't clobber it with a client-side aggregation of the loaded rows.
        // Only skip for chart types that support server mode — gantt falls back
        // to the client render even if the flag is on (it can't push down).
        if config.serverAggregation && chartTypeSupportsServer { return }
        data = ChartAggregator.aggregate(result, config)
    }

    /// Inject server-aggregated data (built by `ServerChartDataBuilder`), clearing
    /// the loading/error state and marking that a run completed this session.
    func setServerData(_ d: ChartData) {
        data = d
        serverLoading = false
        serverError = nil
        serverHasRun = true
    }

    func update(_ mutate: (inout ChartConfig) -> Void) {
        mutate(&config)
        recompute()
        onConfigChanged?(config)
    }

    func kind(_ ref: ColumnRef?) -> ColumnKind? {
        guard let ref, ref.index < columns.count else { return nil }
        return ColumnClassifier.kind(forDataType: columns[ref.index].dataType)
    }

    /// Columns eligible for a role, by kind.
    func eligible(for role: ChartColumnRole, chartType: ChartType) -> [ColumnRef] {
        let refs = columns.enumerated().map { ColumnRef(index: $0.offset, name: $0.element.name) }
        if chartType == .heatmap, role == .x || role == .y { return refs }   // any kind
        switch role {
        case .value, .y, .x, .size, .start, .end:
            return refs.filter { r in
                let k = ColumnClassifier.kind(forDataType: columns[r.index].dataType)
                return k == .numeric || (role == .start || role == .end || role == .x ? k == .temporal : false)
            }
        default:
            return refs   // category/series/label/color accept anything
        }
    }
}

struct ChartRootView: View {
    @ObservedObject var model: ChartViewModel
    /// Banner info supplied by the host (loaded/total counts + load-all action).
    let bannerInfo: ChartBannerInfo
    let onLoadAll: () -> Void
    /// Put the current generated push-down SQL on the pasteboard (host-owned).
    var onCopySQL: () -> Void = {}
    /// Explicitly run a server aggregation (the reopen affordance).
    var onRunServerAggregation: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            // Server-aggregation banner takes precedence over the client subset
            // banner when the toggle is on (they describe different data paths).
            // Gate on chartTypeSupportsServer too: gantt renders client-side even
            // with the flag on, so no server banner for it.
            if model.config.serverAggregation && model.chartTypeSupportsServer { serverBanner }
            else if bannerInfo.shouldShow { banner }
            HStack(spacing: 0) {
                ChartCanvas(data: model.data, config: model.config,
                            onSelectionChanged: { keys in model.onSelectionChanged?(keys) },
                            committedKeys: model.committedKeys,
                            clearToken: model.clearToken,
                            configFingerprint: model.configFingerprint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                configRail.frame(width: 160)
            }
        }
    }

    private var banner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(bannerInfo.text)
            Spacer()
            if bannerInfo.canLoadAll { Button("Load all rows", action: onLoadAll).buttonStyle(.link) }
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Color.orange.opacity(0.15))
    }

    // MARK: Server-aggregation banner
    // On-screen provenance for push-down mode: a live "Running…" spinner, the DB
    // error, an "aggregated as of <t>" summary once a run completes, or (on
    // reopen, before any run) an explicit "Run server aggregation" button so a
    // reopened workspace never silently re-hits the DB.
    @ViewBuilder private var serverBanner: some View {
        HStack(spacing: 8) {
            if model.serverLoading {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                Text("Running server aggregation\u{2026}")
                Spacer()
            } else if let err = model.serverError {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(err).lineLimit(2)
                Spacer()
            } else if model.serverHasRun {
                Image(systemName: "server.rack")
                Text(ranSummary)
                Spacer()
            } else {
                Image(systemName: "server.rack")
                Text("Server aggregation is on.")
                Spacer()
                Button(runButtonTitle, action: onRunServerAggregation).buttonStyle(.link)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background((model.serverError != nil ? Color.red : Color.blue).opacity(0.12))
    }

    private var ranSummary: String {
        let asOf = model.config.lastServerRun.map { shortTime($0.executedAt) } ?? ""
        var s = "Aggregated server-side over the full dataset"
        if !asOf.isEmpty { s += ", as of \(asOf)" }
        if model.config.lastServerRun?.truncated == true { s += " \u{00B7} truncated" }
        if model.config.lastServerRun?.sampled == true { s += " \u{00B7} sampled" }
        return s
    }

    private var runButtonTitle: String {
        if let last = model.config.lastServerRun {
            return "Run server aggregation (last run \(shortTime(last.executedAt)))"
        }
        return "Run server aggregation"
    }

    /// Render an ISO-8601 timestamp as a compact local "yyyy-MM-dd HH:mm", or the
    /// raw string if it doesn't parse.
    private func shortTime(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        guard let d = parser.date(from: iso) else { return iso }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.dateFormat = "yyyy-MM-dd HH:mm"
        return out.string(from: d)
    }

    private var configRail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                railLabel("Chart type")
                Picker("", selection: Binding(get: { model.config.chartType },
                                              set: { t in model.update { $0.chartType = t } })) {
                    ForEach(ChartType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }.labelsHidden()

                ForEach(rolesForCurrentType(), id: \.self) { role in
                    railLabel(roleLabel(role))
                    rolePicker(role)
                }

                if usesAggregation {
                    railLabel("Aggregate")
                    Picker("", selection: Binding(get: { model.config.aggregation },
                                                  set: { a in model.update { $0.aggregation = a } })) {
                        ForEach(AggregationFn.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }.labelsHidden()
                }

                if model.config.chartType == .heatmap {
                    axisBinControls(.x, "X")
                    axisBinControls(.y, "Y")
                } else {
                    if showTimeBucket {
                        railLabel("Time bucket")
                        Picker("", selection: Binding(get: { model.config.temporalBin },
                                                      set: { b in model.update { $0.temporalBin = b } })) {
                            ForEach(TemporalBin.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                        }.labelsHidden()
                    }
                    if showNumericBins {
                        railLabel("Bins")
                        Picker("", selection: Binding(get: { model.config.numericBin },
                                                      set: { b in model.update { $0.numericBin = b } })) {
                            ForEach(NumericBin.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }.labelsHidden()
                    }
                }

                if usesAggregation { serverAggregationSection }

                Spacer()
            }.padding(10)
        }
    }

    // MARK: server-aggregation rail section
    @ViewBuilder private var serverAggregationSection: some View {
        railLabel("Server aggregation")
        if model.pushdownAvailable {
            Toggle("Aggregate on server", isOn: Binding(
                get: { model.config.serverAggregation },
                set: { on in model.update { $0.serverAggregation = on } }))
                .toggleStyle(.checkbox)
                .font(.caption)
            Button("Copy Generated SQL", action: onCopySQL)
                .buttonStyle(.link)
                .font(.caption)
        } else {
            Toggle("Aggregate on server", isOn: .constant(false))
                .toggleStyle(.checkbox)
                .font(.caption)
                .disabled(true)
            if let reason = model.pushdownUnavailableReason {
                Text(reason)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: role helpers
    private func rolesForCurrentType() -> [ChartColumnRole] {
        switch model.config.chartType {
        case .bar, .line, .area, .pie: return [.category, .value, .series]
        case .scatter: return [.x, .y, .size, .color]
        case .gantt: return [.label, .start, .end, .color]
        case .heatmap: return [.x, .y, .value]
        }
    }
    private var usesAggregation: Bool {
        switch model.config.chartType { case .scatter, .gantt: return false; default: return true }
    }
    // Show the Time Bucket control when the axis is date-based: the mapped
    // category for categorical charts, or the Start column for gantt.
    private var showTimeBucket: Bool {
        if model.config.chartType == .gantt {
            return model.kind(model.config.mappings[.start]) == .temporal
        }
        return model.kind(model.config.mappings[.category]) == .temporal
    }
    // Show the numeric Bins control when the axis is numeric: the mapped
    // category for categorical charts, or the X column for heatmap.
    // Mutually exclusive with showTimeBucket (gated on .temporal).
    private var showNumericBins: Bool {
        let ref = model.config.chartType == .heatmap ? model.config.mappings[.x] : model.config.mappings[.category]
        return model.kind(ref) == .numeric
    }
    private func roleLabel(_ r: ChartColumnRole) -> String {
        if model.config.chartType == .heatmap {
            switch r {
            case .x: return "X (columns)"; case .y: return "Y (rows)"; case .value: return "Value (color, optional)"
            default: break
            }
        }
        switch r {
        case .category: return "Category (X)"; case .value: return "Value (Y)"; case .series: return "Series (optional)"
        case .x: return "X"; case .y: return "Y"; case .size: return "Size (optional)"; case .color: return "Color (optional)"
        case .label: return "Label"; case .start: return "Start"; case .end: return "End"
        }
    }
    private func rolePicker(_ role: ChartColumnRole) -> some View {
        let options = model.eligible(for: role, chartType: model.config.chartType)
        return Picker("", selection: Binding(
            get: { model.config.mappings[role]?.index ?? -1 },
            set: { idx in model.update { cfg in
                if idx < 0 { cfg.mappings[role] = nil }
                else { cfg.mappings[role] = ColumnRef(index: idx, name: model.columns[idx].name) }
            } })) {
            Text("—").tag(-1)
            ForEach(options, id: \.index) { Text($0.name).tag($0.index) }
        }.labelsHidden()
    }
    private func railLabel(_ s: String) -> some View {
        Text(s.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
    }

    // For heatmap, the bin control for a given axis role, keyed on the mapped
    // column's kind, writing to config.axisBins[role].
    @ViewBuilder private func axisBinControls(_ role: ChartColumnRole, _ title: String) -> some View {
        let k = model.kind(model.config.mappings[role])
        if k == .temporal {
            railLabel("\(title) time bucket")
            Picker("", selection: Binding(
                get: { model.config.resolvedBin(for: role).temporal },
                set: { b in model.update { var ab = $0.axisBins[role] ?? AxisBin(temporal: $0.temporalBin, numeric: $0.numericBin); ab.temporal = b; $0.axisBins[role] = ab } })) {
                ForEach(TemporalBin.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }.labelsHidden()
        } else if k == .numeric {
            railLabel("\(title) bins")
            Picker("", selection: Binding(
                get: { model.config.resolvedBin(for: role).numeric },
                set: { b in model.update { var ab = $0.axisBins[role] ?? AxisBin(temporal: $0.temporalBin, numeric: $0.numericBin); ab.numeric = b; $0.axisBins[role] = ab } })) {
                ForEach(NumericBin.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }.labelsHidden()
        }
    }
}

struct ChartBannerInfo {
    var shouldShow: Bool
    var canLoadAll: Bool
    var text: String
}
