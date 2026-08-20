import AppKit

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

    /// Marks the one row that means "prompt me for a new folder name".
    ///
    /// A tag, not `numberOfItems - 1`: that index was only correct because
    /// nothing appended after the row, an invariant no code stated. And not
    /// `representedObject` either — both this row and the "No Folder" row carry
    /// no value, so the value alone cannot tell them apart.
    private static let newFolderTag = 1

    private let initialName: String
    private let sql: String
    private let variables: [QueryVariable]
    private var existingQueries: [SavedQuery] = []
    private var onSave: ((SaveQueryAction) -> Void)?

    init(tabName: String, sql: String, variables: [QueryVariable], onSave: @escaping (SaveQueryAction) -> Void) {
        self.initialName = tabName
        self.sql = sql
        self.variables = variables
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
        let titleLabel = NSTextField(labelWithString: "Save Query")
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)

        // Name
        let nameLabel = NSTextField.formLabel("Name")
        nameField.placeholderString = "Query name"
        nameField.stringValue = AuthoredLabelSanitizer.sanitized(initialName)

        // Folder
        let folderLabel = NSTextField.formLabel("Folder")
        // Load existing folders from cached queries
        let existingFolders = Set(existingQueries.compactMap { $0.folder }).filter { !$0.isEmpty }.sorted()
        PopupValueMenu.populate(folderPopup, sentinel: "No Folder", values: existingFolders)
        // The separator goes in after the fact so the sentinel and the folder
        // rows are still built by one call: a folder literally named
        // "No Folder" must not delete the sentinel row, which is what
        // `addItem(withTitle:)` did here — leaving index 0 a separator and the
        // control rendering blank.
        if !existingFolders.isEmpty {
            folderPopup.menu?.insertItem(.separator(), at: 1)
        }
        folderPopup.menu?.addItem(.separator())
        let newFolderItem = NSMenuItem(title: "New Folder...", action: nil, keyEquivalent: "")
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
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelSheet))
        cancelButton.keyEquivalent = "\u{1b}"

        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveSheet))
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded

        let buttonRow = NSStackView(views: [cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        // Layout
        let mainStack = NSStackView(views: [titleLabel, grid, buttonRow])
        mainStack.orientation = .vertical
        mainStack.alignment = .centerX
        mainStack.spacing = 16
        mainStack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: container.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: - Actions

    @objc private func cancelSheet() {
        dismiss(nil)
    }

    @objc private func saveSheet() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
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
            alert.messageText = "New Folder"
            alert.addButton(withTitle: "Create")
            alert.addButton(withTitle: "Cancel")
            let textField = AuthoredLabelTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            textField.placeholderString = "Folder name"
            alert.accessoryView = textField

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let folderName = textField.stringValue.trimmingCharacters(in: .whitespaces)
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
        alert.messageText = "A query named '\(name)' already exists in this folder."
        alert.informativeText = "Do you want to replace it or save as a new query?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Save as New")
        alert.addButton(withTitle: "Cancel")

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
            let update = UpdateSavedQuery(id: duplicate.id, name: name, folder: folder, sql: sql, variables: variables.toSavedJSON())
            let updated = try PharosCore.updateSavedQuery(update)
            onSave?(.replaced(updated))
            dismiss(nil)
        } catch {
            NSLog("Failed to replace saved query: \(error)")
            let alert = NSAlert()
            alert.messageText = "Failed to Save Query"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private func createNewQuery(name: String, folder: String?) {
        let create = CreateSavedQuery(name: name, folder: folder, sql: sql, connectionId: nil, variables: variables.toSavedJSON())
        do {
            let saved = try PharosCore.createSavedQuery(create)
            onSave?(.created(saved))
            dismiss(nil)
        } catch {
            NSLog("Failed to save query: \(error)")
            let alert = NSAlert()
            alert.messageText = "Failed to Save Query"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

}
