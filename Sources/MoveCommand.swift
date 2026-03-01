import EventKit
import Foundation

func runMove(args: [String]) {
    if hasFlag("--help", in: args) || hasFlag("-h", in: args) {
        print("""
        Usage: eventkit move <source-list> <target-list> <title> [options]

        Moves a reminder between lists, preserving all properties (recurrence, priority, alarms).

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

    // Same-list guard
    if sourceCalendar.calendarIdentifier == targetCalendar.calendarIdentifier {
        return OperationResult(success: false, message: "Error: '\(sourceTitle)' is already in '\(targetListName)'.")
    }

    let hasRecurrence = source.recurrenceRules != nil && !source.recurrenceRules!.isEmpty

    if dryRun {
        var desc = "DRY RUN \u{2014} would move '\(sourceTitle)' from '\(sourceListName)' to '\(targetListName)'"
        if let dueStr = dueStr {
            desc += " due \(dueStr)"
            if let timeStr = timeStr { desc += " at \(timeStr)" }
        } else if let timeStr = timeStr {
            desc += " time \(timeStr)"
        }
        if body != nil { desc += " (body overridden)" }
        if hasRecurrence { desc += " [recurrence preserved]" }
        desc += "\nNo changes saved."
        return OperationResult(success: true, message: desc)
    }

    // Reassign calendar (true move — preserves recurrence, priority, alarms, start date)
    source.calendar = targetCalendar

    // Apply overrides only when flags provided
    if let dueStr = dueStr {
        let effectiveTime: String?
        if let timeStr = timeStr {
            effectiveTime = timeStr
        } else if let existing = source.dueDateComponents, let h = existing.hour, let m = existing.minute {
            effectiveTime = String(format: "%02d:%02d", h, m)
        } else {
            effectiveTime = nil
        }
        guard let components = parseDateComponents(dueStr, time: effectiveTime) else {
            return OperationResult(success: false, message: "Error: Invalid date '\(dueStr)'.")
        }
        source.dueDateComponents = components
    } else if let timeStr = timeStr {
        if var existing = source.dueDateComponents {
            let timeParts = timeStr.split(separator: ":").compactMap { Int($0) }
            guard timeParts.count == 2 else {
                return OperationResult(success: false, message: "Error: Invalid time '\(timeStr)'. Use HH:MM.")
            }
            existing.hour = timeParts[0]
            existing.minute = timeParts[1]
            source.dueDateComponents = existing
        } else {
            return OperationResult(success: false, message: "Error: Cannot set time without a due date. Use --due as well.")
        }
    }

    if let body = body {
        source.notes = body
    }

    do {
        try store.save(source, commit: true)
    } catch {
        return OperationResult(success: false, message: "Error: Failed to move reminder to '\(targetListName)': \(error.localizedDescription)")
    }

    // Verify: exists in target, gone from source
    if !skipVerify {
        let inTarget = verifyReminderExists(store: store, calendar: targetCalendar, title: sourceTitle)
        let goneFromSource = verifyReminderGone(store: store, calendar: sourceCalendar, title: sourceTitle)
        if inTarget && goneFromSource {
            var msg = "Moved '\(sourceTitle)' from '\(sourceListName)' to '\(targetListName)'."
            if hasRecurrence { msg += " [recurrence preserved]" }
            msg += "\nVerified: in target, gone from source."
            return OperationResult(success: true, message: msg)
        } else if inTarget {
            return OperationResult(success: true, message: "Moved '\(sourceTitle)' to '\(targetListName)'. (source verification inconclusive)")
        } else {
            return OperationResult(success: false, message: "Warning: Save succeeded but verification failed \u{2014} reminder may not have moved.")
        }
    }

    var msg = "Moved '\(sourceTitle)' from '\(sourceListName)' to '\(targetListName)'."
    if hasRecurrence { msg += " [recurrence preserved]" }
    return OperationResult(success: true, message: msg)
}
