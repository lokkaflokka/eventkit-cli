import EventKit
import Foundation

func runEdit(args: [String]) {
    if hasFlag("--help", in: args) || hasFlag("-h", in: args) {
        print("""
        Usage: eventkit edit <list> <title> [options]
               eventkit update <list> <title> [options]    (alias)

        Options:
          --id ID              Edit by reminder ID instead of title
          --title NEW          Change the title
          --due YYYY-MM-DD     Change the due date
          --time HH:MM         Change the due time
          --body TEXT           Change the note body (alias: --notes)
          --notes TEXT          Alias for --body
          --body-file PATH     Read body from file
          --dry-run            Preview without saving
          --help, -h           Show this help

        When --id is provided, <title> is optional.
        At least one edit flag (--title, --due, --time, --body) is required.
        """)
        exit(0)
    }

    let positional = positionalArgs(
        from: args,
        valueFlags: ["--id", "--title", "--due", "--time", "--body", "--notes", "--body-file"],
        boolFlags: ["--dry-run"]
    )
    let idFlag = extractFlag("--id", from: args)

    guard positional.count >= 2 || (positional.count >= 1 && idFlag != nil) else {
        stderrPrint("Usage: eventkit edit <list> <title> [--id ID] [--title NEW] [--due YYYY-MM-DD] [--time HH:MM] [--body TEXT | --notes TEXT | --body-file PATH] [--dry-run]")
        exit(1)
    }

    let listName = positional[0]
    let titleArg: String? = positional.count >= 2 ? positional[1] : nil
    let newTitle = extractFlag("--title", from: args)
    let dueStr = extractFlag("--due", from: args)
    let timeStr = extractFlag("--time", from: args)
    let bodyFile = extractFlag("--body-file", from: args)
    let newBody: String?
    if let bodyFile = bodyFile {
        guard let contents = try? String(contentsOfFile: bodyFile, encoding: .utf8) else {
            stderrPrint("Error: Cannot read body file '\(bodyFile)'.")
            exit(1)
        }
        newBody = contents.trimmingCharacters(in: .newlines)
    } else {
        newBody = extractFlag(anyOf: ["--body", "--notes"], from: args)
    }
    let dryRun = hasFlag("--dry-run", in: args)

    // Must have at least one edit
    if newTitle == nil && dueStr == nil && timeStr == nil && newBody == nil {
        stderrPrint("Error: No edits specified. Use --title, --due, --time, or --body/--notes.")
        exit(1)
    }

    let store = getAuthorizedStore()
    let calendar = findList(store: store, name: listName)
    let reminders = fetchReminders(store: store, in: [calendar])
    let target = resolveReminder(in: reminders, id: idFlag, title: titleArg)

    let result = executeEdit(
        store: store, calendar: calendar, target: target,
        newTitle: newTitle, dueStr: dueStr, timeStr: timeStr, newBody: newBody,
        dryRun: dryRun, skipVerify: false
    )

    if result.success {
        print(result.message)
    } else {
        stderrPrint(result.message)
        exit(7)
    }
}

func executeEdit(
    store: EKEventStore, calendar: EKCalendar, target: EKReminder,
    newTitle: String?, dueStr: String?, timeStr: String?, newBody: String?,
    dryRun: Bool, skipVerify: Bool
) -> OperationResult {
    let listName = calendar.title
    let title = target.title ?? "(untitled)"

    // Must have at least one edit
    if newTitle == nil && dueStr == nil && timeStr == nil && newBody == nil {
        return OperationResult(success: false, message: "Error: No edits specified.")
    }

    var changes: [String] = []

    if let newTitle = newTitle {
        changes.append("title: '\(target.title ?? "")' \u{2192} '\(newTitle)'")
    }
    if let dueStr = dueStr {
        changes.append("due: \(dueStr)\(timeStr != nil ? " at \(timeStr!)" : "")")
    } else if let timeStr = timeStr {
        changes.append("time: \(timeStr)")
    }
    if let newBody = newBody {
        changes.append("body: \(newBody.prefix(80))...")
    }

    if dryRun {
        var msg = "DRY RUN \u{2014} would edit '\(title)' in '\(listName)':"
        for change in changes { msg += "\n  \(change)" }
        msg += "\nNo changes saved."
        return OperationResult(success: true, message: msg)
    }

    // Apply edits
    if let newTitle = newTitle {
        target.title = newTitle
    }

    if let dueStr = dueStr {
        let effectiveTime: String?
        if let timeStr = timeStr {
            effectiveTime = timeStr
        } else if let existing = target.dueDateComponents, let h = existing.hour, let m = existing.minute {
            effectiveTime = String(format: "%02d:%02d", h, m)
        } else {
            effectiveTime = nil
        }
        guard let components = parseDateComponents(dueStr, time: effectiveTime) else {
            return OperationResult(success: false, message: "Error: Invalid date '\(dueStr)'.")
        }
        target.dueDateComponents = components
    } else if let timeStr = timeStr {
        if var existing = target.dueDateComponents {
            let timeParts = timeStr.split(separator: ":").compactMap { Int($0) }
            guard timeParts.count == 2 else {
                return OperationResult(success: false, message: "Error: Invalid time '\(timeStr)'. Use HH:MM.")
            }
            existing.hour = timeParts[0]
            existing.minute = timeParts[1]
            target.dueDateComponents = existing
        } else {
            return OperationResult(success: false, message: "Error: Cannot set time without a due date. Use --due as well.")
        }
    }

    if let newBody = newBody {
        target.notes = newBody
    }

    do {
        try store.save(target, commit: true)
    } catch {
        return OperationResult(success: false, message: "Error: Failed to save edit: \(error.localizedDescription)")
    }

    let verifyTitle = newTitle ?? target.title ?? title
    if !skipVerify {
        if verifyReminderExists(store: store, calendar: calendar, title: verifyTitle) {
            var msg = "Edited '\(title)' in '\(listName)':"
            for change in changes { msg += "\n  \(change)" }
            msg += "\nVerified: edit persisted."
            return OperationResult(success: true, message: msg)
        } else {
            return OperationResult(success: false, message: "Warning: Edit was saved but verification failed.")
        }
    }

    var msg = "Edited '\(title)' in '\(listName)':"
    for change in changes { msg += "\n  \(change)" }
    return OperationResult(success: true, message: msg)
}
