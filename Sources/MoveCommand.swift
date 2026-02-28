import EventKit
import Foundation

func runMove(args: [String]) {
    if hasFlag("--help", in: args) || hasFlag("-h", in: args) {
        print("""
        Usage: eventkit move <source-list> <target-list> <title> [options]

        Atomically moves a reminder: creates in target list, completes in source.

        Options:
          --id ID              Move by reminder ID instead of title
          --due YYYY-MM-DD     Override due date (default: inherit from source)
          --time HH:MM         Override due time
          --body TEXT           Override note body (alias: --notes)
          --notes TEXT          Alias for --body
          --body-file PATH     Read body from file
          --dry-run            Preview without saving
          --help, -h           Show this help

        When --id is provided, <title> is optional.
        """)
        exit(0)
    }

    let positional = positionalArgs(
        from: args,
        valueFlags: ["--id", "--due", "--time", "--body", "--notes", "--body-file"],
        boolFlags: ["--dry-run"]
    )
    let idFlag = extractFlag("--id", from: args)

    guard positional.count >= 3 || (positional.count >= 2 && idFlag != nil) else {
        stderrPrint("Usage: eventkit move <source-list> <target-list> <title> [--id ID] [--due YYYY-MM-DD] [--time HH:MM] [--body TEXT | --notes TEXT | --body-file PATH] [--dry-run]")
        exit(1)
    }

    let sourceListName = positional[0]
    let targetListName = positional[1]
    let titleArg: String? = positional.count >= 3 ? positional[2] : nil
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
    let dryRun = hasFlag("--dry-run", in: args)

    let store = getAuthorizedStore()
    let sourceCalendar = findList(store: store, name: sourceListName)
    let targetCalendar = findList(store: store, name: targetListName)

    let sourceReminders = fetchReminders(store: store, in: [sourceCalendar])
    let source = resolveReminder(in: sourceReminders, id: idFlag, title: titleArg)

    let result = executeMove(
        store: store, sourceCalendar: sourceCalendar, targetCalendar: targetCalendar,
        source: source, dueStr: dueStr, timeStr: timeStr, body: body,
        dryRun: dryRun, skipVerify: false
    )

    if result.success {
        print(result.message)
    } else {
        stderrPrint(result.message)
        exit(7)
    }
}

func executeMove(
    store: EKEventStore, sourceCalendar: EKCalendar, targetCalendar: EKCalendar,
    source: EKReminder, dueStr: String?, timeStr: String?, body: String?,
    dryRun: Bool, skipVerify: Bool
) -> OperationResult {
    let sourceListName = sourceCalendar.title
    let targetListName = targetCalendar.title
    let sourceTitle = source.title ?? "(untitled)"

    // Resolve body: flag override > copy from source
    let resolvedBody = body ?? source.notes

    // Resolve due date: flag override > inherit source > nil
    var resolvedDueComponents: DateComponents?
    if let dueStr = dueStr {
        guard let components = parseDateComponents(dueStr, time: timeStr) else {
            return OperationResult(success: false, message: "Error: Invalid date '\(dueStr)' or time '\(timeStr ?? "")'.")
        }
        resolvedDueComponents = components
    } else {
        resolvedDueComponents = source.dueDateComponents
    }

    // Dedup check in target (hard fail)
    let targetReminders = fetchReminders(store: store, in: [targetCalendar])
    if targetReminders.contains(where: { $0.title == sourceTitle && !$0.isCompleted }) {
        return OperationResult(success: false, message: "Error: '\(sourceTitle)' already exists incomplete in '\(targetListName)'. Remove it first.")
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
        desc += "\nNo changes saved."
        return OperationResult(success: true, message: desc)
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
        return OperationResult(success: false, message: "Error: Failed to create reminder in '\(targetListName)': \(error.localizedDescription)")
    }

    // Verify creation
    if !skipVerify {
        guard verifyReminderExists(store: store, calendar: targetCalendar, title: sourceTitle) else {
            return OperationResult(success: false, message: "Error: Reminder was saved to '\(targetListName)' but verification failed.")
        }
    }

    // Complete in source
    source.isCompleted = true
    source.completionDate = Date()

    do {
        try store.save(source, commit: true)
    } catch {
        return OperationResult(success: false, message: "Error: Created in '\(targetListName)' but failed to complete in '\(sourceListName)': \(error.localizedDescription)\nACTION REQUIRED: Manually complete '\(sourceTitle)' in '\(sourceListName)'.")
    }

    // Verify completion
    if !skipVerify {
        if verifyReminderCompleted(store: store, calendar: sourceCalendar, title: sourceTitle) {
            return OperationResult(success: true, message: "Moved '\(sourceTitle)' from '\(sourceListName)' to '\(targetListName)'.\nVerified: created in target, completed in source.")
        } else {
            return OperationResult(success: false, message: "Warning: Created in '\(targetListName)' but completion verification failed in '\(sourceListName)'.\nACTION REQUIRED: Manually complete '\(sourceTitle)' in '\(sourceListName)'.")
        }
    }

    return OperationResult(success: true, message: "Moved '\(sourceTitle)' from '\(sourceListName)' to '\(targetListName)'.")
}
