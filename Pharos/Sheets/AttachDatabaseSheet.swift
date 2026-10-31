import AppKit
import UniformTypeIdentifiers
import os

/// Query ▸ Attach Database…: attach one of the user's saved PostgreSQL
/// connections, or a DuckDB or SQLite database file, to the open DuckDB
/// database, so DuckDB can query and join its tables (`alias.schema.table`).
/// Pharos remembers the attach and makes it again each time this database
/// opens (`duck_attach::restore`).
///
/// The password never appears here or in SQL: pharos-core reads it from the
/// connection (Keychain, or what the user typed this session) into a
/// temporary DuckDB secret (`duck_attach`). The connection is connected first
/// through the app's own path, so Touch ID and the password prompt work as
/// they do for a tab. A PostgreSQL attach lasts while that connection stays
/// connected.
final class AttachDatabaseSheet: NSViewController {

    private let duckConnectionId: String
    private let stateManager = AppStateManager.shared
    private var postgresCandidates: [ConnectionConfig] = []
    private var fileCandidates: [ConnectionConfig] = []
    /// A file from Choose File… or a navigator drop, listed first under
    /// DuckDB Files.
    private var chosenFile: URL?
    /// What this database has attached, for the disabled choices.
    private var attachments: [DuckDBAttachment] = []
    /// The choice before Choose File…, to go back to when the panel is
    /// cancelled.
    private var previousChoice: Int = -1

    private let sourcePopup = NSPopUpButton()
    private let aliasField = NSTextField()
    private let readOnlyCheckbox = NSButton(checkboxWithTitle: String(localized: "Read-only"), target: nil, action: nil)
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let cancelButton = NSButton()
    private let attachButton = NSButton()
    private var attachTask: Task<Void, Never>?

    /// Called after a successful attach.
    var onAttached: ((DuckDBAttachment) -> Void)?

    /// `file`: a database file to start on (a drop on the navigator).
    init(duckConnectionId: String, file: URL? = nil) {
        self.duckConnectionId = duckConnectionId
        self.chosenFile = file
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    /// One entry of the Database pop-up.
    private enum Choice {
        case postgres(ConnectionConfig)
        case file(path: String)
        case chooseFile

        var isChooseFile: Bool {
            if case .chooseFile = self { return true }
            return false
        }
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 250))
        view = container

        let title = NSTextField(labelWithString: String(localized: "Attach Database"))
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString: String(localized: "Query and join its tables as name.schema.table. Pharos attaches it again each time this database opens."))
        intro.textColor = .secondaryLabelColor

        let connections = stateManager.connections
        postgresCandidates = DuckDBAttachRules.postgresCandidates(connections)
        fileCandidates = DuckDBAttachRules.fileCandidates(connections, excludingFileOf: connections.first { $0.id == duckConnectionId })
        attachments = DuckDBAttachments.shared.attachments(for: duckConnectionId)
        sourcePopup.menu?.autoenablesItems = false
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceChanged)
        sourcePopup.setAccessibilityIdentifier("sheet.attachdb.source")
        rebuildSourceMenu()

        aliasField.setAccessibilityIdentifier("sheet.attachdb.alias")
        aliasField.target = self
        aliasField.action = #selector(attach)
        readOnlyCheckbox.state = .on
        readOnlyCheckbox.setAccessibilityIdentifier("sheet.attachdb.readonly")
        readOnlyCheckbox.toolTip = String(localized: "DuckDB refuses writes to the attached database. A read-only connection always attaches read-only.")

        let grid = NSGridView(views: [
            [NSTextField.formLabel(String(localized: "Database")), sourcePopup],
            [NSTextField.formLabel(String(localized: "Name in DuckDB")), aliasField],
            [NSGridCell.emptyContentView, readOnlyCheckbox],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 280
        grid.rowSpacing = 8
        grid.columnSpacing = 8

        messageLabel.textColor = .secondaryLabelColor
        messageLabel.setAccessibilityIdentifier("sheet.attachdb.message")
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
        attachButton.setAccessibilityIdentifier("sheet.attachdb.attach")
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
            intro.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
        sourceChanged()

        // The list above is the cached one; the core's is current.
        Task { @MainActor [weak self] in
            guard let self else { return }
            await DuckDBAttachments.shared.reload(self.duckConnectionId)
            self.attachments = DuckDBAttachments.shared.attachments(for: self.duckConnectionId)
            self.rebuildSourceMenu()
            self.sourceChanged()
        }
    }

    // MARK: The Database pop-up

    /// PostgreSQL connections, then DuckDB files, then Choose File…. Keeps
    /// the current choice when it is still there.
    private func rebuildSourceMenu() {
        let current = selectedChoice
        let menu = sourcePopup.menu ?? NSMenu()
        menu.removeAllItems()
        var firstEnabled: NSMenuItem?

        func add(_ item: NSMenuItem, reason: String?) {
            if let reason {
                item.isEnabled = false
                item.subtitle = reason
            } else if firstEnabled == nil {
                firstEnabled = item
            }
            menu.addItem(item)
        }

        if !postgresCandidates.isEmpty {
            menu.addItem(.sectionHeader(title: String(localized: "PostgreSQL")))
            for c in postgresCandidates {
                let item = NSMenuItem(title: c.name, action: nil, keyEquivalent: "")
                item.representedObject = Choice.postgres(c)
                item.subtitle = stateManager.status(for: c.id) == .connected
                    ? String(localized: "Connected") : String(localized: "Not connected")
                add(item, reason: DuckDBAttachRules.unavailableReason(postgres: c.id, in: attachments))
            }
        }
        var files: [(title: String, path: String)] = []
        if let chosenFile { files.append((chosenFile.lastPathComponent, chosenFile.path)) }
        let chosenPath = chosenFile.map { DuckDBFiles.canonicalPath($0.path) }
        for c in fileCandidates where DuckDBFiles.canonicalPath(c.database) != chosenPath {
            files.append((c.name, c.database))
        }
        menu.addItem(.sectionHeader(title: String(localized: "DuckDB Files")))
        for file in files {
            let item = NSMenuItem(title: file.title, action: nil, keyEquivalent: "")
            item.representedObject = Choice.file(path: file.path)
            item.subtitle = ((file.path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
            item.toolTip = file.path
            add(item, reason: DuckDBAttachRules.unavailableReason(file: file.path, in: attachments,
                                                                  openWritable: isOpenWritable(file.path)))
        }
        menu.addItem(.separator())
        let choose = NSMenuItem(title: String(localized: "Choose File…"), action: nil, keyEquivalent: "")
        choose.representedObject = Choice.chooseFile
        menu.addItem(choose)

        // The chosen file first; else the current choice; else a connected
        // PostgreSQL connection (it attaches without a prompt); else the
        // first choice that can be made.
        let keep = menu.items.first { item in
            guard item.isEnabled, let choice = item.representedObject as? Choice else { return false }
            switch (choice, current) {
            case (.file(let a), .file(let b)?): return a == b
            case (.postgres(let a), .postgres(let b)?): return a.id == b.id
            default: return false
            }
        }
        let chosen = chosenFile.flatMap { url in
            menu.items.first { if case .file(let p)? = $0.representedObject as? Choice { return p == url.path && $0.isEnabled }; return false }
        }
        let connected = menu.items.first {
            if case .postgres(let c)? = $0.representedObject as? Choice { return $0.isEnabled && stateManager.status(for: c.id) == .connected }
            return false
        }
        if let item = chosen ?? keep ?? connected ?? firstEnabled {
            sourcePopup.select(item)
        } else {
            sourcePopup.select(choose)
        }
        previousChoice = sourcePopup.indexOfSelectedItem
    }

    /// Whether a tab has this file open with write access (rule G1).
    private func isOpenWritable(_ path: String) -> Bool {
        let open = DuckDBFiles.openRecords(for: path, in: stateManager.connections) {
            self.stateManager.status(for: $0) == .connected
        }
        return open.contains { !$0.readOnly }
    }

    private var selectedChoice: Choice? {
        sourcePopup.selectedItem?.representedObject as? Choice
    }

    @objc private func sourceChanged() {
        switch selectedChoice {
        case .postgres(let c):
            previousChoice = sourcePopup.indexOfSelectedItem
            aliasField.placeholderString = DuckDBAttachRules.defaultAlias(for: c.name)
            let forced = DuckDBAttachRules.forcesReadOnly(c)
            if forced { readOnlyCheckbox.state = .on }
            readOnlyCheckbox.isEnabled = !forced
            attachButton.isEnabled = attachTask == nil
            show(stateManager.status(for: c.id) == .connected
                 ? String(localized: "It stays attached while the connection is connected.")
                 : String(localized: "Pharos connects it first."))
        case .file(let path):
            previousChoice = sourcePopup.indexOfSelectedItem
            aliasField.placeholderString = DuckDBAttachRules.defaultAlias(forFile: path)
            readOnlyCheckbox.isEnabled = true
            attachButton.isEnabled = attachTask == nil
            show("")
        case .chooseFile:
            chooseFile()
        case nil:
            attachButton.isEnabled = false
            show(String(localized: "Choose a database file, or add a PostgreSQL connection in Manage Connections…"))
        }
    }

    /// Choose File…: an open panel for DuckDB and SQLite files, as a sheet on
    /// this sheet.
    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a DuckDB or SQLite database to attach.")
        panel.prompt = String(localized: "Choose")
        panel.allowedContentTypes = DuckDBAttachRules.fileExtensions.compactMap { UTType(filenameExtension: $0) }
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            if response == .OK, let url = panel.url {
                guard DuckDBAttachRules.isDatabaseFile(url) else {
                    self.backToPreviousChoice()
                    self.show(String(localized: "“\(url.lastPathComponent)” is not a DuckDB or SQLite database."), error: true)
                    return
                }
                self.chosenFile = url
                self.rebuildSourceMenu()
                self.sourceChanged()
            } else {
                self.backToPreviousChoice()
            }
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    private func backToPreviousChoice() {
        guard let item = sourcePopup.item(at: previousChoice), item.isEnabled,
              let choice = item.representedObject as? Choice, !choice.isChooseFile else {
            attachButton.isEnabled = false
            return
        }
        sourcePopup.select(item)
        sourceChanged()
    }

    private func show(_ text: String, error: Bool = false) {
        messageLabel.stringValue = text
        messageLabel.textColor = error ? .systemRed : .secondaryLabelColor
    }

    @objc private func cancel() {
        attachTask?.cancel()
        dismiss(nil)
    }

    // MARK: Attach

    @objc private func attach() {
        guard attachTask == nil else { return }
        let source: DuckDBAttachSource
        let pg: ConnectionConfig?
        switch selectedChoice {
        case .postgres(let c): source = .postgres(c.id); pg = c
        case .file(let path): source = .file(path); pg = nil
        default: return
        }
        let alias = aliasField.stringValue.trimmingCharacters(in: .whitespaces)
        guard DuckDBAttachRules.isValidAlias(alias) else {
            show(String(localized: "Use lower-case letters, digits and _ for the name, starting with a letter."), error: true)
            return
        }
        let readOnly = readOnlyCheckbox.state == .on
        setBusy(true)
        attachTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if let pg { self.stateManager.endConnectWithoutWindow(id: pg.id) }
                self.attachTask = nil
                self.setBusy(false)
            }
            if let pg, self.stateManager.status(for: pg.id) != .connected {
                self.show(String(localized: "Connecting \(pg.name)…"))
                // The DuckDB window stays on its own connection.
                self.stateManager.connectWithoutWindow(id: pg.id)
                // Touch ID or a password sheet may come first; wait for the
                // outcome, as long as the user keeps this sheet open.
                while self.stateManager.status(for: pg.id) != .connected {
                    try? await Task.sleep(for: .milliseconds(250))
                    if Task.isCancelled { return }
                }
            }
            self.show(String(localized: "Attaching…"))
            do {
                let attached = try await PharosCore.duckAttach(
                    duckConnectionId: self.duckConnectionId, source: source, alias: alias, readOnly: readOnly)
                DuckDBAttachments.shared.didChange(duckConnectionId: self.duckConnectionId)
                self.onAttached?(attached)
                self.dismiss(nil)
            } catch {
                self.show(error.localizedDescription, error: true)
            }
        }
    }

    private func setBusy(_ busy: Bool) {
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        attachButton.isEnabled = !busy && selectedChoice.map { !$0.isChooseFile } == true
        sourcePopup.isEnabled = !busy
        aliasField.isEnabled = !busy
    }
}

/// Keeps DuckDB navigators current with their attached databases, and makes
/// remembered attaches again when their PostgreSQL connection connects.
///
/// - A PostgreSQL connection connects: the core attaches it to each
///   connected DuckDB database that remembers it (`restore_for_pg`).
/// - A PostgreSQL connection disconnects: the core has detached it; those
///   navigators reload.
/// - A DuckDB database connects: the core restored its attaches before the
///   connect returned; a restore that failed shows as a toast.
@MainActor
final class DuckDBAttachments {
    static let shared = DuckDBAttachments()

    /// Posted after `attachments(for:)` changes; userInfo `connectionId` is
    /// the DuckDB connection.
    static let listDidChange = Notification.Name("PharosDuckDBAttachmentsDidChange")

    /// DuckDB connection id → its attaches, as the core last listed them.
    private var lists: [String: [DuckDBAttachment]] = [:]
    private var observer: NSObjectProtocol?

    func attachments(for duckConnectionId: String) -> [DuckDBAttachment] {
        lists[duckConnectionId] ?? []
    }

    /// Whether the core has listed this database's attaches since it
    /// connected (an empty list counts).
    func hasList(for duckConnectionId: String) -> Bool {
        lists[duckConnectionId] != nil
    }

    /// The attach a navigator schema belongs to (`alias.schema`), if any.
    func attachment(ofSchema schema: String, connectionId: String) -> DuckDBAttachment? {
        guard let db = DuckDBAttachRules.attachedDatabase(ofSchema: schema) else { return nil }
        return attachments(for: connectionId).first { $0.alias == db }
    }

    /// Start watching connection status (app launch).
    func startObserving() {
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

    /// An attach or detach on this DuckDB database (the sheet, Detach, a
    /// card): reload its metadata and its list.
    func didChange(duckConnectionId: String) {
        AppStateManager.shared.refreshMetadata(connectionId: duckConnectionId)
        Task { await reload(duckConnectionId) }
    }

    /// Ask the core for this database's attaches.
    func reload(_ duckConnectionId: String) async {
        guard AppStateManager.shared.status(for: duckConnectionId) == .connected else {
            if lists.removeValue(forKey: duckConnectionId) != nil { post(duckConnectionId) }
            return
        }
        // A failed read counts as an empty list, so a navigator does not ask
        // again in a loop.
        lists[duckConnectionId] = (try? await PharosCore.duckAttachments(duckConnectionId: duckConnectionId)) ?? []
        post(duckConnectionId)
    }

    private func post(_ duckConnectionId: String) {
        NotificationCenter.default.post(name: Self.listDidChange, object: self,
                                        userInfo: ["connectionId": duckConnectionId])
    }

    private func statusChanged(_ id: String) {
        let manager = AppStateManager.shared
        guard let config = manager.connections.first(where: { $0.id == id }) else { return }
        let connected = manager.status(for: id) == .connected
        switch config.engine {
        case .duckdb:
            guard connected else {
                lists[id] = nil
                return
            }
            Task {
                let failures = (try? await PharosCore.duckTakeRestoreFailures(duckConnectionId: id)) ?? []
                await reload(id)
                if !failures.isEmpty { Self.toast(failures, duckConnectionId: id) }
            }
        case .postgres:
            if connected {
                Task {
                    let outcomes = (try? await PharosCore.duckRestoreAttachments(forPostgres: id)) ?? []
                    for duck in Set(outcomes.filter { $0.error == nil }.map(\.duckConnectionId)) {
                        didChange(duckConnectionId: duck)
                    }
                    for (duck, failed) in Dictionary(grouping: outcomes.filter { $0.error != nil }, by: \.duckConnectionId) {
                        Self.toast(failed.map { "\($0.alias): \($0.error ?? "")" }, duckConnectionId: duck)
                    }
                }
            } else {
                for (duck, list) in lists where list.contains(where: { $0.pgId == id && $0.attached }) {
                    if manager.status(for: duck) == .connected { didChange(duckConnectionId: duck) }
                }
            }
        }
    }

    /// Show restore failures in a window on that DuckDB database (the key
    /// one first).
    private static func toast(_ failures: [String], duckConnectionId: String) {
        Log.ui.error("Could not restore \(failures.count) DuckDB attach(es)")
        guard let app = NSApp.delegate as? AppDelegate else { return }
        let windows = app.windowControllers.filter { $0.session.activeConnectionId == duckConnectionId }
        let host = (windows.first { $0.window?.isKeyWindow == true } ?? windows.first)?.window?.contentView
        guard let host else { return }
        let message = String(localized: "Pharos could not attach again:") + "\n" + failures.joined(separator: "\n")
        Toast.show(in: host, message: message, style: .warning)
    }
}
