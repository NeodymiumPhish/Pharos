import AppKit

protocol TagFunnelPopoverDelegate: AnyObject {
    func tagFunnelPopover(_ popover: TagFunnelPopoverVC, didApply values: Set<String>?)
}

// MARK: - TagFunnelPopoverVC

/// The `#` funnel: a label checklist plus "Untagged". Reuses
/// `FilterValueListView` so it looks like the column filter checklist, without
/// the operator UI that means nothing for labels.
///
/// Values are LABEL IDS (stable across rename); "Untagged" is
/// `TagFunnel.untaggedValue`. Applying with everything checked clears the
/// filter — the same rule the column popover has.
final class TagFunnelPopoverVC: NSViewController {

    weak var delegate: TagFunnelPopoverDelegate?

    private let valueList = FilterValueListView()
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)

    /// Checklist rows in display order, and the id each display name stands for.
    private let displayNames: [String]
    private let idForName: [String: String]
    private let checkedNames: Set<String>

    /// - Parameters:
    ///   - labels: the labels present in the result, display order.
    ///   - existing: the active funnel filter's values (label ids), nil when
    ///     no funnel filter is active.
    init(labels: [TagLabel], existing: Set<String>?) {
        var names: [String] = []
        var ids: [String: String] = [:]
        for label in labels {
            // Two labels can share a name; suffix the duplicate so both rows
            // stay selectable.
            var name = label.name
            var n = 2
            while ids[name] != nil { name = "\(label.name) (\(n))"; n += 1 }
            names.append(name)
            ids[name] = label.id
        }
        names.append("Untagged")
        ids["Untagged"] = TagFunnel.untaggedValue
        displayNames = names
        idForName = ids
        if let existing {
            checkedNames = Set(names.filter { existing.contains(ids[$0]!) })
        } else {
            checkedNames = Set(names)
        }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        // NOTE: FilterValueListView carries its own required-priority height
        // constraint (`FilterPopoverSizing.defaultListHeight`, :54 in that
        // file). Pinning both its top AND bottom edges to a fixed-frame root
        // (the plan's literal 220x260 `NSView(frame:)`) double-constrains its
        // height and produces an Auto Layout conflict at runtime. Instead the
        // root here has NO fixed frame: it is content-sized bottom-up —
        // valueList's height comes from its own internal constraint, the
        // buttons' height comes from their intrinsic content size, and root's
        // total height falls out of the chain (top -> valueList -> buttons ->
        // bottom). Only the width is fixed, matching the plan's 220pt column.
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        valueList.translatesAutoresizingMaskIntoConstraints = false
        applyButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        applyButton.target = self
        applyButton.action = #selector(apply)
        applyButton.keyEquivalent = "\r"
        clearButton.target = self
        clearButton.action = #selector(clearFilter)
        root.addSubview(valueList)
        root.addSubview(applyButton)
        root.addSubview(clearButton)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 220),
            valueList.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            valueList.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            valueList.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            clearButton.topAnchor.constraint(equalTo: valueList.bottomAnchor, constant: 8),
            clearButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            clearButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            applyButton.topAnchor.constraint(equalTo: valueList.bottomAnchor, constant: 8),
            applyButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            applyButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        self.view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        valueList.setValues(displayNames, checked: checkedNames, counts: [:])
    }

    @objc private func apply() {
        let checked = valueList.checkedValues
        guard !checked.isEmpty else { return }
        if checked.count == displayNames.count {
            delegate?.tagFunnelPopover(self, didApply: nil)     // everything → clear
        } else {
            delegate?.tagFunnelPopover(self, didApply: Set(checked.compactMap { idForName[$0] }))
        }
        dismiss(nil)
    }

    @objc private func clearFilter() {
        delegate?.tagFunnelPopover(self, didApply: nil)
        dismiss(nil)
    }
}
