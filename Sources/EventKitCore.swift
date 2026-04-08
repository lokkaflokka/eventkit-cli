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
func lookupReminder(in reminders: [EKReminder], title: String) -> ReminderLookupResult {
    // Exact match, incomplete only
    if let exact = reminders.first(where: { $0.title == title && !$0.isCompleted }) {
        return .found(exact)
    }
    // Fallback: case-insensitive contains, incomplete only — collect ALL matches
    let partials = reminders.filter {
        !$0.isCompleted && ($0.title?.localizedCaseInsensitiveContains(title) == true)
    }
    if partials.count == 1 {
        return .found(partials[0])
    }
    if partials.count > 1 {
        return .ambiguous(partials)
    }
    // Not found
    let incomplete = reminders.filter { !$0.isCompleted }.compactMap { $0.title }
    return .notFound(incomplete)
}

/// Find a reminder by title: exact match first, then case-insensitive contains. Incomplete only.
/// Exits on failure (not found or ambiguous).
func findReminder(in reminders: [EKReminder], title: String) -> EKReminder {
    switch lookupReminder(in: reminders, title: title) {
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
func findReminderByID(in reminders: [EKReminder], id: String) -> EKReminder {
    guard let reminder = findReminderByIDOptional(in: reminders, id: id) else {
        stderrPrint("Error: No reminder with id '\(id)'.")
        exit(5)
    }
    return reminder
}

/// Find a reminder by calendarItemExternalIdentifier. Returns nil if not found.
func findReminderByIDOptional(in reminders: [EKReminder], id: String) -> EKReminder? {
    return reminders.first(where: { $0.calendarItemExternalIdentifier == id && !$0.isCompleted })
}

/// Convenience: route to findReminderByID or findReminder based on which is provided.
/// When both id and title are provided, resolves by ID but warns if title doesn't match.
func resolveReminder(in reminders: [EKReminder], id: String?, title: String?) -> EKReminder {
    if let id = id {
        let reminder = findReminderByID(in: reminders, id: id)
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
    return findReminder(in: reminders, title: title)
}

// MARK: - Date helpers

/// Parse YYYY-MM-DD + optional HH:MM into DateComponents (component-based, no DateFormatter)
func parseDateComponents(_ dateStr: String, time: String? = nil) -> DateComponents? {
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
