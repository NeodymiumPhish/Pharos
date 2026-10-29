import SwiftUI

/// Where the rail's Suggest section is: idle, asking, answered (with the words
/// to show under the label), or failed (with one sentence and Retry).
enum ChartSuggestionState: Equatable {
    case idle
    case working
    case answered(reason: String, promptHash: String?, fromModel: Bool)
    case failed(String)
}

/// Owns the live ChartConfig, recomputes ChartData, and reports config changes.
final class ChartViewModel: ObservableObject {
    @Published var config: ChartConfig
    @Published private(set) var data: ChartData = ChartData()
    /// `config` with every `.auto` time bucket resolved from the data's span —
    /// what the aggregator, the generator and the canvas actually use. The
    /// stored `config` keeps `.auto` because that is what the user chose.
    @Published private(set) var resolvedConfig: ChartConfig

    // MARK: Suggestions
    /// One profile per column: kinds (refined from the values), cardinality,
    /// shape. The rail's pickers, the recommender and the model prompt all read
    /// these, so a text column of numbers is a measure everywhere at once.
    let profiles: [ColumnProfile]
    /// The deterministic recommender's ranked list for this result.
    let recommendations: [ChartRecommendation]
    var rowCount: Int { result.rows.count }
    @Published var suggestionState: ChartSuggestionState = .idle
    /// Ask the on-device model (host-owned; the rail calls it only when the
    /// model may be used).
    var onSuggest: (() -> Void)?
    var onCancelSuggest: (() -> Void)?

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
    /// The rows the chart plots: the result, narrowed to the grid's filters.
    private var result: QueryResult
    /// The banner above the chart (loaded/filtered counts + load-all).
    @Published var banner = ChartBannerInfo(shouldShow: false, canLoadAll: false, text: "")
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
            + config.extraColumns.map { "\($0.key.rawValue)+\($0.value.map { String($0.index) }.joined(separator: "+"))" }.sorted().joined(separator: ",")
        let ab = config.axisBins.map { "\($0.key.rawValue):\($0.value.temporal.rawValue)/\($0.value.numeric.rawValue)" }.sorted().joined(separator: ",")
        return "\(config.chartType.rawValue)|\(m)|\(config.temporalBin.rawValue)|\(config.numericBin.rawValue)|\(ab)|\(config.ganttMerge.rawValue)"
    }

    init(result: QueryResult, columns: [ColumnDef], initialConfig: ChartConfig?) {
        self.result = result
        self.columns = columns
        self.profiles = ColumnProfiler.profile(result)
        self.recommendations = ChartRecommender.recommend(profiles: profiles, columns: columns)
        // First open: the recommender's top pick, never the model (a press asks it).
        let initial = initialConfig ?? recommendations.first?.config ?? ChartConfig.infer(from: columns)
        self.config = initial
        self.resolvedConfig = initial.resolvingAutoBins(for: result)
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
        resolvedConfig = config.resolvingAutoBins(for: result)
        if config.serverAggregation && chartTypeSupportsServer { return }
        data = ChartSorter.sorted(ChartAggregator.aggregate(result, resolvedConfig),
                                  by: config.display.sort, chartType: config.chartType)
    }

    /// Plot a new set of rows (the grid's filters changed). Column kinds,
    /// recommendations and the config stay as they were for the full result.
    func setRows(_ result: QueryResult, banner: ChartBannerInfo) {
        self.result = result
        self.banner = banner
        recompute()
    }

    /// Inject server-aggregated data (built by `ServerChartDataBuilder`), clearing
    /// the loading/error state and marking that a run completed this session.
    func setServerData(_ d: ChartData) {
        data = ChartSorter.sorted(d, by: config.display.sort, chartType: config.chartType)
        serverLoading = false
        serverError = nil
        serverHasRun = true
    }

    func update(_ mutate: (inout ChartConfig) -> Void) {
        mutate(&config)
        recompute()
        onConfigChanged?(config)
    }

    /// A display-only edit (title, legend, layout, scale, axis titles): no
    /// re-aggregation, so a keystroke in a title field does not walk the rows.
    /// Sort lives in `display` too and DOES reorder, so it recomputes.
    func updateDisplay(_ mutate: (inout ChartDisplayOptions) -> Void) {
        let before = config.display.sort
        mutate(&config.display)
        resolvedConfig.display = config.display
        if config.display.sort != before { recompute() }
        onConfigChanged?(config)
    }

    /// Apply a suggested config. What the user set about the chart's
    /// surroundings survives — server mode and the legend switch — and a
    /// colour override does not, because the colour domain has changed.
    func apply(config new: ChartConfig, state: ChartSuggestionState) {
        update { cfg in
            var next = new
            next.serverAggregation = cfg.serverAggregation
            next.display.showLegend = cfg.display.showLegend
            next.seriesColors = []
            cfg = next
        }
        suggestionState = state
    }

    func applyRecommendation(_ rec: ChartRecommendation) {
        apply(config: rec.config, state: .answered(reason: rec.reason, promptHash: nil, fromModel: false))
    }

    /// The column's kind as the values show it (a text column of numbers is
    /// numeric here), so the pickers offer what the recommender may map.
    func kind(_ ref: ColumnRef?) -> ColumnKind? {
        guard let ref, ref.index < profiles.count else { return nil }
        return profiles[ref.index].kind
    }

    /// Columns eligible for a role, by kind (one table: `ChartRoleEligibility`).
    func eligible(for role: ChartColumnRole, chartType: ChartType) -> [ColumnRef] {
        profiles.filter { ChartRoleEligibility.accepts(role, kind: $0.kind, chartType: chartType) }
            .map { ColumnRef(index: $0.index, name: $0.name) }
    }
}

struct ChartRootView: View {
    @ObservedObject var model: ChartViewModel
    let onLoadAll: () -> Void
    /// Put the current generated push-down SQL on the pasteboard (host-owned).
    var onCopySQL: () -> Void = {}
    /// Explicitly run a server aggregation (the reopen affordance).
    var onRunServerAggregation: () -> Void = {}

    /// Observe the global chart palette so charts recolor live when it changes
    /// in Settings.
    @ObservedObject private var appState = AppStateManager.shared
    private var globalPalette: [String] { appState.settings.charts.palette }
    /// Whether "Suggest chart" may ask the on-device model. Read from the view,
    /// never re-read inside a sink (tasks/lessons.md, @Published willSet).
    @ObservedObject private var availability = ModelAvailability.shared
    /// The composed answer for THIS feature: the model is offered here and the
    /// user has not cleared "Suggest charts" in Settings ▸ Intelligence.
    private var canAskTheModel: Bool { availability.isAvailable(for: .suggestCharts) }

    /// The rail's width: drag its leading edge; double-click the edge for the default.
    /// One value for every chart, kept across launches.
    @AppStorage("chartRailWidth") private var railWidth: Double = ChartRootView.defaultRailWidth
    @State private var railDragStartWidth: Double?
    static let defaultRailWidth: Double = 160
    static let railWidthRange: ClosedRange<Double> = 160...420

    var body: some View {
        VStack(spacing: 0) {
            // Server-aggregation banner takes precedence over the client subset
            // banner when the toggle is on (they describe different data paths).
            // Gate on chartTypeSupportsServer too: gantt renders client-side even
            // with the flag on, so no server banner for it.
            if model.config.serverAggregation && model.chartTypeSupportsServer { serverBanner }
            else if model.banner.shouldShow { banner }
            HStack(spacing: 0) {
                ChartCanvas(data: model.data, config: model.resolvedConfig,
                            onSelectionChanged: { keys in model.onSelectionChanged?(keys) },
                            committedKeys: model.committedKeys,
                            clearToken: model.clearToken,
                            configFingerprint: model.configFingerprint,
                            globalPalette: globalPalette)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                railDivider
                configRail.frame(width: Self.clampedRailWidth(railWidth))
            }
        }
    }

    /// A divider in a 7 pt grab column (the column itself takes the drag, so
    /// the canvas and rail beside it cannot). Dragging left widens the rail.
    private var railDivider: some View {
        Divider()
            .frame(width: 7)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    let start = railDragStartWidth ?? railWidth
                    railDragStartWidth = start
                    railWidth = Self.clampedRailWidth(start - v.translation.width)
                }
                .onEnded { _ in railDragStartWidth = nil })
            .onTapGesture(count: 2) { railWidth = Self.defaultRailWidth }
            .accessibilityElement()
            .accessibilityLabel("Chart Settings Width")
            .accessibilityValue("\(Int(railWidth)) points")
            .accessibilityAdjustableAction { direction in
                railWidth = Self.clampedRailWidth(railWidth + (direction == .increment ? 20 : -20))
            }
    }

    static func clampedRailWidth(_ w: Double) -> Double {
        min(max(w, railWidthRange.lowerBound), railWidthRange.upperBound)
    }

    private var banner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(model.banner.text)
            Spacer()
            if model.banner.canLoadAll { Button("Load all rows", action: onLoadAll).buttonStyle(.link) }
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

    /// Render an ISO-8601 timestamp as a compact local date + time, or the raw
    /// string if it doesn't parse. Display only — the axis still sorts and
    /// parses from the ISO8601 source; this only changes the label text, which
    /// used to be a fixed "yyyy-MM-dd HH:mm" regardless of the viewer's locale.
    private func shortTime(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        guard let d = parser.date(from: iso) else { return iso }
        let style = Date.FormatStyle(locale: .autoupdatingCurrent)
            .year().month(.twoDigits).day(.twoDigits).hour().minute()
        return d.formatted(style)
    }

    private var configRail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                suggestSection

                railLabel("Chart type")
                Picker("", selection: Binding(get: { model.config.chartType },
                                              set: { t in model.update { $0.chartType = t } })) {
                    ForEach(ChartType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }.labelsHidden()

                ForEach(rolesForCurrentType(), id: \.self) { role in
                    railLabel(roleLabel(role))
                    if ChartRoleEligibility.takesManyColumns(role) { multiColumnPicker(role) } else { rolePicker(role) }
                }

                if model.config.chartType == .gantt { ganttSection }

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

                if showSort {
                    railLabel("Sort")
                    Picker("", selection: Binding(get: { model.config.display.sort },
                                                  set: { s in model.update { $0.display.sort = s } })) {
                        ForEach(ChartSort.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }.labelsHidden()
                }

                displaySection

                colorSection

                if usesAggregation { serverAggregationSection }

                Spacer()
            }.padding(10)
        }
    }

    // MARK: suggest rail section
    // One button. With the model available it asks the model (the recommender's
    // candidates ride along in the prompt); without it, it applies the top
    // candidate. "More layouts" lists every candidate either way.
    @ViewBuilder private var suggestSection: some View {
        railLabel("Suggest")
        let working = model.suggestionState == .working
        let canSuggest = !model.recommendations.isEmpty
        HStack(spacing: 6) {
            Button {
                if canAskTheModel { model.onSuggest?() }
                else if let top = model.recommendations.first { model.applyRecommendation(top) }
            } label: {
                Label("Suggest chart", systemImage: canAskTheModel ? "sparkles" : "wand.and.stars")
                    .font(.caption)
            }
            .disabled(working || !canSuggest)
            .help(canAskTheModel
                  ? "Ask the on-device model which chart fits this result."
                  : "Apply the chart Pharos recommends for these columns.")
            .accessibilityIdentifier("chart.suggest")
            if working { ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14) }
        }
        switch model.suggestionState {
        case .idle:
            EmptyView()
        case .working:
            HStack(spacing: 6) {
                Text("Asking the on-device model\u{2026}").font(.caption).foregroundStyle(.secondary)
                Button("Cancel") { model.onCancelSuggest?() }.buttonStyle(.link).font(.caption)
            }
        case .answered(let reason, let promptHash, let fromModel):
            if fromModel {
                GeneratedContentLabelView(feature: "suggest-chart", promptHash: promptHash)
                    .frame(height: 22)
            }
            if !reason.isEmpty {
                Text(reason)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("chart.suggest.reason")
            }
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Button("Retry") { model.onSuggest?() }.buttonStyle(.link).font(.caption)
        }
        if model.recommendations.count > 1 {
            Menu {
                ForEach(Array(model.recommendations.enumerated()), id: \.offset) { _, rec in
                    Button(rec.title) { model.applyRecommendation(rec) }
                }
            } label: {
                Text("More layouts").font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("chart.suggest.more")
        }
    }

    // MARK: display rail section
    @ViewBuilder private var displaySection: some View {
        railLabel("Display")
        let type = model.config.chartType
        if type != .scatter && (type != .gantt || model.config.mappings[.segment] != nil) {
            Toggle("Legend", isOn: Binding(
                get: { model.config.display.showLegend },
                set: { on in model.updateDisplay { $0.showLegend = on } }))
                .toggleStyle(.checkbox).font(.caption)
        }
        if type == .bar, model.config.mappings[.series] != nil {
            Picker("", selection: Binding(get: { model.config.display.barLayout },
                                          set: { l in model.updateDisplay { $0.barLayout = l } })) {
                ForEach(BarLayout.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().controlSize(.small)
        }
        if type == .bar || type == .line || type == .area || type == .scatter {
            let canLog = ChartCanvas.canUseLogScale(model.data, chartType: type)
            Toggle("Log scale", isOn: Binding(
                get: { model.config.display.logScale && canLog },
                set: { on in model.updateDisplay { $0.logScale = on } }))
                .toggleStyle(.checkbox).font(.caption)
                .disabled(!canLog)
                .help(canLog ? "Plot the Y axis on a logarithmic scale." : "A log scale needs every value above zero.")
        }
        TextField("Title", text: Binding(
            get: { model.config.display.title },
            set: { t in model.updateDisplay { $0.title = t } }))
            .textFieldStyle(.roundedBorder).font(.caption)
            .accessibilityIdentifier("chart.display.title")
        if type != .pie && type != .gantt {
            let derived = ChartAxisTitles.derive(model.config)
            TextField(derived.x.isEmpty ? "X axis title" : derived.x, text: Binding(
                get: { model.config.display.xAxisTitle },
                set: { t in model.updateDisplay { $0.xAxisTitle = t } }))
                .textFieldStyle(.roundedBorder).font(.caption)
                .accessibilityIdentifier("chart.display.xAxisTitle")
            TextField(derived.y.isEmpty ? "Y axis title" : derived.y, text: Binding(
                get: { model.config.display.yAxisTitle },
                set: { t in model.updateDisplay { $0.yAxisTitle = t } }))
                .textFieldStyle(.roundedBorder).font(.caption)
                .accessibilityIdentifier("chart.display.yAxisTitle")
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

    // MARK: colors rail section

    /// The color-domain labels for the current chart type (one control each).
    /// Empty for gantt/heatmap, which don't use the categorical palette.
    private var colorDomainLabels: [String] {
        model.data.colorDomainLabels(for: model.config.chartType)
    }

    @ViewBuilder private var colorSection: some View {
        let labels = colorDomainLabels
        if !labels.isEmpty {
            railLabel("Colors")
            // A gantt can have hundreds of segment values: wells for the Top N only.
            let shown = model.config.chartType == .gantt ? Array(labels.prefix(max(model.config.display.topNCategories, 1))) : labels
            ForEach(Array(shown.enumerated()), id: \.offset) { idx, label in
                HStack(spacing: 6) {
                    ColorPicker("", selection: seriesColorBinding(index: idx, domainCount: labels.count), supportsOpacity: false)
                        .labelsHidden()
                    Text(label).font(.caption).lineLimit(1).truncationMode(.tail)
                        .help(label)
                    Spacer()
                }
            }
            if !model.config.seriesColors.isEmpty {
                Button("Reset to palette") { model.update { $0.seriesColors = [] } }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }

    /// A binding for the color well at `index`. Reads the currently-effective
    /// color; writing seeds the override with the full effective palette first
    /// (so untouched wells keep their color) then updates just `index`.
    private func seriesColorBinding(index: Int, domainCount: Int) -> Binding<Color> {
        let palette = globalPalette
        return Binding(
            get: {
                let hexes = ChartPalette.resolveHex(override: model.config.seriesColors, global: palette, count: domainCount)
                return ChartPalette.color(fromHex: hexes[index])
            },
            set: { newColor in
                model.update { cfg in
                    var colors = cfg.seriesColors
                    if colors.count < domainCount {
                        colors = ChartPalette.resolveHex(override: cfg.seriesColors, global: palette, count: domainCount)
                    }
                    if index < colors.count { colors[index] = ChartPalette.hex(from: newColor) }
                    cfg.seriesColors = colors
                }
            }
        )
    }

    // MARK: role helpers
    private func rolesForCurrentType() -> [ChartColumnRole] {
        ChartRoleEligibility.roles(for: model.config.chartType)
    }
    private var usesAggregation: Bool {
        ChartRoleEligibility.usesAggregation(model.config.chartType)
    }
    // Sort applies only to categorical charts (bar/line/area/pie); scatter and
    // numeric axes auto-sort by value, and gantt/heatmap aren't categorical.
    private var showSort: Bool {
        switch model.config.chartType {
        case .bar, .line, .area, .pie: return true
        default: return false
        }
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
        case .x: return "X"; case .y: return "Y"; case .size: return "Size (optional)"
        case .label: return "Label"; case .start: return "Start"; case .end: return "End"
        case .segment: return "Bars by (optional)"
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
    /// A role that takes several columns (gantt Label, Bars by): one picker per
    /// mapped column, "—" removes that column, and "Add Column" appends one. The
    /// values of every column together make the lane / bar key.
    @ViewBuilder private func multiColumnPicker(_ role: ChartColumnRole) -> some View {
        let options = model.eligible(for: role, chartType: model.config.chartType)
        let mapped = model.config.columns(for: role)
        ForEach(Array(mapped.enumerated()), id: \.offset) { pos, _ in
            Picker("", selection: Binding(
                get: { let refs = model.config.columns(for: role); return pos < refs.count ? refs[pos].index : -1 },
                set: { idx in model.update { cfg in
                    var refs = cfg.columns(for: role)
                    guard pos < refs.count else { return }
                    if idx < 0 { refs.remove(at: pos) }
                    else { refs[pos] = ColumnRef(index: idx, name: model.columns[idx].name) }
                    cfg.setColumns(refs, for: role)
                } })) {
                Text("—").tag(-1)
                ForEach(options, id: \.index) { Text($0.name).tag($0.index) }
            }.labelsHidden()
        }
        let unused = options.filter { o in !mapped.contains { $0.index == o.index } }
        if mapped.isEmpty {
            // Nothing mapped yet: one empty picker, like a single-column role.
            rolePicker(role)
        } else if !unused.isEmpty {
            Menu {
                ForEach(unused, id: \.index) { ref in
                    Button(ref.name) { model.update { $0.setColumns($0.columns(for: role) + [ref], for: role) } }
                }
            } label: {
                Label("Add Column", systemImage: "plus")
            }
            .menuStyle(.borderlessButton).font(.caption).fixedSize()
            .accessibilityIdentifier("chart.\(role.rawValue).addColumn")
        }
    }

    /// Gantt-only controls: how rows become bars, and the horizontal zoom.
    @ViewBuilder private var ganttSection: some View {
        railLabel("Merge rows")
        Picker("", selection: Binding(get: { model.config.ganttMerge },
                                      set: { m in model.update { $0.ganttMerge = m } })) {
            ForEach(GanttMerge.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().controlSize(.small)
        .help("Runs: a new bar each time the Bars by value changes, in Start order. Span: one bar per value, from its first Start to its last End.")

        railLabel("Zoom")
        let zoom = model.config.display.ganttZoom
        // Two rows so every label stays legible at the narrowest rail width.
        HStack(spacing: 4) {
            Button { model.updateDisplay { $0.ganttZoom = Self.zoomStep(zoom, out: true) } } label: { Image(systemName: "minus.magnifyingglass") }
                .disabled(zoom == 0)
                .help("Zoom out")
                .accessibilityLabel("Zoom Out")
            Button { model.updateDisplay { $0.ganttZoom = Self.zoomStep(zoom, out: false) } } label: { Image(systemName: "plus.magnifyingglass") }
                .disabled(zoom >= Self.maxGanttZoom)
                .help("Zoom in")
                .accessibilityLabel("Zoom In")
        }
        .controlSize(.small)
        HStack(spacing: 4) {
            Button("Fit") { model.updateDisplay { $0.ganttZoom = 0 } }
                .disabled(zoom == 0)
                .help("Show the whole time range in the pane")
            Button("Auto Width") { model.updateDisplay { $0.ganttZoom = 1 } }
                .disabled(zoom == 1)
                .help("Give each Time Bucket unit a fixed width, and scroll when the range is wider than the pane")
        }
        .controlSize(.small)
    }

    static let maxGanttZoom: Double = 64
    /// Halve or double the zoom; zooming out past 1/64 is Fit, zooming in from Fit is Auto.
    static func zoomStep(_ zoom: Double, out: Bool) -> Double {
        if zoom == 0 { return out ? 0 : 1 }
        let next = out ? zoom / 2 : zoom * 2
        return out && next < 1.0 / 64 ? 0 : min(next, maxGanttZoom)
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
