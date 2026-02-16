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

/// Find a reminder by title: exact match first, then case-insensitive contains. Incomplete only.
func findReminder(in reminders: [EKReminder], title: String) -> EKReminder {
    // Exact match, incomplete only
    if let exact = reminders.first(where: { $0.title == title && !$0.isCompleted }) {
        return exact
    }
    // Fallback: case-insensitive contains, incomplete only
    if let partial = reminders.first(where: {
        !$0.isCompleted && ($0.title?.localizedCaseInsensitiveContains(title) == true)
    }) {
        return partial
    }
    // Not found
    let incomplete = reminders.filter { !$0.isCompleted }.compactMap { $0.title }
    stderrPrint("Error: No incomplete reminder matching '\(title)'.")
    if incomplete.isEmpty {
        stderrPrint("No incomplete reminders in this list.")
    } else {
        stderrPrint("Incomplete reminders: \(incomplete.joined(separator: ", "))")
    }
    exit(5)
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

    var components = DateComponents()
    components.year = parts[0]
    components.month = parts[1]
    components.day = parts[2]
    components.hour = timeParts[0]
    components.minute = timeParts[1]
    components.second = 0
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

// MARK: - Mutation verification

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

/// Re-fetch and verify a reminder is gone (checks all states, not just incomplete)
func verifyReminderGone(store: EKEventStore, calendar: EKCalendar, title: String) -> Bool {
    let reminders = fetchReminders(store: store, in: [calendar])
    return !reminders.contains { $0.title == title }
}
