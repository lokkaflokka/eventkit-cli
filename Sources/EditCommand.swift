import EventKit
import Foundation

func runEdit(args: [String]) {
    let positional = positionalArgs(
        from: args,
        valueFlags: ["--title", "--due", "--time", "--body", "--body-file"],
        boolFlags: ["--dry-run"]
    )

    guard positional.count >= 2 else {
        stderrPrint("Usage: eventkit edit <list> <title> [--title NEW] [--due YYYY-MM-DD] [--time HH:MM] [--body TEXT | --body-file PATH] [--dry-run]")
        exit(1)
    }

    let listName = positional[0]
    let title = positional[1]
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
        newBody = extractFlag("--body", from: args)
    }
    let dryRun = hasFlag("--dry-run", in: args)

    // Must have at least one edit
    if newTitle == nil && dueStr == nil && timeStr == nil && newBody == nil {
        stderrPrint("Error: No edits specified. Use --title, --due, --time, or --body.")
        exit(1)
    }

    let store = getAuthorizedStore()
    let calendar = findList(store: store, name: listName)
    let reminders = fetchReminders(store: store, in: [calendar])
    let target = findReminder(in: reminders, title: title)

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
        print("DRY RUN \u{2014} would edit '\(target.title ?? title)' in '\(listName)':")
        for change in changes { print("  \(change)") }
        print("No changes saved.")
        exit(0)
    }

    // Apply edits
    if let newTitle = newTitle {
        target.title = newTitle
    }

    if let dueStr = dueStr {
        // When --due is provided, use it (with optional --time, defaulting to existing time or 09:00)
        let effectiveTime: String?
        if let timeStr = timeStr {
            effectiveTime = timeStr
        } else if let existing = target.dueDateComponents, let h = existing.hour, let m = existing.minute {
            effectiveTime = String(format: "%02d:%02d", h, m)
        } else {
            effectiveTime = nil // parseDateComponents defaults to 09:00
        }
        guard let components = parseDateComponents(dueStr, time: effectiveTime) else {
            stderrPrint("Error: Invalid date '\(dueStr)'.")
            exit(1)
        }
        target.dueDateComponents = components
    } else if let timeStr = timeStr {
        // Time-only edit: keep existing date, change time
        if var existing = target.dueDateComponents {
            let timeParts = timeStr.split(separator: ":").compactMap { Int($0) }
            guard timeParts.count == 2 else {
                stderrPrint("Error: Invalid time '\(timeStr)'. Use HH:MM.")
                exit(1)
            }
            existing.hour = timeParts[0]
            existing.minute = timeParts[1]
            target.dueDateComponents = existing
        } else {
            stderrPrint("Error: Cannot set time without a due date. Use --due as well.")
            exit(1)
        }
    }

    if let newBody = newBody {
        target.notes = newBody
    }

    do {
        try store.save(target, commit: true)
    } catch {
        stderrPrint("Error: Failed to save edit: \(error.localizedDescription)")
        exit(7)
    }

    // Verify — use new title if it was changed
    let verifyTitle = newTitle ?? target.title ?? title
    if verifyReminderExists(store: store, calendar: calendar, title: verifyTitle) {
        print("Edited '\(title)' in '\(listName)':")
        for change in changes { print("  \(change)") }
        print("Verified: edit persisted.")
    } else {
        stderrPrint("Warning: Edit was saved but verification failed.")
        exit(7)
    }
}
