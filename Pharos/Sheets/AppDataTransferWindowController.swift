import AppKit
import UniformTypeIdentifiers

/// File ▸ Export App Data… and File ▸ Import App Data…: the user's Sessions,
/// query history, connections (with their passwords), tags and variables,
/// written to one file and read back, on this Mac or another one.
///
/// One small window, app-wide like the Tag Manager, so both commands work
/// with no main window open. The core does the work
/// (`pharos-core/src/commands/app_backup.rs`); this is the form, the save and
/// open panels, and the refresh of every list the import changed.
@MainActor
final class AppDataTransferWindowController: NSWindowController {

    static let shared = AppDataTransferWindowController()

    private static let size = NSSize(width: 520, height: 560)

    private init() {
        let window = UtilityWindow(autosaveName: "PharosAppDataTransferWindow",
                                   title: String(localized: "Export App Data"),
                                   defaultSize: Self.size,
                                   minimumSize: Self.size)
        window.styleMask.remove(.resizable)
        window.styleMask.remove(.miniaturizable)
        super.init(window: window)
        window.setAccessibilityIdentifier("window.appDataTransfer")
        // An export or import that is under way finishes before the window goes.
        window.shouldClose = { [weak self] in !(self?.isBusy ?? false) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private var isBusy: Bool {
        (window?.contentViewController as? AppDataTransferForm)?.isBusy ?? false
    }

    /// File ▸ Export App Data….
    func showExport() {
        guard !isBusy else { return bringForward() }
        install(ExportAppDataVC(), title: String(localized: "Export App Data"))
    }

    /// File ▸ Import App Data…: choose the file first, read what it holds,
    /// then show the form for it.
    func showImport() {
        guard !isBusy else { return bringForward() }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import App Data")
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose a file made with File \u{25B8} Export App Data\u{2026}")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var types: [UTType] = [.json]
        if let type = UTType(filenameExtension: AppDataTransferRules.fileExtension) { types.insert(type, at: 0) }
        panel.allowedContentTypes = types
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            do {
                let summary = try await PharosCore.inspectAppData(path: url.path, passphrase: nil)
                self.install(ImportAppDataVC(url: url, summary: summary), title: String(localized: "Import App Data"))
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = String(localized: "This file cannot be imported.")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    private func install(_ controller: NSViewController, title: String) {
        guard let window else { return }
        window.title = title
        window.contentViewController = controller
        // After the assignment: `contentViewController` sizes the window to
        // the controller's fitting size.
        window.setContentSize(Self.size)
        window.center()
        bringForward()
    }

    private func bringForward() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// What the window asks of either form.
@MainActor
protocol AppDataTransferForm: AnyObject {
    var isBusy: Bool { get }
}

// MARK: - Shared layout

@MainActor
private enum TransferLayout {
    static func title(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        return label
    }

    /// The width of the form's column: the window, less its margins.
    nonisolated static let columnWidth: CGFloat = 480
    static let indent: CGFloat = 20

    /// A small secondary label that wraps at `width` (the column, or the
    /// column less one indent).
    static func note(_ text: String = "", width: CGFloat = columnWidth) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.preferredMaxLayoutWidth = width
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }

    static func indented(_ view: NSView) -> NSView {
        let stack = NSStackView(views: [view])
        stack.edgeInsets = NSEdgeInsets(top: 0, left: indent, bottom: 0, right: 0)
        return stack
    }

    static var indentedWidth: CGFloat { columnWidth - indent }

    /// The form's column inside `root`, below the title bar, with the footer
    /// pinned to the bottom.
    static func install(column: NSStackView, footer: NSStackView, in root: NSView) {
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 16),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            column.bottomAnchor.constraint(lessThanOrEqualTo: footer.topAnchor, constant: -12),
        ])
    }

    static func showAlert(_ message: String, _ detail: String, in window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

// MARK: - Export

final class ExportAppDataVC: NSViewController, NSTextFieldDelegate, AppDataTransferForm {

    private(set) var isBusy = false

    private var boxes: [AppDataCategory: NSButton] = [:]
    let resultsBox = NSButton(checkboxWithTitle: String(localized: "Include each Session\u{2019}s saved results"),
                              target: nil, action: nil)
    let encryptBox = NSButton(checkboxWithTitle: String(localized: "Encrypt the file with a password"),
                              target: nil, action: nil)
    private let encryptNote = TransferLayout.note(width: TransferLayout.indentedWidth)
    let passwordField = NSSecureTextField()
    let confirmField = NSSecureTextField()
    private let problemLabel = TransferLayout.note(width: 260)
    private let spinner = NSProgressIndicator()
    let exportButton = NSButton(title: String(localized: "Export\u{2026}"), target: nil, action: nil)
    private let cancelButton = NSButton(title: String(localized: "Cancel"), target: nil, action: nil)

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: NSSize(width: 520, height: 560)))
        view = root

        let hint = TransferLayout.note(String(localized:
            "Choose what to write to the file. You can import it into Pharos on this Mac or another one."))
        var rows: [NSView] = [TransferLayout.title(String(localized: "Export App Data")), hint]
        for category in AppDataCategory.allCases {
            let box = NSButton(checkboxWithTitle: category.title, target: self, action: #selector(changed))
            box.state = .on
            boxes[category] = box
            rows.append(box)
            if category == .sessions {
                resultsBox.target = self
                resultsBox.action = #selector(changed)
                resultsBox.state = .on
                rows.append(TransferLayout.indented(resultsBox))
                rows.append(TransferLayout.indented(TransferLayout.note(String(localized:
                    "Saved results hold rows from your databases and can make the file large."),
                    width: TransferLayout.indentedWidth)))
            }
        }

        encryptBox.target = self
        encryptBox.action = #selector(changed)
        encryptBox.state = .on
        for (field, placeholder, label) in [
            (passwordField, String(localized: "Password"), String(localized: "Password")),
            (confirmField, String(localized: "Confirm password"), String(localized: "Confirm password")),
        ] {
            field.placeholderString = placeholder
            field.setAccessibilityLabel(label)
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        }
        let separator = NSBox()
        separator.boxType = .separator
        rows += [separator, encryptBox, TransferLayout.indented(encryptNote),
                 TransferLayout.indented(passwordField), TransferLayout.indented(confirmField),
                 TransferLayout.indented(TransferLayout.note(String(localized:
                    "Pharos cannot recover this password. Without it, the file cannot be imported."),
                    width: TransferLayout.indentedWidth))]

        let column = NSStackView(views: rows)
        separator.widthAnchor.constraint(equalToConstant: TransferLayout.columnWidth).isActive = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        problemLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        problemLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.keyEquivalent = "\u{1b}"
        exportButton.target = self
        exportButton.action = #selector(exportTapped)
        exportButton.keyEquivalent = "\r"
        let footer = NSStackView(views: [spinner, problemLabel, cancelButton, exportButton])
        TransferLayout.install(column: column, footer: footer, in: root)
        refresh()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(passwordField)
    }

    private var categories: AppDataCategories {
        var categories = AppDataCategories()
        for (category, box) in boxes { categories[keyPath: category.keyPath] = box.state == .on }
        return categories
    }

    private var encrypt: Bool { encryptBox.state == .on }

    func controlTextDidChange(_ notification: Notification) { refresh() }

    @objc private func changed(_ sender: Any?) { refresh() }

    /// Bring every control in line with the choices: the results box follows
    /// Sessions; Connections turn encryption on and lock it.
    func refresh() {
        let categories = self.categories
        resultsBox.isEnabled = categories.sessions && !isBusy
        let required = AppDataTransferRules.encryptionRequired(categories)
        if required { encryptBox.state = .on }
        encryptBox.isEnabled = !required && !isBusy
        encryptNote.stringValue = required
            ? String(localized: "Connections are written with their passwords, so the file is always encrypted.")
            : encrypt
            ? String(localized: "The file can only be read with this password.")
            : String(localized: "Without a password, anyone who has the file can read what is in it.")
        passwordField.isEnabled = encrypt && !isBusy
        confirmField.isEnabled = encrypt && !isBusy
        for box in boxes.values { box.isEnabled = !isBusy }
        let problem = AppDataTransferRules.exportProblem(categories: categories, encrypt: encrypt,
                                                         password: passwordField.stringValue,
                                                         confirmation: confirmField.stringValue)
        problemLabel.stringValue = isBusy ? String(localized: "Exporting\u{2026}")
            : problem.map(AppDataTransferRules.message(for:)) ?? ""
        exportButton.isEnabled = problem == nil && !isBusy
        cancelButton.isEnabled = !isBusy
    }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        refresh()
    }

    @objc private func cancelTapped(_ sender: Any?) { view.window?.close() }

    @objc private func exportTapped(_ sender: Any?) {
        let categories = self.categories
        guard let window = view.window,
              AppDataTransferRules.exportProblem(categories: categories, encrypt: encrypt,
                                                 password: passwordField.stringValue,
                                                 confirmation: confirmField.stringValue) == nil else { return }
        let passphrase = encrypt ? passwordField.stringValue : nil
        let includeResults = categories.sessions && resultsBox.state == .on
        Task { @MainActor in
            // Every saved password leaves the Keychain in this file, so the
            // device owner confirms it, as for showing one password.
            if categories.connections {
                switch await DeviceOwnerGate.authenticate(reason: String(localized: "export your saved connection passwords")) {
                case .authenticated: break
                case .cancelled: return
                case .failed(let reason):
                    TransferLayout.showAlert(String(localized: "The passwords cannot be exported."), reason, in: window)
                    return
                }
            }
            guard let url = await self.chooseDestination(in: window) else { return }
            self.setBusy(true)
            do {
                let result = try await PharosCore.exportAppData(ExportAppDataOptions(
                    path: url.path, categories: categories,
                    includeSessionResults: includeResults, passphrase: passphrase))
                self.setBusy(false)
                self.showFinished(result, url: url, in: window)
            } catch {
                self.setBusy(false)
                TransferLayout.showAlert(String(localized: "The export did not finish."),
                                         error.localizedDescription, in: window)
            }
        }
    }

    private func chooseDestination(in window: NSWindow) async -> URL? {
        let panel = NSSavePanel()
        panel.title = String(localized: "Export App Data")
        panel.nameFieldStringValue = AppDataTransferRules.defaultFileName(on: Date())
        if let type = UTType(filenameExtension: AppDataTransferRules.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }

    private func showFinished(_ result: ExportAppDataResult, url: URL, in window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Export finished")
        var lines = AppDataTransferRules.exportSummaryLines(result.summary)
        lines.append("")
        lines.append(ByteCountFormatter.string(fromByteCount: Int64(result.bytes), countStyle: .file)
                     + " \u{2014} " + url.lastPathComponent)
        if result.summary.encrypted {
            lines.append(String(localized: "Keep the password somewhere safe: the file cannot be imported without it."))
        }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: String(localized: "Done"))
        alert.addButton(withTitle: String(localized: "Show in Finder"))
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            window.close()
        }
    }
}

// MARK: - Import

final class ImportAppDataVC: NSViewController, NSTextFieldDelegate, AppDataTransferForm {

    private(set) var isBusy = false

    let url: URL
    private(set) var summary: AppDataSummary
    /// The password that opened the file, sent again with the import.
    private var passphrase: String?

    private let fileLabel = NSTextField(labelWithString: "")
    private let dateLabel = TransferLayout.note()

    // Shown while the file is encrypted and not yet opened.
    private let lockedSection = NSStackView()
    let unlockField = NSSecureTextField()
    let unlockButton = NSButton(title: String(localized: "Open"), target: nil, action: nil)
    private let unlockError = TransferLayout.note(width: TransferLayout.columnWidth)

    // Shown once the file's contents are known.
    private let readySection = NSStackView()
    private var boxes: [AppDataCategory: NSButton] = [:]
    private var details: [AppDataCategory: NSTextField] = [:]
    let conflictPopup = NSPopUpButton()

    private let statusLabel = TransferLayout.note(width: 260)
    private let spinner = NSProgressIndicator()
    let importButton = NSButton(title: String(localized: "Import"), target: nil, action: nil)
    private let cancelButton = NSButton(title: String(localized: "Cancel"), target: nil, action: nil)

    init(url: URL, summary: AppDataSummary) {
        self.url = url
        self.summary = summary
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: NSSize(width: 520, height: 560)))
        view = root

        fileLabel.stringValue = DisplayEscape.escaped(url.lastPathComponent)
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)

        // Locked: the password, and Open.
        unlockField.placeholderString = String(localized: "Password")
        unlockField.setAccessibilityLabel(String(localized: "Password"))
        unlockField.delegate = self
        unlockField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        unlockButton.target = self
        unlockButton.action = #selector(unlockTapped)
        let unlockRow = NSStackView(views: [unlockField, unlockButton])
        unlockRow.orientation = .horizontal
        unlockError.textColor = .systemRed
        lockedSection.orientation = .vertical
        lockedSection.alignment = .leading
        lockedSection.spacing = 8
        for item in [TransferLayout.note(String(localized:
                        "This file is encrypted. Enter the password it was exported with.")),
                     unlockRow, unlockError] as [NSView] {
            lockedSection.addArrangedSubview(item)
        }

        // Ready: a box per category, with what the file holds of it.
        readySection.orientation = .vertical
        readySection.alignment = .leading
        readySection.spacing = 6
        readySection.addArrangedSubview(TransferLayout.note(String(localized: "Choose what to import:")))
        for category in AppDataCategory.allCases {
            let box = NSButton(checkboxWithTitle: category.title, target: self, action: #selector(changed))
            let detail = TransferLayout.note(width: TransferLayout.indentedWidth)
            boxes[category] = box
            details[category] = detail
            readySection.addArrangedSubview(box)
            readySection.addArrangedSubview(TransferLayout.indented(detail))
        }
        conflictPopup.addItems(withTitles: [
            String(localized: "Replace them with the file\u{2019}s copy"),
            String(localized: "Keep this Mac\u{2019}s copy"),
        ])
        conflictPopup.setAccessibilityLabel(String(localized: "Items already on this Mac"))
        let conflictRow = NSStackView(views: [NSTextField(labelWithString: String(localized: "Items already on this Mac:")),
                                              conflictPopup])
        conflictRow.orientation = .horizontal
        readySection.setCustomSpacing(14, after: readySection.arrangedSubviews.last!)
        readySection.addArrangedSubview(conflictRow)
        let note = TransferLayout.note(String(localized:
            "Nothing on this Mac is deleted. Query history this Mac already has is always kept. Imported history is subject to your history retention setting."))
        readySection.addArrangedSubview(note)

        let column = NSStackView(views: [TransferLayout.title(String(localized: "Import App Data")),
                                         fileLabel, dateLabel, lockedSection, readySection])
        column.setCustomSpacing(14, after: dateLabel)
        fileLabel.widthAnchor.constraint(lessThanOrEqualToConstant: TransferLayout.columnWidth).isActive = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.keyEquivalent = "\u{1b}"
        importButton.target = self
        importButton.action = #selector(importTapped)
        let footer = NSStackView(views: [spinner, statusLabel, cancelButton, importButton])
        TransferLayout.install(column: column, footer: footer, in: root)
        apply(summary)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if summary.locked { view.window?.makeFirstResponder(unlockField) }
    }

    /// Show what `summary` says: the password row while the file is locked,
    /// the choices once it is open. Every category the file holds starts
    /// ticked; one it does not hold is unavailable.
    private func apply(_ summary: AppDataSummary) {
        self.summary = summary
        dateLabel.stringValue = Self.exportedText(summary)
        lockedSection.isHidden = !summary.locked
        readySection.isHidden = summary.locked
        if !summary.locked {
            let present = AppDataCategories.present(in: summary)
            for category in AppDataCategory.allCases {
                let available = present[keyPath: category.keyPath]
                boxes[category]?.isEnabled = available
                boxes[category]?.state = available ? .on : .off
                details[category]?.stringValue = AppDataTransferRules.importChoiceDetail(category, in: summary)
            }
        }
        refresh()
    }

    static func exportedText(_ summary: AppDataSummary) -> String {
        let kind = summary.encrypted ? String(localized: "Encrypted") : String(localized: "Not encrypted")
        guard let raw = summary.exportedAt, let date = ISO8601DateFormatter().date(from: raw) else { return kind }
        let when = date.formatted(date: .abbreviated, time: .shortened)
        return String(localized: "\(kind) \u{00B7} Exported \(when)")
    }

    private var categories: AppDataCategories {
        var categories = AppDataCategories()
        for (category, box) in boxes { categories[keyPath: category.keyPath] = box.isEnabled && box.state == .on }
        return categories
    }

    func controlTextDidChange(_ notification: Notification) {
        unlockError.stringValue = ""
        refresh()
    }

    @objc private func changed(_ sender: Any?) { refresh() }

    private func refresh() {
        let locked = summary.locked
        unlockField.isEnabled = !isBusy
        unlockButton.isEnabled = !isBusy && !unlockField.stringValue.isEmpty
        // Return opens the file while it is locked, and imports once it is open.
        unlockButton.keyEquivalent = locked ? "\r" : ""
        importButton.keyEquivalent = locked ? "" : "\r"
        importButton.isEnabled = !locked && !isBusy && !categories.isEmpty
        cancelButton.isEnabled = !isBusy
        conflictPopup.isEnabled = !isBusy
        for (category, box) in boxes {
            box.isEnabled = !isBusy && AppDataCategories.present(in: summary)[keyPath: category.keyPath]
        }
        if !isBusy {
            statusLabel.stringValue = locked || !categories.isEmpty ? ""
                : String(localized: "Choose at least one kind of data to import.")
        }
    }

    private func setBusy(_ busy: Bool, _ status: String = "") {
        isBusy = busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        statusLabel.stringValue = status
        refresh()
    }

    @objc private func cancelTapped(_ sender: Any?) { view.window?.close() }

    @objc private func unlockTapped(_ sender: Any?) {
        let password = unlockField.stringValue
        guard !password.isEmpty, !isBusy else { return }
        setBusy(true, String(localized: "Opening\u{2026}"))
        Task { @MainActor in
            do {
                let opened = try await PharosCore.inspectAppData(path: self.url.path, passphrase: password)
                self.setBusy(false)
                self.passphrase = password
                self.apply(opened)
            } catch {
                self.setBusy(false)
                self.unlockError.stringValue = error.localizedDescription
                self.view.window?.makeFirstResponder(self.unlockField)
            }
        }
    }

    @objc private func importTapped(_ sender: Any?) {
        let categories = self.categories
        guard !summary.locked, !categories.isEmpty, !isBusy, let window = view.window else { return }
        let conflict: AppDataConflictPolicy = conflictPopup.indexOfSelectedItem == 1 ? .keep : .replace
        let options = ImportAppDataOptions(path: url.path, passphrase: passphrase,
                                           categories: categories, conflict: conflict)
        setBusy(true, String(localized: "Importing\u{2026}"))
        Task { @MainActor in
            do {
                let result = try await PharosCore.importAppData(options)
                Self.refreshStores(after: categories)
                self.setBusy(false)
                self.showFinished(result, in: window)
            } catch {
                // A category that finished before the failure is in the store,
                // so the lists are re-read either way.
                Self.refreshStores(after: categories)
                self.setBusy(false)
                TransferLayout.showAlert(String(localized: "The import did not finish."),
                                         error.localizedDescription, in: window)
            }
        }
    }

    /// Re-read every list the import may have changed, and tell its views.
    static func refreshStores(after categories: AppDataCategories) {
        if categories.connections { AppStateManager.shared.loadConnections() }
        if categories.sessions { NotificationCoalescer.post(.savedQueriesDidChange) }
        if categories.history { NotificationCoalescer.post(.queryHistoryDidChange) }
        if categories.tags {
            do { try TagStore.shared.reloadTags() } catch {
                Log.state.error("Failed to reload tags after import: \(error.localizedDescription, privacy: .public)")
            }
        }
        if categories.variables {
            do { try QueryVariableStore.shared.reload() } catch {
                Log.state.error("Failed to reload variables after import: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func showFinished(_ result: ImportAppDataResult, in window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Import finished")
        alert.informativeText = AppDataTransferRules.importSummaryLines(result).joined(separator: "\n")
        alert.addButton(withTitle: String(localized: "Done"))
        alert.beginSheetModal(for: window) { _ in window.close() }
    }
}
