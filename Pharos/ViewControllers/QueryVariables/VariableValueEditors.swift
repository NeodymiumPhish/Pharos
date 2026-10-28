import AppKit

// The value editors of the Variable Manager's detail form (`VariableDetailVC`)
// that are more than one stock control: the growing text editor (Literal,
// Text, List), the Number field with its error outline, and the date or
// date-and-time control with its calendar popover.

// MARK: - Growing text editor

/// The value editor for Literal, Text and List variables: a text view that
/// starts one line high, grows with its content up to `maximumLines`, and then
/// scrolls. The line-number gutter shows only while the value has more than
/// one line.
///
/// Lines do not wrap: a long line scrolls sideways, so an ID list stays one
/// entry per line. The gutter, the scroll view and the placeholder are laid
/// out by frame in `layout()`, which AppKit calls whenever this view's size
/// changes, so they always match the bounds of the pass that set them.
final class VariableGrowingTextEditor: NSView {

    static let defaultMaximumLines = 12

    /// The 1 pt border the editor draws round its content.
    private static let border: CGFloat = 1

    let textView = VariableValueTextView()
    let scrollView = NSScrollView()
    let gutter: LineNumberGutter
    /// Stands in for a placeholder, which `NSTextView` does not have: shown
    /// only while the text is empty.
    let placeholderLabel = NSTextField(labelWithString: "")

    var maximumLines = VariableGrowingTextEditor.defaultMaximumLines {
        didSet { contentDidChange() }
    }

    var placeholder: String {
        get { placeholderLabel.stringValue }
        set { placeholderLabel.stringValue = newValue }
    }

    private var heightConstraint: NSLayoutConstraint!
    private var lastLaidOutWidth: CGFloat = -1

    init() {
        gutter = LineNumberGutter(textView: textView, scrollView: scrollView, metrics: .compact,
                                  accessibilityIdentifier: "variables.value.gutter")
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // A horizontally scrolling text view, as the Text System guide sets
        // one up: the container never tracks the view's width, and the view
        // follows the clip's size so a click anywhere in the box lands in it.
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        // The container's default 5 pt padding would sit between the gutter
        // and the first glyph on top of `textContainerInset.width`.
        textView.textContainer?.lineFragmentPadding = 0
        scrollView.documentView = textView

        placeholderLabel.font = textView.font
        placeholderLabel.textColor = .tertiaryLabelColor
        placeholderLabel.isSelectable = false
        // A label over the editor: clicks must reach the text view under it.
        placeholderLabel.isEnabled = false

        gutter.onWidthChange = { [weak self] in self?.needsLayout = true }

        addSubview(gutter)
        addSubview(scrollView)
        addSubview(placeholderLabel)

        heightConstraint = heightAnchor.constraint(equalToConstant: height(forVisibleLines: 1, horizontalScroller: 0))
        heightConstraint.isActive = true
        setContentHuggingPriority(.defaultHigh, for: .vertical)

        NotificationCenter.default.addObserver(self, selector: #selector(textDidChange(_:)),
                                               name: NSText.didChangeNotification, object: textView)
        contentDidChange()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("VariableGrowingTextEditor is built in code") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var isFlipped: Bool { true }

    // MARK: Content

    /// Show `text`. Leaves the text view alone when it already holds it:
    /// assigning `string` moves the caret to the end even for equal text.
    func setText(_ text: String) {
        if textView.string != text { textView.string = text }
        gutter.invalidateLineNumbers()
        contentDidChange()
    }

    /// Lines as the user sees them: one more than the line breaks.
    var lineCount: Int {
        textView.string.reduce(1) { $1.isNewline ? $0 + 1 : $0 }
    }

    /// Lines the box is tall enough to show without scrolling.
    var visibleLineCount: Int { min(max(lineCount, 1), max(maximumLines, 1)) }

    var showsGutter: Bool { lineCount > 1 }

    /// The height of one line of the text view's font.
    var lineHeight: CGFloat {
        let font = textView.font ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
        return textView.layoutManager?.defaultLineHeight(for: font) ?? ceil(font.ascender - font.descender)
    }

    @objc private func textDidChange(_ note: Notification) {
        contentDidChange()
    }

    private func contentDidChange() {
        gutter.isHidden = !showsGutter
        placeholderLabel.isHidden = !textView.string.isEmpty
        needsUpdateConstraints = true
        needsLayout = true
    }

    // MARK: Layout

    /// The box height that shows `lines` lines: the lines, the text view's
    /// top and bottom inset, the border, and room for a horizontal scroller
    /// that takes space (legacy style) when one shows.
    func height(forVisibleLines lines: Int, horizontalScroller: CGFloat) -> CGFloat {
        CGFloat(lines) * lineHeight + 2 * textView.textContainerInset.height + 2 * Self.border + horizontalScroller
    }

    /// A legacy horizontal scroller takes height from the clip. Reserve it
    /// while the longest line is wider than the text area, or a one-line box
    /// would show the scroller and no text. An overlay scroller floats over
    /// the text and needs nothing.
    private var horizontalScrollerAllowance: CGFloat {
        guard scrollView.scrollerStyle == .legacy, bounds.width > 0,
              let layoutManager = textView.layoutManager, let container = textView.textContainer else { return 0 }
        layoutManager.ensureLayout(for: container)
        let textWidth = layoutManager.usedRect(for: container).width + 2 * textView.textContainerInset.width
        let available = bounds.width - 2 * Self.border - (showsGutter ? gutter.desiredWidth : 0)
        guard textWidth > available else { return 0 }
        return NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    }

    override func updateConstraints() {
        let wanted = height(forVisibleLines: visibleLineCount, horizontalScroller: horizontalScrollerAllowance)
        if abs(heightConstraint.constant - wanted) > 0.25 { heightConstraint.constant = wanted }
        super.updateConstraints()
    }

    override func layout() {
        super.layout()
        let b = Self.border
        let gutterWidth = showsGutter ? gutter.desiredWidth : 0
        let height = max(0, bounds.height - 2 * b)
        gutter.frame = NSRect(x: b, y: b, width: gutterWidth, height: height)
        scrollView.frame = NSRect(x: b + gutterWidth, y: b, width: max(0, bounds.width - gutterWidth - 2 * b),
                                  height: height)
        // The text view at least fills the clip, so a click below or beside
        // short text still places the caret.
        let clip = scrollView.contentSize
        if textView.minSize != clip { textView.minSize = clip }

        // Where the first line of typed text starts (the view is flipped).
        let placeholderHeight = placeholderLabel.intrinsicContentSize.height
        placeholderLabel.frame = NSRect(x: scrollView.frame.minX + textView.textContainerInset.width,
                                        y: scrollView.frame.minY + textView.textContainerInset.height,
                                        width: max(0, scrollView.frame.width - 2 * textView.textContainerInset.width),
                                        height: placeholderHeight)

        // A new width can add or remove the legacy scroller's allowance.
        if bounds.width != lastLaidOutWidth {
            lastLaidOutWidth = bounds.width
            needsUpdateConstraints = true
        }
    }

    // MARK: Drawing

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Drawn, not set on a layer, so the dynamic colours resolve for the
    /// appearance in force each time it draws.
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.textBackgroundColor.setFill()
        path.fill()
        path.lineWidth = 1
        NSColor.separatorColor.setStroke()
        path.stroke()
    }
}

// MARK: - List paste

/// What a paste into a List value inserts. A pasted CSV row, a SQL `IN (…)`
/// list or a spreadsheet column becomes one item per line
/// (`ListPasteParser`), with a line break added where the items would
/// otherwise run into the text before or after them.
enum VariableListPaste {

    /// The text to insert for `pasted` over `range` of `text`, or nil to
    /// paste it unchanged (it holds no item). One item is inserted as is,
    /// with its quotes stripped, and no line breaks are added round it: the
    /// user is editing an item, not adding items.
    static func insertion(for pasted: String, in text: String, replacing range: NSRange) -> String? {
        let items = ListPasteParser.items(from: pasted)
        guard let first = items.first else { return nil }
        guard items.count > 1 else { return first }
        var body = ListPasteParser.joined(items)
        let ns = text as NSString
        let start = min(max(range.location, 0), ns.length)
        let end = min(start + max(range.length, 0), ns.length)
        if start > 0, !isLineBreak(ns.character(at: start - 1)) { body = "\n" + body }
        if end < ns.length, !isLineBreak(ns.character(at: end)) { body += "\n" }
        return body
    }

    private static func isLineBreak(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.newlines.contains(scalar)
    }
}

// MARK: - Number field

/// The Number value's field. While `showsError` is set it draws a red
/// outline over its bezel; the colour is resolved when it draws, so it
/// follows Light and Dark.
final class VariableNumberField: NSTextField {

    static let errorOutlineWidth: CGFloat = 2

    var showsError = false {
        didSet { if showsError != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showsError else { return }
        let inset = Self.errorOutlineWidth / 2
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: 5, yRadius: 5)
        path.lineWidth = Self.errorOutlineWidth
        NSColor.systemRed.setStroke()
        path.stroke()
    }
}

// MARK: - Date and date-time control

/// A fixed Date or Timestamp value: a textual date picker, and a calendar
/// button that opens a popover with the graphical picker (a calendar, and for
/// a timestamp a clock too). The two pickers stay in step.
///
/// Both pickers work in UTC with the Gregorian calendar, so the fields they
/// show ARE the stored fields: a Date or Timestamp has no zone, and a
/// zoned timestamp's wall-clock time is edited here while its zone is chosen
/// beside it (`VariableValueRules.dateTime(from:as:)` binds the same way).
final class VariableDateTimeControl: NSView {

    enum Kind {
        case date
        case timestamp

        var elements: NSDatePicker.ElementFlags {
            switch self {
            case .date: return [.yearMonthDay]
            case .timestamp: return [.yearMonthDay, .hourMinuteSecond]
            }
        }
    }

    static let utc = TimeZone(identifier: "UTC")!

    let kind: Kind
    let textualPicker = NSDatePicker()
    let calendarButton = NSButton()
    /// The popover's picker. Made on the first open.
    private(set) var graphicalPicker: NSDatePicker?
    private(set) var popover: NSPopover?

    /// The user changed the date in either picker.
    var onChange: ((Date) -> Void)?

    var dateValue: Date {
        get { textualPicker.dateValue }
        set {
            textualPicker.dateValue = newValue
            graphicalPicker?.dateValue = newValue
        }
    }

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        Self.configure(textualPicker, kind: kind)
        textualPicker.datePickerStyle = .textFieldAndStepper
        textualPicker.isBezeled = true
        textualPicker.drawsBackground = true
        textualPicker.target = self
        textualPicker.action = #selector(textualChanged(_:))
        textualPicker.translatesAutoresizingMaskIntoConstraints = false
        textualPicker.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let calendarLabel = String(localized: "Show Calendar")
        calendarButton.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: calendarLabel)
        calendarButton.bezelStyle = .rounded
        calendarButton.imagePosition = .imageOnly
        calendarButton.toolTip = calendarLabel
        calendarButton.setAccessibilityLabel(calendarLabel)
        calendarButton.target = self
        calendarButton.action = #selector(showCalendar(_:))
        calendarButton.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [textualPicker, calendarButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("VariableDateTimeControl is built in code") }

    /// UTC, Gregorian, and the range the stored form can write (years
    /// 0001–9999, four digits).
    private static func configure(_ picker: NSDatePicker, kind: Kind) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        picker.calendar = calendar
        picker.timeZone = utc
        picker.datePickerElements = kind.elements
        picker.minDate = VariableValueRules.dateTime(from: "0001-01-01", as: .date)?.date
        picker.maxDate = VariableValueRules.dateTime(from: "9999-12-31 23:59:59", as: .timestamp)?.date
    }

    @objc private func textualChanged(_ sender: NSDatePicker) {
        graphicalPicker?.dateValue = sender.dateValue
        onChange?(sender.dateValue)
    }

    @objc private func graphicalChanged(_ sender: NSDatePicker) {
        textualPicker.dateValue = sender.dateValue
        onChange?(sender.dateValue)
    }

    @objc func showCalendar(_ sender: Any?) {
        if let popover, popover.isShown {
            popover.performClose(sender)
            return
        }
        let popover = self.popover ?? makePopover()
        graphicalPicker?.dateValue = textualPicker.dateValue
        popover.show(relativeTo: calendarButton.bounds, of: calendarButton, preferredEdge: .maxY)
    }

    func closePopover() {
        popover?.close()
    }

    private func makePopover() -> NSPopover {
        let picker = NSDatePicker()
        Self.configure(picker, kind: kind)
        picker.datePickerStyle = .clockAndCalendar
        picker.isBezeled = false
        picker.drawsBackground = false
        picker.dateValue = textualPicker.dateValue
        picker.target = self
        picker.action = #selector(graphicalChanged(_:))
        picker.setAccessibilityIdentifier("variables.value.calendarPicker")
        picker.sizeToFit()
        picker.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(picker)
        let size = picker.fittingSize
        NSLayoutConstraint.activate([
            picker.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            picker.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            picker.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            picker.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
            // Fixed, not ceilings: the popover lays its content out again
            // (lessons, "An NSPopover lays its content out AGAIN").
            picker.widthAnchor.constraint(equalToConstant: size.width),
            picker.heightAnchor.constraint(equalToConstant: size.height),
        ])
        let controller = NSViewController()
        controller.view = content

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: size.width + 16, height: size.height + 16)
        graphicalPicker = picker
        self.popover = popover
        return popover
    }
}
