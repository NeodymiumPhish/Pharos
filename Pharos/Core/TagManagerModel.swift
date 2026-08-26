import Foundation

// MARK: - EditableRule

/// One rule as the manager edits it.
struct EditableRule: Equatable {
    /// nil for a rule the analyst has just added and not yet saved.
    let id: String?
    var conditions: [TagCondition]

    /// May the analyst change this rule's conditions?
    ///
    /// No, when it carries a kind this build does not understand. There is no
    /// control that could render or evaluate such a condition, so an edit would
    /// be an edit made blind. ONE unknown condition makes the whole rule
    /// uneditable, because the analyst cannot see what they are changing around
    /// it.
    ///
    /// The older reason — that editing was delete-then-add, which would drop the
    /// unknown kind — no longer holds: `.updateRule` carries the conditions
    /// verbatim and `TagConditionKind.unsupported` re-encodes byte for byte, so
    /// an edited rule would keep the kind now. The read-only treatment is a
    /// policy choice from here on, not a data-loss guard.
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

// MARK: - TagManagerCommit

/// One thing the manager wants written.
///
/// An explicit list rather than the sheet calling the store as it goes. Two
/// reasons: the sheet's own harness can assert exactly what WOULD be written
/// with no store in the binary, and `TagStore.reloadTags` posts a global change
/// that rebuilds every open grid's match — so a per-keystroke write would
/// rebuild the app's grids on every character typed.
enum TagManagerCommit: Equatable {
    case create(CreateTag)
    case update(UpdateTag)
    case addRules(AddTagRules)
    case updateRule(UpdateTagRule)
    case deleteRules([String])
    case deleteTag(String)
}

// The three write payloads are `Codable` but not `Equatable`, and
// `TagManagerCommit` must be comparable for the suite to assert what a save
// would write. `internal`, NOT `public` — these types are internal, and a
// `public` operator on an internal type does not compile.
extension CreateTag: Equatable {
    static func == (a: CreateTag, b: CreateTag) -> Bool {
        a.name == b.name && a.colorIndex == b.colorIndex && a.note == b.note && a.rules == b.rules
    }
}

extension UpdateTag: Equatable {
    static func == (a: UpdateTag, b: UpdateTag) -> Bool {
        a.id == b.id && a.name == b.name && a.colorIndex == b.colorIndex && a.note == b.note
    }
}

extension AddTagRules: Equatable {
    static func == (a: AddTagRules, b: AddTagRules) -> Bool {
        a.tagId == b.tagId && a.rules == b.rules
    }
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
        /// Opened from a grid selection. What the selection OFFERS, not what it
        /// captures: the analyst ticks the values a tag takes from it, and the
        /// draft is derived from those ticks. A fixed list of rules here would
        /// have to be replaced to change a tick, and replacing the model would
        /// throw away a rename typed a moment earlier.
        case add(capture: TagCapture)
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

    /// What a grid selection offers, for `.add`. nil in every other mode.
    var capture: TagCapture? {
        if case .add(let capture) = mode { return capture }
        return nil
    }

    /// The result columns the analyst has TICKED, by index.
    ///
    /// Starts EMPTY, deliberately. A tag is a durable artifact and the choice of
    /// what it captures should be a deliberate one — and capturing every column
    /// by default produces a rule that matches almost nothing but the row it
    /// came from, which is the opposite of a useful indicator. With nothing
    /// ticked the draft is empty and contributes no rules, so Save falls back to
    /// the ordinary `noChanges` blocker.
    private(set) var checkedCaptureColumns: Set<Int> = []

    /// Tick or untick one capture column. Answers false when there is nothing to
    /// tick — no capture, or an index the result does not hold — rather than
    /// trapping, so a checklist and a result that disagree cannot take the app
    /// down.
    ///
    /// A MUTATION on the model that already exists, never a new model: the
    /// analyst may have renamed a tag a moment earlier, and a rebuilt
    /// `TagManagerModel` would throw that away.
    @discardableResult
    mutating func setCaptureColumn(_ index: Int, checked: Bool) -> Bool {
        guard let capture, capture.columns.indices.contains(index) else { return false }
        if checked {
            checkedCaptureColumns.insert(index)
        } else {
            checkedCaptureColumns.remove(index)
        }
        return true
    }

    /// The rules a grid selection would write, for `.add`. Empty otherwise, and
    /// empty until something is ticked.
    ///
    /// DERIVED on every read rather than stored. `commits()`, the live count and
    /// the footer all ask this question, and a stored copy updated by hand is
    /// exactly how the number on screen comes to disagree with what saves.
    var draftRules: [NewTagRule] {
        guard let capture else { return [] }
        return capture.rules(checkedColumns: checkedCaptureColumns)
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

    // MARK: Saving

    /// Why Save is unavailable, or nil when it is.
    enum SaveBlocker: Equatable {
        case noChanges
        /// A rule stripped of every condition. It would be inert in the matcher
        /// and noise in the store, and it is almost certainly a half-finished
        /// edit rather than an intent.
        case emptyRule(tagIndex: Int, ruleIndex: Int)
        /// Two rules of one tag would end up with the same key, and at least one
        /// of them is an EDIT.
        ///
        /// Narrower than "two rules share a key" on purpose. A purely-added
        /// duplicate is absorbed by `INSERT OR IGNORE`, which is the re-tagging
        /// no-op and has always been correct. Only an `UPDATE` moving onto an
        /// occupied key errors — `sqlite::update_tag_rule` is a plain `UPDATE`
        /// deliberately — so only that must block. Blocking the harmless case
        /// too would refuse something the app has always allowed.
        ///
        /// Wider than "what SQLite would refuse", in one case, deliberately: an
        /// edited rule and a newly ADDED rule on one key would succeed, because
        /// the update runs onto a free key and `INSERT OR IGNORE` absorbs the
        /// add. Blocking it anyway is the better answer twice over. `apply` has
        /// no enclosing transaction, so an under-block can leave a half-written
        /// save. And allowing it means the analyst made two rules, watched the
        /// save succeed, and found one afterwards with no explanation — this
        /// says "these are the same finding" while they can still fix it.
        case duplicateRule(tagIndex: Int, ruleIndex: Int)
    }

    /// Nothing about an unsupported rule blocks Save. An `UpdateTag` carries
    /// only name, colour and note — never conditions — so saving can never
    /// rewrite a rule this build does not understand, and blocking would make
    /// such a tag permanently uneditable for no gain.
    func saveBlocker() -> SaveBlocker? {
        for (tagIndex, tag) in tags.enumerated() where !deleted.contains(tagIndex) {
            for (ruleIndex, rule) in tag.rules.enumerated() where rule.conditions.isEmpty {
                // A rule that arrived EMPTY is not the analyst's doing. The Rust
                // CRUD decodes a corrupt `tuple_values` blob to an empty list
                // rather than failing the load, so such a rule can exist in the
                // store — and blocking on it would make its tag permanently
                // unsaveable, unable even to be renamed. Only a rule emptied
                // HERE blocks.
                let wasAlreadyEmpty = rule.id
                    .flatMap { id in stored[tag.id ?? ""]?.rules.first { $0.id == id } }
                    .map(\.conditions.isEmpty) ?? false
                guard !wasAlreadyEmpty else { continue }
                return .emptyRule(tagIndex: tagIndex, ruleIndex: ruleIndex)
            }
        }
        // The empty rule outranks the duplicate: it is the more basic problem
        // and its message is the more actionable one.
        if let duplicate = duplicateRuleBlocker() { return duplicate }
        return commits().isEmpty ? .noChanges : nil
    }

    /// Two live rules of one tag heading for the same key, when at least one of
    /// them is an edit.
    ///
    /// Only an edit can make this reach SQLite as an error. Deletes are written
    /// first, so a key a deleted rule holds is already free; updates follow, and
    /// one moving onto an occupied key errors; the adds come last as
    /// `INSERT OR IGNORE`, which absorbs a collision. A deleted tag is skipped
    /// whole — none of its rules will be written at all — and a rule with no
    /// conditions is skipped because `emptyRule` above has already refused it
    /// and `RuleKey.encode` has no key for one anyway.
    ///
    /// One case is refused that SQLite would in fact accept — an EDITED rule and
    /// a newly ADDED one on one key. `SaveBlocker.duplicateRule` records why
    /// that width is wanted. The rule named there is the added one, which is
    /// the one to drop.
    private func duplicateRuleBlocker() -> SaveBlocker? {
        for (tagIndex, tag) in tags.enumerated() where !deleted.contains(tagIndex) {
            // key -> was the FIRST rule holding it an edit.
            var firstHolderWasEdit: [String: Bool] = [:]
            for (ruleIndex, rule) in tag.rules.enumerated() {
                guard let key = Self.ruleKey(rule) else { continue }
                let isEdit = isEdited(rule, in: tag)
                guard let earlierWasEdit = firstHolderWasEdit[key] else {
                    firstHolderWasEdit[key] = isEdit
                    continue
                }
                // The SECOND rule of the pair is named, not the first: it is the
                // one the analyst has just changed, so it is the one to point at.
                if earlierWasEdit || isEdit {
                    return .duplicateRule(tagIndex: tagIndex, ruleIndex: ruleIndex)
                }
            }
        }
        return nil
    }

    /// Is this a rule that was READ IN, whose conditions have changed since?
    /// False for a rule added this session — it has no stored form to differ
    /// from, and it will be written as an add, not an update.
    private func isEdited(_ rule: EditableRule, in tag: EditableTag) -> Bool {
        guard let ruleId = rule.id, let tagId = tag.id,
              let before = stored[tagId]?.rules.first(where: { $0.id == ruleId })
        else { return false }
        return before.conditions != rule.conditions
    }

    /// Everything to write, in the order it must be written.
    ///
    /// Derived by comparing each edited tag against the stored one it came from,
    /// rather than from a dirty flag maintained by hand — a flag can drift out
    /// of step with what actually changed, and this cannot.
    func commits() -> [TagManagerCommit] {
        var out: [TagManagerCommit] = []
        for (index, tag) in tags.enumerated() {
            // A tag deleted this session: one command, and nothing else. There
            // is no point updating a tag that is about to go — and a tag both
            // CREATED and deleted here never reached the store at all, so it
            // needs no command.
            if deleted.contains(index) {
                if let id = tag.id { out.append(.deleteTag(id)) }
                continue
            }

            guard let id = tag.id, let before = stored[id] else {
                // A tag the analyst made this session.
                out.append(.create(CreateTag(
                    name: Self.committedName(tag.name), colorIndex: tag.colorIndex,
                    note: tag.note.isEmpty ? nil : tag.note,
                    rules: tag.rules.compactMap(Self.newRule))))
                continue
            }

            // Identity. An empty note is written as an empty STRING, never nil:
            // nil means "leave it alone" in this payload, so nil could never
            // clear a note.
            //
            // The name is compared in the form it would be WRITTEN, on BOTH
            // sides. Two different mistakes are avoided by that.
            //
            // Asking it of the edited name stops a trailing space the analyst
            // added, and the trim then removes, from lighting up Save to write
            // the name it already had.
            //
            // Asking it of the STORED name too stops a tag nobody touched from
            // reporting itself as changed. A name written before the sanitiser
            // existed can hold a scalar the sanitiser removes, and comparing the
            // clean form against the raw one would make every such tag arrive
            // pre-edited — Save lit, "Nothing has changed yet" gone, and a write
            // the analyst never asked for. The rewrite still happens when they
            // save a REAL edit, which is right: the name field shows them the
            // sanitised form, so that is the name they are agreeing to.
            //
            // The NOTE is not treated this way — it is prose, it is neither
            // sanitised nor escaped, and its edge whitespace may be deliberate.
            let name = Self.committedName(tag.name)
            if name != Self.committedName(before.name) || tag.colorIndex != before.colorIndex
                || tag.note != (before.note ?? "") {
                out.append(.update(UpdateTag(id: id, name: name,
                                             colorIndex: tag.colorIndex, note: tag.note)))
            }

            // Rules. Three groups: gone, edited, and new.
            let beforeRules = Dictionary(before.rules.map { ($0.id, $0) },
                                         uniquingKeysWith: { first, _ in first })
            let survivingIds = Set(tag.rules.compactMap(\.id))
            let goneIds = before.rules.map(\.id).filter { !survivingIds.contains($0) }

            var updates: [UpdateTagRule] = []
            var added: [NewTagRule] = []
            for rule in tag.rules {
                guard let ruleId = rule.id else {
                    if let new = Self.newRule(rule) { added.append(new) }
                    continue
                }
                guard let beforeRule = beforeRules[ruleId],
                      beforeRule.conditions != rule.conditions else { continue }
                // Edited, and written in place — ONE command. The rule keeps its
                // id, and with it its `createdAt`: when the finding was first
                // recorded. The delete-plus-add this replaces reset both.
                guard let key = Self.ruleKey(rule) else { continue }
                updates.append(UpdateTagRule(ruleId: ruleId, conditions: rule.conditions,
                                             tupleKey: key))
            }

            // Deletes FIRST: a rule being deleted may hold the very key an
            // edited rule is moving onto, and the unique index would refuse the
            // update otherwise.
            if !goneIds.isEmpty { out.append(.deleteRules(goneIds)) }
            // Updates next, each keeping its rule's id and first-seen time.
            for update in updates { out.append(.updateRule(update)) }
            // Adds last. INSERT OR IGNORE absorbs a collision here, which is
            // the re-tagging no-op and is correct.
            if !added.isEmpty { out.append(.addRules(AddTagRules(tagId: id, rules: added))) }
        }
        return out
    }

    /// One tag's name as the store receives it: SANITISED, then TRIMMED.
    ///
    /// Both, and in that ORDER. The sanitiser folds an unusual space to a plain
    /// one and the trim then takes it; trimming first would stop at whatever
    /// invisible sits outboard of that space and leave a plain space behind that
    /// nothing removes. Every scalar the sanitiser folds is itself trimmable, so
    /// the two orders agree on a lone NBSP and disagree only there — which is
    /// exactly why the order has to be written down rather than discovered.
    ///
    /// Sanitising again here, although the name field already sanitises per
    /// keystroke: `rename(tagAt:to:)` takes any string from any caller, and this
    /// is the boundary that reaches the store.
    ///
    /// Trimming belongs HERE and not in the field. A field that ate the space
    /// you just typed would fight ordinary typing mid-word, so the three sheets
    /// this manager replaced each trimmed on the one line that reached the
    /// store — which is this one.
    private static func committedName(_ raw: String) -> String {
        AuthoredLabelSanitizer.sanitized(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One editable rule as the store receives it, or nil when it holds nothing.
    ///
    /// `RuleKey.encode` is the only producer of a rule key, and it returns nil
    /// for an empty rule — which `saveBlocker` has already refused, so this
    /// `compactMap` is a belt to that braces.
    ///
    /// `originConnection` and `originTable` are empty for an authored rule: it
    /// has no origin row. They are provenance only and no code gates on them. A
    /// rule that came from a grid selection carries the real values through
    /// `Mode.add`'s capture, which the sheet folds in at save.
    private static func newRule(_ rule: EditableRule) -> NewTagRule? {
        guard let key = ruleKey(rule) else { return nil }
        return NewTagRule(conditions: rule.conditions, tupleKey: key,
                          originConnection: "", originTable: "")
    }

    /// One editable rule's canonical key, or nil when it holds no conditions.
    ///
    /// The single place the encoding is spelled out: an add, an update and the
    /// duplicate check all need the same key for the same rule, and two copies
    /// of the expression could drift apart into two keys for one rule.
    private static func ruleKey(_ rule: EditableRule) -> String? {
        RuleKey.encode(rule.conditions.map {
            RuleConditionKey(kind: $0.kind, family: $0.family,
                             value: $0.value, operand2: $0.operand2)
        })
    }
}
