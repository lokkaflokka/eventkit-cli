import EventKit
import Foundation

// MARK: - Output helpers

func stderrPrint(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// MARK: - Argument parsing helpers

func hasFlag(_ flag: String, in args: [String]) -> Bool {
    args.contains(flag)
}

func extractFlag(_ flag: String, from args: [String]) -> String? {
    guard let index = args.firstIndex(of: flag), index + 1 < args.count else {
        return nil
    }
    return args[index + 1]
}

func extractFlag(anyOf flags: [String], from args: [String]) -> String? {
    for flag in flags {
        if let v = extractFlag(flag, from: args) { return v }
    }
    return nil
}

/// Strip known flags and their values from args, returning only positional args
func positionalArgs(from args: [String], valueFlags: [String] = [], boolFlags: [String] = []) -> [String] {
    var result: [String] = []
    var i = 0
    while i < args.count {
        if boolFlags.contains(args[i]) {
            i += 1
        } else if valueFlags.contains(args[i]) {
            i += 2
        } else {
            result.append(args[i])
            i += 1
        }
    }
    return result
}

// MARK: - EventKit access

func getAuthorizedStore() -> EKEventStore {
    let store = EKEventStore()
    let semaphore = DispatchSemaphore(value: 0)
    var accessGranted = false
    var accessError: Error?

    store.requestFullAccessToReminders { granted, error in
        accessGranted = granted
        accessError = error
        semaphore.signal()
    }

    semaphore.wait()

    guard accessGranted else {
        stderrPrint("Error: Reminders access not granted. Check System Settings > Privacy > Reminders.")
        if let error = accessError {
            stderrPrint("Detail: \(error.localizedDescription)")
        }
        exit(2)
    }

    return store
}

// MARK: - Operation result (for batch mode)

struct OperationResult {
    let success: Bool
    let message: String
}

// MARK: - Reminder lookup result (for batch mode)

enum ReminderLookupResult {
    case found(EKReminder)
    case notFound([String])      // incomplete titles for error message
    case ambiguous([EKReminder]) // multiple matches
}

// MARK: - List / reminder lookup

func findList(store: EKEventStore, name: String) -> EKCalendar {
    let calendars = store.calendars(for: .reminder)
    guard let calendar = calendars.first(where: { $0.title == name }) else {
        let available = calendars.map { $0.title }.joined(separator: ", ")
        stderrPrint("Error: List '\(name)' not found. Available: \(available)")
        exit(3)
    }
    return calendar
}

func fetchReminders(store: EKEventStore, in calendars: [EKCalendar]) -> [EKReminder] {
    let predicate = store.predicateForReminders(in: calendars)
    let semaphore = DispatchSemaphore(value: 0)
    var result: [EKReminder]?

    store.fetchReminders(matching: predicate) { reminders in
        result = reminders
        semaphore.signal()
    }

    semaphore.wait()

    guard let reminders = result else {
        stderrPrint("Error: Failed to fetch reminders.")
        exit(4)
    }

    return reminders
}

/// Non-exiting reminder lookup: exact match first, then case-insensitive contains with ambiguity detection.
func lookupReminder(in reminders: [EKReminder], title: String, includeCompleted: Bool = false) -> ReminderLookupResult {
    let candidates = includeCompleted ? reminders : reminders.filter { !$0.isCompleted }
    // Exact match
    if let exact = candidates.first(where: { $0.title == title }) {
        return .found(exact)
    }
    // Fallback: case-insensitive contains — collect ALL matches
    let partials = candidates.filter {
        $0.title?.localizedCaseInsensitiveContains(title) == true
    }
    if partials.count == 1 {
        return .found(partials[0])
    }
    if partials.count > 1 {
        return .ambiguous(partials)
    }
    // Not found
    let names = candidates.compactMap { $0.title }
    return .notFound(names)
}

/// Find a reminder by title: exact match first, then case-insensitive contains.
/// Exits on failure (not found or ambiguous).
func findReminder(in reminders: [EKReminder], title: String, includeCompleted: Bool = false) -> EKReminder {
    switch lookupReminder(in: reminders, title: title, includeCompleted: includeCompleted) {
    case .found(let reminder):
        return reminder
    case .ambiguous(let matches):
        stderrPrint("Error: Ambiguous match for '\(title)'. Multiple reminders match:")
        for m in matches {
            let id = m.calendarItemExternalIdentifier ?? "?"
            stderrPrint("  - \"\(m.title ?? "(untitled)")\" (id: \(id))")
        }
        stderrPrint("Use --id <id> to target a specific reminder.")
        exit(5)
    case .notFound(let incomplete):
        stderrPrint("Error: No incomplete reminder matching '\(title)'.")
        if incomplete.isEmpty {
            stderrPrint("No incomplete reminders in this list.")
        } else {
            stderrPrint("Incomplete reminders: \(incomplete.joined(separator: ", "))")
        }
        exit(5)
    }
}

/// Find a reminder by calendarItemExternalIdentifier. Exits on failure.
func findReminderByID(in reminders: [EKReminder], id: String, includeCompleted: Bool = false) -> EKReminder {
    guard let reminder = findReminderByIDOptional(in: reminders, id: id, includeCompleted: includeCompleted) else {
        stderrPrint("Error: No reminder with id '\(id)'.")
        exit(5)
    }
    return reminder
}

/// Find a reminder by calendarItemExternalIdentifier. Returns nil if not found.
func findReminderByIDOptional(in reminders: [EKReminder], id: String, includeCompleted: Bool = false) -> EKReminder? {
    return reminders.first(where: {
        $0.calendarItemExternalIdentifier == id && (includeCompleted || !$0.isCompleted)
    })
}

/// Convenience: route to findReminderByID or findReminder based on which is provided.
/// When both id and title are provided, resolves by ID but warns if title doesn't match.
func resolveReminder(in reminders: [EKReminder], id: String?, title: String?, includeCompleted: Bool = false) -> EKReminder {
    if let id = id {
        let reminder = findReminderByID(in: reminders, id: id, includeCompleted: includeCompleted)
        if let title = title, let resolvedTitle = reminder.title {
            let titleMatches = resolvedTitle == title ||
                resolvedTitle.localizedCaseInsensitiveContains(title) ||
                title.localizedCaseInsensitiveContains(resolvedTitle)
            if !titleMatches {
                stderrPrint("Warning: --id resolved to \"\(resolvedTitle)\" but title argument was \"\(title)\". Proceeding with ID match.")
            }
        }
        return reminder
    }
    guard let title = title else {
        stderrPrint("Error: Either --id or a title must be provided.")
        exit(1)
    }
    return findReminder(in: reminders, title: title, includeCompleted: includeCompleted)
}

// MARK: - Date helpers

/// Parse YYYY-MM-DD + optional HH:MM into DateComponents (component-based, no DateFormatter)
func parseDateComponents(_ dateStr: String, time: String? = nil) -> DateComponents? {
    // ISO-8601 datetime unify (v1.8.0): accept full timestamps like
    // "2026-06-27T13:00:00Z" (or with a numeric offset) so callers can pass the
    // same ISO strings eventkit itself emits — Reminders dueDates are stored UTC,
    // and strategic_due_detail / gather feed ISO. The 'T' marks the datetime form.
    // The Z/offset is resolved to a Date, then read back as LOCAL wall-clock
    // components, so "13:00:00Z" lands as 09:00 EDT — identical round-trip to the
    // YYYY-MM-DD path below. An explicit ISO time is self-contained, so a separate
    // `time:` argument is ignored when an ISO datetime is supplied.
    if dateStr.contains("T") {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        var resolved = isoFormatter.date(from: dateStr)
        if resolved == nil {
            // Retry allowing fractional seconds (e.g. "...13:00:00.000Z").
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            resolved = isoFormatter.date(from: dateStr)
        }
        guard let date = resolved else { return nil }
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        components.timeZone = TimeZone.current
        return components
    }

    let parts = dateStr.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }

    let timeParts: [Int]
    if let time = time {
        timeParts = time.split(separator: ":").compactMap { Int($0) }
        guard timeParts.count == 2 else { return nil }
    } else {
        timeParts = [9, 0]
    }

    var raw = DateComponents()
    raw.year = parts[0]
    raw.month = parts[1]
    raw.day = parts[2]
    raw.hour = timeParts[0]
    raw.minute = timeParts[1]
    raw.second = 0

    // Roundtrip through Calendar to produce properly-contextualized components
    // that Apple Reminders can interpret correctly
    let calendar = Calendar.current
    guard let date = calendar.date(from: raw) else { return nil }
    var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    components.timeZone = TimeZone.current
    return components
}

/// Format DateComponents for human-readable output (e.g., "Feb 17, 2026 at 9:00 AM")
func formatHumanDate(_ components: DateComponents?) -> String? {
    guard let components = components,
          let date = Calendar.current.date(from: components) else {
        return nil
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US")
    if components.hour != nil {
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
    } else {
        formatter.dateFormat = "MMM d, yyyy"
    }
    return formatter.string(from: date)
}

// MARK: - Body tag parsing (M1 precondition gates)

/// Parse `[hw-arrives: YYYY-MM-DD]` tag from reminder notes.
/// Returns the arrival date (start of day, local TZ) if tag is present and valid; nil otherwise.
func parseHwArrivesDate(notes: String?) -> Date? {
    guard let notes = notes else { return nil }
    // Match [hw-arrives: YYYY-MM-DD] with optional whitespace
    guard let range = notes.range(
        of: #"\[hw-arrives:\s*(\d{4})-(\d{2})-(\d{2})\s*\]"#,
        options: .regularExpression
    ) else { return nil }
    let matched = String(notes[range])
    let parts = matched
        .replacingOccurrences(of: "[hw-arrives:", with: "")
        .replacingOccurrences(of: "]", with: "")
        .trimmingCharacters(in: .whitespaces)
        .split(separator: "-")
        .compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    var comps = DateComponents()
    comps.year = parts[0]
    comps.month = parts[1]
    comps.day = parts[2]
    comps.timeZone = TimeZone.current
    return Calendar.current.date(from: comps)
}

/// M1 precondition gate: refuse completion when [hw-arrives:] tag value is in the future.
/// Returns nil if gate passes (no tag, tag <= today, or force=true).
/// Returns an OperationResult with failure message if gate blocks.
func checkHwArrivesGate(target: EKReminder, force: Bool) -> OperationResult? {
    if force { return nil }
    guard let arrivesDate = parseHwArrivesDate(notes: target.notes) else { return nil }
    let today = Calendar.current.startOfDay(for: Date())
    if arrivesDate <= today { return nil }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.dateFormat = "MMM d, yyyy"
    let arrivesStr = formatter.string(from: arrivesDate)
    let todayStr = formatter.string(from: today)
    let title = target.title ?? "(untitled)"
    return OperationResult(
        success: false,
        message: "Refused: '\(title)' has [hw-arrives: \(arrivesStr)] which is after today (\(todayStr)). "
            + "Hardware/dependency not yet available — completing now would be a silent-failure. "
            + "Pass --force (CLI) or \"force\": true (batch) to override if you're sure."
    )
}

// MARK: - Chain-on-Complete tag gate (CREATE-time precondition)
//
// Refuses creation of trigger-verb-titled Personal reminders that don't declare
// a successor ([chain-on-complete: {...}]) or an explicit terminal marker
// ([chain-terminal: <reason>]). Pairs with a downstream detector that scans
// completed reminders for the same pattern; the regexes here mirror that
// detector so CREATE-side and DETECT-side semantics stay consistent.

/// True when title contains a trigger verb (anywhere, word-boundary, case-insensitive),
/// excluding the "Check in" / "Check-in" prefix negation (recurring social check-ins).
func matchesChainTriggerVerb(title: String) -> Bool {
    // Negation: gather-script NEG_RE r"^\s*check[- ]in\b" with re.I
    if title.range(
        of: #"^\s*check[- ]in\b"#,
        options: [.regularExpression, .caseInsensitive]
    ) != nil {
        return false
    }
    // Trigger pattern: gather-script TRIGGER_RE r"\b(check|decide|review|verify|investigate|RSVP|confirm)\b" with re.I
    return title.range(
        of: #"\b(check|decide|review|verify|investigate|RSVP|confirm)\b"#,
        options: [.regularExpression, .caseInsensitive]
    ) != nil
}

/// True when reminder body contains either [chain-on-complete:] or [chain-terminal:] tag.
/// Mirrors gather-script TAG_RE (case-sensitive on chain-on-complete) and TERMINAL_RE (case-insensitive).
func bodyHasChainTag(notes: String?) -> Bool {
    guard let notes = notes, !notes.isEmpty else { return false }
    if notes.range(of: #"\[chain-on-complete:"#, options: .regularExpression) != nil {
        return true
    }
    if notes.range(of: #"\[chain-terminal\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
        return true
    }
    return false
}

/// Precondition gate: refuse `eventkit add` to the Personal list when title matches
/// the chain-trigger-verb pattern but body has neither [chain-on-complete:] nor
/// [chain-terminal:] tag.
/// Scope: list named "Personal" only. Negation: "Check in" / "Check-in" prefix titles skip.
/// Returns nil if gate passes (non-Personal list, no trigger verb, has chain tag, or force=true).
/// Returns an OperationResult with failure message if gate blocks.
func checkChainTagGate(listName: String, title: String, notes: String?, force: Bool) -> OperationResult? {
    if force { return nil }
    if listName != "Personal" { return nil }
    if !matchesChainTriggerVerb(title: title) { return nil }
    if bodyHasChainTag(notes: notes) { return nil }
    return OperationResult(
        success: false,
        message: "Refused: '\(title)' has trigger-verb title (check|decide|review|verify|investigate|RSVP|confirm) but body has no [chain-on-complete:] or [chain-terminal:] tag. "
            + "Without a chain tag, this becomes a chain gap at completion. "
            + "Add [chain-on-complete: {\"title\":\"...\",\"due\":\"YYYY-MM-DD\"}] for a successor, "
            + "[chain-terminal: <reason>] if genuinely terminal, "
            + "or pass --force (CLI) / \"force\": true (batch) to bypass."
    )
}

// MARK: - Field verification

struct FieldVerification {
    var expectedDate: DateComponents?
    var expectedTitle: String?
    var expectedNotes: String?
}

/// Re-fetch a reminder by calendarItemExternalIdentifier and compare actual field values against expected.
/// Returns (passed, mismatches) where mismatches lists human-readable descriptions of each mismatch.
func verifyFields(
    store: EKEventStore, calendar: EKCalendar,
    reminderID: String, expected: FieldVerification
) -> (passed: Bool, mismatches: [String]) {
    let reminders = fetchReminders(store: store, in: [calendar])
    guard let fresh = reminders.first(where: { $0.calendarItemExternalIdentifier == reminderID }) else {
        return (false, ["reminder not found after save"])
    }

    var mismatches: [String] = []

    if let expectedTitle = expected.expectedTitle {
        if fresh.title != expectedTitle {
            mismatches.append("title: expected '\(expectedTitle)', got '\(fresh.title ?? "(nil)")'")
        }
    }

    if let expectedNotes = expected.expectedNotes {
        if fresh.notes != expectedNotes {
            let got = fresh.notes ?? "(nil)"
            mismatches.append("notes: expected '\(expectedNotes.prefix(60))...', got '\(got.prefix(60))...'")
        }
    }

    if let expectedDate = expected.expectedDate {
        let actual = fresh.dueDateComponents
        if let expTZ = expectedDate.timeZone {
            let actTZ = actual?.timeZone
            if actTZ == nil || actTZ != expTZ {
                mismatches.append("date.timeZone: expected \(expTZ.identifier), got \(actTZ?.identifier ?? "nil")")
            }
        }
        let fields: [(String, (DateComponents) -> Int?)] = [
            ("year", { $0.year }), ("month", { $0.month }), ("day", { $0.day }),
            ("hour", { $0.hour }), ("minute", { $0.minute }),
        ]
        for (name, getter) in fields {
            let exp = getter(expectedDate)
            let act = actual.flatMap(getter)
            if exp != act {
                mismatches.append("date.\(name): expected \(exp.map(String.init) ?? "nil"), got \(act.map(String.init) ?? "nil")")
            }
        }
    }

    return (mismatches.isEmpty, mismatches)
}

/// Delete a reminder and recreate it with the given fields. Returns the new reminder's ID or nil on failure.
func recreateReminder(
    store: EKEventStore, calendar: EKCalendar, target: EKReminder,
    title: String, notes: String?, dueDateComponents: DateComponents?,
    recurrenceRules: [EKRecurrenceRule]?, priority: Int
) -> (success: Bool, newID: String?, message: String) {
    // Capture all fields before deletion
    let capturedTitle = title
    let capturedNotes = notes
    let capturedDue = dueDateComponents
    let capturedRules = recurrenceRules
    let capturedPriority = priority

    // Delete the corrupted reminder
    do {
        try store.remove(target, commit: true)
    } catch {
        return (false, nil, "Failed to delete corrupted reminder: \(error.localizedDescription)")
    }

    // Create a new reminder with all captured fields
    let newReminder = EKReminder(eventStore: store)
    newReminder.title = capturedTitle
    newReminder.calendar = calendar
    newReminder.notes = capturedNotes
    newReminder.priority = capturedPriority
    if var due = capturedDue {
        if due.timeZone == nil { due.timeZone = TimeZone.current }
        newReminder.dueDateComponents = due
        // Set alarm to match due date — Reminders.app uses alarm absoluteDate
        // for display/sorting, not just dueDateComponents
        if let dueDate = Calendar.current.date(from: due) {
            newReminder.addAlarm(EKAlarm(absoluteDate: dueDate))
        }
    }
    if let rules = capturedRules {
        for rule in rules {
            newReminder.addRecurrenceRule(rule)
        }
    }

    do {
        try store.save(newReminder, commit: true)
    } catch {
        return (false, nil, "Deleted corrupted reminder but failed to recreate: \(error.localizedDescription)")
    }

    let newID = newReminder.calendarItemExternalIdentifier ?? ""

    // Verify the recreated reminder
    var expectedFields = FieldVerification()
    expectedFields.expectedTitle = capturedTitle
    if let due = capturedDue {
        expectedFields.expectedDate = due
    }
    // Don't verify notes — they may be long and exact match is fragile

    let (passed, mismatches) = verifyFields(store: store, calendar: calendar, reminderID: newID, expected: expectedFields)
    if !passed {
        return (false, newID, "Recreated but verification failed: \(mismatches.joined(separator: "; "))")
    }

    return (true, newID, "recreated successfully")
}

// MARK: - Mutation verification (legacy — title-only checks)

/// Re-fetch reminders and verify a reminder with the given title exists (incomplete)
func verifyReminderExists(store: EKEventStore, calendar: EKCalendar, title: String) -> Bool {
    let reminders = fetchReminders(store: store, in: [calendar])
    return reminders.contains { $0.title == title && !$0.isCompleted }
}

/// Re-fetch and verify a reminder is completed
func verifyReminderCompleted(store: EKEventStore, calendar: EKCalendar, title: String) -> Bool {
    let reminders = fetchReminders(store: store, in: [calendar])
    return reminders.contains { $0.title == title && $0.isCompleted }
}

/// Re-fetch and verify a reminder is gone by ID (checks all states, not just incomplete)
func verifyReminderGone(store: EKEventStore, calendar: EKCalendar, reminderID: String) -> Bool {
    let reminders = fetchReminders(store: store, in: [calendar])
    return !reminders.contains { $0.calendarItemExternalIdentifier == reminderID }
}

// MARK: - Pre-flight argument-shape error helpers (v1.7.0, S275)
//
// The ×6-recurrence failure mode caught by the TECHNICAL_GOTCHAS entry: callers
// invoke write subcommands with --id but no positional <list>, then re-emit the
// same error pattern on retry because the generic "Usage: ..." line doesn't
// teach the empty-title-with-id form. These helpers detect the specific shape
// and emit an instructive error referencing the user's own --id value.

/// Emit a specific error when --id is provided but the required positional
/// <list> argument is missing. Returns true if an error was emitted (caller
/// should exit(1)). Subcommands with --id support: complete, edit, delete,
/// move (note: Move has a different positional shape — uses its own message).
func reportMissingListWithIdError(subcommand: String, idFlag: String?) -> Bool {
    guard let id = idFlag else { return false }
    stderrPrint("""

    ERROR: 'eventkit \(subcommand)' requires <list> as the first positional argument.
    You provided --id \(id) but no <list>.

    Correct forms when targeting by ID:
      eventkit \(subcommand) Strategic ""              --id \(id)    (empty title is OK with --id)
      eventkit \(subcommand) <list> "Item title"                     (title alone)
      eventkit \(subcommand) <list> "Item title" --id \(id)          (--id disambiguates)

    Run 'eventkit \(subcommand) --help' for full options.
    """)
    return true
}

/// Emit a specific error when <list> is present but <title> is missing and no
/// --id was provided. Returns true if an error was emitted.
func reportMissingTitleError(subcommand: String, listName: String, supportsId: Bool) -> Bool {
    if supportsId {
        stderrPrint("""

        ERROR: 'eventkit \(subcommand)' requires <title> as the second positional argument (or --id <ID>).
        You provided <list>='\(listName)' but no <title> and no --id.

        Examples:
          eventkit \(subcommand) \(listName) "Item title"
          eventkit \(subcommand) \(listName) "" --id ABC123    (empty title is OK with --id)

        Run 'eventkit \(subcommand) --help' for full options.
        """)
    } else {
        stderrPrint("""

        ERROR: 'eventkit \(subcommand)' requires <title> as the second positional argument.
        You provided <list>='\(listName)' but no <title>.

        Example:
          eventkit \(subcommand) \(listName) "Item title"

        Run 'eventkit \(subcommand) --help' for full options.
        """)
    }
    return true
}
