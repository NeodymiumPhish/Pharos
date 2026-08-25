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

    // A rule carrying a kind from a NEWER build is NOT editable. Editing is
    // delete-then-add, and re-adding would drop the kind this build cannot
    // reproduce — destroying a rule that currently round-trips intact.
    let future = storedRule("r9", [
        TagCondition(family: "text", kind: .unsupported("startsWith"),
                     value: "neo", operand2: nil, display: "neo"),
    ])
    let futureModel = TagManagerModel(tags: [storedTag("t3", "future", [future])], mode: .manage)
    expect(!futureModel.tags[0].rules[0].isEditable, "a rule with an unknown kind is not editable")

    // A rule is only uneditable if it holds an unknown kind. One known-kind
    // condition beside an unknown one still makes the whole rule uneditable,
    // because rebuilding it would drop the unknown one.
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

    // Add mode carries draft rules and shows every tag, because the analyst
    // chooses which one they join — or makes a new one.
    let draft = [NewTagRule(conditions: [ip], tupleKey: "k", originConnection: "c1",
                            originTable: "public.certs")]
    let adding = TagManagerModel(tags: two, mode: .add(draft: draft))
    expect(adding.visibleTagIndices == [0, 1], "add mode shows every tag")
    expect(adding.draftRules.count == 1, "and carries the draft rules")
    expect(TagManagerModel(tags: two, mode: .manage).draftRules.isEmpty,
           "manage mode carries no draft rules")

    // MARK: rule and condition edits

    var edit = TagManagerModel(tags: [stored], mode: .manage)

    // Adding a rule. A new rule has no id until it is saved.
    edit.addRule(toTagAt: 0, conditions: [condition("text", "new.example")])
    expect(edit.tags[0].rules.count == 2, "a rule can be added")
    expect(edit.tags[0].rules[1].id == nil, "a new rule has no id yet")

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
    expect(creating.tags[1].id == nil, "a new tag has no id yet")
    expect(creating.tags[1].note == "", "and an empty note, never nil")
    expect(creating.tags[1].rules.isEmpty, "and no rules yet")

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

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
