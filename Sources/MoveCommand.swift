import EventKit
import Foundation

func runMove(args: [String]) {
    let positional = positionalArgs(
        from: args,
        valueFlags: ["--due", "--time", "--body", "--body-file"],
        boolFlags: ["--dry-run"]
    )

    guard positional.count >= 3 else {
        stderrPrint("Usage: eventkit move <source-list> <target-list> <title> [--due YYYY-MM-DD] [--time HH:MM] [--body TEXT | --body-file PATH] [--dry-run]")
        exit(1)
    }

    let sourceListName = positional[0]
    let targetListName = positional[1]
    let title = positional[2]
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
    let dryRun = hasFlag("--dry-run", in: args)

    let store = getAuthorizedStore()
    let sourceCalendar = findList(store: store, name: sourceListName)
    let targetCalendar = findList(store: store, name: targetListName)

    // Find reminder in source (incomplete only)
    let sourceReminders = fetchReminders(store: store, in: [sourceCalendar])
    let source = findReminder(in: sourceReminders, title: title)
    let sourceTitle = source.title ?? title

    // Resolve body: flag override > copy from source
    let resolvedBody = body ?? source.notes

    // Resolve due date: flag override > inherit source > nil
    var resolvedDueComponents: DateComponents?
    if let dueStr = dueStr {
        guard let components = parseDateComponents(dueStr, time: timeStr) else {
            stderrPrint("Error: Invalid date '\(dueStr)' or time '\(timeStr ?? "")'.")
            exit(1)
        }
        resolvedDueComponents = components
    } else {
        resolvedDueComponents = source.dueDateComponents
    }

    // Dedup check in target (hard fail)
    let targetReminders = fetchReminders(store: store, in: [targetCalendar])
    if targetReminders.contains(where: { $0.title == sourceTitle && !$0.isCompleted }) {
        stderrPrint("Error: '\(sourceTitle)' already exists incomplete in '\(targetListName)'. Remove it first.")
        exit(5)
    }

    if dryRun {
        var desc = "DRY RUN \u{2014} would move '\(sourceTitle)' from '\(sourceListName)' to '\(targetListName)'"
        if let dueStr = dueStr {
            desc += " due \(dueStr)"
            if let timeStr = timeStr { desc += " at \(timeStr)" }
        } else if let dueComps = resolvedDueComponents, let formatted = formatHumanDate(dueComps) {
            desc += " due \(formatted) (inherited)"
        }
        if body != nil { desc += " (body overridden)" }
        print(desc)
        print("No changes saved.")
        exit(0)
    }

    // Create in target
    let newReminder = EKReminder(eventStore: store)
    newReminder.title = sourceTitle
    newReminder.calendar = targetCalendar
    newReminder.notes = resolvedBody
    if let dueComps = resolvedDueComponents {
        newReminder.dueDateComponents = dueComps
    }

    do {
        try store.save(newReminder, commit: true)
    } catch {
        stderrPrint("Error: Failed to create reminder in '\(targetListName)': \(error.localizedDescription)")
        exit(7)
    }

    // Verify creation
    guard verifyReminderExists(store: store, calendar: targetCalendar, title: sourceTitle) else {
        stderrPrint("Error: Reminder was saved to '\(targetListName)' but verification failed.")
        exit(7)
    }

    // Complete in source
    source.isCompleted = true
    source.completionDate = Date()

    do {
        try store.save(source, commit: true)
    } catch {
        stderrPrint("Error: Created in '\(targetListName)' but failed to complete in '\(sourceListName)': \(error.localizedDescription)")
        stderrPrint("ACTION REQUIRED: Manually complete '\(sourceTitle)' in '\(sourceListName)'.")
        exit(7)
    }

    // Verify completion
    if verifyReminderCompleted(store: store, calendar: sourceCalendar, title: sourceTitle) {
        print("Moved '\(sourceTitle)' from '\(sourceListName)' to '\(targetListName)'.")
        print("Verified: created in target, completed in source.")
    } else {
        stderrPrint("Warning: Created in '\(targetListName)' but completion verification failed in '\(sourceListName)'.")
        stderrPrint("ACTION REQUIRED: Manually complete '\(sourceTitle)' in '\(sourceListName)'.")
        exit(7)
    }
}
