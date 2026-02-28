import EventKit
import Foundation

func runDelete(args: [String]) {
    if hasFlag("--help", in: args) || hasFlag("-h", in: args) {
        print("""
        Usage: eventkit delete <list> <title> [options]

        Options:
          --id ID          Delete by reminder ID instead of title
          --dry-run        Preview without saving
          --help, -h       Show this help

        When --id is provided, <title> is optional.
        """)
        exit(0)
    }

    let positional = positionalArgs(from: args, valueFlags: ["--id"], boolFlags: ["--dry-run"])
    let idFlag = extractFlag("--id", from: args)

    guard positional.count >= 2 || (positional.count >= 1 && idFlag != nil) else {
        stderrPrint("Usage: eventkit delete <list> <title> [--id ID] [--dry-run]")
        exit(1)
    }

    let listName = positional[0]
    let titleArg: String? = positional.count >= 2 ? positional[1] : nil
    let dryRun = hasFlag("--dry-run", in: args)

    let store = getAuthorizedStore()
    let calendar = findList(store: store, name: listName)
    let reminders = fetchReminders(store: store, in: [calendar])
    let target = resolveReminder(in: reminders, id: idFlag, title: titleArg)

    let result = executeDelete(
        store: store, calendar: calendar, target: target,
        dryRun: dryRun, skipVerify: false
    )

    if result.success {
        print(result.message)
    } else {
        stderrPrint(result.message)
        exit(7)
    }
}

func executeDelete(
    store: EKEventStore, calendar: EKCalendar, target: EKReminder,
    dryRun: Bool, skipVerify: Bool
) -> OperationResult {
    let listName = calendar.title
    let title = target.title ?? "(untitled)"

    if dryRun {
        return OperationResult(success: true, message: "DRY RUN \u{2014} would delete '\(title)' from '\(listName)'.\nNo changes saved.")
    }

    do {
        try store.remove(target, commit: true)
    } catch {
        return OperationResult(success: false, message: "Error: Failed to delete reminder: \(error.localizedDescription)")
    }

    if !skipVerify {
        if verifyReminderGone(store: store, calendar: calendar, title: title) {
            return OperationResult(success: true, message: "Deleted '\(title)' from '\(listName)'.\nVerified: reminder removed.")
        } else {
            return OperationResult(success: false, message: "Warning: Delete was executed but verification failed \u{2014} reminder may still exist.")
        }
    }

    return OperationResult(success: true, message: "Deleted '\(title)' from '\(listName)'.")
}
