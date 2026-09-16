import AppKit
import os

/// Result of a save query operation.
enum SaveQueryAction {
    case created(SavedQuery)
    case replaced(SavedQuery)
}

/// Sheet for saving the current query to the library.
/// Allows choosing a name and folder. Detects duplicate names and offers replace.
class SaveQuerySheet: NSViewController {

    private let nameField = AuthoredLabelTextField()
    private let folderPopup = NSPopUpButton()
    // Stored, not local to `loadView`, so `wireKeyViewLoop()` can reach them.
    private let cancelButton = NSButton()
    private let saveButton = NSButton()

    /// Marks the one row that means "prompt me for a new folder name".
    ///
    /// A tag, not `numberOfItems - 1`: that index was only correct because
    /// nothing appended after the row, an invariant no code stated. And not
    /// `representedObject` either — both this row and the "No Folder" row carry
    /// no value, so the value alone cannot tell them apart.
    private static let newFolderTag = 1

    private let initialName: String
    private let sql: String
    private var existingQueries: [SavedQuery] = []
    private var onSave: ((SaveQueryAction) -> Void)?

    // MARK: - Suggested name

    /// The folders offered in the popup, in the popup's own spelling. Also the
    /// list the model is allowed to choose from.
    private var existingFolders: [String] = []
    /// What the field held when the sheet opened. A suggestion replaces the
    /// field only while it still holds exactly this.
    private var defaultName = ""
    /// Set the first time the user types. The text comparison alone would let
    /// a suggestion land on top of a name the user had typed and then deleted
    /// back to the default.
    private var nameWasEdited = false
    private var suggestionTask: Task<Void, Never>?
    private var nameChangeObserver: NSObjectProtocol?

    init(tabName: String, sql: String, onSave: @escaping (SaveQueryAction) -> Void) {
        self.initialName = tabName
        self.sql = sql
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 180))
        self.view = container

        // Load existing queries for duplicate detection and folder list
        existingQueries = (try? PharosCore.loadSavedQueries()) ?? []

        // Title
        let titleLabel = NSTextField(labelWithString: String(localized: "Save Query"))
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)

        // Name
        let nameLabel = NSTextField.formLabel(String(localized: "Name"))
        nameField.placeholderString = String(localized: "Query name")
        nameField.stringValue = AuthoredLabelSanitizer.sanitized(initialName)
        defaultName = nameField.stringValue

        // Folder
        let folderLabel = NSTextField.formLabel(String(localized: "Folder"))
        // Load existing folders from cached queries
        let existingFolders = Set(existingQueries.compactMap { $0.folder }).filter { !$0.isEmpty }.sorted()
        self.existingFolders = existingFolders
        PopupValueMenu.populate(folderPopup, sentinel: String(localized: "No Folder"), values: existingFolders)
        // The separator goes in after the fact so the sentinel and the folder
        // rows are still built by one call: a folder literally named
        // "No Folder" must not delete the sentinel row, which is what
        // `addItem(withTitle:)` did here — leaving index 0 a separator and the
        // control rendering blank.
        if !existingFolders.isEmpty {
            folderPopup.menu?.insertItem(.separator(), at: 1)
        }
        folderPopup.menu?.addItem(.separator())
        let newFolderItem = NSMenuItem(title: String(localized: "New Folder..."), action: nil, keyEquivalent: "")
        newFolderItem.tag = Self.newFolderTag
        folderPopup.menu?.addItem(newFolderItem)

        // Grid
        let grid = NSGridView(views: [
            [nameLabel, nameField],
            [folderLabel, folderPopup],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 70
        grid.column(at: 1).width = 260
        grid.rowSpacing = 8
        grid.columnSpacing = 8

        // Buttons
        cancelButton.title = String(localized: "Cancel")
        cancelButton.target = self
        cancelButton.action = #selector(cancelSheet)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityIdentifier("sheet.savequery.cancel")

        saveButton.title = String(localized: "Save")
        saveButton.target = self
        saveButton.action = #selector(saveSheet)
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded
        saveButton.setAccessibilityIdentifier("sheet.savequery.default")

        let buttonRow = NSStackView(views: [Self.spacer(), cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        // Layout
        let mainStack = NSStackView(views: [titleLabel, grid, buttonRow])
        mainStack.orientation = .vertical
        // `.leading` plus the width pin, not `.centerX`: an NSStackView rejects
        // `.width` outright, so every row is pinned to the stack's own width
        // instead — see NSStackView+SpanFullWidth.swift. That is what lets the
        // button row's leading spacer push Cancel/Save to the trailing edge.
        mainStack.alignment = .leading
        mainStack.spacing = 16
        mainStack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        mainStack.spanArrangedSubviewsFullWidth()
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: container.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: - Layout Helpers

    /// An empty view that takes the slack in the button row, so the buttons
    /// after it sit at the trailing edge. A plain NSView would not give way,
    /// because its hugging priority matches the buttons'.
    private static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        return view
    }

    // MARK: - Key View Loop

    override func viewWillAppear() {
        super.viewWillAppear()
        view.window?.initialFirstResponder = nameField
        // NOT true: that recalculates the window's key view loop from the
        // view hierarchy — repeatedly, not just once — which silently
        // discards the explicit chain below the first time anything
        // (opening the window, a control becoming key) triggers it.
        view.window?.autorecalculatesKeyViewLoop = false
        wireKeyViewLoop()
        startNameSuggestion()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        suggestionTask?.cancel()
        suggestionTask = nil
        if let nameChangeObserver {
            NotificationCenter.default.removeObserver(nameChangeObserver)
            self.nameChangeObserver = nil
        }
    }

    // MARK: - Suggested name

    /// Ask the on-device model for a name while the sheet is already open.
    ///
    /// Nothing waits for it. The sheet opens with the tab's own name, exactly
    /// as it did before, and the suggestion replaces it only if it arrives
    /// before the user has typed anything — the user is always faster than the
    /// model when they already know what to call it.
    ///
    /// There is no `GeneratedContentLabel` here and no thumbs. The name is a
    /// starting point that the user reads and edits inside a form they are
    /// about to press Save on, not a generated answer they are asked to trust.
    private func startNameSuggestion() {
        guard suggestionTask == nil, ModelAvailability.shared.isAvailable else { return }
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        nameChangeObserver = NotificationCenter.default.addObserver(
            forName: NSControl.textDidChangeNotification, object: nameField, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.nameWasEdited = true
                self.nameField.toolTip = nil
            }
        }

        // Only visible once the field is emptied, which is exactly when the
        // user is waiting to be told something is coming.
        nameField.placeholderString = String(localized: "Suggested…")
        nameField.toolTip = String(localized: "Name suggested by Apple Intelligence")

        let sql = self.sql
        let folders = existingFolders
        suggestionTask = Task { [weak self] in
            let suggester = NameSuggester()
            do {
                let suggestion = try await suggester.suggest(
                    sql: sql, existingFolders: folders, kind: .savedQuery)
                guard !Task.isCancelled else { return }
                self?.apply(suggestion)
            } catch {
                Log.intelligence.error(
                    "Name suggestion failed: \(error.localizedDescription, privacy: .public)")
                self?.nameField.placeholderString = String(localized: "Query name")
                self?.nameField.toolTip = nil
            }
        }
    }

    private func apply(_ suggestion: NameSuggestion) {
        nameField.placeholderString = String(localized: "Query name")
        guard !nameWasEdited, nameField.stringValue == defaultName,
              !suggestion.title.isEmpty else {
            nameField.toolTip = nil
            return
        }

        nameField.stringValue = suggestion.title
        defaultName = suggestion.title
        // Selected, not just typed in: the next character the user types
        // replaces the whole suggestion, which is how a suggestion should
        // behave when it is wrong.
        nameField.selectText(nil)

        // The folder follows only while the popup is untouched — the sentinel
        // row is index 0 and is what the popup opens on.
        if let folder = suggestion.folder, folderPopup.indexOfSelectedItem == 0 {
            PopupValueMenu.selectValue(folder, in: folderPopup)
        }
    }

    /// Explicit, because these fields sit in NSGridView rows: AppKit's
    /// automatic key view loop follows the grid's own subview order, which
    /// does not match the row-by-row reading order the form is laid out in.
    private func wireKeyViewLoop() {
        nameField.nextKeyView = folderPopup
        folderPopup.nextKeyView = cancelButton
        cancelButton.nextKeyView = saveButton
        saveButton.nextKeyView = nameField
    }

    // MARK: - Actions

    @objc private func cancelSheet() {
        dismiss(nil)
    }

    @objc private func saveSheet() {
        // `committed`, not a bare trim: a saved-query name is an AUTHORED
        // LABEL, so the store must not receive a bidi override or a zero-width
        // character in one. It also trims newlines, which a bare `.whitespaces`
        // trim leaves at an edge of a pasted name — and the delete confirmation
        // trims what it draws, so an untrimmed stored name would be a name the
        // dialog silently disagrees with.
        let name = AuthoredLabelSanitizer.committed(nameField.stringValue)
        guard !name.isEmpty else {
            NSSound.beep()
            return
        }

        // Handle "New Folder..." selection
        var folder: String?
        // The selected ITEM decides, not its title: titles are escaped for
        // display, and a folder genuinely named "No Folder" used to be
        // swallowed by a sentinel string comparison here.
        let selectedIsNewFolder = folderPopup.selectedItem?.tag == Self.newFolderTag
        let selectedFolder = PopupValueMenu.selectedValue(in: folderPopup)
        if selectedIsNewFolder {
            // Prompt for folder name synchronously
            let alert = NSAlert()
            alert.messageText = String(localized: "New Folder")
            alert.addButton(withTitle: String(localized: "Create"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            let textField = AuthoredLabelTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            textField.placeholderString = String(localized: "Folder name")
            alert.accessoryView = textField

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let folderName = AuthoredLabelSanitizer.committed(textField.stringValue)
                folder = folderName.isEmpty ? nil : folderName
            } else {
                return // User cancelled folder creation
            }
        } else {
            folder = selectedFolder
        }

        // Check for duplicate name in the same folder
        let duplicate = existingQueries.first { q in
            q.name.lowercased() == name.lowercased() &&
            q.folder == folder
        }

        if let duplicate = duplicate {
            showDuplicateAlert(name: name, folder: folder, duplicate: duplicate)
        } else {
            createNewQuery(name: name, folder: folder)
        }
    }

    // MARK: - Duplicate Handling

    private func showDuplicateAlert(name: String, folder: String?, duplicate: SavedQuery) {
        let alert = NSAlert()
        alert.messageText = String(localized: "A query named '\(name)' already exists in this folder.")
        alert.informativeText = String(localized: "Do you want to replace it or save as a new query?")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Replace"))
        alert.addButton(withTitle: String(localized: "Save as New"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                // Replace: update the existing query's SQL (and name casing)
                self.replaceQuery(duplicate: duplicate, name: name, folder: folder)
            case .alertSecondButtonReturn:
                // Save as New: create a new query
                self.createNewQuery(name: name, folder: folder)
            default:
                // Cancel: stay on sheet
                break
            }
        }
    }

    private func replaceQuery(duplicate: SavedQuery, name: String, folder: String?) {
        do {
            let update = UpdateSavedQuery(id: duplicate.id, name: name, folder: folder, sql: sql, variables: nil)
            let updated = try PharosCore.updateSavedQuery(update)
            onSave?(.replaced(updated))
            dismiss(nil)
        } catch {
            Log.ui.error("Failed to replace saved query: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = String(localized: "Failed to Save Query")
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private func createNewQuery(name: String, folder: String?) {
        let create = CreateSavedQuery(name: name, folder: folder, sql: sql, connectionId: nil, variables: nil)
        do {
            let saved = try PharosCore.createSavedQuery(create)
            onSave?(.created(saved))
            dismiss(nil)
        } catch {
            Log.ui.error("Failed to save query: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = String(localized: "Failed to Save Query")
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

}
