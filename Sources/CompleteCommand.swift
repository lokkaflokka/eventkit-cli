import EventKit
import Foundation

func runComplete(args: [String]) {
    let positional = positionalArgs(from: args, boolFlags: ["--dry-run"])

    guard positional.count >= 2 else {
        stderrPrint("Usage: eventkit complete <list> <title> [--dry-run]")
        exit(1)
    }

    let listName = positional[0]
    let title = positional[1]
    let dryRun = hasFlag("--dry-run", in: args)

    let store = getAuthorizedStore()
    let calendar = findList(store: store, name: listName)
    let reminders = fetchReminders(store: store, in: [calendar])
    let target = findReminder(in: reminders, title: title)

    if dryRun {
        print("DRY RUN \u{2014} would complete '\(target.title ?? title)' in '\(listName)'.")
        print("No changes saved.")
        exit(0)
    }

    target.isCompleted = true
    target.completionDate = Date()

    do {
        try store.save(target, commit: true)
    } catch {
        stderrPrint("Error: Failed to save completion: \(error.localizedDescription)")
        exit(7)
    }

    // Verify
    if verifyReminderCompleted(store: store, calendar: calendar, title: target.title ?? title) {
        print("Completed '\(target.title ?? title)' in '\(listName)'.")
        print("Verified: completion persisted.")
    } else {
        stderrPrint("Warning: Completion was saved but verification failed.")
        exit(7)
    }
}
