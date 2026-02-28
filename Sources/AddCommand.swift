import EventKit
import Foundation

func runAdd(args: [String]) {
    if hasFlag("--help", in: args) || hasFlag("-h", in: args) {
        print("""
        Usage: eventkit add <list> <title> [options]

        Options:
          --due YYYY-MM-DD       Due date
          --time HH:MM           Due time (default 09:00)
          --body TEXT             Note body (alias: --notes)
          --notes TEXT            Alias for --body
          --body-file PATH       Read body from file
          --recurrence FREQ      Recurrence: daily, weekly, monthly, yearly
          --interval N           Recurrence interval (default 1)
          --force                Create even if duplicate exists
          --dry-run              Preview without saving
          --help, -h             Show this help
        """)
        exit(0)
    }

    let positional = positionalArgs(
        from: args,
        valueFlags: ["--due", "--time", "--body", "--notes", "--body-file", "--recurrence", "--interval"],
        boolFlags: ["--dry-run", "--force"]
    )

    guard positional.count >= 2 else {
        stderrPrint("Usage: eventkit add <list> <title> [--due YYYY-MM-DD] [--time HH:MM] [--body TEXT | --notes TEXT | --body-file PATH] [--recurrence FREQ] [--interval N] [--force] [--dry-run]")
        exit(1)
    }

    let listName = positional[0]
    let title = positional[1]
    let dueStr = extractFlag("--due", from: args)
    let timeStr = extractFlag("--time", from: args)
    let bodyFile = extractFlag("--body-file", from: args)
    let body: String?
    if let bodyFile = bodyFile {
        guard let contents = try? String(contentsOfFile: bodyFile, encoding: .utf8) else {
            stderrPrint("Error: Cannot read body file '\(bodyFile)'.")
            exit(1)
        }
        body = contents.trimmingCharacters(in: .newlines)
    } else {
        body = extractFlag(anyOf: ["--body", "--notes"], from: args)
    }
    let recurrenceStr = extractFlag("--recurrence", from: args)
    let intervalStr = extractFlag("--interval", from: args)
    let dryRun = hasFlag("--dry-run", in: args)
    let force = hasFlag("--force", in: args)

    let store = getAuthorizedStore()
    let calendar = findList(store: store, name: listName)
    let reminders = fetchReminders(store: store, in: [calendar])

    let result = executeAdd(
        store: store, calendar: calendar, reminders: reminders,
        title: title, dueStr: dueStr, timeStr: timeStr, body: body,
        recurrenceStr: recurrenceStr, intervalStr: intervalStr,
        force: force, dryRun: dryRun, skipVerify: false
    )

    if result.success {
        print(result.message)
    } else {
        stderrPrint(result.message)
        exit(7)
    }
}

func executeAdd(
    store: EKEventStore, calendar: EKCalendar, reminders: [EKReminder],
    title: String, dueStr: String?, timeStr: String?, body: String?,
    recurrenceStr: String?, intervalStr: String?,
    force: Bool, dryRun: Bool, skipVerify: Bool
) -> OperationResult {
    let listName = calendar.title

    // Dedup check
    if !force {
        if reminders.contains(where: { $0.title == title && !$0.isCompleted }) {
            return OperationResult(success: true, message: "SKIP (exists): '\(title)' already exists incomplete in '\(listName)'. Use --force to override.")
        }
    }

    // Parse due date components
    var dueDateComponents: DateComponents?
    if let dueStr = dueStr {
        guard let components = parseDateComponents(dueStr, time: timeStr) else {
            return OperationResult(success: false, message: "Error: Invalid date '\(dueStr)' or time '\(timeStr ?? "")'.")
        }
        dueDateComponents = components
    }

    // Parse recurrence
    let frequencyMap: [String: EKRecurrenceFrequency] = [
        "daily": .daily, "weekly": .weekly, "monthly": .monthly, "yearly": .yearly,
    ]
    var recurrenceRule: EKRecurrenceRule?
    if let recurrenceStr = recurrenceStr {
        guard let freq = frequencyMap[recurrenceStr.lowercased()] else {
            return OperationResult(success: false, message: "Error: Invalid frequency '\(recurrenceStr)'. Must be: daily, weekly, monthly, yearly.")
        }
        let interval = Int(intervalStr ?? "1") ?? 1
        guard interval > 0 else {
            return OperationResult(success: false, message: "Error: Interval must be a positive integer.")
        }
        recurrenceRule = EKRecurrenceRule(recurrenceWith: freq, interval: interval, end: nil)
    }

    if dryRun {
        var desc = "DRY RUN \u{2014} would create '\(title)' in '\(listName)'"
        if let dueStr = dueStr {
            desc += " due \(dueStr)"
            if let timeStr = timeStr { desc += " at \(timeStr)" }
        }
        if let body = body { desc += " body: \(body.prefix(80))..." }
        if let recurrenceStr = recurrenceStr {
            desc += " [recur: \(recurrenceStr) x\(intervalStr ?? "1")]"
        }
        desc += "\nNo changes saved."
        return OperationResult(success: true, message: desc)
    }

    // Create reminder
    let reminder = EKReminder(eventStore: store)
    reminder.title = title
    reminder.calendar = calendar
    reminder.notes = body

    if let dueDateComponents = dueDateComponents {
        reminder.dueDateComponents = dueDateComponents
    }

    if let rule = recurrenceRule {
        reminder.addRecurrenceRule(rule)
    }

    do {
        try store.save(reminder, commit: true)
    } catch {
        return OperationResult(success: false, message: "Error: Failed to save reminder: \(error.localizedDescription)")
    }

    // Verify
    if !skipVerify {
        if verifyReminderExists(store: store, calendar: calendar, title: title) {
            var desc = "Created '\(title)' in '\(listName)'"
            if let dueStr = dueStr { desc += " due \(dueStr)" }
            if recurrenceRule != nil { desc += " [recurrence set]" }
            desc += "\nVerified: reminder persisted."
            return OperationResult(success: true, message: desc)
        } else {
            return OperationResult(success: false, message: "Warning: Reminder was saved but verification failed \u{2014} could not find '\(title)' in '\(listName)'.")
        }
    }

    var desc = "Created '\(title)' in '\(listName)'"
    if let dueStr = dueStr { desc += " due \(dueStr)" }
    if recurrenceRule != nil { desc += " [recurrence set]" }
    return OperationResult(success: true, message: desc)
}
