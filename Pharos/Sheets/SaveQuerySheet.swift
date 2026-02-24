import AppKit

/// Sheet for saving the current query to the library.
/// Allows choosing a name, folder, and scope (connection-specific or general).
class SaveQuerySheet: NSViewController {

    private let nameField = NSTextField()
    private let folderPopup = NSPopUpButton()
    private let scopeControl = NSSegmentedControl()

    private let initialName: String
    private let sql: String
    private let connectionId: String?
    private let connectionName: String?
    private var onSave: ((SavedQuery) -> Void)?

    init(tabName: String, sql: String, connectionId: String?, connectionName: String?, onSave: @escaping (SavedQuery) -> Void) {
        self.initialName = tabName
        self.sql = sql
        self.connectionId = connectionId
        self.connectionName = connectionName
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 220))
        self.view = container

        // Title
        let titleLabel = NSTextField(labelWithString: "Save Query")
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)

        // Name
        let nameLabel = makeLabel("Name")
        nameField.placeholderString = "Query name"
        nameField.stringValue = initialName

        // Folder
        let folderLabel = makeLabel("Folder")
        folderPopup.addItem(withTitle: "No Folder")
        // Load existing folders
        let existingFolders = loadExistingFolders()
        if !existingFolders.isEmpty {
            folderPopup.menu?.addItem(.separator())
            for folder in existingFolders {
                folderPopup.addItem(withTitle: folder)
            }
        }
        folderPopup.menu?.addItem(.separator())
        folderPopup.addItem(withTitle: "New Folder…")

        // Scope
        let scopeLabel = makeLabel("Save to")
        scopeControl.segmentCount = 2
        if let name = connectionName {
            scopeControl.setLabel(name, forSegment: 0)
        } else {
            scopeControl.setLabel("Connection", forSegment: 0)
            scopeControl.setEnabled(false, forSegment: 0)
        }
        scopeControl.setLabel("General", forSegment: 1)
        scopeControl.segmentStyle = .texturedSquare
        // Default to connection if available, otherwise general
        scopeControl.selectedSegment = connectionId != nil ? 0 : 1

        // Grid
        let grid = NSGridView(views: [
            [nameLabel, nameField],
            [folderLabel, folderPopup],
            [scopeLabel, scopeControl],
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

        // Handle "New Folder…" selection
        var folder: String?
        let selectedTitle = folderPopup.titleOfSelectedItem ?? "No Folder"
        if selectedTitle == "New Folder…" {
            // Prompt for folder name synchronously
            let alert = NSAlert()
            alert.messageText = "New Folder"
            alert.addButton(withTitle: "Create")
            alert.addButton(withTitle: "Cancel")
            let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            textField.placeholderString = "Folder name"
            alert.accessoryView = textField

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let folderName = textField.stringValue.trimmingCharacters(in: .whitespaces)
                folder = folderName.isEmpty ? nil : folderName
            } else {
                return // User cancelled folder creation
            }
        } else if selectedTitle != "No Folder" {
            folder = selectedTitle
        }

        let scopeConnectionId: String?
        if scopeControl.selectedSegment == 0, connectionId != nil {
            scopeConnectionId = connectionId
        } else {
            scopeConnectionId = nil
        }

        let create = CreateSavedQuery(name: name, folder: folder, sql: sql, connectionId: scopeConnectionId)
        do {
            let saved = try PharosCore.createSavedQuery(create)
            onSave?(saved)
            dismiss(nil)
        } catch {
            NSLog("Failed to save query: \(error)")
        }
    }

    // MARK: - Helpers

    private func loadExistingFolders() -> [String] {
        guard let queries = try? PharosCore.loadSavedQueries() else { return [] }
        let folders = Set(queries.compactMap { $0.folder }).filter { !$0.isEmpty }
        return folders.sorted()
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text + ":")
        label.alignment = .right
        label.font = .systemFont(ofSize: 13)
        return label
    }
}
