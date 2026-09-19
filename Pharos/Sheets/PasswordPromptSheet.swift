import AppKit

/// Asks for a connection's password, when the app has none to dial with.
///
/// Two connections reach this sheet: one whose "Remember the password in the
/// keychain" is off — which is what that switch MEANS, that the password is
/// asked for rather than kept — and one that has simply never been given a
/// password. Before this existed both failed with whatever the server says
/// about a missing password, which reads as a fault rather than as a question.
///
/// The sheet shows nothing it was given. It only takes: an empty secure field,
/// the connection's name and address for context, and a checkbox that turns
/// this connection into one that remembers. Nothing here is logged.
final class PasswordPromptSheet: NSViewController {

    /// How the sheet ended.
    enum Outcome {
        /// The user gave a password. `remember` is the checkbox: when it is
        /// set, the caller writes the password to the Keychain and turns the
        /// record's `rememberPassword` on.
        case connect(password: String, remember: Bool)
        /// The user changed their mind. Nothing failed.
        case cancelled
    }

    private let connectionName: String
    private let connectionAddress: String
    /// Pre-set when the record already remembers — this is then the "first
    /// password for a record that keeps one" case, and unticking it is how the
    /// user says they would rather be asked each time.
    private let remembersAlready: Bool

    private let passwordField = NSSecureTextField()
    private let rememberCheckbox = NSButton()
    private let cancelButton = NSButton()
    private let connectButton = NSButton()

    /// Called once, however the sheet ended. Nilled before it runs, so a second
    /// disappearance — the window closing behind the sheet — cannot answer a
    /// waiting caller twice.
    private var onFinish: ((Outcome) -> Void)?
    private var outcome: Outcome = .cancelled

    /// - Parameters:
    ///   - name: the connection's name, shown escaped.
    ///   - address: `user@host:port/database`, for telling two records with
    ///     similar names apart.
    ///   - remembersAlready: the record's own `rememberPassword`.
    init(name: String,
         address: String,
         remembersAlready: Bool,
         onFinish: @escaping (Outcome) -> Void) {
        self.connectionName = name
        self.connectionAddress = address
        self.remembersAlready = remembersAlready
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 210))
        self.view = container

        let titleLabel = NSTextField(labelWithString: String(localized: "Password Required"))
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.setAccessibilityIdentifier("connections.passwordPrompt.title")

        // The name is a DISPLAY of something the user authored, so it is
        // escaped rather than sanitised — the same reading the connections
        // list and the delete confirmation give it.
        let subtitle = NSTextField(wrappingLabelWithString: String(
            localized: "Enter the password for “\(DisplayEscape.escapedTrimmed(connectionName))”."))
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.setAccessibilityIdentifier("connections.passwordPrompt.subtitle")

        let addressLabel = NSTextField(labelWithString: DisplayEscape.escapedTrimmed(connectionAddress))
        addressLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        addressLabel.textColor = .secondaryLabelColor
        addressLabel.lineBreakMode = .byTruncatingMiddle
        addressLabel.setAccessibilityIdentifier("connections.passwordPrompt.address")

        let passwordLabel = NSTextField.formLabel(String(localized: "Password"))
        passwordField.placeholderString = String(localized: "Password")
        passwordField.setAccessibilityIdentifier("connections.passwordPrompt.password")
        // Return in the field is Connect, so the common case is type-and-enter.
        passwordField.target = self
        passwordField.action = #selector(connectSheet)

        let grid = NSGridView(views: [[passwordLabel, passwordField]])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 70
        grid.column(at: 1).width = 270
        grid.rowSpacing = 8
        grid.columnSpacing = 8

        rememberCheckbox.setButtonType(.switch)
        rememberCheckbox.title = String(localized: "Remember in the Keychain")
        rememberCheckbox.state = remembersAlready ? .on : .off
        rememberCheckbox.setAccessibilityIdentifier("connections.passwordPrompt.remember")
        rememberCheckbox.toolTip = String(localized:
            "Writes this password to your login keychain and turns this connection's “Remember the password in the keychain” on, so you are not asked again. Left clear, the password is kept in memory until Pharos quits and never written to disk.")

        cancelButton.title = String(localized: "Cancel")
        cancelButton.target = self
        cancelButton.action = #selector(cancelSheet)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityIdentifier("connections.passwordPrompt.cancel")

        connectButton.title = String(localized: "Connect")
        connectButton.target = self
        connectButton.action = #selector(connectSheet)
        connectButton.keyEquivalent = "\r"
        connectButton.bezelStyle = .rounded
        connectButton.setAccessibilityIdentifier("connections.passwordPrompt.connect")

        let buttonRow = NSStackView(views: [Self.spacer(), cancelButton, connectButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let mainStack = NSStackView(views: [titleLabel, subtitle, addressLabel, grid,
                                            rememberCheckbox, buttonRow])
        mainStack.orientation = .vertical
        // `.leading` plus the width pin, not `.centerX`: an NSStackView rejects
        // `.width` outright, so every row is pinned to the stack's own width
        // instead — see NSStackView+SpanFullWidth.swift.
        mainStack.alignment = .leading
        mainStack.spacing = 12
        mainStack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        mainStack.spanArrangedSubviewsFullWidth()
        mainStack.setCustomSpacing(4, after: subtitle)
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: container.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    /// An empty view that takes the slack in the button row, so the buttons
    /// after it sit at the trailing edge.
    private static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        return view
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        view.window?.initialFirstResponder = passwordField
        view.window?.makeFirstResponder(passwordField)
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        let handler = onFinish
        onFinish = nil
        let result = outcome
        // The field is emptied whichever way the sheet ended, so the password
        // does not sit in an AppKit control after the sheet is gone.
        passwordField.stringValue = ""
        handler?(result)
    }

    @objc private func connectSheet() {
        let password = passwordField.stringValue
        // An empty field is not an answer. Connect stays put rather than
        // dismissing into the same failure the user was just shown.
        guard !password.isEmpty else {
            NSSound.beep()
            view.window?.makeFirstResponder(passwordField)
            return
        }
        outcome = .connect(password: password, remember: rememberCheckbox.state == .on)
        dismiss(nil)
    }

    @objc private func cancelSheet() {
        outcome = .cancelled
        dismiss(nil)
    }
}
