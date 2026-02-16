import EventKit
import Foundation

func runDelete(args: [String]) {
    let positional = positionalArgs(from: args, boolFlags: ["--dry-run"])

    guard positional.count >= 2 else {
        stderrPrint("Usage: eventkit delete <list> <title> [--dry-run]")
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
        print("DRY RUN \u{2014} would delete '\(target.title ?? title)' from '\(listName)'.")
        print("No changes saved.")
        exit(0)
    }

    do {
        try store.remove(target, commit: true)
    } catch {
        stderrPrint("Error: Failed to delete reminder: \(error.localizedDescription)")
        exit(7)
    }

    // Verify it's gone
    if verifyReminderGone(store: store, calendar: calendar, title: target.title ?? title) {
        print("Deleted '\(target.title ?? title)' from '\(listName)'.")
        print("Verified: reminder removed.")
    } else {
        stderrPrint("Warning: Delete was executed but verification failed \u{2014} reminder may still exist.")
        exit(7)
    }
}
