// Standalone test for TagManagerModel: the editable tag, what may be edited,
// and the commands that save it.
import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

// MARK: Fixtures

func condition(_ family: String, _ value: String,
               _ kind: TagConditionKind = .exact) -> TagCondition {
    TagCondition(family: family, kind: kind,
                 value: TagValueNormalizer.normalize(value, family: family),
                 operand2: nil, display: value)
}

func storedRule(_ id: String, _ conditions: [TagCondition]) -> TagRule {
    TagRule(id: id, conditions: conditions, tupleKey: "key-\(id)",
            originConnection: "c1", originTable: "public.certs", createdAt: "2026-08-01T00:00:00Z")
}

/// What a grid selection offers: two columns of different families, and three
/// selected rows — the last with a NULL in the second column, so the NULL rule
/// is exercised by the same fixture.
func fixtureCapture() -> TagCapture {
    TagCapture(
        columns: [
            ColumnDef(name: "ip", dataType: "inet", relationOid: nil, relationAttno: nil),
            ColumnDef(name: "host", dataType: "text", relationOid: nil, relationAttno: nil),
        ],
        selectedRows: [
            ["10.0.0.1", "evil.com"],
            ["10.0.0.2", "other.com"],
            ["10.0.0.3", nil],
        ],
        originConnection: "c1",
        originTable: "public.certs")
}

func storedTag(_ id: String, _ name: String, _ rules: [TagRule]) -> Tag {
    Tag(id: id, name: name, colorIndex: 2, note: "a note",
        createdAt: "2026-08-01T00:00:00Z", updatedAt: "2026-08-01T00:00:00Z", rules: rules)
}

func runTests() {
    // MARK: reading stored tags in

    let ip = condition("address", "10.0.0.1")
    let host = condition("text", "evil.com")
    let stored = storedTag("t1", "Suspect infra", [storedRule("r1", [ip, host])])
    let model = TagManagerModel(tags: [stored], mode: .manage)

    expect(model.tags.count == 1, "one stored tag reads in as one editable tag")
    expect(model.tags[0].id == "t1", "the id travels")
    expect(model.tags[0].name == "Suspect infra", "the name travels")
    expect(model.tags[0].colorIndex == 2, "the colour travels")
    expect(model.tags[0].note == "a note", "the note travels")
    expect(model.tags[0].rules.count == 1, "the rules travel")
    expect(model.tags[0].rules[0].id == "r1", "a stored rule keeps its id")
    expect(model.tags[0].rules[0].conditions.count == 2, "and its conditions")

    // A nil note reads in as an empty string, so the field never shows "nil".
    let noNote = Tag(id: "t2", name: "n", colorIndex: 0, note: nil,
                     createdAt: "", updatedAt: "", rules: [])
    expect(TagManagerModel(tags: [noNote], mode: .manage).tags[0].note == "",
           "a nil note reads in as empty text")

    // MARK: what may be edited

    // A rule this build fully understands is editable.
    expect(model.tags[0].rules[0].isEditable, "a rule of known kinds is editable")

    // A rule carrying a kind from a NEWER build is NOT editable: no control can
    // render or evaluate such a condition, so an edit would be made blind.
    let future = storedRule("r9", [
        TagCondition(family: "text", kind: .unsupported("startsWith"),
                     value: "neo", operand2: nil, display: "neo"),
    ])
    let futureModel = TagManagerModel(tags: [storedTag("t3", "future", [future])], mode: .manage)
    expect(!futureModel.tags[0].rules[0].isEditable, "a rule with an unknown kind is not editable")

    // A rule is only uneditable if it holds an unknown kind. One known-kind
    // condition beside an unknown one still makes the whole rule uneditable,
    // because the analyst cannot see what sits beside what they are changing.
    let mixed = storedRule("r10", [
        host,
        TagCondition(family: "text", kind: .unsupported("endsWith"),
                     value: "x", operand2: nil, display: "x"),
    ])
    expect(!TagManagerModel(tags: [storedTag("t6", "mixed", [mixed])], mode: .manage)
            .tags[0].rules[0].isEditable,
           "one unknown condition makes the whole rule uneditable")

    // But the tag around it stays fully editable — an UpdateTag carries only
    // name, colour and note, never conditions, so renaming can never rewrite it.
    var futureEdit = futureModel
    futureEdit.rename(tagAt: 0, to: "renamed")
    expect(futureEdit.tags[0].name == "renamed", "a tag holding an unknown rule can still be renamed")
    futureEdit.recolour(tagAt: 0, to: 4)
    expect(futureEdit.tags[0].colorIndex == 4, "and recoloured")
    futureEdit.note(tagAt: 0, to: "new note")
    expect(futureEdit.tags[0].note == "new note", "and re-noted")

    // MARK: the three entry modes

    expect(TagManagerModel(tags: [stored], mode: .manage).visibleTagIndices == [0],
           "manage mode shows every tag")

    // Remove mode narrows the sidebar to the tags holding the named rules.
    let two = [stored, storedTag("t4", "Other", [storedRule("r4", [host])])]
    let removing = TagManagerModel(tags: two, mode: .remove(ruleIds: ["r4"]))
    expect(removing.visibleTagIndices == [1], "remove mode shows only the tags holding those rules")
    expect(removing.isPreselected(ruleId: "r4"), "and the named rule is preselected")
    expect(!removing.isPreselected(ruleId: "r1"), "while others are not")

    // Preselection is meaningless outside remove mode.
    expect(!TagManagerModel(tags: two, mode: .manage).isPreselected(ruleId: "r4"),
           "manage mode preselects nothing")

    // Add mode carries what the selection OFFERS and shows every tag, because
    // the analyst chooses which one the capture joins — or makes a new one.
    var adding = TagManagerModel(tags: two, mode: .add(capture: fixtureCapture()))
    expect(adding.visibleTagIndices == [0, 1], "add mode shows every tag")
    expect(adding.capture != nil, "and carries the capture")
    expect(TagManagerModel(tags: two, mode: .manage).capture == nil,
           "manage mode carries no capture")
    expect(TagManagerModel(tags: two, mode: .manage).draftRules.isEmpty,
           "manage mode carries no draft rules")

    // MARK: the capture checklist

    // NOTHING starts ticked. A tag is a durable artifact and the choice of what
    // it captures should be deliberate; capturing every column by default gives
    // a rule that matches almost nothing but the row it came from.
    expect(adding.checkedCaptureColumns.isEmpty, "no capture column starts ticked")
    expect(adding.draftRules.isEmpty, "so the draft starts empty")

    // Ticking one column: one rule per selected row, each of one condition.
    expect(adding.setCaptureColumn(0, checked: true), "a capture column can be ticked")
    expect(adding.checkedCaptureColumns == [0], "and the model records it")
    let oneTicked = adding.draftRules
    expect(oneTicked.count == 3, "one rule per selected row")
    expect(oneTicked.allSatisfy { $0.conditions.count == 1 },
           "each holding just the ticked column's value")
    expect(oneTicked.allSatisfy { $0.originConnection == "c1" && $0.originTable == "public.certs" },
           "carrying the provenance the capture came with")

    // Ticking a second widens each rule, never the rule count: a cross product
    // would invent pairs no observation ever showed.
    expect(adding.setCaptureColumn(1, checked: true), "a second column can be ticked")
    let twoTicked = adding.draftRules
    expect(twoTicked.count == 3, "still one rule per selected row")
    // Two conditions each, except the row whose host is NULL — see the NULL
    // assertions below, which is the same fixture read the other way round.
    expect(twoTicked.map(\.conditions.count) == [2, 2, 1],
           "each now holding both ticked columns, bar the row with a NULL in one")

    // The conditions arrive in RESULT COLUMN order whatever order the boxes
    // were ticked in, so two analysts ticking the same two columns write the
    // same rule.
    expect(twoTicked.first.map { $0.conditions.map(\.family) == ["address", "text"] } ?? false,
           "in result-column order")

    // Unticking takes it back out again.
    expect(adding.setCaptureColumn(0, checked: false), "a column can be unticked")
    expect(adding.draftRules.allSatisfy { $0.conditions.count == 1 },
           "and the rules narrow again")
    expect(adding.setCaptureColumn(1, checked: false), "the last column can be unticked")
    expect(adding.draftRules.isEmpty, "leaving no draft at all")

    // A NULL is the ABSENCE of a value: it drops out of the tuple rather than
    // becoming a slot nothing can satisfy, so a row whose ticked column is NULL
    // yields a NARROWER rule than its neighbours.
    var nulling = TagManagerModel(tags: two, mode: .add(capture: fixtureCapture()))
    nulling.setCaptureColumn(0, checked: true)
    nulling.setCaptureColumn(1, checked: true)
    let nulled = nulling.draftRules
    expect(nulled.count == 3, "a NULL cell still yields a rule for its row")
    if nulled.count == 3 {
        expect(nulled[2].conditions.count == 1,
               "but a narrower one, with no condition for the NULL column")
        expect(nulled[2].conditions.allSatisfy { $0.family == "address" },
               "keeping only the column that held a value")
    }

    // An index the result does not hold is REFUSED rather than trapping: the
    // checklist and the grid could disagree after a Load More.
    expect(!nulling.setCaptureColumn(9, checked: true),
           "a column the result does not hold cannot be ticked")
    expect(!nulling.setCaptureColumn(-1, checked: true),
           "nor can a negative index")

    // Ticking is meaningless outside add mode, and must not pretend otherwise.
    var managing = TagManagerModel(tags: two, mode: .manage)
    expect(!managing.setCaptureColumn(0, checked: true),
           "manage mode has nothing to capture from, so it refuses a tick")
    expect(managing.draftRules.isEmpty, "and still carries no draft rules")

    // The property the whole design turns on: a tick MUTATES the model rather
    // than replacing it, so an edit made a moment earlier survives.
    var renamingThenTicking = TagManagerModel(tags: two, mode: .add(capture: fixtureCapture()))
    renamingThenTicking.rename(tagAt: 0, to: "Renamed First")
    renamingThenTicking.setCaptureColumn(0, checked: true)
    expect(renamingThenTicking.tags[0].name == "Renamed First",
           "a tick does not discard a rename typed before it")
    expect(!renamingThenTicking.draftRules.isEmpty, "and the tick took effect")

    // MARK: rule and condition edits

    var edit = TagManagerModel(tags: [stored], mode: .manage)

    // Adding a rule. A new rule has no id until it is saved.
    edit.addRule(toTagAt: 0, conditions: [condition("text", "new.example")])
    expect(edit.tags[0].rules.count == 2, "a rule can be added")
    // Rule 1 exists only because `addRule` appended it, so its index is guarded
    // rather than assumed. A trap here would take the whole file's output down.
    if edit.tags[0].rules.count == 2 {
        expect(edit.tags[0].rules[1].id == nil, "a new rule has no id yet")
    }

    // Adding a condition to an existing rule.
    expect(edit.addCondition(condition("numeric", "443"), toRuleAt: 0, inTagAt: 0),
           "a condition can be added to an editable rule")
    expect(edit.tags[0].rules[0].conditions.count == 3, "and it lands")

    // Replacing one, which is how the value field commits.
    expect(edit.replaceCondition(at: 0, inRuleAt: 0, ofTagAt: 0,
                                 with: condition("address", "10.0.0.2")),
           "a condition can be replaced")
    expect(edit.tags[0].rules[0].conditions[0].display == "10.0.0.2", "and it lands")

    // Removing one.
    expect(edit.removeCondition(at: 2, fromRuleAt: 0, inTagAt: 0), "a condition can be removed")
    expect(edit.tags[0].rules[0].conditions.count == 2, "and it goes")

    // Removing a whole rule.
    edit.removeRule(at: 1, fromTagAt: 0)
    expect(edit.tags[0].rules.count == 1, "a rule can be removed")

    // A rule this build cannot understand refuses every condition edit, and the
    // refusal is REPORTED rather than silent — the sheet must be able to say why
    // nothing happened.
    var futureEdits = TagManagerModel(tags: [storedTag("t3", "future", [future])], mode: .manage)
    expect(!futureEdits.addCondition(condition("text", "x"), toRuleAt: 0, inTagAt: 0),
           "an unknown-kind rule refuses a new condition")
    expect(!futureEdits.removeCondition(at: 0, fromRuleAt: 0, inTagAt: 0),
           "an unknown-kind rule refuses a condition removal")
    expect(!futureEdits.replaceCondition(at: 0, inRuleAt: 0, ofTagAt: 0,
                                         with: condition("text", "x")),
           "an unknown-kind rule refuses a replacement")
    expect(futureEdits.tags[0].rules[0].conditions.count == 1,
           "and none of the refusals changed it")

    // But it can be DELETED whole, which needs no understanding of it.
    futureEdits.removeRule(at: 0, fromTagAt: 0)
    expect(futureEdits.tags[0].rules.isEmpty, "an unknown-kind rule can still be deleted whole")

    // New tags.
    var creating = TagManagerModel(tags: [stored], mode: .manage)
    creating.addTag(name: "New case", colorIndex: 3)
    expect(creating.tags.count == 2, "a tag can be added")
    // Tag 1 exists only because `addTag` appended it. Guarded, not assumed.
    if creating.tags.count == 2 {
        expect(creating.tags[1].id == nil, "a new tag has no id yet")
        expect(creating.tags[1].note == "", "and an empty note, never nil")
        expect(creating.tags[1].rules.isEmpty, "and no rules yet")
    }

    // Deleting a tag marks it, rather than dropping it from the array — the
    // sidebar keeps its indices stable while the sheet is open.
    creating.deleteTag(at: 0)
    expect(creating.isDeleted(tagAt: 0), "a deleted tag is marked")
    expect(creating.tags.count == 2, "and is still in the array, so indices hold")
    expect(creating.visibleTagIndices == [1], "but leaves the sidebar")

    // Every index-taking method survives an out-of-range index rather than
    // trapping. The sheet's indices and the model's can disagree for one run
    // loop after a delete.
    var ranges = TagManagerModel(tags: [stored], mode: .manage)
    ranges.rename(tagAt: 99, to: "x")
    ranges.recolour(tagAt: 99, to: 5)
    ranges.note(tagAt: 99, to: "x")
    ranges.removeRule(at: 99, fromTagAt: 99)
    ranges.addRule(toTagAt: 99, conditions: [condition("text", "x")])
    ranges.deleteTag(at: 99)
    expect(!ranges.addCondition(condition("text", "x"), toRuleAt: 99, inTagAt: 99),
           "an out-of-range condition add is refused, not a trap")
    expect(!ranges.removeCondition(at: 99, fromRuleAt: 99, inTagAt: 99),
           "an out-of-range condition remove is refused, not a trap")
    expect(!ranges.replaceCondition(at: 99, inRuleAt: 99, ofTagAt: 99,
                                    with: condition("text", "x")),
           "an out-of-range replacement is refused, not a trap")
    expect(ranges.tags[0].name == "Suspect infra", "and nothing was disturbed")
    expect(ranges.tags.count == 1, "and no tag was added or removed")

    // An in-range TAG but an out-of-range RULE is refused too — the two indices
    // are checked separately and both can be stale.
    expect(!ranges.addCondition(condition("text", "x"), toRuleAt: 99, inTagAt: 0),
           "a stale rule index inside a live tag is refused")
    // And an in-range rule with an out-of-range CONDITION index.
    expect(!ranges.removeCondition(at: 99, fromRuleAt: 0, inTagAt: 0),
           "a stale condition index inside a live rule is refused")

    // MARK: deriving the save

    // Nothing touched, nothing written. This is the property that makes Save
    // safe to press twice.
    expect(TagManagerModel(tags: [stored], mode: .manage).commits().isEmpty,
           "an untouched model writes nothing")

    // A rename writes an update carrying ONLY the identity fields. It must never
    // carry conditions — that is what lets a tag holding a rule this build
    // cannot understand still be renamed without destroying it.
    var renamed = TagManagerModel(tags: [stored], mode: .manage)
    renamed.rename(tagAt: 0, to: "Renamed")
    let renameCommits = renamed.commits()
    expect(renameCommits.count == 1, "a rename writes one command")
    if case .update(let payload)? = renameCommits.first {
        expect(payload.id == "t1", "the update names the tag")
        expect(payload.name == "Renamed", "and carries the new name")
        expect(payload.colorIndex == 2, "and the unchanged colour")
    } else {
        expect(false, "a rename writes an update")
    }

    // A note cleared to empty is written as an empty STRING, not nil — a nil
    // field means "leave it alone" in this payload, so nil could never clear it.
    var cleared = TagManagerModel(tags: [stored], mode: .manage)
    cleared.note(tagAt: 0, to: "")
    if case .update(let payload)? = cleared.commits().first {
        expect(payload.note == "", "a cleared note is written as empty text, not nil")
    } else {
        expect(false, "clearing a note writes an update")
    }

    // A brand-new tag writes a create carrying its rules, and no update.
    var created = TagManagerModel(tags: [], mode: .manage)
    created.addTag(name: "New case", colorIndex: 1)
    created.addRule(toTagAt: 0, conditions: [condition("text", "evil.com")])
    let createCommits = created.commits()
    expect(createCommits.count == 1, "a new tag writes exactly one command")
    if case .create(let payload)? = createCommits.first {
        expect(payload.name == "New case", "the create carries the name")
        expect(payload.rules.count == 1, "and its rules")
        // `.first?`, not `[0]` — the count above is an assertion, not a guard.
        expect(payload.rules.first?.tupleKey.isEmpty == false,
               "and a rule key derived for it")
    } else {
        expect(false, "a new tag writes a create")
    }

    // MARK: the name a save writes

    // The three sheets this manager replaced each trimmed the name on the ONE
    // line that reached the store. The manager sanitises per keystroke but did
    // not trim, so `"  Suspect  "` was stored with its spaces. Trimming happens
    // HERE, at the commit, and not in the field: a field that ate the space you
    // just typed would fight ordinary typing mid-word.
    var padded = TagManagerModel(tags: [stored], mode: .manage)
    padded.rename(tagAt: 0, to: "  Suspect  ")
    if case .update(let payload)? = padded.commits().first {
        expect(payload.name == "Suspect", "a padded name commits trimmed")
    } else {
        expect(false, "a padded rename writes an update")
    }

    // The same on the create path, which reaches the store by a different line.
    var paddedNew = TagManagerModel(tags: [], mode: .manage)
    paddedNew.addTag(name: "  Fresh  ", colorIndex: 1)
    paddedNew.addRule(toTagAt: 0, conditions: [condition("text", "evil.com")])
    if case .create(let payload)? = paddedNew.commits().first {
        expect(payload.name == "Fresh", "a padded new name commits trimmed too")
    } else {
        expect(false, "a padded new tag writes a create")
    }

    // Padding ALONE is not a change. Without this the analyst types a trailing
    // space, Save lights up, and the write that follows sets the name to what it
    // already was.
    var onlyPadding = TagManagerModel(tags: [stored], mode: .manage)
    onlyPadding.rename(tagAt: 0, to: "  \(stored.name)  ")
    expect(onlyPadding.commits().isEmpty,
           "adding spaces around the stored name is no change at all")

    // SANITISE FIRST, THEN TRIM. An unusual space folds to a plain one, which
    // the trim then takes. A lone NBSP therefore commits as an EMPTY name —
    // which `TagManagerSheet.blockingReason` refuses, so Save stays shut rather
    // than writing a tag whose name is one invisible character.
    var nbspOnly = TagManagerModel(tags: [stored], mode: .manage)
    nbspOnly.rename(tagAt: 0, to: "\u{00A0}")
    if case .update(let payload)? = nbspOnly.commits().first {
        expect(payload.name == "", "a name of one unusual space commits as empty")
    } else {
        expect(false, "a name of one unusual space still writes an update")
    }

    // The ordering, pinned by an input that can actually tell the two apart.
    //
    // The lone NBSP above cannot. Every scalar the sanitiser FOLDS is itself in
    // `.whitespacesAndNewlines`, so trimming first reaches the same empty string
    // — that input pins the BEHAVIOUR but not the order.
    //
    // What tells them apart is a REMOVED scalar sitting outboard of a folded
    // one. A BOM pasted off the end of a line is the everyday version. Trim
    // first and the BOM stops the trim before it reaches the NBSP; the NBSP then
    // folds to a plain space that nothing trims any more, and the name commits
    // as `"Suspect "` — the very defect the trim was added to fix, one paste
    // further along.
    //
    // U+200B is NOT the character to use here: Foundation's whitespace set
    // includes it, so the trim goes straight through it either way.
    var foldedEdge = TagManagerModel(tags: [stored], mode: .manage)
    foldedEdge.rename(tagAt: 0, to: "Suspect\u{00A0}\u{FEFF}")
    if case .update(let payload)? = foldedEdge.commits().first {
        expect(payload.name == "Suspect",
               "a folded space behind an invisible is sanitised BEFORE it is "
               + "trimmed, so no space survives the commit")
    } else {
        expect(false, "a name with a folded edge writes an update")
    }

    // A new rule on an EXISTING tag writes an add, not a create.
    var grown = TagManagerModel(tags: [stored], mode: .manage)
    grown.addRule(toTagAt: 0, conditions: [condition("text", "new.example")])
    let growCommits = grown.commits()
    expect(growCommits.count == 1, "adding a rule writes one command")
    if case .addRules(let payload)? = growCommits.first {
        expect(payload.tagId == "t1", "the add names the tag")
        expect(payload.rules.count == 1, "and carries the one new rule")
    } else {
        expect(false, "a new rule on an existing tag writes an add")
    }

    // Deleting a rule writes its id.
    var pruned = TagManagerModel(tags: [stored], mode: .manage)
    pruned.removeRule(at: 0, fromTagAt: 0)
    if case .deleteRules(let ids)? = pruned.commits().first {
        expect(ids == ["r1"], "deleting a rule writes its id")
    } else {
        expect(false, "deleting a rule writes a delete")
    }

    // MARK: editing a rule in place

    // An edited rule now writes ONE command, and the rule keeps its id — which
    // is what keeps its `createdAt`, the time the finding was first recorded.
    var edited = TagManagerModel(tags: [stored], mode: .manage)
    _ = edited.addCondition(condition("numeric", "443"), toRuleAt: 0, inTagAt: 0)
    let editedCommits = edited.commits()
    expect(editedCommits.count == 1, "editing a rule writes exactly one command")
    // Guarded, never indexed on the strength of the line above. A trap discards
    // Swift's stdout buffer, so one out-of-range index would destroy the output
    // of EVERY assertion in this file — including the one that just failed —
    // and the run would then look exactly like a mutation that never applied.
    if editedCommits.count == 1, case .updateRule(let payload) = editedCommits[0] {
        expect(payload.ruleId == "r1", "the update names the rule, keeping its id")
        expect(payload.conditions.count == 3, "and carries the new conditions")
        expect(!payload.tupleKey.isEmpty, "and a key derived from them")
    } else {
        expect(false, "editing a rule writes an updateRule")
    }

    // The key really is derived from the NEW conditions, not carried over.
    var rekeyed = TagManagerModel(tags: [stored], mode: .manage)
    _ = rekeyed.replaceCondition(at: 0, inRuleAt: 0, ofTagAt: 0,
                                 with: condition("address", "10.9.9.9"))
    if case .updateRule(let payload)? = rekeyed.commits().first {
        expect(payload.tupleKey.contains("10.9.9.9"), "the key follows the new conditions")
    } else {
        expect(false, "replacing a condition writes an updateRule")
    }

    // Deleting a tag writes one command and nothing else — no point updating a
    // tag that is about to go.
    var dropped = TagManagerModel(tags: [stored], mode: .manage)
    dropped.rename(tagAt: 0, to: "doomed")
    dropped.deleteTag(at: 0)
    let dropCommits = dropped.commits()
    expect(dropCommits.count == 1, "a deleted tag writes exactly one command")
    if case .deleteTag(let id)? = dropCommits.first {
        expect(id == "t1", "and it is the delete")
    } else {
        expect(false, "a deleted tag writes a delete")
    }

    // A tag created and then deleted in the same session writes NOTHING — it
    // never reached the store, so there is nothing to undo.
    var churned = TagManagerModel(tags: [], mode: .manage)
    churned.addTag(name: "brief", colorIndex: 0)
    churned.deleteTag(at: 0)
    expect(churned.commits().isEmpty, "a tag created and deleted in one session writes nothing")

    // A new tag with no rules still writes a create: a named case with no
    // indicators yet is a legitimate thing to make.
    var empty = TagManagerModel(tags: [], mode: .manage)
    empty.addTag(name: "empty case", colorIndex: 0)
    expect(empty.commits().count == 1, "a new tag with no rules is still created")

    // MARK: what blocks Save

    expect(TagManagerModel(tags: [stored], mode: .manage).saveBlocker() == .noChanges,
           "an untouched model cannot be saved")
    expect(renamed.saveBlocker() == nil, "a rename can be saved")

    // A rule stripped of every condition blocks Save. It would be inert in the
    // matcher and noise in the store, and it is almost certainly a half-finished
    // edit rather than an intent.
    var hollow = TagManagerModel(tags: [stored], mode: .manage)
    _ = hollow.removeCondition(at: 0, fromRuleAt: 0, inTagAt: 0)
    _ = hollow.removeCondition(at: 0, fromRuleAt: 0, inTagAt: 0)
    expect(hollow.saveBlocker() == .emptyRule(tagIndex: 0, ruleIndex: 0),
           "a rule with no conditions blocks Save, and says which")

    // A rule that arrived EMPTY from a corrupt blob must NOT block Save, or its
    // tag could never be renamed again. Only a rule emptied in this session does.
    let corrupt = storedTag("t5", "corrupt", [storedRule("r5", [])])
    var corruptEdit = TagManagerModel(tags: [corrupt], mode: .manage)
    corruptEdit.rename(tagAt: 0, to: "renamed anyway")
    expect(corruptEdit.saveBlocker() == nil,
           "a rule that arrived empty does not block Save")

    // A tag holding a rule this build cannot understand is still saveable —
    // an update carries no conditions, so it cannot rewrite the unknown rule.
    var futureRename = TagManagerModel(tags: [storedTag("t3", "future", [future])], mode: .manage)
    futureRename.rename(tagAt: 0, to: "still fine")
    expect(futureRename.saveBlocker() == nil,
           "a tag holding an unknown rule can still be saved")

    // MARK: collisions

    // Two rules of one tag, edited until they match, cannot be saved: the
    // UPDATE would error on the unique index.
    let twoRules = storedTag("t7", "two", [
        storedRule("r7a", [condition("text", "one.example")]),
        storedRule("r7b", [condition("text", "two.example")]),
    ])
    var colliding = TagManagerModel(tags: [twoRules], mode: .manage)
    _ = colliding.replaceCondition(at: 0, inRuleAt: 1, ofTagAt: 0,
                                   with: condition("text", "one.example"))
    expect(colliding.saveBlocker() == .duplicateRule(tagIndex: 0, ruleIndex: 1),
           "two rules edited to match block Save, naming the second")

    // The same conditions in DIFFERENT tags do not collide — the index is per
    // tag, and one indicator legitimately appears in two cases.
    let sameInTwo = [
        storedTag("t8", "a", [storedRule("r8", [condition("text", "shared.example")])]),
        storedTag("t9", "b", [storedRule("r9b", [condition("text", "other.example")])]),
    ]
    var across = TagManagerModel(tags: sameInTwo, mode: .manage)
    _ = across.replaceCondition(at: 0, inRuleAt: 0, ofTagAt: 1,
                                with: condition("text", "shared.example"))
    expect(across.saveBlocker() == nil, "the same rule in two different tags is fine")

    // A purely-ADDED duplicate does NOT block: INSERT OR IGNORE absorbs it,
    // which is the re-tagging no-op and has always been allowed.
    var addedDuplicate = TagManagerModel(tags: [twoRules], mode: .manage)
    addedDuplicate.addRule(toTagAt: 0, conditions: [condition("text", "one.example")])
    expect(addedDuplicate.saveBlocker() == nil,
           "a newly added duplicate is absorbed, not blocked")

    // Deleting a rule and editing another onto its key is FINE, and the delete
    // must be emitted first.
    var freed = TagManagerModel(tags: [twoRules], mode: .manage)
    freed.removeRule(at: 0, fromTagAt: 0)
    _ = freed.replaceCondition(at: 0, inRuleAt: 0, ofTagAt: 0,
                               with: condition("text", "one.example"))
    expect(freed.saveBlocker() == nil, "taking a deleted rule's key is allowed")
    let freedCommits = freed.commits()
    expect(freedCommits.count == 2, "it writes a delete and an update")
    if freedCommits.count == 2 {
        if case .deleteRules = freedCommits[0] {
            expect(true, "the delete comes first")
        } else {
            expect(false, "the delete comes first")
        }
    }

    // An empty rule outranks a duplicate: it is the more basic problem and its
    // message is more actionable. The duplicate has to be REALLY THERE for this
    // to test anything — rule 0 is emptied, and rule 2 moves onto rule 1's key,
    // so both blockers hold at once and only the empty one may be reported.
    let threeRules = storedTag("t10", "three", [
        storedRule("r10a", [condition("text", "one.example")]),
        storedRule("r10b", [condition("text", "two.example")]),
        storedRule("r10c", [condition("text", "three.example")]),
    ])
    var emptyOutranks = TagManagerModel(tags: [threeRules], mode: .manage)
    _ = emptyOutranks.removeCondition(at: 0, fromRuleAt: 0, inTagAt: 0)
    _ = emptyOutranks.replaceCondition(at: 0, inRuleAt: 2, ofTagAt: 0,
                                       with: condition("text", "two.example"))
    expect(emptyOutranks.saveBlocker() == .emptyRule(tagIndex: 0, ruleIndex: 0),
           "an empty rule outranks a duplicate that is really there")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
