import SwiftUI

/// Owns the live ChartConfig, recomputes ChartData, and reports config changes.
final class ChartViewModel: ObservableObject {
    @Published var config: ChartConfig
    @Published private(set) var data: ChartData = ChartData()

    let columns: [ColumnDef]
    private let result: QueryResult
    /// Called (debounced by the host) whenever config changes, for persistence.
    var onConfigChanged: ((ChartConfig) -> Void)?

    init(result: QueryResult, columns: [ColumnDef], initialConfig: ChartConfig?) {
        self.result = result
        self.columns = columns
        self.config = initialConfig ?? ChartConfig.infer(from: columns)
        recompute()
    }

    func recompute() {
        // A restored result whose cached rows were demoted arrives with no
        // columns; surface the "re-run to chart" state rather than "pick columns".
        if columns.isEmpty { data = .empty(.noData); return }
        data = ChartAggregator.aggregate(result, config)
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
    func eligible(for role: ChartColumnRole) -> [ColumnRef] {
        let refs = columns.enumerated().map { ColumnRef(index: $0.offset, name: $0.element.name) }
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

    var body: some View {
        VStack(spacing: 0) {
            if bannerInfo.shouldShow { banner }
            HStack(spacing: 0) {
                ChartCanvas(data: model.data, chartType: model.config.chartType,
                            temporalBin: model.config.temporalBin)
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

                if showTimeBucket {
                    railLabel("Time bucket")
                    Picker("", selection: Binding(get: { model.config.temporalBin },
                                                  set: { b in model.update { $0.temporalBin = b } })) {
                        ForEach(TemporalBin.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }.labelsHidden()
                }
                Spacer()
            }.padding(10)
        }
    }

    // MARK: role helpers
    private func rolesForCurrentType() -> [ChartColumnRole] {
        switch model.config.chartType {
        case .bar, .line, .area, .pie: return [.category, .value, .series]
        case .scatter: return [.x, .y, .size, .color]
        case .gantt: return [.label, .start, .end, .color]
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
    private func roleLabel(_ r: ChartColumnRole) -> String {
        switch r {
        case .category: return "Category (X)"; case .value: return "Value (Y)"; case .series: return "Series (optional)"
        case .x: return "X"; case .y: return "Y"; case .size: return "Size (optional)"; case .color: return "Color (optional)"
        case .label: return "Label"; case .start: return "Start"; case .end: return "End"
        }
    }
    private func rolePicker(_ role: ChartColumnRole) -> some View {
        let options = model.eligible(for: role)
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
}

struct ChartBannerInfo {
    var shouldShow: Bool
    var canLoadAll: Bool
    var text: String
}
