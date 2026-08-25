import Foundation

// MARK: - EditableRule

/// One rule as the manager edits it.
struct EditableRule: Equatable {
    /// nil for a rule the analyst has just added and not yet saved.
    let id: String?
    var conditions: [TagCondition]

    /// May the analyst change this rule's conditions?
    ///
    /// No, when it carries a kind this build does not understand. The store has
    /// no update-rule command, so editing is delete-then-add — and re-adding
    /// would drop the kind this build cannot reproduce, destroying a rule that
    /// currently round-trips intact. ONE unknown condition makes the whole rule
    /// uneditable, because rebuilding it would drop that one.
    ///
    /// It may still be DELETED outright, which needs no understanding of it, and
    /// the tag around it stays fully editable — an `UpdateTag` carries only
    /// name, colour and note.
    var isEditable: Bool { conditions.allSatisfy { $0.kind.isSupported } }
}

// MARK: - EditableTag

/// One tag as the manager edits it.
struct EditableTag: Equatable {
    /// nil for a tag the analyst has just created and not yet saved.
    let id: String?
    var name: String
    var colorIndex: Int
    /// Always a string, never nil — a field showing "nil" is its own bug.
    var note: String
    var rules: [EditableRule]
}

// MARK: - TagManagerModel

/// Every decision the Tag Manager makes, with no AppKit in sight.
///
/// The sheet renders this and calls its mutating methods; it never reaches the
/// store directly. That is what lets the sheet's own harness assert exactly what
/// a save would write, with no store in the binary — `TagStore` is `@MainActor`
/// and reaches the macOS Keychain through the FFI, which would hang a headless
/// run.
///
/// Edits commit on SAVE, not per keystroke: `TagStore.reloadTags` posts a global
/// change that makes every open grid rebuild its match, so live commits would
/// rebuild the app's grids on every character typed.
struct TagManagerModel {

    /// Why the manager was opened. One modal with three jobs.
    enum Mode: Equatable {
        /// Opened from the menu. Every tag, nothing preselected.
        case manage
        /// Opened from a grid selection. The draft rules join a tag the analyst
        /// picks, or a new one.
        case add(draft: [NewTagRule])
        /// Opened from "Remove from tag" on a row. The sidebar narrows to the
        /// tags holding these rules, and they start ticked.
        case remove(ruleIds: Set<String>)
    }

    let mode: Mode
    private(set) var tags: [EditableTag]
    /// The tags as they were read, keyed by id. The only source for the diff a
    /// later task derives, so a hand-maintained dirty flag cannot drift out of
    /// step with what actually changed.
    private let stored: [String: Tag]
    /// Tags the analyst has deleted this session, by index.
    ///
    /// Marked rather than removed from the array: the sheet's table holds
    /// indices into `tags`, and dropping an element under it would shift every
    /// later row's meaning between one run loop and the next.
    private var deleted: Set<Int> = []

    func isDeleted(tagAt index: Int) -> Bool { deleted.contains(index) }

    init(tags: [Tag], mode: Mode) {
        self.mode = mode
        self.stored = Dictionary(tags.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.tags = tags.map { tag in
            EditableTag(
                id: tag.id,
                name: tag.name,
                colorIndex: tag.colorIndex,
                note: tag.note ?? "",
                rules: tag.rules.map { EditableRule(id: $0.id, conditions: $0.conditions) })
        }
    }

    /// The rules a grid selection brought in, for `.add`. Empty otherwise.
    var draftRules: [NewTagRule] {
        if case .add(let draft) = mode { return draft }
        return []
    }

    /// Which tags the sidebar shows, by index.
    ///
    /// Only `.remove` narrows: it answers a question about ONE ROW, so showing
    /// forty tags the row has nothing to do with would bury the two it does.
    /// `.add` shows everything, because the analyst is choosing which tag the
    /// draft joins.
    var visibleTagIndices: [Int] {
        let live = tags.indices.filter { !deleted.contains($0) }
        guard case .remove(let ruleIds) = mode else { return live }
        return live.filter { index in
            tags[index].rules.contains { $0.id.map(ruleIds.contains) ?? false }
        }
    }

    /// Does this rule start ticked? True only in `.remove`, for the named rules.
    func isPreselected(ruleId: String) -> Bool {
        guard case .remove(let ruleIds) = mode else { return false }
        return ruleIds.contains(ruleId)
    }

    // MARK: Identity edits

    /// Rename a tag. Always allowed, even when the tag holds a rule this build
    /// cannot understand — an `UpdateTag` carries no conditions.
    mutating func rename(tagAt index: Int, to name: String) {
        guard tags.indices.contains(index) else { return }
        tags[index].name = name
    }

    mutating func recolour(tagAt index: Int, to colorIndex: Int) {
        guard tags.indices.contains(index) else { return }
        tags[index].colorIndex = colorIndex
    }

    mutating func note(tagAt index: Int, to note: String) {
        guard tags.indices.contains(index) else { return }
        tags[index].note = note
    }

    // MARK: Tag edits

    mutating func addTag(name: String, colorIndex: Int) {
        tags.append(EditableTag(id: nil, name: name, colorIndex: colorIndex,
                                note: "", rules: []))
    }

    mutating func deleteTag(at index: Int) {
        guard tags.indices.contains(index) else { return }
        deleted.insert(index)
    }

    // MARK: Rule edits

    mutating func addRule(toTagAt tagIndex: Int, conditions: [TagCondition]) {
        guard tags.indices.contains(tagIndex) else { return }
        tags[tagIndex].rules.append(EditableRule(id: nil, conditions: conditions))
    }

    /// Delete a rule whole. Allowed even for a rule this build cannot
    /// understand: deleting by id needs no understanding of its conditions.
    mutating func removeRule(at ruleIndex: Int, fromTagAt tagIndex: Int) {
        guard tags.indices.contains(tagIndex),
              tags[tagIndex].rules.indices.contains(ruleIndex) else { return }
        tags[tagIndex].rules.remove(at: ruleIndex)
    }

    // MARK: Condition edits
    //
    // Each returns false rather than trapping, for two independent reasons that
    // both matter. An out-of-range index is possible for one run loop after a
    // delete, when the sheet's table indices and this array have not yet
    // resynchronised. And a rule this build cannot understand must refuse every
    // condition edit — but the refusal has to be VISIBLE, so the sheet can say
    // why nothing happened instead of appearing to ignore the click.

    @discardableResult
    mutating func addCondition(_ condition: TagCondition,
                               toRuleAt ruleIndex: Int, inTagAt tagIndex: Int) -> Bool {
        guard editableRuleExists(ruleIndex, tagIndex) else { return false }
        tags[tagIndex].rules[ruleIndex].conditions.append(condition)
        return true
    }

    @discardableResult
    mutating func replaceCondition(at conditionIndex: Int, inRuleAt ruleIndex: Int,
                                   ofTagAt tagIndex: Int, with condition: TagCondition) -> Bool {
        guard editableRuleExists(ruleIndex, tagIndex),
              tags[tagIndex].rules[ruleIndex].conditions.indices.contains(conditionIndex)
        else { return false }
        tags[tagIndex].rules[ruleIndex].conditions[conditionIndex] = condition
        return true
    }

    @discardableResult
    mutating func removeCondition(at conditionIndex: Int, fromRuleAt ruleIndex: Int,
                                  inTagAt tagIndex: Int) -> Bool {
        guard editableRuleExists(ruleIndex, tagIndex),
              tags[tagIndex].rules[ruleIndex].conditions.indices.contains(conditionIndex)
        else { return false }
        tags[tagIndex].rules[ruleIndex].conditions.remove(at: conditionIndex)
        return true
    }

    /// Does this rule exist, and may its conditions be changed?
    private func editableRuleExists(_ ruleIndex: Int, _ tagIndex: Int) -> Bool {
        guard tags.indices.contains(tagIndex),
              tags[tagIndex].rules.indices.contains(ruleIndex)
        else { return false }
        return tags[tagIndex].rules[ruleIndex].isEditable
    }
}
