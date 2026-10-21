import AppKit
import os

/// Query ▸ Attach PostgreSQL Connection…: attach one of the user's saved
/// PostgreSQL connections to the open DuckDB database, so DuckDB can query
/// and join its tables (`alias.schema.table`).
///
/// The password never appears here or in SQL: pharos-core reads it from the
/// connection (Keychain, or what the user typed this session) into a
/// temporary DuckDB secret (`duck_attach`). The connection is connected first
/// through the app's own path, so Touch ID and the password prompt work as
/// they do for a tab. The attach lasts while that connection stays connected.
final class AttachPostgresSheet: NSViewController {

    private let duckConnectionId: String
    private let stateManager = AppStateManager.shared
    private var candidates: [ConnectionConfig] = []

    private let connectionPopup = NSPopUpButton()
    private let aliasField = NSTextField()
    private let readOnlyCheckbox = NSButton(checkboxWithTitle: String(localized: "Read-only"), target: nil, action: nil)
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let cancelButton = NSButton()
    private let attachButton = NSButton()
    private var attachTask: Task<Void, Never>?

    /// Called after a successful attach.
    var onAttached: ((DuckDBAttachment) -> Void)?

    init(duckConnectionId: String) {
        self.duckConnectionId = duckConnectionId
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 240))
        view = container

        let title = NSTextField(labelWithString: String(localized: "Attach PostgreSQL Connection"))
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString: String(localized: "DuckDB can then query and join its tables as name.schema.table. It stays attached while the connection stays connected."))
        intro.textColor = .secondaryLabelColor

        candidates = DuckDBAttachRules.candidates(stateManager.connections)
        connectionPopup.removeAllItems()
        for c in candidates {
            let item = NSMenuItem(title: c.name, action: nil, keyEquivalent: "")
            item.representedObject = c.id
            item.subtitle = stateManager.status(for: c.id) == .connected
                ? String(localized: "Connected") : String(localized: "Not connected")
            connectionPopup.menu?.addItem(item)
        }
        // Start on a connected one: it attaches without any prompt.
        if let i = candidates.firstIndex(where: { stateManager.status(for: $0.id) == .connected }) {
            connectionPopup.selectItem(at: i)
        }
        connectionPopup.target = self
        connectionPopup.action = #selector(connectionChanged)
        connectionPopup.setAccessibilityIdentifier("sheet.attachpg.connection")

        aliasField.setAccessibilityIdentifier("sheet.attachpg.alias")
        aliasField.target = self
        aliasField.action = #selector(attach)
        readOnlyCheckbox.state = .on
        readOnlyCheckbox.setAccessibilityIdentifier("sheet.attachpg.readonly")
        readOnlyCheckbox.toolTip = String(localized: "DuckDB refuses writes to the attached database. A read-only connection always attaches read-only.")

        let grid = NSGridView(views: [
            [NSTextField.formLabel(String(localized: "Connection")), connectionPopup],
            [NSTextField.formLabel(String(localized: "Name in DuckDB")), aliasField],
            [NSGridCell.emptyContentView, readOnlyCheckbox],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 260
        grid.rowSpacing = 8
        grid.columnSpacing = 8

        messageLabel.textColor = .secondaryLabelColor
        messageLabel.setAccessibilityIdentifier("sheet.attachpg.message")
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        cancelButton.title = String(localized: "Cancel")
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        attachButton.title = String(localized: "Attach")
        attachButton.target = self
        attachButton.action = #selector(attach)
        attachButton.keyEquivalent = "\r"
        attachButton.setAccessibilityIdentifier("sheet.attachpg.attach")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [spinner, spacer, cancelButton, attachButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [title, intro, grid, messageLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.spanArrangedSubviewsFullWidth()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            intro.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
        ])
        connectionChanged()
    }

    private var selected: ConnectionConfig? {
        guard let id = connectionPopup.selectedItem?.representedObject as? String else { return nil }
        return candidates.first { $0.id == id }
    }

    @objc private func connectionChanged() {
        guard let c = selected else {
            attachButton.isEnabled = false
            show(String(localized: "There is no saved PostgreSQL connection. Add one in Manage Connections…"))
            return
        }
        aliasField.placeholderString = DuckDBAttachRules.defaultAlias(for: c.name)
        let forced = DuckDBAttachRules.forcesReadOnly(c)
        if forced { readOnlyCheckbox.state = .on }
        readOnlyCheckbox.isEnabled = !forced
        attachButton.isEnabled = true
        show(stateManager.status(for: c.id) == .connected
             ? "" : String(localized: "Pharos connects it first."))
    }

    private func show(_ text: String, error: Bool = false) {
        messageLabel.stringValue = text
        messageLabel.textColor = error ? .systemRed : .secondaryLabelColor
    }

    @objc private func cancel() {
        attachTask?.cancel()
        dismiss(nil)
    }

    @objc private func attach() {
        guard attachTask == nil, let c = selected else { return }
        let alias = aliasField.stringValue.trimmingCharacters(in: .whitespaces)
        guard DuckDBAttachRules.isValidAlias(alias) else {
            show(String(localized: "Use lower-case letters, digits and _ for the name, starting with a letter."), error: true)
            return
        }
        let readOnly = readOnlyCheckbox.state == .on
        setBusy(true)
        attachTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.attachTask = nil; self.setBusy(false) }
            if self.stateManager.status(for: c.id) != .connected {
                self.show(String(localized: "Connecting \(c.name)…"))
                self.stateManager.connect(id: c.id)
                // Touch ID or a password sheet may come first; wait for the
                // outcome, as long as the user keeps this sheet open.
                while self.stateManager.status(for: c.id) != .connected {
                    try? await Task.sleep(for: .milliseconds(250))
                    if Task.isCancelled { return }
                }
            }
            self.show(String(localized: "Attaching…"))
            do {
                let attached = try await PharosCore.duckAttachPostgres(
                    duckConnectionId: self.duckConnectionId, pgConnectionId: c.id, alias: alias, readOnly: readOnly)
                DuckDBAttachments.shared.didAttach(attached, duckConnectionId: self.duckConnectionId)
                self.onAttached?(attached)
                self.dismiss(nil)
            } catch {
                self.show(error.localizedDescription, error: true)
            }
        }
    }

    private func setBusy(_ busy: Bool) {
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        attachButton.isEnabled = !busy && selected != nil
        connectionPopup.isEnabled = !busy
        aliasField.isEnabled = !busy
    }
}

/// Keeps DuckDB navigators current: pharos-core detaches a PostgreSQL
/// connection from DuckDB when that connection disconnects, so the DuckDB
/// database's schema list must reload then too.
@MainActor
final class DuckDBAttachments {
    static let shared = DuckDBAttachments()

    /// PostgreSQL connection id → the DuckDB connection ids it is attached to.
    private var attached: [String: Set<String>] = [:]
    private var observer: NSObjectProtocol?

    func didAttach(_ attachment: DuckDBAttachment, duckConnectionId: String) {
        attached[attachment.pgId, default: []].insert(duckConnectionId)
        startObserving()
        Self.refreshMetadata(duckConnectionId)
    }

    func didDetach(duckConnectionId: String) {
        for key in attached.keys { attached[key]?.remove(duckConnectionId) }
        Self.refreshMetadata(duckConnectionId)
    }

    static func refreshMetadata(_ connectionId: String) {
        AppStateManager.shared.refreshMetadata(connectionId: connectionId)
    }

    private func startObserving() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: AppStateManager.connectionStatusDidChange, object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                guard let id = note.userInfo?["connectionId"] as? String else { return }
                DuckDBAttachments.shared.statusChanged(id)
            }
        }
    }

    private func statusChanged(_ pgId: String) {
        guard let ducks = attached[pgId], AppStateManager.shared.status(for: pgId) != .connected else { return }
        attached[pgId] = nil
        for duck in ducks where AppStateManager.shared.status(for: duck) == .connected {
            Self.refreshMetadata(duck)
        }
    }
}
