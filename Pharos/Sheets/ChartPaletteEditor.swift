import SwiftUI

/// Mutable working copy of the palette for the Settings Charts tab. Held by
/// `SettingsSheet`; its value is read back in `collectSettings()`.
final class ChartPaletteModel: ObservableObject {
    @Published var palette: [String]
    init(palette: [String]) { self.palette = palette }
}

/// SwiftUI palette editor hosted (via `NSHostingView`) in the Settings Charts
/// tab: one color well per slot, add/remove, and reset-to-defaults.
struct ChartPaletteEditor: View {
    @ObservedObject var model: ChartPaletteModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DEFAULT SERIES PALETTE")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(model.palette.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    ColorPicker("", selection: colorBinding(i), supportsOpacity: false)
                        .labelsHidden()
                    Text("Series \(i + 1)").font(.callout)
                    Spacer()
                    Button {
                        model.palette.remove(at: i)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.palette.count <= 1)
                }
            }

            HStack {
                Button {
                    model.palette.append(ChartPalette.defaultHex[model.palette.count % ChartPalette.defaultHex.count])
                } label: {
                    Label("Add color", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                Spacer()
                Button("Reset to defaults") { model.palette = ChartPalette.defaultHex }
                    .buttonStyle(.link)
            }
            .padding(.top, 4)

            Spacer()
        }
        .padding(16)
        .frame(width: 520, alignment: .leading)
    }

    private func colorBinding(_ i: Int) -> Binding<Color> {
        Binding(
            get: { ChartPalette.color(fromHex: model.palette[i]) },
            set: { model.palette[i] = ChartPalette.hex(from: $0) }
        )
    }
}
