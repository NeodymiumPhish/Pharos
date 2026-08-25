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

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
