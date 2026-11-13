import SwiftUI

/// The API key row of Settings ▸ Intelligence. The pane wires `store` and
/// `remove` to the Keychain; the key never enters `AppSettings`.
final class IntelligenceEndpointKeyModel: ObservableObject {
    /// Whether a key is stored. The key itself is never shown again.
    @Published var hasKey = false
    /// Set when the Keychain refused the last change.
    @Published var failed = false

    /// Keep a key; false when the Keychain refused it.
    var store: (String) -> Bool = { _ in false }
    /// Remove the stored key; false when the Keychain refused.
    var remove: () -> Bool = { false }
}

/// A secure field with Save and Remove. The field is empty when a key is
/// stored: leaving it empty keeps that key.
struct IntelligenceEndpointKeyEditor: View {
    @ObservedObject var model: IntelligenceEndpointKeyModel
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                SecureField("API key", text: $draft,
                            prompt: Text(model.hasKey ? String(localized: "Saved in the Keychain") : String(localized: "None")))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    // A fixed width: the hosting view sizes the row from
                    // this view's ideal size, and a field with only a
                    // maximum has an ideal width of a few characters.
                    .frame(width: 200)
                    .onSubmit(save)
                    .accessibilityLabel(Text("API key"))
                    .accessibilityIdentifier("settings.intelligence.endpointKey.field")
                Button("Save", action: save)
                    .fixedSize()
                    .disabled(draft.isEmpty)
                    .accessibilityIdentifier("settings.intelligence.endpointKey.save")
                Button("Remove") {
                    model.failed = !model.remove()
                    if !model.failed { model.hasKey = false }
                }
                .fixedSize()
                .disabled(!model.hasKey)
                .accessibilityIdentifier("settings.intelligence.endpointKey.remove")
            }
            if model.failed {
                Text("The Keychain refused the change. Try again, or check Keychain Access.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func save() {
        guard !draft.isEmpty else { return }
        model.failed = !model.store(draft)
        if !model.failed {
            model.hasKey = true
            draft = ""
        }
    }
}
