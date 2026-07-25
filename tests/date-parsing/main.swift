import Foundation

// Regression suite for parseDateComponents — the single chokepoint behind
// add/edit/move --due and list --due-before/--due-after (5 call sites).
//
// WHY THIS FILE EXISTS: the v1.8.1 fix was verified against a scratch driver that
// was deleted immediately after, leaving the repo with a behavioral guarantee and
// nothing to enforce it. A control replay had to reconstruct the driver from a log
// to confirm the fix still held. That is the gap this closes.
//
// Not XCTest on purpose: this machine builds with Command Line Tools only, where
// `swift test` cannot resolve XCTest ("unable to lookup item 'PlatformPath'").
// A plain driver compiled straight against Sources/EventKitCore.swift runs
// anywhere swiftc does. Run via tests/run-tests.sh.
//
// Contract under test — a typo'd date must FAIL LOUDLY, never silently shift:
//   v1.8.1  value validation  — reject out-of-range dates/times (Calendar's lenient
//                               normalization turned 2026-02-30 into Mar 2)
//   v1.8.2  tokenizer strictness — reject malformed components before conversion
//                               (split+compactMap turned "2026-02--5" into Feb 5)

struct Case {
    let name: String
    let input: String
    let time: String?
    let wantNil: Bool
}

let cases: [Case] = [
    // ---- plain YYYY-MM-DD: out-of-range values must be rejected (v1.8.1) ----
    Case(name: "plain Feb-30 invalid day",         input: "2026-02-30", time: nil,     wantNil: true),
    Case(name: "plain Apr-31 invalid day",         input: "2026-04-31", time: nil,     wantNil: true),
    Case(name: "plain month 13",                   input: "2026-13-01", time: nil,     wantNil: true),
    Case(name: "plain month 0",                    input: "2026-00-10", time: nil,     wantNil: true),
    Case(name: "plain day 0",                      input: "2026-02-00", time: nil,     wantNil: true),
    Case(name: "non-leap Feb-29 invalid",          input: "2026-02-29", time: nil,     wantNil: true),
    Case(name: "bad time 25:99",                   input: "2026-02-15", time: "25:99", wantNil: true),
    Case(name: "hour 24 boundary",                 input: "2026-02-15", time: "24:00", wantNil: true),
    Case(name: "garbage time",                     input: "2026-02-15", time: "ab:cd", wantNil: true),

    // ---- plain YYYY-MM-DD: valid input must survive (no-regression guard) ----
    Case(name: "leap Feb-29 valid",                input: "2024-02-29", time: nil,     wantNil: false),
    Case(name: "valid baseline",                   input: "2026-02-15", time: nil,     wantNil: false),
    Case(name: "single-digit month still valid",   input: "2026-2-15",  time: nil,     wantNil: false),
    Case(name: "single-digit day still valid",     input: "2026-02-5",  time: nil,     wantNil: false),
    Case(name: "valid date + time",                input: "2026-02-15", time: "14:30", wantNil: false),
    Case(name: "midnight boundary valid",          input: "2026-02-15", time: "00:00", wantNil: false),
    Case(name: "23:59 boundary valid",             input: "2026-02-15", time: "23:59", wantNil: false),

    // ---- tokenizer strictness (v1.8.2) — the class value validation cannot catch ----
    Case(name: "TOKEN empty component (2026-02--5)", input: "2026-02--5",  time: nil,   wantNil: true),
    Case(name: "TOKEN empty leading (2026--02-15)",  input: "2026--02-15", time: nil,   wantNil: true),
    Case(name: "TOKEN trailing separator",           input: "2026-02-",    time: nil,   wantNil: true),
    Case(name: "TOKEN signed component (+5)",        input: "2026-02-+5",  time: nil,   wantNil: true),
    Case(name: "TOKEN negative component (-5)",      input: "2026-02--5",  time: nil,   wantNil: true),
    Case(name: "TOKEN four components",              input: "2026-02-15-1",time: nil,   wantNil: true),
    Case(name: "TOKEN non-ASCII digits",             input: "٢٠٢٦-٠٢-١٥",  time: nil,   wantNil: true),
    Case(name: "TOKEN empty time component",         input: "2026-02-15",  time: "1::30", wantNil: true),
    Case(name: "TOKEN trailing time separator",      input: "2026-02-15",  time: "09:",   wantNil: true),
    Case(name: "TOKEN ISO empty component",          input: "2026-02--5T09:00:00Z", time: nil, wantNil: true),

    // ---- ISO-8601 datetime path ----
    Case(name: "ISO Feb-30 invalid day",           input: "2026-02-30T09:00:00Z",     time: nil, wantNil: true),
    Case(name: "ISO Apr-31 invalid day",           input: "2026-04-31T09:00:00Z",     time: nil, wantNil: true),
    Case(name: "ISO month 13",                     input: "2026-13-01T09:00:00Z",     time: nil, wantNil: true),
    Case(name: "ISO bad hour 25",                  input: "2026-02-15T25:00:00Z",     time: nil, wantNil: true),
    Case(name: "ISO bad minute 99",                input: "2026-02-15T09:99:00Z",     time: nil, wantNil: true),
    Case(name: "ISO no timezone",                  input: "2026-06-27T09:00:00",      time: nil, wantNil: true),
    Case(name: "ISO date-portion only",            input: "2026-06-27T",              time: nil, wantNil: true),
    Case(name: "ISO lowercase t separator",        input: "2026-02-30t09:00:00Z",     time: nil, wantNil: true),
    Case(name: "ISO valid (emitted form)",         input: "2026-06-27T13:00:00Z",     time: nil, wantNil: false),
    Case(name: "ISO valid fractional seconds",     input: "2026-06-27T13:00:00.000Z", time: nil, wantNil: false),
    Case(name: "ISO valid negative offset",        input: "2026-06-27T09:00:00-04:00", time: nil, wantNil: false),

    // ---- non-date garbage ----
    Case(name: "empty string",                     input: "",           time: nil, wantNil: true),
    Case(name: "non-date text",                    input: "tomorrow",   time: nil, wantNil: true),
]

print("parseDateComponents regression suite — TZ=\(TimeZone.current.identifier), calendar=\(Calendar.current.identifier)")

var passed = 0
var failures: [String] = []

for c in cases {
    let got = parseDateComponents(c.input, time: c.time)
    let ok = (got == nil) == c.wantNil
    let shown: String
    if let g = got {
        shown = "Y=\(g.year ?? -1) M=\(g.month ?? -1) D=\(g.day ?? -1) h=\(g.hour ?? -1) m=\(g.minute ?? -1)"
    } else {
        shown = "nil"
    }
    if ok {
        passed += 1
    } else {
        let line = "FAIL [\(c.name)] in='\(c.input)' time=\(c.time ?? "-") -> \(shown) (want \(c.wantNil ? "nil" : "value"))"
        failures.append(line)
        print(line)
    }
}

print("\(passed)/\(cases.count) passed")
if !failures.isEmpty {
    print("FAILED: \(failures.count)")
    exit(1)
}
print("OK")
