import AppKit

/// Sheet for adding/editing a database connection.
/// Presented as a sheet on the main window.
class ConnectionSheet: NSViewController {

    // MARK: - Properties

    private var existingConfig: ConnectionConfig?
    private var onSave: ((ConnectionConfig) -> Void)?

    private let nameField = NSTextField()
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let databaseField = NSTextField()
    private let usernameField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let sslPopup = NSPopUpButton()
    private let colorWell = NSColorWell()
    private let testButton = NSButton()
    private let testStatusLabel = NSTextField(labelWithString: "")
    private let testSpinner = NSProgressIndicator()

    // MARK: - Factory

    /// Create a sheet for adding a new connection.
    static func forNew(onSave: @escaping (ConnectionConfig) -> Void) -> ConnectionSheet {
        let sheet = ConnectionSheet()
        sheet.onSave = onSave
        return sheet
    }

    /// Create a sheet for editing an existing connection.
    static func forEdit(_ config: ConnectionConfig, onSave: @escaping (ConnectionConfig) -> Void) -> ConnectionSheet {
        let sheet = ConnectionSheet()
        sheet.existingConfig = config
        sheet.onSave = onSave
        return sheet
    }

    // MARK: - View Lifecycle

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 380))
        self.view = container

        let title = existingConfig != nil ? "Edit Connection" : "New Connection"
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)

        // Form fields
        let nameLabel = makeLabel("Name")
        nameField.placeholderString = "My Database"

        let hostLabel = makeLabel("Host")
        hostField.placeholderString = "localhost"

        let portLabel = makeLabel("Port")
        portField.placeholderString = "5432"

        let databaseLabel = makeLabel("Database")
        databaseField.placeholderString = "postgres"

        let usernameLabel = makeLabel("Username")
        usernameField.placeholderString = "postgres"

        let passwordLabel = makeLabel("Password")
        passwordField.placeholderString = "Optional"

        let sslLabel = makeLabel("SSL Mode")
        sslPopup.addItems(withTitles: ["Prefer", "Require", "Disable"])

        // Test connection row
        testButton.title = "Test Connection"
        testButton.bezelStyle = .rounded
        testButton.target = self
        testButton.action = #selector(testConnection)

        testSpinner.style = .spinning
        testSpinner.controlSize = .small
        testSpinner.isHidden = true

        testStatusLabel.font = .systemFont(ofSize: 12)
        testStatusLabel.textColor = .secondaryLabelColor

        let testRow = NSStackView(views: [testButton, testSpinner, testStatusLabel])
        testRow.orientation = .horizontal
        testRow.spacing = 8

        // Build form grid
        let grid = NSGridView(views: [
            [nameLabel, nameField],
            [hostLabel, hostField],
            [portLabel, portField],
            [databaseLabel, databaseField],
            [usernameLabel, usernameField],
            [passwordLabel, passwordField],
            [sslLabel, sslPopup],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 90
        grid.column(at: 1).width = 300
        grid.rowSpacing = 8
        grid.columnSpacing = 8

        // Action buttons
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelSheet))
        cancelButton.keyEquivalent = "\u{1b}" // Escape

        let saveButton = NSButton(title: existingConfig != nil ? "Save" : "Add", target: self, action: #selector(saveSheet))
        saveButton.keyEquivalent = "\r" // Return
        saveButton.bezelStyle = .rounded

        let buttonRow = NSStackView(views: [cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        // Layout
        let mainStack = NSStackView(views: [titleLabel, grid, testRow, buttonRow])
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

        // Pre-fill for edit mode
        if let config = existingConfig {
            nameField.stringValue = config.name
            hostField.stringValue = config.host
            portField.stringValue = String(config.port)
            databaseField.stringValue = config.database
            usernameField.stringValue = config.username
            passwordField.stringValue = config.password
            switch config.sslMode {
            case .prefer: sslPopup.selectItem(at: 0)
            case .require: sslPopup.selectItem(at: 1)
            case .disable: sslPopup.selectItem(at: 2)
            }
        } else {
            portField.stringValue = "5432"
        }
    }

    // MARK: - Actions

    @objc private func testConnection() {
        let config = buildConfig()
        testButton.isEnabled = false
        testSpinner.isHidden = false
        testSpinner.startAnimation(nil)
        testStatusLabel.stringValue = "Testing..."
        testStatusLabel.textColor = .secondaryLabelColor

        Task {
            do {
                let result = try await PharosCore.testConnection(config)
                await MainActor.run {
                    self.testSpinner.stopAnimation(nil)
                    self.testSpinner.isHidden = true
                    self.testButton.isEnabled = true
                    if result.success {
                        let ms = result.latencyMs.map { "\($0)ms" } ?? ""
                        self.testStatusLabel.stringValue = "Connected \(ms)"
                        self.testStatusLabel.textColor = .systemGreen
                    } else {
                        self.testStatusLabel.stringValue = result.error ?? "Failed"
                        self.testStatusLabel.textColor = .systemRed
                    }
                }
            } catch {
                await MainActor.run {
                    self.testSpinner.stopAnimation(nil)
                    self.testSpinner.isHidden = true
                    self.testButton.isEnabled = true
                    self.testStatusLabel.stringValue = error.localizedDescription
                    self.testStatusLabel.textColor = .systemRed
                }
            }
        }
    }

    @objc private func cancelSheet() {
        dismiss(nil)
    }

    @objc private func saveSheet() {
        let config = buildConfig()
        guard !config.name.isEmpty, !config.host.isEmpty, !config.database.isEmpty, !config.username.isEmpty else {
            NSSound.beep()
            return
        }
        onSave?(config)
        dismiss(nil)
    }

    // MARK: - Helpers

    private func buildConfig() -> ConnectionConfig {
        let sslMode: SslMode = {
            switch sslPopup.indexOfSelectedItem {
            case 1: return .require
            case 2: return .disable
            default: return .prefer
            }
        }()

        return ConnectionConfig(
            id: existingConfig?.id ?? UUID().uuidString,
            name: nameField.stringValue.isEmpty ? "Untitled" : nameField.stringValue,
            host: hostField.stringValue.isEmpty ? "localhost" : hostField.stringValue,
            port: UInt16(portField.stringValue) ?? 5432,
            database: databaseField.stringValue.isEmpty ? "postgres" : databaseField.stringValue,
            username: usernameField.stringValue.isEmpty ? "postgres" : usernameField.stringValue,
            password: passwordField.stringValue,
            sslMode: sslMode,
            color: existingConfig?.color
        )
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text + ":")
        label.alignment = .right
        label.font = .systemFont(ofSize: 13)
        return label
    }
}
