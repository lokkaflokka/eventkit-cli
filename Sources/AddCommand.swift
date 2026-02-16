import EventKit
import Foundation

func runAdd(args: [String]) {
    let positional = positionalArgs(
        from: args,
        valueFlags: ["--due", "--time", "--body", "--body-file", "--recurrence", "--interval"],
        boolFlags: ["--dry-run", "--force"]
    )

    guard positional.count >= 2 else {
        stderrPrint("Usage: eventkit add <list> <title> [--due YYYY-MM-DD] [--time HH:MM] [--body TEXT | --body-file PATH] [--recurrence FREQ] [--interval N] [--force] [--dry-run]")
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
        body = extractFlag("--body", from: args)
    }
    let recurrenceStr = extractFlag("--recurrence", from: args)
    let intervalStr = extractFlag("--interval", from: args)
    let dryRun = hasFlag("--dry-run", in: args)
    let force = hasFlag("--force", in: args)

    let store = getAuthorizedStore()
    let calendar = findList(store: store, name: listName)

    // Dedup check
    if !force {
        let existing = fetchReminders(store: store, in: [calendar])
        if existing.contains(where: { $0.title == title && !$0.isCompleted }) {
            print("SKIP (exists): '\(title)' already exists incomplete in '\(listName)'. Use --force to override.")
            exit(0)
        }
    }

    // Parse due date components
    var dueDateComponents: DateComponents?
    if let dueStr = dueStr {
        guard let components = parseDateComponents(dueStr, time: timeStr) else {
            stderrPrint("Error: Invalid date '\(dueStr)' or time '\(timeStr ?? "")'.")
            exit(1)
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
            stderrPrint("Error: Invalid frequency '\(recurrenceStr)'. Must be: daily, weekly, monthly, yearly.")
            exit(1)
        }
        let interval = Int(intervalStr ?? "1") ?? 1
        guard interval > 0 else {
            stderrPrint("Error: Interval must be a positive integer.")
            exit(1)
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
        print(desc)
        print("No changes saved.")
        exit(0)
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
        stderrPrint("Error: Failed to save reminder: \(error.localizedDescription)")
        exit(7)
    }

    // Verify
    if verifyReminderExists(store: store, calendar: calendar, title: title) {
        var desc = "Created '\(title)' in '\(listName)'"
        if let dueStr = dueStr { desc += " due \(dueStr)" }
        if recurrenceRule != nil { desc += " [recurrence set]" }
        print(desc)
        print("Verified: reminder persisted.")
    } else {
        stderrPrint("Warning: Reminder was saved but verification failed \u{2014} could not find '\(title)' in '\(listName)'.")
        exit(7)
    }
}
