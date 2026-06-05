import AppKit
import Combine
import SwiftUI

// MARK: - List view model

/// Drives the SwiftUI list on the left. Owns the user-facing connection list
/// state and exposes callbacks for actions that need VC orchestration (add /
/// delete confirmation / drag-reorder persistence). SwiftUI's `List` +
/// `.onMove` handles drag-and-drop reordering natively — we just hand it the
/// data and let it call back when the user finishes a drag.
@MainActor
final class ConnectionsListModel: ObservableObject {
    @Published var connections: [ConnectionConfig] = []
    @Published var selectedIds: Set<String> = []
    @Published var pendingStubIds: Set<String> = []
    @Published var statuses: [String: ConnectionStatus] = [:]
    /// Connection currently being edited in the right pane and not yet saved.
    /// Used to render the orange dirty-dot in the corresponding list row.
    @Published var dirtyConnectionId: String?

    var onMove: ((IndexSet, Int) -> Void)?
    var onAdd: (() -> Void)?
    var onDelete: ((Set<String>) -> Void)?

    var selectedId: String? { selectedIds.first }

    func status(for id: String) -> ConnectionStatus { statuses[id] ?? .disconnected }
    func isStub(_ id: String) -> Bool { pendingStubIds.contains(id) }
    func isDirty(_ id: String) -> Bool { dirtyConnectionId == id && !pendingStubIds.contains(id) }
}

// MARK: - SwiftUI list

struct ConnectionsListView: View {
    @ObservedObject var model: ConnectionsListModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $model.selectedIds) {
                ForEach(model.connections, id: \.id) { connection in
                    ConnectionListRow(
                        connection: connection,
                        status: model.status(for: connection.id),
                        isStub: model.isStub(connection.id),
                        isDirty: model.isDirty(connection.id)
                    )
                    .tag(connection.id)
                }
                .onMove { source, destination in
                    model.onMove?(source, destination)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider()

            HStack(spacing: 4) {
                Button {
                    model.onAdd?()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 22, height: 16)
                }
                .help("Add Connection")

                Button {
                    if !model.selectedIds.isEmpty {
                        model.onDelete?(model.selectedIds)
                    }
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 22, height: 16)
                }
                .disabled(model.selectedIds.isEmpty)
                .help("Delete Connection")

                Spacer()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }
}

private struct ConnectionListRow: View {
    let connection: ConnectionConfig
    let status: ConnectionStatus
    let isStub: Bool
    let isDirty: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(connection.name.isEmpty ? "Untitled" : connection.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(isStub ? Color.orange : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            if isDirty {
                Circle().fill(Color.orange).frame(width: 6, height: 6)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        isStub
            ? "Not saved"
            : "\(connection.host):\(connection.port) · \(connection.database)"
    }

    private var statusColor: Color {
        if isStub { return Color.orange }
        switch status {
        case .connected:    return Color.green
        case .connecting:   return Color.yellow
        case .error:        return Color.red
        case .disconnected: return Color(nsColor: .tertiaryLabelColor)
        }
    }
}

// MARK: - View Controller

/// Two-pane connections manager. Left pane: SwiftUI `List` with `.onMove`
/// drag-reorder and a +/- footer (hosted via NSHostingView). Right pane:
/// detail form (AppKit) with Save/Revert footer.
final class ConnectionsManagerVC: NSViewController {

    // MARK: - State

    private let stateManager = AppStateManager.shared
    private var cancellables = Set<AnyCancellable>()
    private let listModel = ConnectionsListModel()

    /// Convenience accessors for the model-owned list state.
    private var connections: [ConnectionConfig] {
        get { listModel.connections }
        set { listModel.connections = newValue }
    }
    private var pendingStubIds: Set<String> {
        get { listModel.pendingStubIds }
        set { listModel.pendingStubIds = newValue }
    }

    private var draft: ConnectionConfig?
    private var draftBaseline: ConnectionConfig?
    private var fetchedSchemas: [String] = []

    private var isDirty: Bool {
        guard let draft, let draftBaseline else { return false }
        return draft != draftBaseline
    }

    // MARK: - Right pane

    private let placeholderLabel = NSTextField(labelWithString: "Select a connection or click + to add a new one.")
    private let detailContent = NSView()
    private let titleField = NSTextField(labelWithString: "Connection")
    private let statusBadge = StatusBadge()

    private let nameField = NSTextField()
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let databaseField = NSTextField()
    private let usernameField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let sslPopup = NSPopUpButton()
    private let defaultSchemaPopup = NSPopUpButton()

    private let testButton = NSButton()
    private let testStatusLabel = NSTextField(labelWithString: "")
    private let testSpinner = NSProgressIndicator()

    private let revertButton = NSButton()
    private let saveButton = NSButton()

    private enum L {
        static let listWidth: CGFloat = 240
        static let formInsetH: CGFloat = 28
        static let formInsetTop: CGFloat = 18
        static let formInsetBottom: CGFloat = 20
        static let labelColumnWidth: CGFloat = 130
        static let fieldMinWidth: CGFloat = 320
        static let portWidth: CGFloat = 90
        static let popupMinWidth: CGFloat = 200
        static let sectionSpacing: CGFloat = 18
        static let rowSpacing: CGFloat = 10
    }

    /// Slightly darker than the right pane content background so the left
    /// pane reads as a sidebar. Tracks light/dark mode via NSColor.
    private static let sidebarBackgroundColor: NSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(white: 0.16, alpha: 1.0)
            : NSColor(white: 0.94, alpha: 1.0)
    }

    // MARK: - Lifecycle

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        self.view = root

        let split = NSSplitView()
        split.dividerStyle = .thin
        split.isVertical = true
        split.translatesAutoresizingMaskIntoConstraints = false

        let left = buildLeftPane()
        let right = buildRightPane()
        split.addArrangedSubview(left)
        split.addArrangedSubview(right)

        root.addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            left.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            left.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            right.widthAnchor.constraint(greaterThanOrEqualToConstant: 480),
        ])
        DispatchQueue.main.async { [weak split] in
            split?.setPosition(L.listWidth, ofDividerAt: 0)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Wire the list model's callbacks to VC handlers.
        listModel.onMove = { [weak self] source, destination in
            self?.handleMove(from: source, to: destination)
        }
        listModel.onAdd = { [weak self] in self?.addStub() }
        listModel.onDelete = { [weak self] ids in self?.deleteSelected(ids: ids) }

        // React to selection changes from the SwiftUI list.
        listModel.$selectedIds
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.handleSelectionChange() }
            .store(in: &cancellables)

        // Seed initial state, then keep in sync with the global state manager.
        listModel.connections = stateManager.connections
        listModel.statuses = stateManager.connectionStatuses
        updateDetailVisibility()

        stateManager.$connections
            .receive(on: RunLoop.main)
            .sink { [weak self] configs in
                self?.externalConnectionsChanged(configs)
            }
            .store(in: &cancellables)

        stateManager.$connectionStatuses
            .receive(on: RunLoop.main)
            .sink { [weak self] statuses in
                self?.listModel.statuses = statuses
                self?.refreshStatusBadge()
            }
            .store(in: &cancellables)
    }

    // MARK: - Left pane (SwiftUI host)

    private func buildLeftPane() -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = Self.sidebarBackgroundColor.cgColor
        container.translatesAutoresizingMaskIntoConstraints = false

        let host = NSHostingView(rootView: ConnectionsListView(model: listModel))
        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    // MARK: - Right pane (AppKit form)

    private func buildRightPane() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.alignment = .center
        placeholderLabel.font = .systemFont(ofSize: 13)
        placeholderLabel.textColor = .secondaryLabelColor
        container.addSubview(placeholderLabel)

        detailContent.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(detailContent)
        buildDetailForm(in: detailContent)

        NSLayoutConstraint.activate([
            placeholderLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            placeholderLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),

            detailContent.topAnchor.constraint(equalTo: container.topAnchor),
            detailContent.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            detailContent.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            detailContent.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    private func buildDetailForm(in container: NSView) {
        titleField.font = .systemFont(ofSize: 22, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.translatesAutoresizingMaskIntoConstraints = false

        statusBadge.translatesAutoresizingMaskIntoConstraints = false
        statusBadge.setContentHuggingPriority(.required, for: .horizontal)

        let header = NSStackView(views: [titleField, NSView(), statusBadge])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false

        for field in [nameField, hostField, portField, databaseField, usernameField] {
            configureField(field)
        }
        configureField(passwordField)

        nameField.placeholderString = "My Database"
        hostField.placeholderString = "db.example.com or 10.0.0.5"
        portField.placeholderString = "5432"
        let portFormatter = NumberFormatter()
        portFormatter.minimum = 1
        portFormatter.maximum = 65535
        portFormatter.allowsFloats = false
        portField.formatter = portFormatter
        databaseField.placeholderString = "postgres"
        usernameField.placeholderString = "postgres"
        passwordField.placeholderString = "Optional"

        sslPopup.target = self
        sslPopup.action = #selector(sslPopupChanged)
        sslPopup.addItems(withTitles: ["Prefer", "Require", "Disable"])
        sslPopup.translatesAutoresizingMaskIntoConstraints = false

        defaultSchemaPopup.target = self
        defaultSchemaPopup.action = #selector(defaultSchemaChanged)
        defaultSchemaPopup.addItem(withTitle: "Test connection first")
        defaultSchemaPopup.isEnabled = false
        defaultSchemaPopup.translatesAutoresizingMaskIntoConstraints = false

        testButton.title = "Test Connection"
        testButton.bezelStyle = .rounded
        testButton.controlSize = .regular
        testButton.target = self
        testButton.action = #selector(testConnection)

        testSpinner.style = .spinning
        testSpinner.controlSize = .small
        testSpinner.isHidden = true

        testStatusLabel.font = .systemFont(ofSize: 12)
        testStatusLabel.textColor = .secondaryLabelColor
        testStatusLabel.lineBreakMode = .byTruncatingTail
        testStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let testRow = NSStackView(views: [testButton, testSpinner, testStatusLabel])
        testRow.orientation = .horizontal
        testRow.alignment = .centerY
        testRow.spacing = 10

        revertButton.title = "Revert"
        revertButton.bezelStyle = .rounded
        revertButton.target = self
        revertButton.action = #selector(revertChanges)

        saveButton.title = "Save"
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(saveChanges)

        let footerSpacer = NSView()
        footerSpacer.translatesAutoresizingMaskIntoConstraints = false
        let footer = NSStackView(views: [footerSpacer, revertButton, saveButton])
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.alignment = .centerY

        let serverSection = section(title: "Server", rows: [
            row(label: "Name", field: nameField),
            row(label: "Host", field: hostField),
            row(label: "Port", field: portField, fieldFixedWidth: L.portWidth),
        ])
        let authSection = section(title: "Authentication", rows: [
            row(label: "Username", field: usernameField),
            row(label: "Password", field: passwordField),
            row(label: "SSL Mode", control: sslPopup),
        ])
        let dbSection = section(title: "Database", rows: [
            row(label: "Database", field: databaseField),
            row(label: "Default Schema", control: defaultSchemaPopup),
        ])

        let main = NSStackView(views: [header, serverSection, authSection, dbSection, testRow, footer])
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = L.sectionSpacing
        main.translatesAutoresizingMaskIntoConstraints = false
        main.edgeInsets = NSEdgeInsets(top: L.formInsetTop, left: L.formInsetH,
                                       bottom: L.formInsetBottom, right: L.formInsetH)

        container.addSubview(main)
        NSLayoutConstraint.activate([
            main.topAnchor.constraint(equalTo: container.topAnchor),
            main.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            main.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            main.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            header.widthAnchor.constraint(equalTo: main.widthAnchor, constant: -L.formInsetH * 2),
            footer.widthAnchor.constraint(equalTo: main.widthAnchor, constant: -L.formInsetH * 2),
            testRow.widthAnchor.constraint(equalTo: main.widthAnchor, constant: -L.formInsetH * 2),
            serverSection.widthAnchor.constraint(equalTo: main.widthAnchor, constant: -L.formInsetH * 2),
            authSection.widthAnchor.constraint(equalTo: main.widthAnchor, constant: -L.formInsetH * 2),
            dbSection.widthAnchor.constraint(equalTo: main.widthAnchor, constant: -L.formInsetH * 2),
        ])
    }

    private func configureField(_ field: NSTextField) {
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.controlSize = .regular
        field.font = .systemFont(ofSize: 13)
        field.target = self
        field.action = #selector(fieldEdited)
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
    }

    private func row(label: String, field: NSControl, fieldFixedWidth: CGFloat? = nil) -> NSView {
        let labelView = NSTextField(labelWithString: label)
        labelView.alignment = .right
        labelView.font = .systemFont(ofSize: 13)
        labelView.textColor = .labelColor
        labelView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(labelView)
        container.addSubview(field)

        var constraints: [NSLayoutConstraint] = [
            labelView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            labelView.widthAnchor.constraint(equalToConstant: L.labelColumnWidth),
            labelView.firstBaselineAnchor.constraint(equalTo: field.firstBaselineAnchor),

            field.leadingAnchor.constraint(equalTo: labelView.trailingAnchor, constant: 10),
            field.topAnchor.constraint(equalTo: container.topAnchor),
            field.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ]
        if let w = fieldFixedWidth {
            constraints.append(field.widthAnchor.constraint(equalToConstant: w))
            constraints.append(field.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor))
        } else {
            constraints.append(field.trailingAnchor.constraint(equalTo: container.trailingAnchor))
            constraints.append(field.widthAnchor.constraint(greaterThanOrEqualToConstant: L.fieldMinWidth))
        }
        NSLayoutConstraint.activate(constraints)
        return container
    }

    private func row(label: String, control: NSControl) -> NSView {
        let labelView = NSTextField(labelWithString: label)
        labelView.alignment = .right
        labelView.font = .systemFont(ofSize: 13)
        labelView.textColor = .labelColor
        labelView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(labelView)
        container.addSubview(control)

        NSLayoutConstraint.activate([
            labelView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            labelView.widthAnchor.constraint(equalToConstant: L.labelColumnWidth),
            labelView.firstBaselineAnchor.constraint(equalTo: control.firstBaselineAnchor),

            control.leadingAnchor.constraint(equalTo: labelView.trailingAnchor, constant: 10),
            control.widthAnchor.constraint(greaterThanOrEqualToConstant: L.popupMinWidth),
            control.topAnchor.constraint(equalTo: container.topAnchor),
            control.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            control.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ])
        return container
    }

    private func section(title: String, rows: [NSView]) -> NSView {
        let headerLabel = NSTextField(labelWithString: title.uppercased())
        headerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox.separator()

        let headerRow = NSStackView(views: [headerLabel, separator])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 8
        separator.setContentHuggingPriority(.defaultLow, for: .horizontal)
        separator.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = L.rowSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(headerRow)
        for row in rows { stack.addArrangedSubview(row) }
        stack.setCustomSpacing(L.rowSpacing + 2, after: headerRow)

        for view in [headerRow] + rows {
            view.translatesAutoresizingMaskIntoConstraints = false
            stack.addConstraint(view.leadingAnchor.constraint(equalTo: stack.leadingAnchor))
            stack.addConstraint(view.trailingAnchor.constraint(equalTo: stack.trailingAnchor))
        }
        return stack
    }

    // MARK: - External state sync

    private func externalConnectionsChanged(_ configs: [ConnectionConfig]) {
        // Preserve in-flight stubs that aren't yet in the backend.
        let stubs = connections.filter { pendingStubIds.contains($0.id) }
        let preservedSelection = listModel.selectedId
        connections = configs + stubs
        if let preservedSelection,
           connections.contains(where: { $0.id == preservedSelection }) {
            listModel.selectedIds = [preservedSelection]
        }
        updateDetailVisibility()
    }

    // MARK: - Drag reorder

    private func handleMove(from source: IndexSet, to destination: Int) {
        // SwiftUI's `.onMove` provides source indices + destination offset
        // (the position before which to insert). `Array.move(fromOffsets:toOffset:)`
        // is the matching Foundation API.
        var updated = connections
        updated.move(fromOffsets: source, toOffset: destination)
        connections = updated
        stateManager.reorderConnections(ids: updated.map { $0.id })
    }

    // MARK: - Selection / detail population

    private func handleSelectionChange() {
        // The current selection drives the detail form. If the user has
        // pending edits, prompt before clearing them.
        guard isDirty else {
            updateDetailVisibility()
            return
        }
        guard let window = view.window else {
            updateDetailVisibility()
            return
        }
        let alert = NSAlert()
        let name = (draft?.name.isEmpty == false ? draft?.name : nil) ?? "this connection"
        alert.messageText = "Save changes to \"\(name)\"?"
        alert.informativeText = "Your edits will be lost if you don't save."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        let response = alert.runModal(for: window)
        switch response {
        case .alertFirstButtonReturn:
            saveChangesInternal()
            updateDetailVisibility()
        case .alertSecondButtonReturn:
            if let id = draft?.id, pendingStubIds.contains(id) {
                pendingStubIds.remove(id)
                connections.removeAll { $0.id == id }
            }
            draft = draftBaseline
            listModel.dirtyConnectionId = nil
            updateDetailVisibility()
        default:
            // Revert the selection change.
            let target = draft?.id
            DispatchQueue.main.async { [weak self] in
                self?.listModel.selectedIds = target.map { Set([$0]) } ?? []
            }
        }
    }

    private func updateDetailVisibility() {
        let hasSelection = listModel.selectedId != nil
        detailContent.isHidden = !hasSelection
        placeholderLabel.isHidden = hasSelection

        if hasSelection {
            loadSelectionIntoForm()
        } else {
            draft = nil
            draftBaseline = nil
            listModel.dirtyConnectionId = nil
            updateButtonStates()
        }
    }

    private func loadSelectionIntoForm() {
        guard let id = listModel.selectedId,
              let config = connections.first(where: { $0.id == id }) else { return }
        draft = config
        draftBaseline = config
        listModel.dirtyConnectionId = nil
        fetchedSchemas = []

        titleField.stringValue = config.name.isEmpty ? "Untitled Connection" : config.name
        nameField.stringValue = config.name
        hostField.stringValue = config.host
        portField.stringValue = String(config.port)
        databaseField.stringValue = config.database
        usernameField.stringValue = config.username
        passwordField.stringValue = config.password
        switch config.sslMode {
        case .prefer:  sslPopup.selectItem(at: 0)
        case .require: sslPopup.selectItem(at: 1)
        case .disable: sslPopup.selectItem(at: 2)
        }
        defaultSchemaPopup.removeAllItems()
        if let saved = config.defaultSchema, !saved.isEmpty {
            defaultSchemaPopup.addItem(withTitle: saved)
            defaultSchemaPopup.isEnabled = false
            defaultSchemaPopup.toolTip = "Test the connection to refresh the schema list."
        } else {
            defaultSchemaPopup.addItem(withTitle: "Test connection first")
            defaultSchemaPopup.isEnabled = false
            defaultSchemaPopup.toolTip = nil
        }

        testStatusLabel.stringValue = ""
        testSpinner.isHidden = true
        testSpinner.stopAnimation(nil)

        refreshStatusBadge()
        updateButtonStates()
    }

    private func refreshStatusBadge() {
        guard let id = listModel.selectedId else {
            statusBadge.isHidden = true
            return
        }
        statusBadge.isHidden = false
        if pendingStubIds.contains(id) {
            statusBadge.apply(state: .stub)
            return
        }
        switch listModel.status(for: id) {
        case .connected:   statusBadge.apply(state: .connected)
        case .connecting:  statusBadge.apply(state: .connecting)
        case .error:       statusBadge.apply(state: .error)
        case .disconnected: statusBadge.apply(state: .disconnected)
        }
    }

    private func updateButtonStates() {
        let canSave = isDirty && isDraftValid()
        saveButton.isEnabled = canSave
        saveButton.bezelColor = canSave ? .controlAccentColor : nil
        saveButton.contentTintColor = canSave ? .white : nil
        revertButton.isEnabled = isDirty
        listModel.dirtyConnectionId = isDirty ? draft?.id : nil
    }

    private func isDraftValid() -> Bool {
        guard let d = draft else { return false }
        return !d.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !d.host.trimmingCharacters(in: .whitespaces).isEmpty
            && !d.database.trimmingCharacters(in: .whitespaces).isEmpty
            && !d.username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Editing

    @objc private func fieldEdited() { syncFormIntoDraft() }
    @objc private func sslPopupChanged() { syncFormIntoDraft() }
    @objc private func defaultSchemaChanged() { syncFormIntoDraft() }

    private func syncFormIntoDraft() {
        guard var d = draft else { return }
        d.name = nameField.stringValue
        d.host = hostField.stringValue
        d.port = UInt16(portField.stringValue) ?? d.port
        d.database = databaseField.stringValue
        d.username = usernameField.stringValue
        d.password = passwordField.stringValue
        switch sslPopup.indexOfSelectedItem {
        case 1: d.sslMode = .require
        case 2: d.sslMode = .disable
        default: d.sslMode = .prefer
        }
        if defaultSchemaPopup.isEnabled,
           defaultSchemaPopup.indexOfSelectedItem > 0 {
            d.defaultSchema = defaultSchemaPopup.titleOfSelectedItem
        }
        draft = d

        titleField.stringValue = d.name.isEmpty ? "Untitled Connection" : d.name
        // Update the row's display name in the SwiftUI list.
        if let idx = connections.firstIndex(where: { $0.id == d.id }) {
            connections[idx].name = d.name
        }
        updateButtonStates()
    }

    // MARK: - Save / Revert / Test

    @objc private func saveChanges() { saveChangesInternal() }

    private func saveChangesInternal() {
        guard let d = draft, isDraftValid() else { NSSound.beep(); return }
        pendingStubIds.remove(d.id)
        stateManager.saveConnection(d)
        draftBaseline = d
        updateButtonStates()
    }

    @objc private func revertChanges() {
        if let id = draft?.id, pendingStubIds.contains(id) {
            pendingStubIds.remove(id)
            connections.removeAll { $0.id == id }
            listModel.selectedIds = []
            updateDetailVisibility()
            return
        }
        loadSelectionIntoForm()
    }

    @objc private func testConnection() {
        guard let d = draft else { return }
        testButton.isEnabled = false
        testSpinner.isHidden = false
        testSpinner.startAnimation(nil)
        testStatusLabel.stringValue = "Testing…"
        testStatusLabel.textColor = .secondaryLabelColor

        Task { [weak self] in
            do {
                let result = try await PharosCore.testConnection(d)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.testSpinner.stopAnimation(nil)
                    self.testSpinner.isHidden = true
                    self.testButton.isEnabled = true
                    if result.success {
                        let ms = result.latencyMs.map { " \($0)ms" } ?? ""
                        self.testStatusLabel.stringValue = "Connected\(ms)"
                        self.testStatusLabel.textColor = .systemGreen
                        self.populateDefaultSchemas(using: d)
                    } else {
                        self.testStatusLabel.stringValue = result.error ?? "Failed"
                        self.testStatusLabel.textColor = .systemRed
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.testSpinner.stopAnimation(nil)
                    self.testSpinner.isHidden = true
                    self.testButton.isEnabled = true
                    self.testStatusLabel.stringValue = error.localizedDescription
                    self.testStatusLabel.textColor = .systemRed
                }
            }
        }
    }

    private func populateDefaultSchemas(using config: ConnectionConfig) {
        Task { [weak self] in
            do {
                let tempId = "__test_schema_fetch_\(UUID().uuidString)"
                var tempConfig = config
                tempConfig.id = tempId
                try PharosCore.saveConnection(tempConfig)
                _ = try await PharosCore.connect(connectionId: tempId)
                let schemas: [SchemaInfo] = try await PharosCore.getSchemas(connectionId: tempId)
                try await PharosCore.disconnect(connectionId: tempId)
                try PharosCore.deleteConnection(id: tempId)

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.fetchedSchemas = schemas.map { $0.name }
                    self.defaultSchemaPopup.removeAllItems()
                    self.defaultSchemaPopup.addItem(withTitle: "None")
                    for schema in schemas {
                        self.defaultSchemaPopup.addItem(withTitle: schema.name)
                    }
                    self.defaultSchemaPopup.isEnabled = true
                    if let existing = self.draft?.defaultSchema,
                       let idx = self.fetchedSchemas.firstIndex(of: existing) {
                        self.defaultSchemaPopup.selectItem(at: idx + 1)
                    }
                }
            } catch {
                NSLog("Failed to fetch schemas for default schema picker: \(error)")
            }
        }
    }

    // MARK: - +/- Actions

    private func addStub() {
        confirmDiscardIfDirty { [weak self] proceed in
            guard let self, proceed else { return }
            let stub = ConnectionConfig(
                id: UUID().uuidString,
                name: "Untitled",
                host: "localhost",
                port: 5432,
                database: "postgres",
                username: "postgres"
            )
            self.pendingStubIds.insert(stub.id)
            self.connections.append(stub)
            self.listModel.selectedIds = [stub.id]
            self.view.window?.makeFirstResponder(self.nameField)
            self.nameField.selectText(nil)
            self.draftBaseline = ConnectionConfig(
                id: stub.id, name: "", host: "", port: stub.port,
                database: "", username: ""
            )
            self.updateButtonStates()
        }
    }

    private func deleteSelected(ids: Set<String>) {
        let selected = ids.compactMap { id in connections.first(where: { $0.id == id }) }
        guard !selected.isEmpty else { return }

        let alert = NSAlert()
        if selected.count == 1 {
            alert.messageText = "Delete \"\(selected[0].name)\"?"
        } else {
            alert.messageText = "Delete \(selected.count) connections?"
        }
        let suffix = selected.count == 1 ? "" : "s"
        alert.informativeText = "This will remove the saved configuration\(suffix) and stored password\(suffix)."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            for config in selected {
                if self.pendingStubIds.contains(config.id) {
                    self.pendingStubIds.remove(config.id)
                    self.connections.removeAll { $0.id == config.id }
                } else {
                    self.stateManager.deleteConnection(id: config.id)
                }
            }
            self.listModel.selectedIds = []
            self.updateDetailVisibility()
        }
    }
}

// MARK: - NSTextFieldDelegate

extension ConnectionsManagerVC: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { syncFormIntoDraft() }
}

// MARK: - Status badge

private final class StatusBadge: NSView {

    enum State {
        case connected, connecting, error, disconnected, stub

        var text: String {
            switch self {
            case .connected:   return "Connected"
            case .connecting:  return "Connecting…"
            case .error:       return "Error"
            case .disconnected: return "Disconnected"
            case .stub:        return "Not Saved"
            }
        }
        var background: NSColor {
            switch self {
            case .connected:    return NSColor.systemGreen.withAlphaComponent(0.18)
            case .connecting:   return NSColor.systemYellow.withAlphaComponent(0.20)
            case .error:        return NSColor.systemRed.withAlphaComponent(0.18)
            case .disconnected: return NSColor.tertiaryLabelColor.withAlphaComponent(0.22)
            case .stub:         return NSColor.systemOrange.withAlphaComponent(0.20)
            }
        }
        var foreground: NSColor {
            switch self {
            case .connected:    return .systemGreen
            case .connecting:   return .systemYellow
            case .error:        return .systemRed
            case .disconnected: return .secondaryLabelColor
            case .stub:         return .systemOrange
            }
        }
    }

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply(state: State) {
        label.stringValue = state.text
        label.textColor = state.foreground
        layer?.backgroundColor = state.background.cgColor
    }
}

// MARK: - Equality (drives isDirty)

extension ConnectionConfig: Equatable {
    public static func == (a: ConnectionConfig, b: ConnectionConfig) -> Bool {
        a.id == b.id && a.name == b.name && a.host == b.host && a.port == b.port
            && a.database == b.database && a.username == b.username
            && a.password == b.password && a.sslMode == b.sslMode
            && a.color == b.color && a.defaultSchema == b.defaultSchema
    }
}

// MARK: - Helpers

private extension NSBox {
    static func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }
}

private extension ConnectionsManagerVC {
    func confirmDiscardIfDirty(_ completion: @escaping (Bool) -> Void) {
        guard isDirty, let window = view.window else { completion(true); return }
        let alert = NSAlert()
        alert.messageText = "You have unsaved changes."
        alert.informativeText = "Save before adding a new connection?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        let response = alert.runModal(for: window)
        switch response {
        case .alertFirstButtonReturn:
            if isDraftValid() { saveChangesInternal(); completion(true) }
            else { NSSound.beep(); completion(false) }
        case .alertSecondButtonReturn:
            if let id = draft?.id, pendingStubIds.contains(id) {
                pendingStubIds.remove(id)
                connections.removeAll { $0.id == id }
            } else {
                draft = draftBaseline
            }
            completion(true)
        default:
            completion(false)
        }
    }
}

private extension NSAlert {
    @MainActor
    func runModal(for window: NSWindow) -> NSApplication.ModalResponse {
        self.window.title = window.title
        return self.runModal()
    }
}
