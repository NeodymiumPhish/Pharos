import AppKit
import Combine
import SwiftUI
import os

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

private extension String {
    /// `self`, or `fallback` when `self` holds nothing. Used where a name is
    /// trimmed for display: the placeholder has to be chosen AFTER the trim,
    /// because a name of nothing but spaces trims away to nothing.
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
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
                // The placeholder is chosen on the TRIMMED text, not the raw
                // name: a stored name of nothing but spaces trims to nothing,
                // and a blank row is less use than "Untitled".
                Text(DisplayEscape.escapedTrimmed(connection.name).ifEmpty("Untitled"))
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
        guard !isStub else { return "Not saved" }
        let base = "\(DisplayEscape.escaped(connection.host)):\(connection.port) · \(DisplayEscape.escaped(connection.database))"
        // The tunnel is part of WHERE this connection goes, and a bastion's
        // name is the one thing that tells two otherwise identical records
        // apart. Escaped like every other stored string shown as a label.
        return base + SshTunnelForm.viaSuffix(connection.sshTunnel,
                                              escape: DisplayEscape.escaped)
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

    /// Schema lists fetched by "Test Connection", keyed by connection id.
    ///
    /// Without this the list lived only in the popup's menu, and
    /// `loadSelectionIntoForm` rebuilt that menu from the SAVED value and
    /// disabled it again. That runs from `updateDetailVisibility`, which
    /// `externalConnectionsChanged` calls on EVERY `AppStateManager.$connections`
    /// publish — so any connection write anywhere in the app silently threw the
    /// fetched list away and took the picker back to "test the connection
    /// first", losing an unsaved pick with it.
    private var fetchedSchemas: [String: [String]] = [:]

    /// The connection settings each fetched list was read with. An edit to any
    /// of them makes the list stale: it describes a different server now, so
    /// the picker has to go back to asking for a test.
    private var fetchedSchemaFingerprints: [String: String] = [:]

    /// Connections whose schema list is being read from the live connection, so
    /// two status updates cannot start the same fetch twice.
    private var liveSchemaFetchesInFlight: Set<String> = []

    private let doneButton = NSButton()

    private var draft: ConnectionConfig?
    private var draftBaseline: ConnectionConfig?

    /// The record whose password arrived in a `postgres://` link. The note
    /// under the password field is shown for this record only, and is dropped
    /// the moment the user types a password of their own.
    private var passwordFromLinkId: String?

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

    // One badge per round-trip field. `nameField` has none — it is an authored
    // label and is sanitised instead — and `portField` has none, because a port
    // is digits.
    private let hostBadge = HostileTextBadge()
    private let databaseBadge = HostileTextBadge()
    private let usernameBadge = HostileTextBadge()
    private let passwordBadge = HostileTextBadge()

    /// Caption under the password field, shown only for a connection opened
    /// from a link that carried a password. Its row is hidden with it, so the
    /// form does not keep an empty line when there is nothing to say.
    private let passwordFromLinkLabel = NSTextField(labelWithString: "")
    private var passwordFromLinkRow: NSView?

    /// The Touch ID gate for this record: ask the device owner to authenticate
    /// before connecting, and before the stored password is shown.
    private let requireAuthCheckbox = NSButton()

    /// Stands beside a masked password field. Pressing it runs the gate; the
    /// real password appears only after the device owner authenticates.
    private let showPasswordButton = NSButton()

    /// Caption under the password field for the gate's own reporting — the
    /// reason an attempt did not succeed. Its row is hidden when it is empty.
    private let passwordAuthLabel = NSTextField(labelWithString: "")
    private var passwordAuthRow: NSView?

    /// False while the password field shows the mask rather than the stored
    /// password. It is per SELECTION, not per record: a gated record starts
    /// masked every time it is selected, and revealing it lasts only until the
    /// selection moves.
    ///
    /// The mask is what makes `syncFormIntoDraft` skip the password — otherwise
    /// a Save from the masked form would write the mask over the stored value.
    /// The checkbox does NOT drive this: unticking the box must not reveal a
    /// password the gate is still holding back.
    private var passwordRevealed = true

    /// What a masked password field shows. Eight bullets, so the field's width
    /// carries no hint of the stored password's length.
    private static let passwordMask = "••••••••"

    // MARK: SSH tunnel controls
    //
    // Every row below the checkbox is hidden while the checkbox is off, and
    // the key-file and secret rows follow the authentication pop-up. A hidden
    // row keeps its constraints, so the form's width never moves.

    private let sshEnabledCheckbox = NSButton()
    private let sshHostField = NSTextField()
    private let sshPortField = NSTextField()
    private let sshUserField = NSTextField()
    private let sshAuthPopup = NSPopUpButton()
    private let sshKeyPathField = NSTextField()
    private let sshChooseKeyButton = NSButton()
    private let sshSecretField = NSSecureTextField()
    private let sshShowSecretButton = NSButton()
    private let sshAcceptNewHostKeysCheckbox = NSButton()
    private let sshHostBadge = HostileTextBadge()
    private let sshUserBadge = HostileTextBadge()

    /// The rows that appear only when the tunnel is on, in form order.
    private var sshRows: [NSView] = []
    /// The key-file row, shown only for `.keyFile`.
    private var sshKeyPathRow: NSView?
    /// The secret row and its label, shown for `.keyFile` and `.password`.
    /// The label follows the pop-up: a key file takes a PASSPHRASE, a password
    /// mode takes a PASSWORD, and calling both the same thing would be wrong
    /// in one of the two.
    private var sshSecretRow: NSView?
    private let sshSecretLabel = NSTextField(labelWithString: "")

    private let testButton = NSButton()
    private let testStatusLabel = NSTextField(labelWithString: "")
    private let testSpinner = NSProgressIndicator()

    private let revertButton = NSButton()
    private let saveButton = NSButton()

    /// The form's scroll view. Held so turning the tunnel on can take the user
    /// to the section it just revealed.
    private var detailScrollView: NSScrollView?

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
        static let badgeGap: CGFloat = 6
        /// The gap under the pinned action bar, and above its separator.
        static let actionBarInsetBottom: CGFloat = 16
        static let actionBarInsetTop: CGFloat = 14
    }

    /// Slightly darker than the right pane's content background, so the left
    /// pane reads as a sidebar.
    ///
    /// The system pair, not two hand-picked greys: `windowBackgroundColor`
    /// behind `controlBackgroundColor` is the contrast macOS already uses for
    /// exactly this, and it stays right in both appearances and under Increase
    /// Contrast without anyone maintaining a number.
    private static var sidebarBackgroundColor: NSColor { .windowBackgroundColor }

    // MARK: - Lifecycle

    override func loadView() {
        // A sheet takes its size from this frame, the way every other sheet in
        // Pharos/Sheets does. It used to be 860x560, matching TagManagerSheet —
        // but MEASURED against this form that was always too short: with no SSH
        // section at all the form wants 633 pt against a 508 pt viewport, so
        // Test Connection, Revert and Save sat below the fold on a fresh
        // connection and the user had to scroll to reach Save.
        //
        // 720 gives a 668 pt viewport, which holds the whole form with the SSH
        // section closed — the common case — with room to spare. With the
        // section open the form wants 848 pt and still scrolls; that is the
        // right trade, because an advanced section should not make every
        // connection's window taller.
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 880, height: 720))
        self.view = root

        let split = NSSplitView()
        split.dividerStyle = .thin
        split.isVertical = true
        split.translatesAutoresizingMaskIntoConstraints = false

        let left = buildLeftPane()
        let right = buildRightPane()
        split.addArrangedSubview(left)
        split.addArrangedSubview(right)

        doneButton.title = String(localized: "Done")
        doneButton.bezelStyle = .rounded
        // Escape closes the sheet. Save and Revert are per-connection and stay
        // in the form; this button only dismisses, after the same unsaved-work
        // prompt a selection change already puts up.
        doneButton.keyEquivalent = "\u{1b}"
        doneButton.target = self
        doneButton.action = #selector(doneTapped)
        doneButton.setAccessibilityIdentifier("sheet.connections.done")
        doneButton.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(doneButton)

        root.addSubview(split)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: footer.topAnchor),
            left.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            left.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            right.widthAnchor.constraint(greaterThanOrEqualToConstant: 480),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 52),
            doneButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -20),
            doneButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
        DispatchQueue.main.async { [weak split] in
            split?.setPosition(L.listWidth, ofDividerAt: 0)
        }
    }

    /// Close the sheet, after the same unsaved-work prompt that guards moving
    /// between connections.
    @objc private func doneTapped() {
        guard isDirty, let window = view.window else {
            dismiss(nil)
            return
        }
        let alert = NSAlert()
        let name = (draft?.name.isEmpty == false ? draft?.name : nil) ?? "this connection"
        alert.messageText = DestructiveConfirmationText.unsavedChangesConfirmTitle(name: name)
        alert.informativeText = String(localized: "Your changes will be lost if you close now.")
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Discard"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.saveChangesInternal()
                self.dismiss(nil)
            case .alertSecondButtonReturn:
                self.dismiss(nil)
            default:
                break
            }
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
                guard let self else { return }
                self.listModel.statuses = statuses
                self.refreshStatusBadge()
                // Connecting in another window is enough to make the picker
                // usable, so take the list as soon as one is available.
                if let d = self.draft, self.liveOrFetchedSchemas(for: d) == nil,
                   self.canUseLiveSchemas(for: d) {
                    self.loadLiveSchemas(for: d.id)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Left pane (SwiftUI host)

    private func buildLeftPane() -> NSView {
        let container = AppearanceBackgroundView()
        container.colorProvider = { Self.sidebarBackgroundColor }
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
        let container = AppearanceBackgroundView()
        container.colorProvider = { .controlBackgroundColor }
        container.translatesAutoresizingMaskIntoConstraints = false

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

        showPasswordButton.title = String(localized: "Show")
        showPasswordButton.bezelStyle = .rounded
        showPasswordButton.controlSize = .regular
        showPasswordButton.target = self
        showPasswordButton.action = #selector(revealPassword)
        showPasswordButton.setAccessibilityIdentifier("connections.showPassword")
        showPasswordButton.toolTip = String(localized: "Authenticate to show the stored password.")
        showPasswordButton.setContentHuggingPriority(.required, for: .horizontal)
        showPasswordButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        // A hidden arranged subview is detached from the stack, so an ungated
        // record's password field fills the row exactly as it did before.
        showPasswordButton.isHidden = true

        requireAuthCheckbox.setButtonType(.switch)
        requireAuthCheckbox.title = String(localized: "Require Touch ID to connect and to show the password")
        requireAuthCheckbox.target = self
        requireAuthCheckbox.action = #selector(requireAuthChanged)
        requireAuthCheckbox.translatesAutoresizingMaskIntoConstraints = false
        requireAuthCheckbox.setAccessibilityIdentifier("connections.requireAuth")
        requireAuthCheckbox.toolTip = String(localized:
            "Asks for Touch ID, an Apple Watch or your login password. The password itself stays in the keychain, where it already was.")

        sslPopup.target = self
        sslPopup.action = #selector(sslPopupChanged)
        sslPopup.addItems(withTitles: ["Prefer", "Require", "Disable"])
        sslPopup.translatesAutoresizingMaskIntoConstraints = false

        defaultSchemaPopup.target = self
        defaultSchemaPopup.action = #selector(defaultSchemaChanged)
        PopupValueMenu.populate(defaultSchemaPopup, sentinel: "Test connection first", values: [])
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


        revertButton.title = "Revert"
        revertButton.bezelStyle = .rounded
        revertButton.target = self
        revertButton.action = #selector(revertChanges)

        saveButton.title = "Save"
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(saveChanges)

        // Test Connection, Revert and Save live in a bar pinned to the bottom
        // of the pane, OUTSIDE the scroll view — the same place, and the same
        // reason, as the sheet's own Done button.
        //
        // Measured: with no SSH section at all this form wants 633 pt of a
        // 508 pt viewport, so inside the scroll view Save sat below the fold on
        // a fresh connection. An action the user must reach to finish the task
        // must never be something they have to find by scrolling.
        let actionSpacer = NSView()
        actionSpacer.translatesAutoresizingMaskIntoConstraints = false
        let actionBar = NSStackView(views: [testButton, testSpinner, testStatusLabel,
                                            actionSpacer, revertButton, saveButton])
        actionBar.orientation = .horizontal
        actionBar.alignment = .centerY
        actionBar.spacing = 10
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        // The status text yields first: the three buttons keep their size and
        // the message truncates, with the whole of it in the tooltip.
        actionBar.setHuggingPriority(.defaultLow, for: .horizontal)
        let actionSeparator = NSBox.separator()
        actionSeparator.translatesAutoresizingMaskIntoConstraints = false

        let serverSection = section(title: "Server", rows: [
            row(label: "Name", field: nameField),
            row(label: "Host", field: hostField, badge: hostBadge),
            row(label: "Port", field: portField, fieldFixedWidth: L.portWidth),
        ])
        passwordFromLinkLabel.stringValue = String(localized: "Password taken from the link.")
        passwordFromLinkLabel.font = .systemFont(ofSize: 11)
        passwordFromLinkLabel.textColor = .secondaryLabelColor
        passwordFromLinkLabel.setAccessibilityIdentifier("connections.passwordFromLink")
        let passwordNoteRow = noteRow(passwordFromLinkLabel)
        passwordNoteRow.isHidden = true
        passwordFromLinkRow = passwordNoteRow

        passwordAuthLabel.font = .systemFont(ofSize: 11)
        passwordAuthLabel.textColor = .secondaryLabelColor
        passwordAuthLabel.setAccessibilityIdentifier("connections.passwordAuthNote")
        let authNoteRow = noteRow(passwordAuthLabel)
        authNoteRow.isHidden = true
        passwordAuthRow = authNoteRow

        // The field and its Show button travel together, so the badge still owns
        // the row's trailing edge and the row keeps ONE width whichever state
        // the gate is in.
        let passwordControls = NSStackView(views: [passwordField, showPasswordButton])
        passwordControls.orientation = .horizontal
        passwordControls.alignment = .centerY
        passwordControls.distribution = .fill
        passwordControls.spacing = 8
        passwordControls.translatesAutoresizingMaskIntoConstraints = false
        passwordField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let authSection = section(title: "Authentication", rows: [
            row(label: "Username", field: usernameField, badge: usernameBadge),
            row(label: "Password", field: passwordControls, badge: passwordBadge),
            passwordNoteRow,
            authNoteRow,
            row(label: "SSL Mode", control: sslPopup),
            row(label: "", control: requireAuthCheckbox),
        ])
        // `row` linked the badge to the stack it was handed. The warning is
        // about the FIELD, so say so — a screen reader on the badge must land
        // on the password field, not on its container.
        passwordBadge.link(to: passwordField)
        let sshSection = buildSshSection()

        let dbSection = section(title: "Database", rows: [
            row(label: "Database", field: databaseField, badge: databaseBadge),
            row(label: "Default Schema", control: defaultSchemaPopup),
        ])

        let main = NSStackView(views: [header, serverSection, authSection, sshSection, dbSection])
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = L.sectionSpacing
        main.translatesAutoresizingMaskIntoConstraints = false
        main.edgeInsets = NSEdgeInsets(top: L.formInsetTop, left: L.formInsetH,
                                       bottom: L.formInsetBottom, right: L.formInsetH)
        // Nothing below the form now competes for the pane's height, so the
        // stack keeps its content height and the scroll view supplies the rest.
        main.setHuggingPriority(.required, for: .vertical)

        // The form scrolls.
        //
        // With the SSH Tunnel section open the form is taller than the sheet,
        // and the section's height changes with its checkbox — so a taller
        // window would be wrong for the common case (no tunnel) and a fixed
        // one would squash the rows. A scroll view is the only answer that is
        // right in both states. The document view is FLIPPED, or a form
        // shorter than the sheet would sit against its bottom edge.
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = ConnectionsFormDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(main)
        scroll.documentView = document
        container.addSubview(scroll)
        container.addSubview(actionSeparator)
        container.addSubview(actionBar)
        detailScrollView = scroll

        NSLayoutConstraint.activate([
            actionBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: L.formInsetH),
            actionBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -L.formInsetH),
            actionBar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -L.actionBarInsetBottom),

            actionSeparator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            actionSeparator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            actionSeparator.bottomAnchor.constraint(equalTo: actionBar.topAnchor,
                                                    constant: -L.actionBarInsetTop),

            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: actionSeparator.topAnchor),
            // The document takes the clip's width, so nothing ever scrolls
            // sideways and the rows keep the width they had before.
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            main.topAnchor.constraint(equalTo: document.topAnchor),
            main.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            main.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            main.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            header.widthAnchor.constraint(equalTo: main.widthAnchor, constant: -L.formInsetH * 2),
            serverSection.widthAnchor.constraint(equalTo: main.widthAnchor, constant: -L.formInsetH * 2),
            authSection.widthAnchor.constraint(equalTo: main.widthAnchor, constant: -L.formInsetH * 2),
            sshSection.widthAnchor.constraint(equalTo: main.widthAnchor, constant: -L.formInsetH * 2),
            dbSection.widthAnchor.constraint(equalTo: main.widthAnchor, constant: -L.formInsetH * 2),
        ])
    }

    // MARK: - SSH tunnel section

    /// The SSH Tunnel section, between Authentication and Database.
    ///
    /// D6 puts it there because a tunnel is part of HOW the app reaches the
    /// server, like the credentials above it, and before the database it
    /// finally opens.
    private func buildSshSection() -> NSView {
        sshEnabledCheckbox.setButtonType(.switch)
        sshEnabledCheckbox.title = String(localized: "Connect through an SSH tunnel")
        sshEnabledCheckbox.target = self
        sshEnabledCheckbox.action = #selector(sshEnabledChanged)
        sshEnabledCheckbox.translatesAutoresizingMaskIntoConstraints = false
        sshEnabledCheckbox.setAccessibilityIdentifier("connections.ssh.enabled")

        for field in [sshHostField, sshPortField, sshUserField, sshKeyPathField] {
            configureField(field)
        }
        configureField(sshSecretField)
        sshHostField.placeholderString = String(localized: "bastion.example.com or a Host from ~/.ssh/config")
        sshHostField.setAccessibilityIdentifier("connections.ssh.host")
        sshPortField.placeholderString = "22"
        sshPortField.setAccessibilityIdentifier("connections.ssh.port")
        sshUserField.placeholderString = String(localized: "From ~/.ssh/config")
        sshUserField.setAccessibilityIdentifier("connections.ssh.user")
        sshKeyPathField.placeholderString = "~/.ssh/id_ed25519"
        sshKeyPathField.setAccessibilityIdentifier("connections.ssh.keyPath")
        sshSecretField.setAccessibilityIdentifier("connections.ssh.secret")

        sshAuthPopup.removeAllItems()
        sshAuthPopup.addItems(withTitles: [
            String(localized: "SSH agent"),
            String(localized: "Private key file"),
            String(localized: "Password"),
        ])
        sshAuthPopup.target = self
        sshAuthPopup.action = #selector(sshAuthChanged)
        sshAuthPopup.translatesAutoresizingMaskIntoConstraints = false
        sshAuthPopup.setAccessibilityIdentifier("connections.ssh.auth")

        sshChooseKeyButton.title = String(localized: "Choose…")
        sshChooseKeyButton.bezelStyle = .rounded
        sshChooseKeyButton.controlSize = .regular
        sshChooseKeyButton.target = self
        sshChooseKeyButton.action = #selector(chooseSshKeyFile)
        sshChooseKeyButton.setAccessibilityIdentifier("connections.ssh.chooseKey")
        sshChooseKeyButton.setContentHuggingPriority(.required, for: .horizontal)
        sshChooseKeyButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        // The same gate as the database password (D6): one authentication
        // reveals both of a record's secrets, so this button runs the same
        // action rather than a second prompt of its own.
        sshShowSecretButton.title = String(localized: "Show")
        sshShowSecretButton.bezelStyle = .rounded
        sshShowSecretButton.controlSize = .regular
        sshShowSecretButton.target = self
        sshShowSecretButton.action = #selector(revealPassword)
        sshShowSecretButton.toolTip = String(localized: "Authenticate to show the stored secret.")
        sshShowSecretButton.setAccessibilityIdentifier("connections.ssh.showSecret")
        sshShowSecretButton.setContentHuggingPriority(.required, for: .horizontal)
        sshShowSecretButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        sshShowSecretButton.isHidden = true

        sshAcceptNewHostKeysCheckbox.setButtonType(.switch)
        sshAcceptNewHostKeysCheckbox.title = String(localized: "Accept new host keys")
        sshAcceptNewHostKeysCheckbox.target = self
        sshAcceptNewHostKeysCheckbox.action = #selector(fieldEdited)
        sshAcceptNewHostKeysCheckbox.translatesAutoresizingMaskIntoConstraints = false
        sshAcceptNewHostKeysCheckbox.setAccessibilityIdentifier("connections.ssh.acceptNewHostKeys")

        let keyControls = NSStackView(views: [sshKeyPathField, sshChooseKeyButton])
        keyControls.orientation = .horizontal
        keyControls.alignment = .centerY
        keyControls.distribution = .fill
        keyControls.spacing = 8
        keyControls.translatesAutoresizingMaskIntoConstraints = false
        sshKeyPathField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let secretControls = NSStackView(views: [sshSecretField, sshShowSecretButton])
        secretControls.orientation = .horizontal
        secretControls.alignment = .centerY
        secretControls.distribution = .fill
        secretControls.spacing = 8
        secretControls.translatesAutoresizingMaskIntoConstraints = false
        sshSecretField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let hostRow = row(label: String(localized: "SSH Host"), field: sshHostField, badge: sshHostBadge)
        let portRow = row(label: String(localized: "SSH Port"), field: sshPortField,
                          fieldFixedWidth: L.portWidth)
        let userRow = row(label: String(localized: "SSH User"), field: sshUserField, badge: sshUserBadge)
        let authRow = row(label: String(localized: "Authentication"), control: sshAuthPopup)
        let keyRow = row(label: String(localized: "Key File"), field: keyControls)
        sshSecretLabel.alignment = .right
        sshSecretLabel.font = .systemFont(ofSize: 13)
        sshSecretLabel.textColor = .labelColor
        let secretRow = row(labelView: sshSecretLabel, field: secretControls)
        let acceptRow = row(label: "", control: sshAcceptNewHostKeysCheckbox)
        let acceptNote = noteRow(caption(String(localized:
            "Records an unknown server key on the first connection. A changed key is still refused.")))
        let configNote = noteRow(caption(String(localized:
            "Pharos runs the system ssh, so Host aliases, ProxyJump and IdentityAgent from ~/.ssh/config apply.")))

        sshKeyPathRow = keyRow
        sshSecretRow = secretRow
        sshRows = [hostRow, portRow, userRow, authRow, keyRow, secretRow,
                   acceptRow, acceptNote, configNote]

        let enabledRow = row(label: "", control: sshEnabledCheckbox)
        return section(title: String(localized: "SSH Tunnel"), rows: [enabledRow] + sshRows)
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// Show or hide every SSH row for the current checkbox and pop-up.
    ///
    /// One function, called from `populate`, from the checkbox and from the
    /// pop-up, so the three routes into this state cannot disagree.
    private func applySshRowVisibility() {
        let rules = SshTunnelForm.visibility(enabled: sshEnabledCheckbox.state == .on,
                                             auth: sshAuthMethodForPopup())
        for view in sshRows { view.isHidden = !rules.tunnelRows }
        sshKeyPathRow?.isHidden = !rules.keyFileRow
        sshSecretRow?.isHidden = !rules.secretRow
        sshSecretLabel.stringValue = rules.secretLabel
    }

    private func sshAuthMethodForPopup() -> SshAuthMethod {
        switch sshAuthPopup.indexOfSelectedItem {
        case 1: return .keyFile
        case 2: return .password
        default: return .agent
        }
    }

    private func selectSshAuthPopup(_ method: SshAuthMethod) {
        switch method {
        case .agent:    sshAuthPopup.selectItem(at: 0)
        case .keyFile:  sshAuthPopup.selectItem(at: 1)
        case .password: sshAuthPopup.selectItem(at: 2)
        }
    }

    @objc private func sshEnabledChanged() {
        applySshRowVisibility()
        syncFormIntoDraft()
        applyPasswordGateState(storedPassword: draft?.password ?? "")
    }

    @objc private func sshAuthChanged() {
        applySshRowVisibility()
        syncFormIntoDraft()
        applyPasswordGateState(storedPassword: draft?.password ?? "")
    }

    @objc private func chooseSshKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // Private keys have no extension and start in a hidden folder, so the
        // panel has to show hidden files or ~/.ssh cannot be reached at all.
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose the private key file for this tunnel.")
        panel.beginSheetModal(for: view.window ?? NSApp.keyWindow ?? NSWindow()) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.sshKeyPathField.stringValue = url.path
            self.syncFormIntoDraft()
        }
    }

    /// The tunnel the form currently describes, or `nil` when the checkbox is
    /// off.
    ///
    /// The secret follows the same rule as the password: a MASKED field holds
    /// the mask, not a secret, so the draft's stored value is kept instead.
    private func sshTunnelFromForm(existing: SshTunnelConfig?) -> SshTunnelConfig? {
        SshTunnelForm.tunnel(
            from: SshTunnelForm.Fields(
                enabled: sshEnabledCheckbox.state == .on,
                host: sshHostField.stringValue,
                port: sshPortField.stringValue,
                user: sshUserField.stringValue,
                auth: sshAuthMethodForPopup(),
                keyPath: sshKeyPathField.stringValue,
                secret: sshSecretField.stringValue,
                acceptNewHostKeys: sshAcceptNewHostKeysCheckbox.state == .on,
                secretRevealed: passwordRevealed),
            existing: existing)
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

    /// Builds one label-plus-field row. `badge`, when given, stands at the
    /// trailing edge and discloses an invisible character in a field whose text
    /// must never be altered.
    private func row(label: String, field: NSView, fieldFixedWidth: CGFloat? = nil,
                     badge: HostileTextBadge? = nil) -> NSView {
        let labelView = NSTextField(labelWithString: label)
        labelView.alignment = .right
        labelView.font = .systemFont(ofSize: 13)
        labelView.textColor = .labelColor
        return row(labelView: labelView, field: field,
                   fieldFixedWidth: fieldFixedWidth, badge: badge)
    }

    /// The same row, for a caller that OWNS its label and needs to change the
    /// text later — the SSH secret row, whose label follows the authentication
    /// pop-up.
    private func row(labelView: NSTextField, field: NSView, fieldFixedWidth: CGFloat? = nil,
                     badge: HostileTextBadge? = nil) -> NSView {
        labelView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(labelView)
        field.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(field)
        // The badge announces the field it warns about, and the field the badge.
        badge?.link(to: field)

        var constraints: [NSLayoutConstraint] = [
            labelView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            labelView.widthAnchor.constraint(equalToConstant: L.labelColumnWidth),
            labelView.firstBaselineAnchor.constraint(equalTo: field.firstBaselineAnchor),

            field.leadingAnchor.constraint(equalTo: labelView.trailingAnchor, constant: 10),
            field.topAnchor.constraint(equalTo: container.topAnchor),
            field.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ]

        // The badge owns the container's trailing edge, and the field stops
        // short of it. A hidden view's constraints still apply, so the badge
        // holds its slot whether it is shown or not: the field keeps ONE width
        // and the row never reflows when a badge is raised.
        if let badge {
            container.addSubview(badge)
            constraints.append(badge.trailingAnchor.constraint(equalTo: container.trailingAnchor))
            constraints.append(badge.centerYAnchor.constraint(equalTo: field.centerYAnchor))
        }

        if let w = fieldFixedWidth {
            constraints.append(field.widthAnchor.constraint(equalToConstant: w))
            // A fixed-width field cannot stretch, so the trailing edge is only
            // a limit — an equality here would fight the fixed width.
            if let badge {
                constraints.append(field.trailingAnchor.constraint(
                    lessThanOrEqualTo: badge.leadingAnchor, constant: -L.badgeGap))
            } else {
                constraints.append(field.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor))
            }
        } else {
            // An equality, not a limit: this pin is what makes the field fill
            // the row, so a `lessThanOrEqualTo` alone would leave the width
            // undetermined between its minimum and the trailing edge.
            if let badge {
                constraints.append(field.trailingAnchor.constraint(
                    equalTo: badge.leadingAnchor, constant: -L.badgeGap))
            } else {
                constraints.append(field.trailingAnchor.constraint(equalTo: container.trailingAnchor))
            }
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
        // Here, not at the call site. A control that still translates its
        // autoresizing mask brings constraints from its ZERO frame, which
        // outrank the ones below: the control renders as a tiny square at the
        // container's origin with its title clipped away, and it cannot be
        // clicked. Every earlier caller happened to set this itself, so the
        // helper's dependence on them was invisible until one did not.
        control.translatesAutoresizingMaskIntoConstraints = false
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

    /// A caption row: nothing in the label column, the text in the field
    /// column, so it reads as a footnote to the row above it.
    private func noteRow(_ label: NSTextField) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                           constant: L.labelColumnWidth + 10),
            label.topAnchor.constraint(equalTo: container.topAnchor),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
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

        // An UNSAVED edit to the record on screen outlives a republish.
        //
        // `$connections` fires for every connection write anywhere in the app —
        // the editor's "Set as Default Schema" (EditorPaneVC), a delete, a drag
        // reorder — and reloading the form here reset `draft` and
        // `draftBaseline` from the SAVED record. The user's edit vanished and
        // Save went grey with the form still showing their typing, which is
        // exactly the "Save is greyed out unless I change some other setting"
        // report: only a further edit could make the draft differ again.
        //
        // The list still updates above; only the form is left alone.
        if isDirty, let id = draft?.id, connections.contains(where: { $0.id == id }) {
            updateButtonStates()
            return
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
        // The selection publisher is delivered on the NEXT run loop turn, so it
        // can arrive when the form ALREADY shows the record that was selected:
        // `beginNewConnection` selects a new stub and loads it in one turn.
        // The prompt below guards a move AWAY from an edited record; arriving
        // where the form already is, is not that, and prompting there would ask
        // the user to save the record they just asked for.
        if let selected = listModel.selectedId, selected == draft?.id { return }

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
        alert.messageText = DestructiveConfirmationText.unsavedChangesConfirmTitle(name: name)
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
            showPasswordFromLinkNote(false)
            updateButtonStates()
        }
    }

    private func loadSelectionIntoForm() {
        guard let id = listModel.selectedId,
              let config = connections.first(where: { $0.id == id }) else { return }
        draft = config
        // A stub has never been stored, so its baseline is an EMPTY record:
        // every field on screen is already a change, Save is live from the
        // start, and leaving the stub counts as discarding unsaved work. The
        // rule lives here rather than at the `+`/link entry points because the
        // selection publisher re-loads the form a turn later and would
        // otherwise overwrite a baseline set there.
        draftBaseline = pendingStubIds.contains(id)
            ? ConnectionConfig(id: id, name: "", host: "", port: config.port,
                               database: "", username: "")
            : config
        listModel.dirtyConnectionId = nil
        showPasswordFromLinkNote(passwordFromLinkId == id)

        // A display label, so it is ESCAPED rather than sanitised — matching the
        // list row and the delete confirmation for the same name. It is also the
        // largest rendering of the name in this view, so it is the last place
        // that should be able to lie. TRIMMED as well, because the save path
        // trims: an edge space here is a record written before it did.
        titleField.stringValue = DisplayEscape.escapedTrimmed(config.name)
            .ifEmpty("Untitled Connection")
        nameField.stringValue = AuthoredLabelSanitizer.sanitized(config.name)
        hostField.stringValue = config.host
        portField.stringValue = String(config.port)
        databaseField.stringValue = config.database
        usernameField.stringValue = config.username
        // A gated record is masked on EVERY selection, including a return to a
        // record revealed a moment ago: the gate is about walking up to the
        // window, so it has to re-arm when the form moves on.
        requireAuthCheckbox.state = config.requiresAuthentication ? .on : .off
        // The tunnel, before the gate is applied: `applyPasswordGateState`
        // masks the secret field, so the fields must hold the record first.
        let tunnel = config.sshTunnel
        sshEnabledCheckbox.state = tunnel != nil ? .on : .off
        sshHostField.stringValue = tunnel?.host ?? ""
        sshPortField.stringValue = String(tunnel?.port ?? 22)
        sshUserField.stringValue = tunnel?.user ?? ""
        selectSshAuthPopup(tunnel?.auth ?? .agent)
        sshKeyPathField.stringValue = tunnel?.keyPath ?? ""
        sshAcceptNewHostKeysCheckbox.state = (tunnel?.acceptNewHostKeys ?? false) ? .on : .off
        applySshRowVisibility()
        passwordRevealed = !config.requiresAuthentication
        showPasswordAuthNote("")
        // The field is reloaded here whatever state it was in — the guard inside
        // `applyPasswordGateState` protects TYPED edits, and a selection change
        // has none to protect.
        if passwordRevealed {
            passwordField.stringValue = config.password
            sshSecretField.stringValue = tunnel?.secret ?? ""
        }
        applyPasswordGateState(storedPassword: config.password)
        switch config.sslMode {
        case .prefer:  sslPopup.selectItem(at: 0)
        case .require: sslPopup.selectItem(at: 1)
        case .disable: sslPopup.selectItem(at: 2)
        }
        if let fetched = liveOrFetchedSchemas(for: config) {
            // Already read this session, for these settings: keep the real list
            // and the user's pick.
            showSchemaChoices(fetched, selecting: draft?.defaultSchema)
        } else if canUseLiveSchemas(for: config) {
            // Connected, and the form still describes that server — read the
            // list straight off the open connection instead of making the user
            // press Test Connection.
            PopupValueMenu.populate(defaultSchemaPopup, sentinel: nil,
                                    values: [config.defaultSchema ?? ""].filter { !$0.isEmpty })
            defaultSchemaPopup.isEnabled = false
            defaultSchemaPopup.toolTip = String(localized: "Reading schemas…")
            loadLiveSchemas(for: config.id)
        } else if let saved = config.defaultSchema, !saved.isEmpty {
            // Not tested yet: show the one saved schema and nothing else, since
            // there is no list to pick from until the connection is tested.
            PopupValueMenu.populate(defaultSchemaPopup, sentinel: nil, values: [saved])
            defaultSchemaPopup.isEnabled = false
            defaultSchemaPopup.toolTip = "Test the connection to refresh the schema list."
        } else {
            PopupValueMenu.populate(defaultSchemaPopup, sentinel: "Test connection first", values: [])
            defaultSchemaPopup.isEnabled = false
            defaultSchemaPopup.toolTip = nil
        }

        setTestStatus("")
        testSpinner.isHidden = true
        testSpinner.stopAnimation(nil)

        // The text delegate only fires on edits, so a SAVED value that already
        // carries an invisible character would disclose nothing until the user
        // typed. Disclose it on open instead.
        refreshHostileTextBadges()
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
            statusBadge.toolTip = nil
            return
        }
        // The badge says THAT the last attempt failed; the tooltip says why —
        // including a refused Touch ID gate, which otherwise leaves the user
        // with a red badge and no sentence.
        statusBadge.toolTip = stateManager.connectionError(for: id)
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
        // NOT `.white`: on a `controlAccentColor` bezel the system's own
        // label colour is the one that stays legible when the user picks a
        // light accent, or turns Increase Contrast on.
        saveButton.contentTintColor = canSave ? .alternateSelectedControlTextColor : nil
        revertButton.isEnabled = isDirty
        listModel.dirtyConnectionId = isDirty ? draft?.id : nil
    }

    /// The Test Connection result line.
    ///
    /// The label shares one row with three buttons now, so a long message —
    /// and the SSH ones are long by design, because they tell the user what to
    /// do next — truncates. The tooltip carries the whole of it, so nothing is
    /// lost; without this the host-key sentence would end at "Turn on".
    private func setTestStatus(_ text: String) {
        testStatusLabel.stringValue = text
        testStatusLabel.toolTip = text.isEmpty ? nil : text
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

    /// Ticking the box gates the record from the next save on. Unticking it does
    /// NOT reveal a password the gate is currently holding — that still needs
    /// the Show button — so a masked field stays masked either way, and a record
    /// whose password is already on screen keeps it until the selection changes.
    @objc private func requireAuthChanged() {
        syncFormIntoDraft()
        applyPasswordGateState(storedPassword: draft?.password ?? "")
    }

    /// Runs the gate for the Show button. On success the stored password takes
    /// the field and the field becomes editable; on cancel or refusal nothing
    /// about the field changes and the reason appears as a caption.
    @objc private func revealPassword() {
        let selectionAtRequest = listModel.selectedId
        let name = DisplayEscape.escapedTrimmed(draft?.name ?? "").ifEmpty(String(localized: "this connection"))
        showPasswordButton.isEnabled = false
        Task { @MainActor in
            let outcome = await DeviceOwnerGate.authenticate(
                reason: String(localized: "show the password for \(name)"))
            self.showPasswordButton.isEnabled = true
            // The prompt is modal to the app, not to this form. If the selection
            // moved while it was up, the answer belongs to a record that is no
            // longer on screen.
            guard self.listModel.selectedId == selectionAtRequest else { return }
            switch outcome {
            case .authenticated:
                self.passwordRevealed = true
                self.passwordAuthLabel.stringValue = ""
                self.applyPasswordGateState(storedPassword: self.draft?.password ?? "")
            case .cancelled:
                self.showPasswordAuthNote(String(localized: "Cancelled. The password stays hidden."))
            case .failed(let reason):
                self.showPasswordAuthNote(reason)
                Log.ui.error("Password reveal refused: \(reason, privacy: .public)")
            }
        }
    }

    /// Puts the password field into the state `passwordRevealed` calls for: the
    /// stored password and an editable field, or the mask and a Show button.
    private func applyPasswordGateState(storedPassword: String) {
        if passwordRevealed {
            // Assign only when the field is coming OUT of the mask — an
            // already-revealed field may hold edits the user has typed. The
            // test is the field's own editability, not its text: a user whose
            // password IS the mask string would fail a text comparison.
            if !passwordField.isEditable {
                passwordField.stringValue = storedPassword
            }
            passwordField.isEditable = true
            passwordField.isSelectable = true
            showPasswordButton.isHidden = true
        } else {
            passwordField.stringValue = Self.passwordMask
            passwordField.isEditable = false
            passwordField.isSelectable = false
            showPasswordButton.isHidden = false
        }
        // D6: the gate covers EVERY secret the record owns, so the SSH secret
        // is masked by the same flag and revealed by the same authentication.
        // Leaving it readable would make the gate worthless for a tunnel whose
        // password opens a shell on the bastion.
        applySshSecretGateState(storedSecret: draft?.sshTunnel?.secret ?? "")
        refreshHostileTextBadges()
    }

    private func applySshSecretGateState(storedSecret: String) {
        if passwordRevealed {
            if !sshSecretField.isEditable {
                sshSecretField.stringValue = storedSecret
            }
            sshSecretField.isEditable = true
            sshSecretField.isSelectable = true
            sshShowSecretButton.isHidden = true
        } else {
            sshSecretField.stringValue = Self.passwordMask
            sshSecretField.isEditable = false
            sshSecretField.isSelectable = false
            sshShowSecretButton.isHidden = false
        }
    }

    private func showPasswordAuthNote(_ text: String) {
        passwordAuthLabel.stringValue = text
        passwordAuthRow?.isHidden = text.isEmpty
    }
    @objc private func defaultSchemaChanged() { syncFormIntoDraft() }

    private func syncFormIntoDraft() {
        guard var d = draft else { return }
        d.name = nameField.stringValue
        d.host = hostField.stringValue
        d.port = UInt16(portField.stringValue) ?? d.port
        d.database = databaseField.stringValue
        d.username = usernameField.stringValue
        // A masked field holds the MASK, not a password. Reading it here is
        // what would write "••••••••" over the stored password on the next
        // Save, so the draft keeps the value it already has.
        if passwordRevealed {
            d.password = passwordField.stringValue
        }
        d.requiresAuthentication = requireAuthCheckbox.state == .on
        d.sshTunnel = sshTunnelFromForm(existing: d.sshTunnel)
        switch sslPopup.indexOfSelectedItem {
        case 1: d.sslMode = .require
        case 2: d.sslMode = .disable
        default: d.sslMode = .prefer
        }
        // Only once a list has actually been fetched — until then the popup
        // holds a placeholder, not a choice, and must not write over the saved
        // value. `selectedValue` returns nil for the "None" sentinel, and nil
        // is a real answer here: it is how the default schema gets CLEARED.
        // The old guard was `indexOfSelectedItem > 0`, which silently ignored
        // row 0, so "None" could never be chosen and the draft never changed.
        // Only while the picker holds a list read for THESE settings. A stale
        // list describes a different server, and a placeholder is not a choice
        // at all — either would write over the saved value. `selectedValue`
        // returns nil for the "None" sentinel, and nil is a real answer here:
        // it is how the default schema gets CLEARED. The old guard was
        // `indexOfSelectedItem > 0`, which silently ignored row 0, so "None"
        // could never be chosen and the draft never changed.
        if liveOrFetchedSchemas(for: d) != nil, defaultSchemaPopup.isEnabled {
            d.defaultSchema = PopupValueMenu.selectedValue(in: defaultSchemaPopup)
        }
        draft = d

        // An edit to the host, port, database, user or SSL mode has just made
        // any fetched list describe a different server. Take the picker back to
        // asking for a test rather than letting it offer the old server's
        // schemas as if they were this one's.
        if defaultSchemaPopup.isEnabled, liveOrFetchedSchemas(for: d) == nil {
            PopupValueMenu.populate(defaultSchemaPopup,
                                    sentinel: String(localized: "Test connection first"),
                                    values: [])
            defaultSchemaPopup.isEnabled = false
            defaultSchemaPopup.toolTip = nil
        }

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
        guard var d = draft, isDraftValid() else { NSSound.beep(); return }

        // The name is an AUTHORED LABEL, so the store receives it COMMITTED —
        // sanitised and trimmed — the same producer a tag name and a workspace
        // name already go through. Two reasons it has to happen here and not
        // only in the field:
        //
        //  - `loadSelectionIntoForm` puts the RAW stored name in the draft while
        //    showing the sanitised one in the field, so saving an untouched
        //    legacy record would otherwise write its hostile name straight back.
        //  - Nothing trimmed until now, so `"prod "` was a stored name distinct
        //    from `"prod"` while reading identically on every surface.
        //
        // Host, database, username and password are round-trip DATA — they must
        // reach libpq byte for byte — so they are never altered.
        d.name = AuthoredLabelSanitizer.committed(d.name)

        // `isDraftValid` trims with `.whitespaces` only, so a name of nothing
        // but a bidi override passes it and commits to empty.
        guard !d.name.isEmpty else { NSSound.beep(); return }

        // The draft, the baseline and the field all take the committed name, so
        // what is on screen is what was saved and the view is not left dirty.
        draft = d
        nameField.stringValue = d.name
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
        setTestStatus(String(localized: "Testing…"))
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
                        self.setTestStatus("Connected\(ms)")
                        self.testStatusLabel.textColor = .systemGreen
                        self.populateDefaultSchemas(using: d)
                    } else {
                        self.setTestStatus(DisplayEscape.escaped(result.error ?? "Failed"))
                        self.testStatusLabel.textColor = .systemRed
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.testSpinner.stopAnimation(nil)
                    self.testSpinner.isHidden = true
                    self.testButton.isEnabled = true
                    self.setTestStatus(DisplayEscape.escaped(error.localizedDescription))
                    self.testStatusLabel.textColor = .systemRed
                }
            }
        }
    }

    /// Everything about a record that decides WHICH server it reaches. The
    /// name, the colour and the default schema itself are deliberately absent:
    /// changing those does not make a fetched schema list wrong.
    private static func connectionFingerprint(_ c: ConnectionConfig) -> String {
        "\(c.host):\(c.port)/\(c.database)@\(c.username)#\(c.sslMode.rawValue)#\(c.requiresAuthentication)#\(tunnelFingerprint(c.sshTunnel))"
    }

    /// The tunnel's part of the fingerprint. Everything here changes WHICH
    /// server the connection reaches, so a fetched schema list made before the
    /// change describes a different machine.
    ///
    /// The secret is deliberately absent: a new passphrase for the same key
    /// reaches the same server, and this string is used as a dictionary key,
    /// which is no place for a secret.
    private static func tunnelFingerprint(_ t: SshTunnelConfig?) -> String {
        SshTunnelForm.fingerprint(t)
    }

    /// Whether the picker can be filled from the connection Pharos already has
    /// open, with no "Test Connection" round trip.
    ///
    /// Two conditions, both necessary. The connection has to be CONNECTED — an
    /// open pool is what makes this free — and the form has to still describe
    /// that same server: once the user edits the host, port, database, user or
    /// SSL mode, the open connection is not the one the form is talking about,
    /// and only a test can answer for the new settings.
    private func canUseLiveSchemas(for d: ConnectionConfig) -> Bool {
        guard stateManager.status(for: d.id) == .connected,
              let saved = stateManager.connections.first(where: { $0.id == d.id })
        else { return false }
        return Self.connectionFingerprint(saved) == Self.connectionFingerprint(d)
    }

    /// Fill the picker from the open connection. Cheap: no temporary record, no
    /// second connection, no password.
    private func loadLiveSchemas(for id: String) {
        guard !liveSchemaFetchesInFlight.contains(id) else { return }
        liveSchemaFetchesInFlight.insert(id)
        Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.liveSchemaFetchesInFlight.remove(id) } }
            do {
                let schemas: [SchemaInfo] = try await PharosCore.getSchemas(connectionId: id)
                await MainActor.run { [weak self] in
                    guard let self, let d = self.draft, d.id == id,
                          self.canUseLiveSchemas(for: d) else { return }
                    self.fetchedSchemas[id] = schemas.map(\.name)
                    self.fetchedSchemaFingerprints[id] = Self.connectionFingerprint(d)
                    self.showSchemaChoices(schemas.map(\.name), selecting: d.defaultSchema)
                    self.syncFormIntoDraft()
                }
            } catch {
                Log.ui.error("Failed to read schemas from the open connection: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The fetched list for a record, or nil when there is none or it was read
    /// with different connection settings.
    private func liveOrFetchedSchemas(for d: ConnectionConfig) -> [String]? {
        guard let names = fetchedSchemas[d.id],
              fetchedSchemaFingerprints[d.id] == Self.connectionFingerprint(d)
        else { return nil }
        return names
    }

    /// Show a fetched schema list in the picker. "None" is row 0 and clears
    /// the default schema; it is a real choice, not a placeholder.
    private func showSchemaChoices(_ names: [String], selecting value: String?) {
        PopupValueMenu.populate(defaultSchemaPopup, sentinel: "None", values: names)
        defaultSchemaPopup.isEnabled = true
        defaultSchemaPopup.toolTip = nil
        // By value, not by index: a schema named "None" does not have to be
        // counted around, and a saved schema the server has since dropped
        // simply leaves row 0 ("None") selected.
        PopupValueMenu.selectValue(value, in: defaultSchemaPopup)
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
                    guard let self, let id = self.draft?.id else { return }
                    let names = schemas.map(\.name)
                    self.fetchedSchemas[id] = names
                    self.fetchedSchemaFingerprints[id] = Self.connectionFingerprint(config)
                    self.showSchemaChoices(names, selecting: self.draft?.defaultSchema)
                    // The populate above can MOVE the selection — a saved
                    // schema the server has since dropped lands on "None" —
                    // and a selection the draft does not know about is a
                    // change the Save button has to hear about.
                    self.syncFormIntoDraft()
                }
            } catch {
                Log.ui.error("Failed to fetch schemas for default schema picker: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - +/- Actions

    private func addStub() {
        beginNewConnection(
            prefilled: ConnectionConfig(
                id: UUID().uuidString,
                name: "Untitled",
                host: "localhost",
                port: 5432,
                database: "postgres",
                username: "postgres"
            ),
            passwordFromLink: false
        )
    }

    /// Opens a new, unsaved connection in the form, filled in from `prefilled`,
    /// and selects it. This is the `+` button's path and the `postgres://` link
    /// path both — the only difference between them is where the field values
    /// came from.
    ///
    /// Nothing is written anywhere: the record is a stub in the list until the
    /// user presses Save, which is the only path that reaches SQLite and the
    /// Keychain. `passwordFromLink` raises the note under the password field,
    /// so a password the user did not type is never silent.
    @MainActor
    func beginNewConnection(prefilled: ConnectionConfig, passwordFromLink: Bool) {
        confirmDiscardIfDirty { [weak self] proceed in
            guard let self, proceed else { return }
            let stub = prefilled
            self.passwordFromLinkId = passwordFromLink ? stub.id : nil
            self.pendingStubIds.insert(stub.id)
            self.connections.append(stub)
            self.listModel.selectedIds = [stub.id]
            // Load the form NOW rather than waiting for the selection
            // publisher's next turn, so the fields are filled in before the
            // window comes forward and the name below is there to select.
            self.updateDetailVisibility()
            self.view.window?.makeFirstResponder(self.nameField)
            self.nameField.selectText(nil)
        }
    }

    /// Shows or hides the "password came from the link" caption and its row.
    private func showPasswordFromLinkNote(_ visible: Bool) {
        passwordFromLinkLabel.isHidden = !visible
        passwordFromLinkRow?.isHidden = !visible
    }

    private func deleteSelected(ids: Set<String>) {
        let selected = ids.compactMap { id in connections.first(where: { $0.id == id }) }
        guard !selected.isEmpty else { return }

        let alert = NSAlert()
        if selected.count == 1 {
            // Built by `DestructiveConfirmationText`, never interpolated here:
            // this title gates an irreversible delete, and a bidi override in
            // the name would let it name a different connection than the one
            // about to go.
            alert.messageText = DestructiveConfirmationText
                .deleteConnectionConfirmTitle(name: selected[0].name)
        } else {
            alert.messageText = "Delete \(selected.count) connections?"
        }
        alert.informativeText = selected.count == 1
            ? "This will remove the saved configuration and stored password."
            : "This will remove the saved configurations and stored passwords."
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
    func controlTextDidChange(_ obj: Notification) {
        // The name is an authored label and is sanitised. Host, database, user
        // and password are round-trip DATA — they must reach libpq byte for
        // byte, so they are never altered here. Sanitising runs before the
        // sync, because `syncFormIntoDraft` copies the field straight into the
        // draft.
        if (obj.object as? NSTextField) === nameField {
            nameField.sanitizeAsAuthoredLabel()
        }
        // The note says where the password came from. Once the user types one,
        // it no longer does, so it goes — and it does not come back on a later
        // re-selection of this record.
        if (obj.object as? NSTextField) === passwordField {
            passwordFromLinkId = nil
            showPasswordFromLinkNote(false)
        }
        refreshHostileTextBadges()
        syncFormIntoDraft()
    }

    /// Every round-trip field's badge, refreshed from the current field text.
    private func refreshHostileTextBadges() {
        hostBadge.update(for: hostField.stringValue)
        databaseBadge.update(for: databaseField.stringValue)
        usernameBadge.update(for: usernameField.stringValue)
        sshHostBadge.update(for: sshHostField.stringValue)
        sshUserBadge.update(for: sshUserField.stringValue)
        // A masked field shows the mask, which carries no invisible character
        // and would silence a warning the STORED password has earned. Read the
        // draft instead, so the badge tells the truth in both states.
        passwordBadge.update(for: passwordRevealed ? passwordField.stringValue : (draft?.password ?? ""))
    }
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

// The `ConnectionConfig: Equatable` conformance that drives `isDirty` lives
// beside the type, in `Pharos/Models/Connection.swift`, so a suite that compiles
// the model alone can assert it.

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

// MARK: - Appearance-following background

/// A view whose layer colour is resolved in `updateLayer()` rather than baked
/// into the layer once.
///
/// `NSColor.cgColor` resolves a dynamic colour against whatever appearance is
/// current at the moment it is read — and in `loadView()` that is before the
/// view is in a window at all. Both panes of this window did exactly that, so
/// their backgrounds froze at launch: AppKit's own controls repainted for Dark
/// Mode while the two plates behind them stayed light. That is the "light-grey
/// chrome with dark fields" the user saw, and switching the app's Light/Dark
/// preference (`ThemeApplier`) could not fix it either.
///
/// The rest of the app already does this properly — `VariableListView`,
/// `ResultTabsPanelVC`, `FilterableHeaderView` all resolve inside
/// `updateLayer()`. This is the same pattern, with the colour injected.
final class AppearanceBackgroundView: NSView {

    /// Read at draw time, never cached.
    var colorProvider: () -> NSColor = { .windowBackgroundColor } {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = colorProvider().cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The connections form's document view, whose origin is the TOP left.
///
/// An `NSScrollView` puts an unflipped document view against the BOTTOM of the
/// clip when the content is shorter than the clip, so a short form — a
/// connection with no tunnel — would sit at the foot of the sheet with empty
/// space above it. Declared here rather than shared, because two other files
/// already declare a private `FlippedView` of their own.
private final class ConnectionsFormDocumentView: NSView {
    override var isFlipped: Bool { true }
}
