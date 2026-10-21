import SwiftUI

/// The entries Settings ▸ Connections ▸ DuckDB edits. The pane watches
/// `entries` and saves it into `AppSettings.connections.duckdbCloudSecrets`;
/// secret keys go straight to the Keychain through `onStoreSecret`, never
/// into the settings.
final class DuckDBCloudSecretsModel: ObservableObject {
    @Published var entries: [DuckDBCloudSecret]
    /// Store (or, with nil, delete) an entry's secret key.
    var onStoreSecret: (_ id: String, _ secret: String?) -> Void = { _, _ in }
    /// Whether an entry has a secret key stored.
    var secretExists: (_ id: String) -> Bool = { _ in false }

    init(entries: [DuckDBCloudSecret]) { self.entries = entries }
}

/// Cloud storage credentials for DuckDB (D12): S3 or compatible, Cloudflare
/// R2, Google Cloud Storage. Each becomes a temporary secret of every DuckDB
/// database when it opens, so `read_parquet('s3://…')` needs no CREATE
/// SECRET card (a card's text is kept in plain text by relaunch restore and
/// saved Sessions).
struct DuckDBCloudSecretsEditor: View {
    @ObservedObject var model: DuckDBCloudSecretsModel
    @State private var editing: DuckDBCloudSecret?
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.entries.isEmpty {
                Text("No cloud credentials. Public files and presigned https:// links need none.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                List(selection: $selection) {
                    ForEach(model.entries) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.name.isEmpty ? String(localized: "Untitled") : entry.name)
                                Text(entry.provider.displayName + " · " + Self.scopeText(entry))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !model.secretExists(entry.id) {
                                Text("No secret key")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .tag(entry.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { editing = entry }
                    }
                }
                .frame(minHeight: 72, maxHeight: 160)
                .accessibilityLabel(Text("Cloud credentials"))
            }
            HStack(spacing: 8) {
                Button {
                    editing = DuckDBCloudSecret()
                } label: { Image(systemName: "plus") }
                    .help(Text("Add a cloud credential"))
                    .accessibilityLabel(Text("Add Credential"))
                Button {
                    guard let id = selection else { return }
                    model.entries.removeAll { $0.id == id }
                    model.onStoreSecret(id, nil)
                    selection = nil
                } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                    .help(Text("Remove the selected credential and its secret key"))
                    .accessibilityLabel(Text("Remove Credential"))
                Button("Edit…") {
                    editing = model.entries.first { $0.id == selection }
                }
                .disabled(selection == nil)
            }
            .buttonStyle(.borderless)
        }
        .sheet(item: $editing) { entry in
            DuckDBCloudSecretForm(entry: entry, hasSecret: model.secretExists(entry.id)) { saved, secret in
                if let index = model.entries.firstIndex(where: { $0.id == saved.id }) {
                    model.entries[index] = saved
                } else {
                    model.entries.append(saved)
                }
                if let secret, !secret.isEmpty { model.onStoreSecret(saved.id, secret) }
                selection = saved.id
                editing = nil
            } onCancel: {
                editing = nil
            }
        }
    }

    /// "s3://bucket", or "every s3:// path" for an entry with no scope.
    static func scopeText(_ entry: DuckDBCloudSecret) -> String {
        let scope = entry.scope.trimmingCharacters(in: .whitespaces)
        return scope.isEmpty ? String(localized: "every \(entry.provider.scheme) path") : scope
    }
}

/// One credential. The secret key field is empty when editing: leaving it
/// empty keeps the stored key.
struct DuckDBCloudSecretForm: View {
    @State var entry: DuckDBCloudSecret
    let hasSecret: Bool
    let onSave: (DuckDBCloudSecret, String?) -> Void
    let onCancel: () -> Void
    @State private var secret = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cloud Credential").font(.headline)
            Form {
                TextField("Name", text: $entry.name, prompt: Text("Data lake"))
                Picker("Provider", selection: $entry.provider) {
                    ForEach(CloudProvider.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                TextField("Key ID", text: $entry.keyId)
                SecureField("Secret key", text: $secret,
                            prompt: Text(hasSecret ? String(localized: "Saved in the Keychain") : ""))
                switch entry.provider {
                case .s3:
                    TextField("Region", text: $entry.region, prompt: Text("us-east-1"))
                    TextField("Endpoint", text: $entry.endpoint, prompt: Text("Empty for AWS"))
                case .r2:
                    TextField("Account ID", text: $entry.accountId)
                case .gcs:
                    EmptyView()
                }
                TextField("Scope", text: $entry.scope, prompt: Text(entry.provider.scheme + "bucket"))
            }
            if entry.scope.trimmingCharacters(in: .whitespaces).isEmpty {
                Label("With no scope, this credential applies to every \(entry.provider.scheme) path.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("The secret key is kept in the Keychain. Pharos gives DuckDB the credential when a database opens, so no CREATE SECRET card is needed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(entry, secret.isEmpty ? nil : secret) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(entry.keyId.trimmingCharacters(in: .whitespaces).isEmpty
                              || (!hasSecret && secret.isEmpty)
                              || (entry.provider == .r2 && entry.accountId.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
