import AppKit
import Combine
import os

private extension String {
    /// `self`, or `fallback` when `self` holds nothing. Used where a name is
    /// trimmed for display: the placeholder has to be chosen AFTER the trim,
    /// because a name of nothing but spaces trims away to nothing.
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

// MARK: - View Controller

/// The Connections Manager's content: the shared manager shell
/// (`ManagerSplitViewController`) with every connection in its Glass sidebar
/// (`ConnectionSidebarRows` → `ManagerSidebarVC`) and the chosen record's form
/// in the detail. The form is built from the Settings furniture — a section
/// header and a `SettingsGroupBox` of `SettingsRow`s per section — and Test
/// Connection, Revert and Save sit in a bar under it.
///
/// Hosted by `ConnectionsManagerWindowController`, which closes the window
/// through `confirmClose(in:then:)`.
final class ConnectionsManagerVC: NSViewController {

    // MARK: - State

    private let stateManager = AppStateManager.shared
    private var cancellables = Set<AnyCancellable>()

    /// The list, in order: the saved records, then the stubs not saved yet.
    /// Every change redraws the sidebar.
    private var connections: [ConnectionConfig] = [] {
        didSet { refreshSidebar() }
    }
    /// Records added by + or by a `postgres://` link and never saved.
    private var pendingStubIds: Set<String> = [] {
        didSet { refreshSidebar() }
    }
    private var statuses: [String: ConnectionStatus] = [:] {
        didSet { refreshSidebar() }
    }
    /// The record being edited and not yet saved: its row shows the unsaved
    /// dot.
    private var dirtyConnectionId: String? {
        didSet { if dirtyConnectionId != oldValue { refreshSidebar() } }
    }

    /// The record the form shows: the sidebar's selection. It survives a
    /// filter that hides its row.
    private var selectedId: String? { sidebar.selectedId }

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

    /// The record in the form, as edited. Its NAME is what the sidebar row
    /// shows for it (`refreshSidebar`), so a rename shows in the list as it is
    /// typed while `connections` keeps the stored name — and a Revert or a
    /// Discard needs nothing more than dropping the draft to put it back.
    private var draft: ConnectionConfig? {
        didSet {
            if draft?.id != oldValue?.id || draft?.name != oldValue?.name { refreshSidebar() }
        }
    }
    private var draftBaseline: ConnectionConfig?

    /// The record whose password arrived in a `postgres://` link. The note
    /// under the password field is shown for this record only, and is dropped
    /// the moment the user types a password of their own.
    private var passwordFromLinkId: String?

    private var isDirty: Bool {
        guard let draft, let draftBaseline else { return false }
        return draft != draftBaseline
    }

    // MARK: - Window furniture

    private let sidebar = ManagerSidebarVC(accessibilityLabel: String(localized: "Connections"))
    private let toolbarController = ManagerToolbarController(
        identifier: "PharosConnectionsManagerToolbar",
        addLabel: String(localized: "New Connection"))
    private var splitVC: ManagerSplitViewController?
    /// The detail while a record is selected: the form and its action bar.
    private lazy var formPane = ConnectionsDetailPaneVC(content: buildFormPane())
    /// The detail while nothing is selected.
    private lazy var emptyPane = ConnectionsDetailPaneVC(content: buildEmptyPane())
    private let emptyState = EmptyStateView()

    // MARK: - Form

    private let titleField = NSTextField(labelWithString: String(localized: "Connection"))
    private let statusBadge = StatusBadge()

    private let nameField = NSTextField()
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let databaseField = NSTextField()
    private let usernameField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let sslPopup = NSPopUpButton()
    /// The PEM root certificate for verify-ca / verify-full, with its own
    /// Choose… button. The row is hidden for every other SSL mode.
    private let sslRootCertField = NSTextField()
    private let sslChooseCertButton = NSButton()
    private var sslRootCertRow: SettingsRow?
    /// Session ▸ per-connection: read-only, connect at launch, remember the
    /// password, and the connection's own time zone.
    private let readOnlyCheckbox = NSSwitch()
    private let connectOnLaunchCheckbox = NSSwitch()
    private let sessionTimeZonePopup = NSPopUpButton()
    private let defaultSchemaPopup = NSPopUpButton()
    private var readOnlyRow: SettingsRow?

    /// The engine pop-up (PostgreSQL / DuckDB), and the DuckDB file controls.
    /// The sections and rows are kept so `applyEngineVisibility` can show the
    /// ones the engine uses (`ConnectionFormRules.visibility`).
    private let enginePopup = NSPopUpButton()
    private let duckPathField = NSTextField()
    private let duckChooseButton = NSButton()
    private let duckNewButton = NSButton()
    private let duckRevealButton = NSButton()
    private let duckInMemoryCheckbox = NSSwitch()
    private var serverSectionView: NSView?
    private var authSectionView: NSView?
    private var sshSectionView: NSView?
    private var duckSectionView: NSView?
    private var databaseNameRow: SettingsRow?
    private var timeZoneRow: SettingsRow?

    /// The rows that show a "Required" caption while their field is blank
    /// (`ConnectionFormRules.missingFields`). A row's own caption, if it has
    /// one, stays under the problem (`SettingsRow.captionProblems`).
    private var requiredRows: [ConnectionFormRules.RequiredField: SettingsRow] = [:]
    /// The server's Port row, which says when the field holds no port
    /// (`ConnectionFormRules.portProblem`).
    private var portRow: SettingsRow?

    /// Every group box in the form. A box draws the separators between its
    /// rows, so it is redrawn when a row is shown or hidden.
    private var boxes: [SettingsGroupBox] = []

    // One badge per round-trip field. `nameField` has none — it is an authored
    // label and is sanitised instead — and `portField` has none, because a port
    // is digits.
    private let hostBadge = HostileTextBadge()
    private let databaseBadge = HostileTextBadge()
    private let usernameBadge = HostileTextBadge()
    private let passwordBadge = HostileTextBadge()

    /// The Password row. Its caption carries the two notes about the password:
    /// that it came from a `postgres://` link, and why the Touch ID gate did
    /// not open. Empty, the row closes up to one line.
    private var passwordRow: SettingsRow?
    /// Shown only for a connection opened from a link that carried a password.
    private var showsPasswordFromLinkNote = false
    /// The gate's own reporting — the reason an attempt did not succeed.
    private var passwordAuthNote = ""

    /// The Touch ID gate for this record: ask the device owner to authenticate
    /// before connecting, and before the stored password is shown.
    private let requireAuthCheckbox = NSSwitch()

    /// Whether this record's password is kept in the login keychain. Cleared,
    /// the password is asked for instead — `PasswordPromptSheet` — and held in
    /// memory until Pharos quits.
    private let rememberPasswordCheckbox = NSSwitch()

    /// Stands beside a masked password field. Pressing it runs the gate; the
    /// real password appears only after the device owner authenticates.
    private let showPasswordButton = NSButton()

    /// False while the password field shows the mask rather than the stored
    /// password. It is per SELECTION, not per record: a gated record starts
    /// masked every time it is selected, and revealing it lasts only until the
    /// selection moves.
    ///
    /// The mask is what makes `syncFormIntoDraft` skip the password — otherwise
    /// a Save from the masked form would write the mask over the stored value.
    /// The switch does NOT drive this: turning it off must not reveal a
    /// password the gate is still holding back.
    private var passwordRevealed = true

    /// What a masked password field shows. Eight bullets, so the field's width
    /// carries no hint of the stored password's length.
    private static let passwordMask = "••••••••"

    // MARK: SSH tunnel controls
    //
    // Every row below the switch is hidden while the switch is off, and the
    // key-file and secret rows follow the authentication pop-up.

    private let sshEnabledCheckbox = NSSwitch()
    private let sshHostField = NSTextField()
    private let sshPortField = NSTextField()
    private let sshUserField = NSTextField()
    private let sshAuthPopup = NSPopUpButton()
    private let sshKeyPathField = NSTextField()
    private let sshChooseKeyButton = NSButton()
    private let sshSecretField = NSSecureTextField()
    private let sshShowSecretButton = NSButton()
    private let sshAcceptNewHostKeysCheckbox = NSSwitch()
    private let sshRememberSecretCheckbox = NSSwitch()
    private let sshHostBadge = HostileTextBadge()
    private let sshUserBadge = HostileTextBadge()

    /// The rows that appear only when the tunnel is on, in form order.
    private var sshRows: [NSView] = []
    /// The key-file row, shown only for `.keyFile`.
    private var sshKeyPathRow: SettingsRow?
    /// The secret row, shown for `.keyFile` and `.password`. Its title follows
    /// the pop-up: a key file takes a PASSPHRASE, a password mode takes a
    /// PASSWORD, and calling both the same thing would be wrong in one of the
    /// two.
    private var sshSecretRow: SettingsRow?
    private var sshRememberSecretRow: SettingsRow?
    /// Its caption says why Save is off while the port is not a port.
    private var sshPortRow: SettingsRow?

    private let testButton = NSButton()
    private let testStatusLabel = NSTextField(labelWithString: "")
    private let testSpinner = NSProgressIndicator()

    private let revertButton = NSButton()
    private let saveButton = NSButton()

    private enum L {
        /// The narrowest the form may get: with the sidebar at its widest
        /// (320) this is the window's minimum width (820).
        static let detailMinimum: CGFloat = 500
        /// Every text field and pop-up is this wide, so the controls form one
        /// column down the form: the same leading edge and the same trailing
        /// edge in every box.
        static let controlWidth: CGFloat = 320
        static let portWidth: CGFloat = 90
        static let badgeGap: CGFloat = 6
        /// The gap under the pinned action bar, and above its separator.
        static let actionBarInsetBottom: CGFloat = 16
        static let actionBarInsetTop: CGFloat = 14
    }

    // MARK: - Lifecycle

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: ConnectionsManagerWindowController.defaultSize))
        view = root

        // Built now, so every control and row exists before the first record
        // is loaded into it.
        _ = formPane

        let split = ManagerSplitViewController(sidebar: sidebar, detail: emptyPane,
                                               autosaveName: "PharosConnectionsManagerSplit",
                                               detailMinimum: L.detailMinimum)
        split.toolbarController = toolbarController
        addChild(split)
        split.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(split.view)
        NSLayoutConstraint.activate([
            split.view.topAnchor.constraint(equalTo: root.topAnchor),
            split.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        splitVC = split
    }

    /// Give `window` the manager toolbar (+ and the filter field), once.
    func installToolbarIfNeeded(on window: NSWindow) {
        _ = view
        splitVC?.installToolbarIfNeeded(on: window)
    }

    /// Whether the window may close now. With unsaved edits it asks — Save,
    /// Discard or Cancel — on a sheet and returns false; `close` runs once the
    /// edits are saved or discarded. A Save the form cannot make (a required
    /// field is blank, the SSH port is not a port) keeps the window open.
    func confirmClose(in window: NSWindow, then close: @escaping () -> Void) -> Bool {
        guard isDirty else { return true }
        // A second ⌘W while the question is up must not queue another.
        guard window.attachedSheet == nil else { return false }
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
                guard self.saveChangesInternal() else { return }
            case .alertSecondButtonReturn:
                self.revertChanges()
            default:
                return
            }
            // The next turn: the sheet is still being taken down in this one.
            DispatchQueue.main.async(execute: close)
        }
        return false
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        sidebar.onSelect = { [weak self] _ in
            // The next turn, as the old list's selection publisher delivered
            // it: the unsaved-work prompt is modal, and the table reports a
            // click from inside its own mouse-down.
            DispatchQueue.main.async { [weak self] in self?.handleSelectionChange() }
        }
        sidebar.onDelete = { [weak self] ids in self?.deleteSelected(ids: Set(ids)) }
        sidebar.onMove = { [weak self] from, to in
            self?.handleMove(from: IndexSet(integer: from), to: to)
        }
        toolbarController.onAdd = { [weak self] in self?.addStub() }

        // Seed initial state, then keep in sync with the global state manager.
        // Saved records only: an opened DuckDB file is not a connection until
        // the user saves it (`ConnectionVisibility`).
        connections = ConnectionVisibility.listed(stateManager.connections)
        statuses = stateManager.connectionStatuses
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
                self.statuses = statuses
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

    // MARK: - Sidebar

    /// Hand the sidebar every row. The record in the form shows its EDITED
    /// name, so the row follows the name field as the user types.
    private func refreshSidebar() {
        var shown = connections
        if let draft, let index = shown.firstIndex(where: { $0.id == draft.id }) {
            shown[index].name = draft.name
        }
        sidebar.setItems(ConnectionSidebarRows.items(for: shown, statuses: statuses,
                                                     stubIds: pendingStubIds, dirtyId: dirtyConnectionId))
    }

    // MARK: - Empty detail

    private func buildEmptyPane() -> NSView {
        let root = SettingsPaneSurfaceView()
        root.translatesAutoresizingMaskIntoConstraints = false
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(emptyState)
        NSLayoutConstraint.activate([
            // The safe area: the pane runs under the toolbar, and the message
            // is centred in what the user can see.
            emptyState.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            emptyState.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        emptyState.show(symbol: ConnectionTile.symbolName(of: .server),
                        title: String(localized: "No Connection Selected"),
                        message: String(localized: "Select a connection or click + to add a new one."))
        return root
    }

    // MARK: - Form

    /// The form pane: the furniture form in a scroll view, and the action bar
    /// pinned under it.
    private func buildFormPane() -> NSView {
        titleField.font = .systemFont(ofSize: 22, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusBadge.translatesAutoresizingMaskIntoConstraints = false
        statusBadge.setContentHuggingPriority(.required, for: .horizontal)

        let headerSpacer = NSView()
        headerSpacer.translatesAutoresizingMaskIntoConstraints = false
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [titleField, headerSpacer, statusBadge])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false

        for field in [nameField, hostField, portField, databaseField, usernameField] {
            configureField(field)
        }
        configureField(passwordField)

        nameField.placeholderString = String(localized: "My Database")
        nameField.setAccessibilityIdentifier("connections.name")
        hostField.placeholderString = String(localized: "db.example.com or 10.0.0.5")
        hostField.setAccessibilityIdentifier("connections.host")
        portField.placeholderString = "5432"
        portField.formatter = SettingsControlFactory.numberFormatter(min: 1, max: 65535)
        portField.alignment = .right
        portField.setAccessibilityIdentifier("connections.port")
        databaseField.placeholderString = "postgres"
        databaseField.setAccessibilityIdentifier("connections.database")
        usernameField.placeholderString = "postgres"
        usernameField.setAccessibilityIdentifier("connections.username")
        passwordField.placeholderString = String(localized: "Optional")
        passwordField.setAccessibilityIdentifier("connections.password")

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

        configureSwitch(requireAuthCheckbox, action: #selector(requireAuthChanged),
                        identifier: "connections.requireAuth")
        configureSwitch(rememberPasswordCheckbox, action: #selector(perConnectionFlagChanged),
                        identifier: "connections.rememberPassword")

        sslPopup.target = self
        sslPopup.action = #selector(sslPopupChanged)
        // Built from `SslMode.formOrder`, so a mode added to the model cannot
        // be missing from the form — the old literal list of three titles
        // could, and the index switch below it silently mapped the rest to
        // Prefer.
        sslPopup.addItems(withTitles: SslMode.formOrder.map(\.displayLabel))
        sslPopup.setAccessibilityIdentifier("connections.sslMode")

        configureField(sslRootCertField)
        sslRootCertField.placeholderString = String(localized: "System trust store")
        sslRootCertField.setAccessibilityIdentifier("connections.sslRootCert")
        configureChooseButton(sslChooseCertButton, title: String(localized: "Choose…"),
                              action: #selector(chooseSslRootCert))

        configureSwitch(readOnlyCheckbox, action: #selector(perConnectionFlagChanged),
                        identifier: "connections.readOnly")
        configureSwitch(connectOnLaunchCheckbox, action: #selector(perConnectionFlagChanged),
                        identifier: "connections.connectOnLaunch")

        sessionTimeZonePopup.target = self
        sessionTimeZonePopup.action = #selector(perConnectionFlagChanged)
        sessionTimeZonePopup.setAccessibilityIdentifier("connections.sessionTimeZone")
        PopupValueMenu.populate(sessionTimeZonePopup,
                                sentinel: String(localized: "Use the Settings default"),
                                values: SessionTimeZone.identifiers)

        defaultSchemaPopup.target = self
        defaultSchemaPopup.action = #selector(defaultSchemaChanged)
        defaultSchemaPopup.setAccessibilityIdentifier("connections.defaultSchema")
        PopupValueMenu.populate(defaultSchemaPopup, sentinel: String(localized: "Test connection first"), values: [])
        defaultSchemaPopup.isEnabled = false

        testButton.title = String(localized: "Test Connection")
        testButton.bezelStyle = .rounded
        testButton.controlSize = .regular
        testButton.target = self
        testButton.action = #selector(testConnection)
        testButton.setAccessibilityIdentifier("connections.test")

        testSpinner.style = .spinning
        testSpinner.controlSize = .small
        testSpinner.isHidden = true

        testStatusLabel.font = .systemFont(ofSize: 12)
        testStatusLabel.textColor = .secondaryLabelColor
        testStatusLabel.lineBreakMode = .byTruncatingTail
        testStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        testStatusLabel.setAccessibilityIdentifier("connections.testStatus")

        revertButton.title = String(localized: "Revert")
        revertButton.bezelStyle = .rounded
        revertButton.target = self
        revertButton.action = #selector(revertChanges)
        revertButton.setAccessibilityIdentifier("connections.revert")

        saveButton.title = String(localized: "Save")
        saveButton.bezelStyle = .rounded
        // The default button: Return saves, from any field in the form.
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(saveChanges)
        saveButton.setAccessibilityIdentifier("connections.save")

        enginePopup.target = self
        enginePopup.action = #selector(engineChanged)
        enginePopup.addItems(withTitles: DatabaseEngine.allCases.map(\.displayName))
        enginePopup.setAccessibilityIdentifier("connections.engine")

        configureField(duckPathField)
        duckPathField.placeholderString = String(localized: "~/Data/sales.duckdb")
        duckPathField.setAccessibilityIdentifier("connections.duckdbPath")
        configureChooseButton(duckChooseButton, title: String(localized: "Choose…"), action: #selector(chooseDuckDBFile))
        configureChooseButton(duckNewButton, title: String(localized: "New…"), action: #selector(newDuckDBFile))
        configureChooseButton(duckRevealButton, title: String(localized: "Show in Finder"),
                              action: #selector(revealDuckDBFile))
        duckChooseButton.toolTip = String(localized: "Open an existing DuckDB database file.")
        duckNewButton.toolTip = String(localized: "Choose where to create a new database file. Save creates it.")
        duckRevealButton.toolTip = String(localized: "Show the database file in the Finder.")
        duckRevealButton.setAccessibilityIdentifier("connections.duckdbReveal")
        configureSwitch(duckInMemoryCheckbox, action: #selector(duckInMemoryChanged),
                        identifier: "connections.duckdbInMemory")
        let duckFileControls = hStack([duckPathField, duckChooseButton, duckNewButton, duckRevealButton])

        // MARK: Connection

        let nameRow = row(String(localized: "Name"), control: sized(nameField))
        requiredRows[.name] = nameRow
        let generalSection = section(String(localized: "Connection"), rows: [
            nameRow,
            row(String(localized: "Engine"), control: sized(enginePopup)),
        ])

        // MARK: Server

        let hostRow = row(String(localized: "Host"), control: withBadge(hostField, hostBadge), titling: hostField)
        requiredRows[.host] = hostRow
        let serverPortRow = row(String(localized: "Port"), control: sized(portField, width: L.portWidth))
        portRow = serverPortRow
        let serverSection = section(String(localized: "Server"), rows: [hostRow, serverPortRow])

        // MARK: Database File

        // Below the title, across the row: a path and three buttons do not
        // fit the trailing column.
        let fileNote = String(localized: "Connect opens the file. Save creates a new file; Connect never makes an empty database in place of a file that has gone.")
        let duckFileRow = row(String(localized: "File"), control: duckFileControls, caption: fileNote,
                              placement: .below, titling: duckPathField)
        requiredRows[.databaseFile] = duckFileRow
        let inMemoryRow = row(String(localized: "In-memory database"), control: duckInMemoryCheckbox,
                              caption: String(localized: "An in-memory database's tables are lost when it disconnects or Pharos quits. Pharos asks first, and offers to save them to a file."))
        setToolTip(String(localized: "Keeps the database in memory only. Its tables are lost when the connection closes or Pharos quits."),
                   on: inMemoryRow)
        let duckSection = section(String(localized: "Database File"), rows: [duckFileRow, inMemoryRow])

        // MARK: Authentication

        let usernameRow = row(String(localized: "Username"), control: withBadge(usernameField, usernameBadge),
                              titling: usernameField)
        requiredRows[.username] = usernameRow
        // The field and its Show button travel together, so the badge still
        // owns the row's trailing edge and the row keeps ONE width whichever
        // state the gate is in.
        let passwordControls = hStack([passwordField, showPasswordButton])
        let passwordRow = row(String(localized: "Password"), control: withBadge(passwordControls, passwordBadge),
                              titling: passwordField)
        // `withBadge` linked the badge to the stack it was handed. The warning
        // is about the FIELD, so say so — a screen reader on the badge must
        // land on the password field, not on its container.
        passwordBadge.link(to: passwordField)
        passwordRow.captionLabel.setAccessibilityIdentifier("connections.passwordNote")
        self.passwordRow = passwordRow

        let certControls = hStack([sslRootCertField, sslChooseCertButton])
        let sslCertRow = row(String(localized: "Root Certificate"), control: sized(certControls),
                             titling: sslRootCertField)
        // Hidden until a selection loads: the default mode is Prefer, which
        // uses no certificate, and a row that flashed into view on every open
        // would be the only row in the form that did.
        sslCertRow.isHidden = true
        sslRootCertRow = sslCertRow

        let rememberRow = row(String(localized: "Remember the password in the keychain"),
                              control: rememberPasswordCheckbox)
        // What it ACTUALLY does, both ways round. The row was out of this form
        // until the behaviour existed, because the old one said the opposite
        // of what happened.
        setToolTip(String(localized: "On, the password is written to your login keychain and this connection opens without asking. Off, Pharos asks you for it the first time you connect after each launch, keeps it in memory only, and DELETES the one already in your keychain when you save."),
                   on: rememberRow)
        let requireAuthRow = row(String(localized: "Require Touch ID to connect and to show the password"),
                                 control: requireAuthCheckbox)
        setToolTip(String(localized: "Asks for Touch ID, an Apple Watch or your login password. The password itself stays in the keychain, where it already was."),
                   on: requireAuthRow)

        let authSection = section(String(localized: "Authentication"), rows: [
            usernameRow,
            passwordRow,
            row(String(localized: "SSL Mode"), control: sized(sslPopup)),
            sslCertRow,
            rememberRow,
            requireAuthRow,
        ])
        let sshSection = buildSshSection()

        // MARK: Database

        let databaseRow = row(String(localized: "Database"), control: withBadge(databaseField, databaseBadge),
                              titling: databaseField)
        requiredRows[.database] = databaseRow
        databaseNameRow = databaseRow
        let dbSection = section(String(localized: "Database"), rows: [
            databaseRow,
            row(String(localized: "Default Schema"), control: sized(defaultSchemaPopup)),
        ])
        serverSectionView = serverSection
        duckSectionView = duckSection
        authSectionView = authSection
        sshSectionView = sshSection

        // MARK: Session — the per-connection rules, at the end of the form.
        // Database sits under Server (owner's order, 2026-10-28).

        let readOnlyRow = row(String(localized: "Read-only connection"), control: readOnlyCheckbox)
        // The engine's own wording is set by `applyEngineVisibility`.
        setToolTip(ConnectionFormRules.readOnlyHelp(for: .postgres), on: readOnlyRow)
        self.readOnlyRow = readOnlyRow
        let launchRow = row(String(localized: "Connect when Pharos starts"), control: connectOnLaunchCheckbox)
        setToolTip(String(localized: "Opens this connection as Pharos starts, once the saved tabs are back. A connection that asks for Touch ID is opened last, and one at a time, so two prompts cannot arrive together."),
                   on: launchRow)
        let zoneRow = row(String(localized: "Time Zone"), control: sized(sessionTimeZonePopup),
                          caption: String(localized: "Applies to connections opened after this change."))
        timeZoneRow = zoneRow
        let sessionSection = section(String(localized: "Session"), rows: [readOnlyRow, launchRow, zoneRow])

        let scroll = SettingsFormScroll.makePane(sections: [header, generalSection, serverSection, dbSection,
                                                            duckSection, authSection, sshSection, sessionSection])

        // Test Connection, Revert and Save live in a bar pinned to the bottom
        // of the pane, OUTSIDE the scroll view. An action the user must reach
        // to finish the task must never be something they have to find by
        // scrolling: with the SSH section open the form is taller than the
        // window.
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

        let root = SettingsPaneSurfaceView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        root.addSubview(actionSeparator)
        root.addSubview(actionBar)
        NSLayoutConstraint.activate([
            // The pane's top, not its safe area: the scroll view insets itself
            // under the toolbar (`SettingsFormScroll`).
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: actionSeparator.topAnchor),

            actionSeparator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            actionSeparator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            actionSeparator.bottomAnchor.constraint(equalTo: actionBar.topAnchor, constant: -L.actionBarInsetTop),

            actionBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: SettingsMetrics.paneInsetH),
            actionBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -SettingsMetrics.paneInsetH),
            actionBar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -L.actionBarInsetBottom),
        ])
        return root
    }

    // MARK: - SSH tunnel section

    /// The SSH Tunnel section, between Authentication and Database.
    ///
    /// D6 puts it there because a tunnel is part of HOW the app reaches the
    /// server, like the credentials above it, and before the database it
    /// finally opens.
    private func buildSshSection() -> NSView {
        configureSwitch(sshEnabledCheckbox, action: #selector(sshEnabledChanged),
                        identifier: "connections.ssh.enabled")

        for field in [sshHostField, sshPortField, sshUserField, sshKeyPathField] {
            configureField(field)
        }
        configureField(sshSecretField)
        sshHostField.placeholderString = String(localized: "bastion.example.com or a Host from ~/.ssh/config")
        sshHostField.setAccessibilityIdentifier("connections.ssh.host")
        sshPortField.placeholderString = "22"
        // The same rule as Port: a whole number from 1 to 65535. Mid-edit the
        // field can still hold anything, so `SshTunnelForm.portProblem` keeps
        // Save off and says why until it is a port.
        sshPortField.formatter = SettingsControlFactory.numberFormatter(min: 1, max: 65535)
        sshPortField.alignment = .right
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
        sshAuthPopup.setAccessibilityIdentifier("connections.ssh.auth")

        configureChooseButton(sshChooseKeyButton, title: String(localized: "Choose…"), action: #selector(chooseSshKeyFile))
        sshChooseKeyButton.setAccessibilityIdentifier("connections.ssh.chooseKey")

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

        configureSwitch(sshAcceptNewHostKeysCheckbox, action: #selector(fieldEdited),
                        identifier: "connections.ssh.acceptNewHostKeys")
        configureSwitch(sshRememberSecretCheckbox, action: #selector(fieldEdited),
                        identifier: "connections.ssh.rememberSecret")

        let keyControls = hStack([sshKeyPathField, sshChooseKeyButton])
        let secretControls = hStack([sshSecretField, sshShowSecretButton])

        let hostRow = row(String(localized: "SSH Host"), control: withBadge(sshHostField, sshHostBadge),
                          caption: String(localized: "Pharos runs the system ssh, so Host aliases, ProxyJump and IdentityAgent from ~/.ssh/config apply."),
                          titling: sshHostField)
        requiredRows[.sshHost] = hostRow
        let portRow = row(String(localized: "SSH Port"), control: sized(sshPortField, width: L.portWidth))
        sshPortRow = portRow
        let userRow = row(String(localized: "SSH User"), control: withBadge(sshUserField, sshUserBadge),
                          titling: sshUserField)
        let authRow = row(String(localized: "Authentication"), control: sized(sshAuthPopup))
        let keyRow = row(String(localized: "Key File"), control: sized(keyControls), titling: sshKeyPathField)
        // The title is set by `applySshRowVisibility` from the pop-up.
        let secretRow = row(String(localized: "Passphrase"), control: sized(secretControls), titling: sshSecretField)
        let rememberSecretRow = row(String(localized: "Remember the SSH secret in the keychain"),
                                    control: sshRememberSecretCheckbox)
        // What it ACTUALLY does, both ways round, and that it is the TUNNEL's
        // switch — the database password has its own, higher up this form.
        setToolTip(String(localized: "On, the SSH password or key passphrase is written to your login keychain and the tunnel opens without asking. Off, Pharos asks you for it the first time the tunnel is refused after each launch, keeps it in memory only, and DELETES the one already in your keychain when you save. This is separate from the database password's own switch."),
                   on: rememberSecretRow)
        let acceptRow = row(String(localized: "Accept new host keys"), control: sshAcceptNewHostKeysCheckbox,
                            caption: String(localized: "Records an unknown server key on the first connection. A changed key is still refused."))

        sshKeyPathRow = keyRow
        sshSecretRow = secretRow
        sshRememberSecretRow = rememberSecretRow
        // The remember switch sits directly under the secret it governs.
        sshRows = [hostRow, portRow, userRow, authRow, keyRow, secretRow, rememberSecretRow, acceptRow]

        let enabledRow = row(String(localized: "Connect through an SSH tunnel"), control: sshEnabledCheckbox)
        return section(String(localized: "SSH Tunnel"), rows: [enabledRow] + sshRows)
    }

    /// Show or hide every SSH row for the current switch and pop-up.
    ///
    /// One function, called from `populate`, from the switch and from the
    /// pop-up, so the three routes into this state cannot disagree.
    private func applySshRowVisibility() {
        let rules = SshTunnelForm.visibility(enabled: sshEnabledCheckbox.state == .on,
                                             auth: sshAuthMethodForPopup())
        for view in sshRows { view.isHidden = !rules.tunnelRows }
        sshKeyPathRow?.isHidden = !rules.keyFileRow
        sshSecretRow?.isHidden = !rules.secretRow
        sshRememberSecretRow?.isHidden = !rules.rememberSecretRow
        sshSecretRow?.titleLabel.stringValue = rules.secretLabel
        rowVisibilityChanged()
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

    /// The raw values the SSH Tunnel section's controls hold.
    private func sshFormFields() -> SshTunnelForm.Fields {
        SshTunnelForm.Fields(
            enabled: sshEnabledCheckbox.state == .on,
            host: sshHostField.stringValue,
            // The field editor's text while the port is being typed: see
            // `currentText(of:)`.
            port: currentText(of: sshPortField),
            user: sshUserField.stringValue,
            auth: sshAuthMethodForPopup(),
            keyPath: sshKeyPathField.stringValue,
            secret: sshSecretField.stringValue,
            acceptNewHostKeys: sshAcceptNewHostKeysCheckbox.state == .on,
            // Cleared, this is a DESTRUCTIVE save: `save_connection` deletes
            // the `<id>/ssh` item already in the keychain rather than merely
            // stopping writing new ones. That is the point of the switch, and
            // it is what the tooltip states.
            rememberSecret: sshRememberSecretCheckbox.state == .on,
            secretRevealed: passwordRevealed)
    }

    /// The tunnel the form currently describes, or `nil` when the switch is
    /// off.
    ///
    /// The secret follows the same rule as the password: a MASKED field holds
    /// the mask, not a secret, so the draft's stored value is kept instead.
    private func sshTunnelFromForm(existing: SshTunnelConfig?) -> SshTunnelConfig? {
        SshTunnelForm.tunnel(from: sshFormFields(), existing: existing)
    }

    /// Why Save cannot write the server's Port field, or nil
    /// (`ConnectionFormRules.portProblem`; none for a DuckDB record). The
    /// field editor's text, as `syncFormIntoDraft` reads it.
    private var serverPortProblem: String? {
        guard draft != nil else { return nil }
        return ConnectionFormRules.portProblem(engine: draft?.engine ?? selectedEngine,
                                               portText: currentText(of: portField))
    }

    /// Why Save cannot write the tunnel, or nil. Only while the engine shows
    /// the section: a DuckDB record keeps no tunnel, so a port left behind in
    /// the hidden field cannot block it.
    private var sshPortProblem: String? {
        guard ConnectionFormRules.visibility(for: draft?.engine ?? selectedEngine).sshTunnel else { return nil }
        return SshTunnelForm.portProblem(sshFormFields())
    }

    /// What `field` holds right now. While it is being edited this is the
    /// field editor's text. `stringValue` would run the field's formatter
    /// (`validateEditing`), and when the formatter refuses the text — "99999"
    /// in a 1…65535 port field — reading it from `controlTextDidChange` WIPES
    /// the field as the user types (measured on macOS 27, 2026-10-28). The
    /// formatter still refuses to let the field go with a bad value; the
    /// caption says why.
    private func currentText(of field: NSTextField) -> String {
        field.currentEditor()?.string ?? field.stringValue
    }

    // MARK: - Form building helpers

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

    /// A switch, as the Settings furniture makes one (`SettingsControlFactory
    /// .toggle`): its row's title is its label.
    private func configureSwitch(_ toggle: NSSwitch, action: Selector, identifier: String) {
        toggle.controlSize = .regular
        toggle.target = self
        toggle.action = action
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.setAccessibilityIdentifier(identifier)
    }

    private func configureChooseButton(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    /// A field followed by buttons: the field takes what the buttons leave.
    private func hStack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        views.first?.setContentHuggingPriority(.defaultLow, for: .horizontal)
        views.first?.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return stack
    }

    /// Pins `view` to one width. Every field and pop-up takes the form's
    /// control width, so the controls line up down the whole form.
    private func sized(_ view: NSView, width: CGFloat = L.controlWidth) -> NSView {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        return view
    }

    /// `control` with its hostile-text badge after it, the pair as wide as
    /// any other control. A hidden view keeps its constraints, so the badge
    /// holds its slot whether it is raised or not: the field keeps ONE width
    /// and the row never reflows when a badge appears.
    private func withBadge(_ control: NSView, _ badge: HostileTextBadge) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(control)
        container.addSubview(badge)
        // The badge announces the field it warns about, and the field the badge.
        badge.link(to: control)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: L.controlWidth),
            control.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            control.topAnchor.constraint(equalTo: container.topAnchor),
            control.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            control.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -L.badgeGap),
            badge.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            badge.centerYAnchor.constraint(equalTo: control.centerYAnchor),
        ])
        return container
    }

    /// One furniture row: the title leading, the control trailing (or below
    /// it). `titling` is the control inside a composite — a field beside its
    /// badge or its button — that VoiceOver should hear the title for; the row
    /// itself titles only the composite.
    private func row(_ title: String, control: NSView, caption: String? = nil,
                     placement: SettingsRow.ControlPlacement = .trailing,
                     titling inner: NSView? = nil) -> SettingsRow {
        let row = SettingsRow(title: title, caption: caption, control: control, placement: placement)
        inner?.setAccessibilityTitleUIElement(row.titleLabel)
        if let caption, !caption.isEmpty { inner?.setAccessibilityHelp(caption) }
        return row
    }

    /// One section: the bold header over a box of rows, as the Settings
    /// panes build theirs (`SettingsFormBuilder`).
    private func section(_ title: String, rows: [NSView]) -> NSView {
        let box = SettingsGroupBox(title: title, rows: rows)
        boxes.append(box)
        let stack = NSStackView(views: [SettingsSectionHeader.make(title), box])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = SettingsMetrics.headerToBoxGap
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.spanArrangedSubviewsFullWidth()
        return stack
    }

    /// A tooltip on a row's control AND on its title, so hovering the words
    /// explains the switch as hovering the old checkbox's title did.
    private func setToolTip(_ text: String?, on row: SettingsRow?) {
        row?.control?.toolTip = text
        row?.titleLabel.toolTip = text
    }

    /// A row was shown or hidden: each box draws the separators between its
    /// visible rows, so it redraws.
    private func rowVisibilityChanged() {
        for box in boxes { box.needsDisplay = true }
    }

    /// The "Required" captions, from the draft (`ConnectionFormRules
    /// .missingFields`), and each port's problem, if any — in the system red,
    /// as the Variable Manager shows its errors, over any caption the row
    /// carries anyway (`SettingsRow.captionProblems`).
    private func refreshFieldCaptions() {
        let missing = Set(draft.map(ConnectionFormRules.missingFields) ?? [])
        let required = String(localized: "Required")
        for (field, row) in requiredRows {
            row.captionProblems = missing.contains(field) ? [required] : []
        }
        sshPortRow?.captionProblems = sshPortProblem.map { [$0] } ?? []
        portRow?.captionProblems = serverPortProblem.map { [$0] } ?? []
    }

    /// The Password row's caption: where the password came from, and why the
    /// gate refused, each on its own line.
    private func refreshPasswordCaption() {
        var lines: [String] = []
        if showsPasswordFromLinkNote { lines.append(String(localized: "Password taken from the link.")) }
        if !passwordAuthNote.isEmpty { lines.append(passwordAuthNote) }
        passwordRow?.caption = lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: - External state sync

    private func externalConnectionsChanged(_ configs: [ConnectionConfig]) {
        // Preserve in-flight stubs that aren't yet in the backend. The sidebar
        // keeps its selection by id, so a record still listed stays selected.
        let stubs = connections.filter { pendingStubIds.contains($0.id) }
        connections = ConnectionVisibility.listed(configs) + stubs

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
        // The sidebar reports the source row and the gap it was dropped in,
        // counted before the move — `Array.move(fromOffsets:toOffset:)`'s
        // convention. It offers a drag only while no filter hides rows, so the
        // indices are positions in `connections` itself.
        var updated = connections
        updated.move(fromOffsets: source, toOffset: destination)
        connections = updated
        // The list shows saved records only; the hidden ones follow them, so
        // no two records keep the same position.
        stateManager.reorderConnections(ids: ConnectionVisibility.reorderedIds(
            saved: updated.map { $0.id }, all: stateManager.connections))
    }

    // MARK: - Selection / detail population

    private func handleSelectionChange() {
        // The sidebar's report is handled on the NEXT run loop turn, so it can
        // arrive when the form ALREADY shows the record that was selected.
        // The prompt below guards a move AWAY from an edited record; arriving
        // where the form already is, is not that, and prompting there would ask
        // the user to save the record they just asked for.
        if let selected = selectedId, selected == draft?.id { return }

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
        // Put the selection back on the record being edited. A Save the form
        // cannot make (a required field is blank) does this too, rather than
        // moving on and losing the edits it could not store.
        let stayOnDraft = { [weak self] in
            let target = self?.draft?.id
            DispatchQueue.main.async { [weak self] in self?.sidebar.selectedId = target }
        }
        switch response {
        case .alertFirstButtonReturn:
            guard saveChangesInternal() else { stayOnDraft(); return }
            updateDetailVisibility()
        case .alertSecondButtonReturn:
            if let id = draft?.id, pendingStubIds.contains(id) {
                pendingStubIds.remove(id)
                connections.removeAll { $0.id == id }
            }
            draft = draftBaseline
            dirtyConnectionId = nil
            updateDetailVisibility()
        default:
            stayOnDraft()
        }
    }

    private func updateDetailVisibility() {
        let hasSelection = selectedId != nil
        splitVC?.setDetail(hasSelection ? formPane : emptyPane)

        if hasSelection {
            loadSelectionIntoForm()
        } else {
            draft = nil
            draftBaseline = nil
            dirtyConnectionId = nil
            showPasswordFromLinkNote(false)
            updateButtonStates()
        }
    }

    private func loadSelectionIntoForm() {
        guard let id = selectedId,
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
                               database: "", username: "", engine: config.engine)
            : config
        dirtyConnectionId = nil
        showPasswordFromLinkNote(passwordFromLinkId == id)

        // A display label, so it is ESCAPED rather than sanitised — matching the
        // list row and the delete confirmation for the same name. It is also the
        // largest rendering of the name in this view, so it is the last place
        // that should be able to lie. TRIMMED as well, because the save path
        // trims: an edge space here is a record written before it did.
        titleField.stringValue = DisplayEscape.escapedTrimmed(config.name)
            .ifEmpty(String(localized: "Untitled Connection"))
        nameField.stringValue = AuthoredLabelSanitizer.sanitized(config.name)
        enginePopup.selectItem(at: DatabaseEngine.allCases.firstIndex(of: config.engine) ?? 0)
        hostField.stringValue = config.host
        portField.stringValue = String(config.port)
        // The two engines keep different things in `database`: a server's
        // database NAME, or a DuckDB FILE. Each goes to its own field, so
        // switching the pop-up back and forth loses neither.
        databaseField.stringValue = config.isDuckDB ? "" : config.database
        duckInMemoryCheckbox.state = config.isInMemoryDuckDB ? .on : .off
        duckPathField.stringValue = config.isDuckDB && !config.isInMemoryDuckDB ? config.database : ""
        usernameField.stringValue = config.username
        // A gated record is masked on EVERY selection, including a return to a
        // record revealed a moment ago: the gate is about walking up to the
        // window, so it has to re-arm when the form moves on.
        requireAuthCheckbox.state = config.requiresAuthentication ? .on : .off
        rememberPasswordCheckbox.state = config.rememberPassword ? .on : .off
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
        // A record with no tunnel yet starts ON, which is what a tunnel added
        // to it would have done before this switch existed.
        sshRememberSecretCheckbox.state = (tunnel?.rememberSecret ?? true) ? .on : .off
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
        sslPopup.selectItem(at: SslMode.formOrder.firstIndex(of: config.sslMode) ?? 0)
        sslRootCertField.stringValue = config.sslRootCertPath ?? ""
        applySslRowVisibility()
        readOnlyCheckbox.state = config.readOnly ? .on : .off
        connectOnLaunchCheckbox.state = config.connectOnLaunch ? .on : .off
        applyEngineVisibility(config.engine)
        // `selectValue` leaves the selection alone when there is no such row,
        // so the empty case has to pick the sentinel itself — otherwise a
        // record with no zone would show the zone of the record before it.
        let storedZone = SessionTimeZone.normalized(config.sessionTimeZone ?? "")
        if storedZone.isEmpty {
            sessionTimeZonePopup.selectItem(at: 0)
        } else {
            PopupValueMenu.selectValue(storedZone, in: sessionTimeZonePopup)
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
            let placeholder = ConnectionFormRules.schemaPlaceholder(for: config.engine)
            PopupValueMenu.populate(defaultSchemaPopup, sentinel: placeholder.sentinel, values: placeholder.values)
            defaultSchemaPopup.isEnabled = false
            defaultSchemaPopup.toolTip = config.isDuckDB
                ? String(localized: "DuckDB's default schema. Test the connection to choose another.") : nil
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
        guard let id = selectedId else {
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
        // `humanised` takes off the `[SSH AUTH]` marker the core puts in front
        // of a tunnel authentication failure. The marker is for the app —
        // `SshSecretPrompt` reads it — never for the reader.
        statusBadge.toolTip = stateManager.connectionError(for: id)
            .map { DuckDBOpenError.humanised(SshTunnelAuthError.humanised($0)) }
        switch statuses[id] ?? .disconnected {
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
        dirtyConnectionId = isDirty ? draft?.id : nil
        refreshFieldCaptions()
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

    /// Whether Save can write the draft: every required field is filled in
    /// (`ConnectionFormRules.missingFields`, the SSH host among them while
    /// the tunnel is on), the server's Port is a port
    /// (`ConnectionFormRules.portProblem`), and so is the SSH port when the
    /// tunnel is on (`SshTunnelForm.portProblem`). The form shows a caption
    /// for each problem, so a greyed-out Save always has a reason on screen.
    private func isDraftValid() -> Bool {
        guard let d = draft else { return false }
        return ConnectionFormRules.isValid(d) && serverPortProblem == nil && sshPortProblem == nil
    }

    // MARK: - Engine

    /// The engine the pop-up shows.
    private var selectedEngine: DatabaseEngine {
        let i = enginePopup.indexOfSelectedItem
        return DatabaseEngine.allCases.indices.contains(i) ? DatabaseEngine.allCases[i] : .postgres
    }

    @objc private func engineChanged() {
        applyEngineVisibility(selectedEngine)
        syncFormIntoDraft()
        // No list read yet: the pop-up shows the new engine's placeholder
        // ("main" for DuckDB).
        if let d = draft, liveOrFetchedSchemas(for: d) == nil {
            let placeholder = ConnectionFormRules.schemaPlaceholder(for: d.engine)
            PopupValueMenu.populate(defaultSchemaPopup, sentinel: placeholder.sentinel, values: placeholder.values)
            defaultSchemaPopup.isEnabled = false
        }
    }

    /// Show the sections the engine uses and hide the rest. A hidden section
    /// keeps its fields, so switching back restores what was typed.
    private func applyEngineVisibility(_ engine: DatabaseEngine) {
        let v = ConnectionFormRules.visibility(for: engine)
        serverSectionView?.isHidden = !v.server
        authSectionView?.isHidden = !v.authentication
        sshSectionView?.isHidden = !v.sshTunnel
        databaseNameRow?.isHidden = !v.databaseName
        duckSectionView?.isHidden = !v.databaseFile
        timeZoneRow?.isHidden = !v.timeZone
        rowVisibilityChanged()
        let inMemory = duckInMemoryCheckbox.state == .on
        duckPathField.isEnabled = !inMemory
        duckChooseButton.isEnabled = !inMemory
        duckNewButton.isEnabled = !inMemory
        duckRevealButton.isEnabled = !inMemory && !duckPathField.stringValue.isEmpty
        setToolTip(ConnectionFormRules.readOnlyHelp(for: engine), on: readOnlyRow)
        // The row, so its title dims with the switch.
        readOnlyRow?.isEnabled = !(engine == .duckdb && inMemory)
    }

    @objc private func duckInMemoryChanged() {
        applyEngineVisibility(selectedEngine)
        syncFormIntoDraft()
    }

    /// Show in Finder: the file, or its folder while the file does not exist
    /// yet (a new record before Save).
    @objc private func revealDuckDBFile() {
        let path = (duckPathField.stringValue as NSString).expandingTildeInPath
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        } else {
            NSSound.beep()
        }
    }

    /// Choose… an existing DuckDB file. Any file can be picked: DuckDB names
    /// none, and `.db` is as common as `.duckdb`.
    @objc private func chooseDuckDBFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose a DuckDB database file.")
        panel.beginSheetModal(for: view.window ?? NSApp.keyWindow ?? NSWindow()) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.useDuckDBFile(url)
        }
    }

    /// New… — where a new database file goes. Save creates the file
    /// (`createDuckDBFileIfNew`); Connect never does.
    @objc private func newDuckDBFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [DuckDBFiles.contentType]
        panel.nameFieldStringValue = String(localized: "Untitled.duckdb")
        panel.prompt = String(localized: "Create")
        panel.message = String(localized: "Choose where to create the DuckDB database.")
        panel.beginSheetModal(for: view.window ?? NSApp.keyWindow ?? NSWindow()) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.useDuckDBFile(url)
        }
    }

    private func useDuckDBFile(_ url: URL) {
        let oldPath = duckPathField.stringValue
        duckPathField.stringValue = url.path
        duckInMemoryCheckbox.state = .off
        // A name Pharos gave (the + button's, or one taken from the previous
        // file) follows the new file; a name the user typed stays.
        if let d = draft {
            let others = connections.filter { $0.id != d.id }
            let given = [Self.newConnectionName,
                         URL(fileURLWithPath: oldPath).deletingPathExtension().lastPathComponent,
                         DuckDBFiles.uniqueName(forPath: oldPath, in: others)]
            if d.name.isEmpty || given.contains(d.name) {
                nameField.stringValue = DuckDBFiles.uniqueName(forPath: url.path, in: others)
            }
        }
        applyEngineVisibility(selectedEngine)
        syncFormIntoDraft()
    }

    // MARK: - Editing

    @objc private func fieldEdited() {
        duckRevealButton.isEnabled = duckInMemoryCheckbox.state == .off && !duckPathField.stringValue.isEmpty
        syncFormIntoDraft()
    }
    @objc private func sslPopupChanged() {
        applySslRowVisibility()
        syncFormIntoDraft()
    }

    /// One handler for the three per-connection switches and the time-zone
    /// pop-up: each only has to reach the draft.
    @objc private func perConnectionFlagChanged() { syncFormIntoDraft() }

    /// The root-certificate row belongs to verify-ca and verify-full alone.
    /// Called from `loadSelectionIntoForm` and from the pop-up, so the two
    /// routes into this state cannot disagree — the same rule the SSH rows
    /// follow.
    private func applySslRowVisibility() {
        let index = sslPopup.indexOfSelectedItem
        let mode = SslMode.formOrder.indices.contains(index) ? SslMode.formOrder[index] : .prefer
        sslRootCertRow?.isHidden = !mode.verifiesCertificate
        rowVisibilityChanged()
    }

    @objc private func chooseSslRootCert() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // A PEM bundle often lives in a hidden folder (~/.postgresql/), so the
        // panel has to show hidden files to be usable at all.
        panel.showsHiddenFiles = true
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose the PEM root certificate for this connection.")
        panel.beginSheetModal(for: view.window ?? NSApp.keyWindow ?? NSWindow()) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.sslRootCertField.stringValue = url.path
            self.syncFormIntoDraft()
        }
    }

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
        let selectionAtRequest = selectedId
        let name = DisplayEscape.escapedTrimmed(draft?.name ?? "").ifEmpty(String(localized: "this connection"))
        showPasswordButton.isEnabled = false
        Task { @MainActor in
            let outcome = await DeviceOwnerGate.authenticate(
                reason: String(localized: "show the password for \(name)"))
            self.showPasswordButton.isEnabled = true
            // The prompt is modal to the app, not to this form. If the selection
            // moved while it was up, the answer belongs to a record that is no
            // longer on screen.
            guard self.selectedId == selectionAtRequest else { return }
            switch outcome {
            case .authenticated:
                self.passwordRevealed = true
                self.showPasswordAuthNote("")
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
        passwordAuthNote = text
        refreshPasswordCaption()
    }
    @objc private func defaultSchemaChanged() { syncFormIntoDraft() }

    private func syncFormIntoDraft() {
        guard var d = draft else { return }
        d.name = nameField.stringValue
        d.engine = selectedEngine
        d.host = hostField.stringValue
        // The field editor's text, not `stringValue`: see `currentText(of:)`.
        d.port = SshTunnelForm.port(from: currentText(of: portField)) ?? d.port
        d.database = d.engine == .duckdb
            ? ConnectionFormRules.duckDBPath(inMemory: duckInMemoryCheckbox.state == .on,
                                             typed: duckPathField.stringValue)
            : databaseField.stringValue
        d.username = usernameField.stringValue
        // A masked field holds the MASK, not a password. Reading it here is
        // what would write "••••••••" over the stored password on the next
        // Save, so the draft keeps the value it already has.
        if passwordRevealed {
            d.password = passwordField.stringValue
        }
        d.requiresAuthentication = requireAuthCheckbox.state == .on
        d.sshTunnel = sshTunnelFromForm(existing: d.sshTunnel)
        let modeIndex = sslPopup.indexOfSelectedItem
        d.sslMode = SslMode.formOrder.indices.contains(modeIndex)
            ? SslMode.formOrder[modeIndex]
            : .prefer
        // Only the two verifying modes use a root certificate. A path left
        // behind by a mode the user moved away from is kept in the FIELD but
        // not written, so switching back restores it without ever sending a
        // certificate the mode ignores.
        let certPath = sslRootCertField.stringValue.trimmingCharacters(in: .whitespaces)
        d.sslRootCertPath = (d.sslMode.verifiesCertificate && !certPath.isEmpty) ? certPath : nil
        d.readOnly = readOnlyCheckbox.state == .on
        d.connectOnLaunch = connectOnLaunchCheckbox.state == .on
        // Cleared, this is a DESTRUCTIVE save: `save_connection` deletes the
        // password already in the keychain rather than merely stopping writing
        // new ones. That is the whole point — a switch that left the old one
        // behind would say the opposite of what it does — and it is what the
        // tooltip states.
        d.rememberPassword = rememberPasswordCheckbox.state == .on
        d.sessionTimeZone = PopupValueMenu.selectedValue(in: sessionTimeZonePopup)
            .map(SessionTimeZone.normalized)
            .flatMap { $0.isEmpty ? nil : $0 }
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
        // A DuckDB record keeps no server fields (or tunnel, gate, zone).
        d = ConnectionFormRules.normalized(d)
        if d.isInMemoryDuckDB { d.readOnly = false }
        draft = d

        // An edit to the host, port, database, user or SSL mode has just made
        // any fetched list describe a different server. Take the picker back to
        // asking for a test rather than letting it offer the old server's
        // schemas as if they were this one's.
        if defaultSchemaPopup.isEnabled, liveOrFetchedSchemas(for: d) == nil {
            let placeholder = ConnectionFormRules.schemaPlaceholder(for: d.engine)
            PopupValueMenu.populate(defaultSchemaPopup, sentinel: placeholder.sentinel, values: placeholder.values)
            defaultSchemaPopup.isEnabled = false
            defaultSchemaPopup.toolTip = nil
        }

        titleField.stringValue = d.name.isEmpty ? String(localized: "Untitled Connection") : d.name
        // The sidebar row follows the draft's name (`refreshSidebar`), which
        // `draft`'s observer has already passed on.
        updateButtonStates()
    }

    // MARK: - Save / Revert / Test

    @objc private func saveChanges() { saveChangesInternal() }

    /// Saves the draft. False, with a beep, when it cannot: a required field
    /// is blank or the SSH port is not a port (the form says which).
    @discardableResult
    private func saveChangesInternal() -> Bool {
        guard var d = draft, isDraftValid() else { NSSound.beep(); return false }

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
        guard !d.name.isEmpty else { NSSound.beep(); return false }

        // The draft, the baseline and the field all take the committed name, so
        // what is on screen is what was saved and the view is not left dirty.
        draft = d
        nameField.stringValue = d.name
        pendingStubIds.remove(d.id)
        stateManager.saveConnection(d)
        createDuckDBFileIfNew(d)
        draftBaseline = d
        updateButtonStates()
        return true
    }

    /// A DuckDB record whose file does not exist yet (New…, or a typed path):
    /// Save creates the file, because Connect never creates one (a missing
    /// file may have moved). The core opens and closes it at once; the app's
    /// connection state is untouched.
    private func createDuckDBFileIfNew(_ d: ConnectionConfig) {
        guard d.isDuckDB, !d.isInMemoryDuckDB,
              !FileManager.default.fileExists(atPath: (d.database as NSString).expandingTildeInPath),
              stateManager.status(for: d.id) != .connected else { return }
        let id = d.id
        Task { @MainActor [weak self] in
            do {
                let info = try await PharosCore.connectCreate(connectionId: id)
                try? await PharosCore.disconnect(connectionId: id)
                if info.status != .connected, let self {
                    self.setTestStatus(DisplayEscape.escaped(DuckDBOpenError.humanised(info.error ?? "")))
                    self.testStatusLabel.textColor = .systemRed
                }
            } catch {
                self?.setTestStatus(DisplayEscape.escaped(error.localizedDescription))
                self?.testStatusLabel.textColor = .systemRed
            }
        }
    }

    @objc private func revertChanges() {
        if let id = draft?.id, pendingStubIds.contains(id) {
            pendingStubIds.remove(id)
            connections.removeAll { $0.id == id }
            sidebar.selectedId = nil
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
                    let path = (d.database as NSString).expandingTildeInPath
                    let attributes = d.isDuckDB && !d.isInMemoryDuckDB
                        ? try? FileManager.default.attributesOfItem(atPath: path) : nil
                    if result.success, d.isDuckDB, !d.isInMemoryDuckDB, attributes == nil {
                        // The folder is fine and the file is not there. Not
                        // green: nothing was opened.
                        self.setTestStatus(self.pendingStubIds.contains(d.id)
                            ? String(localized: "The file does not exist yet. Save creates it.")
                            : String(localized: "No file at this path. Connect asks whether to create it."))
                        self.testStatusLabel.textColor = .secondaryLabelColor
                    } else if result.success, let attributes,
                              let size = (attributes[.size] as? NSNumber)?.int64Value,
                              let modified = attributes[.modificationDate] as? Date {
                        self.setTestStatus(ConnectionFormRules.duckDBFileSummary(size: size, modified: modified,
                                                                                 storage: result.storage))
                        self.testStatusLabel.textColor = .systemGreen
                        self.testStatusLabel.toolTip = String(localized:
                            "The size of the database file. A .wal file beside it is not counted.")
                        self.populateDefaultSchemas(using: d)
                    } else if result.success {
                        let ms = result.latencyMs.map { " \($0)ms" } ?? ""
                        self.setTestStatus("Connected\(ms)")
                        self.testStatusLabel.textColor = .systemGreen
                        self.populateDefaultSchemas(using: d)
                    } else {
                        self.setTestStatus(DisplayEscape.escaped(DuckDBOpenError.humanised(result.error ?? "Failed")))
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
        "\(c.engine.rawValue)|\(c.host):\(c.port)/\(c.database)@\(c.username)#\(c.sslMode.rawValue)#\(c.requiresAuthentication)#\(tunnelFingerprint(c.sshTunnel))"
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
        guard ConnectionFormRules.shouldFetchSchemas(config, fileExists: { FileManager.default.fileExists(atPath: $0) })
        else { return }
        Task { [weak self] in
            let tempId = ConnectionFormRules.schemaFetchIdPrefix + UUID().uuidString
            var saved = false
            // The temporary record goes away on EVERY exit. A fetch that
            // failed half-way used to leave it in the store, where it showed
            // as a second copy of the connection.
            func removeTemporaryRecord() async {
                guard saved else { return }
                try? await PharosCore.disconnect(connectionId: tempId)
                try? PharosCore.deleteConnection(id: tempId)
            }
            do {
                var tempConfig = config
                tempConfig.id = tempId
                // Reading a DuckDB file's schemas must never create or change it.
                if tempConfig.isDuckDB && !tempConfig.isInMemoryDuckDB { tempConfig.readOnly = true }
                try PharosCore.saveConnection(tempConfig)
                saved = true
                let info = try await PharosCore.connect(connectionId: tempId)
                guard info.status == .connected else {
                    throw PharosCoreError.rustError(info.error ?? "The connection did not open.")
                }
                let schemas: [SchemaInfo] = try await PharosCore.getSchemas(connectionId: tempId)
                await removeTemporaryRecord()

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
                await removeTemporaryRecord()
                Log.ui.error("Failed to fetch schemas for default schema picker: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - +/- Actions

    /// The + button's name for a new record.
    private static let newConnectionName = "Untitled"

    private func addStub() {
        beginNewConnection(
            prefilled: ConnectionConfig(
                id: UUID().uuidString,
                name: Self.newConnectionName,
                host: "localhost",
                // Settings ▸ Connections ▸ Default port. A NEW connection
                // only; nothing already saved is touched.
                port: UInt16(clamping: AppStateManager.shared.settings.connections.defaultPort),
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
            // Programmatic: the sidebar reports no selection for it, so the
            // form is loaded here, and the fields are filled in before the
            // name below is selected.
            self.sidebar.selectedId = stub.id
            self.updateDetailVisibility()
            self.view.window?.makeFirstResponder(self.nameField)
            self.nameField.selectText(nil)
        }
    }

    /// Shows or hides the "password came from the link" line of the Password
    /// row's caption.
    private func showPasswordFromLinkNote(_ visible: Bool) {
        showsPasswordFromLinkNote = visible
        refreshPasswordCaption()
    }

    private func deleteSelected(ids: Set<String>) {
        let selected = ids.compactMap { id in connections.first(where: { $0.id == id }) }
        guard !selected.isEmpty else { return }

        let alert = NSAlert()
        // Built by `DestructiveConfirmationText`, never interpolated here:
        // this title gates an irreversible delete, and a bidi override in the
        // name would let it name a different connection than the one about to
        // go. A DuckDB file is "Remove … from Connections": it is not
        // deleted, only no longer saved.
        guard let window = view.window else { return }
        // An open in-memory database that holds tables loses them: the alert
        // says so (one alert; F7). Counted first, with the core's short wait.
        let open = selected.filter { $0.isInMemoryDuckDB && stateManager.status(for: $0.id) == .connected }
        Task { @MainActor [weak self] in
            var losing: Set<String> = []
            for record in open {
                let count = try? await PharosCore.duckUserTableCount(connectionId: record.id)
                if count != 0 { losing.insert(record.id) }
            }
            self?.presentDeleteAlert(alert, selected: selected, openInMemory: losing, window: window)
        }
    }

    private func presentDeleteAlert(_ alert: NSAlert, selected: [ConnectionConfig], openInMemory: Set<String>,
                                    window: NSWindow) {
        let text = DestructiveConfirmationText.deleteConnectionsAlert(selected, openInMemory: openInMemory)
        alert.messageText = text.title
        alert.informativeText = text.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: text.button)
        alert.addButton(withTitle: String(localized: "Cancel"))

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let selectedBefore = self.selectedId
            for config in selected {
                if self.pendingStubIds.contains(config.id) {
                    self.pendingStubIds.remove(config.id)
                    self.connections.removeAll { $0.id == config.id }
                } else if config.isDuckDB && !config.isInMemoryDuckDB {
                    // Remove from Connections: the record stays, not saved, so
                    // the file's tabs, Sessions and history keep their link.
                    self.stateManager.setSaved(false, id: config.id)
                } else {
                    self.stateManager.deleteConnection(id: config.id)
                }
            }
            // Only when the record in the form went: the context menu can
            // delete a row that is not the selected one, and the form's edits
            // to another record must not go with it. Read before the loop
            // ran: removing a stub's row has already cleared the selection.
            if let current = selectedBefore, selected.contains(where: { $0.id == current }) {
                self.sidebar.selectedId = nil
                self.updateDetailVisibility()
            }
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

/// The capsule beside the record's name: Connected, Connecting…, Error,
/// Disconnected or Not Saved.
///
/// Its plate is resolved in `updateLayer()`, never written into the layer
/// once: a dynamic colour turned into a `CGColor` keeps the appearance it was
/// read in, which is how the old window's plates stayed light in Dark Mode
/// (lessons, 2026-09-16).
private final class StatusBadge: NSView {

    enum State {
        case connected, connecting, error, disconnected, stub

        var text: String {
            switch self {
            case .connected:   return String(localized: "Connected")
            case .connecting:  return String(localized: "Connecting…")
            case .error:       return String(localized: "Error")
            case .disconnected: return String(localized: "Disconnected")
            case .stub:        return String(localized: "Not Saved")
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
    private var state: State = .disconnected

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityIdentifier("connections.status")
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

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = state.background.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func apply(state: State) {
        self.state = state
        label.stringValue = state.text
        // A label's text colour stays dynamic: AppKit resolves it as it draws.
        label.textColor = state.foreground
        needsDisplay = true
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
            // `saveChangesInternal` beeps when it cannot save.
            completion(saveChangesInternal())
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

// MARK: - Detail pane

/// One of the two details the split view shows — the form, or the empty
/// state — as a view controller around a view built elsewhere.
private final class ConnectionsDetailPaneVC: NSViewController {
    private let content: NSView

    init(content: NSView) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("ConnectionsDetailPaneVC is built in code") }

    override func loadView() {
        view = content
    }
}
