// chain-tag-gate regression suite.
//
// THE DEFECT: bodyHasChainTag matched "[chain-terminal" ANYWHERE in the body, so
// an item whose body merely DOCUMENTED the tag for OTHER items passed the gate
// while declaring nothing. It failed OPEN, which is worse than failing closed: a
// refusal leaves an artifact you can see, whereas a bypass leaves nothing and the
// damage surfaces later as a broken chain at completion, the exact condition this
// gate exists to prevent.
//
// THE PIN THAT MATTERS is case 1, the reproduction verbatim. Its payload is "yes",
// non-empty and unbackticked, so a predicate checking only for an empty or
// placeholder payload still passes it. Rule 3 (prose on both sides) is the only one
// that closes it, and it is the rule most likely to be dropped in a refactor as
// over-engineering. If this case ever goes green while the others pass, the gate has
// silently reopened.
import Foundation

var pass = 0, fail = 0
func check(_ name: String, _ got: Bool, _ want: Bool) {
    if got == want { pass += 1; print("  ok   \(name)") }
    else { fail += 1; print("  FAIL \(name): got=\(got) want=\(want)") }
}

// --- 1. The reproduction, verbatim. MUST NOT read as a declaration. ---------
check("repro: tag documented for OTHER items is not a declaration",
      bodyHasChainTag(notes: """
      Note: consumer items each carry [chain-terminal: yes] so the gate passes for them.
                This item is the producer and carries no such tag.
      """), false)

// --- 2. Genuine declarations MUST survive (the false-refusal side) -----------
check("tag-only line declares",
      bodyHasChainTag(notes: "[chain-terminal: the decision is the outcome, nothing follows]"), true)
check("tag among adjacent tags declares",
      bodyHasChainTag(notes: "[ref: x] [ctx: laptop] [chain-terminal: nothing follows this]"), true)
check("chain-on-complete with JSON payload declares",
      bodyHasChainTag(notes: "[chain-on-complete: {\"title\":\"next\",\"due\":\"2026-10-05\"}]"), true)
check("tag on its own line after prose declares",
      bodyHasChainTag(notes: "Some context here.\n[chain-terminal: genuinely terminal]"), true)
check("tag ending a line declares (prose before only)",
      bodyHasChainTag(notes: "Why this is terminal: [chain-terminal: the outcome is the choice]"), true)
check("status glyph before the tag still declares (the #135 measured case)",
      bodyHasChainTag(notes: "⏸️ [chain-terminal: waiting, but terminal]"), true)

// --- 3. Mentions MUST NOT declare -------------------------------------------
check("empty payload is a mention",
      bodyHasChainTag(notes: "[chain-terminal:]"), false)
check("placeholder payload is a mention",
      bodyHasChainTag(notes: "[chain-terminal: <reason>]"), false)
check("backticked tag is a mention",
      bodyHasChainTag(notes: "See `[chain-terminal: yes]` for how the gate works."), false)
check("[tag note] escape is honoured",
      bodyHasChainTag(notes: "[tag note] the form is [chain-terminal: yes] for terminal items."), false)
check("no tag at all",
      bodyHasChainTag(notes: "No tag here at all."), false)
check("nil body",
      bodyHasChainTag(notes: nil), false)
check("empty body",
      bodyHasChainTag(notes: ""), false)

// --- 4. The gate itself, end to end -----------------------------------------
func blocked(_ title: String, _ notes: String?, list: String = "Personal", force: Bool = false) -> Bool {
    return checkChainTagGate(listName: list, title: title, notes: notes, force: force) != nil
}
check("gate REFUSES the repro",
      blocked("Decide whether to renew the thing",
              "Note: consumer items each carry [chain-terminal: yes] so the gate passes for them."), true)
check("gate allows a genuine declaration",
      blocked("Decide whether to renew the thing", "[chain-terminal: nothing follows]"), false)
check("gate still refuses a bare trigger-verb item",
      blocked("Decide whether to renew the thing", "No tag here at all."), true)
check("gate ignores non-Personal lists",
      blocked("Review the thing", "no tag", list: "Strategic"), false)
check("gate honours --force",
      blocked("Review the thing", "no tag", force: true), false)
check("Check-in negation still skips the gate",
      blocked("Check in -- Katie", "no tag"), false)

print("\nchain-tag-gate: \(pass) passed, \(fail) failed")
exit(fail == 0 ? 0 : 1)
