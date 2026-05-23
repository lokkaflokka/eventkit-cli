import EventKit
import Foundation

func runComplete(args: [String]) {
    if hasFlag("--help", in: args) || hasFlag("-h", in: args) {
        print("""
        Usage: eventkit complete <list> <title> [options]

        Options:
          --id ID          Complete by reminder ID instead of title
          --dry-run        Preview without saving
          --force          Bypass [hw-arrives:] precondition gate (M1 safeguard)
          --help, -h       Show this help

        When --id is provided, <title> is optional.

        Precondition gate: if the reminder's body contains [hw-arrives: YYYY-MM-DD]
        and that date is after today, completion is refused unless --force is given.
        """)
        exit(0)
    }

    let positional = positionalArgs(from: args, valueFlags: ["--id"], boolFlags: ["--dry-run", "--force"])
    let idFlag = extractFlag("--id", from: args)

    guard positional.count >= 2 || (positional.count >= 1 && idFlag != nil) else {
        stderrPrint("Usage: eventkit complete <list> <title> [--id ID] [--dry-run] [--force]")
        exit(1)
    }

    let listName = positional[0]
    let titleArg: String? = positional.count >= 2 ? positional[1] : nil
    let dryRun = hasFlag("--dry-run", in: args)
    let force = hasFlag("--force", in: args)

    let store = getAuthorizedStore()
    let calendar = findList(store: store, name: listName)
    let reminders = fetchReminders(store: store, in: [calendar])
    let target = resolveReminder(in: reminders, id: idFlag, title: titleArg)

    let result = executeComplete(
        store: store, calendar: calendar, target: target,
        dryRun: dryRun, skipVerify: false, force: force
    )

    if result.success {
        print(result.message)
    } else {
        stderrPrint(result.message)
        exit(7)
    }
}

func executeComplete(
    store: EKEventStore, calendar: EKCalendar, target: EKReminder,
    dryRun: Bool, skipVerify: Bool, force: Bool = false
) -> OperationResult {
    let listName = calendar.title
    let title = target.title ?? "(untitled)"

    // M1 precondition gate: refuse if [hw-arrives:] tag value is in the future.
    if let blocked = checkHwArrivesGate(target: target, force: force) {
        return blocked
    }

    if dryRun {
        return OperationResult(success: true, message: "DRY RUN \u{2014} would complete '\(title)' in '\(listName)'.\nNo changes saved.")
    }

    target.isCompleted = true
    target.completionDate = Date()

    do {
        try store.save(target, commit: true)
    } catch {
        return OperationResult(success: false, message: "Error: Failed to save completion: \(error.localizedDescription)")
    }

    if !skipVerify {
        if verifyReminderCompleted(store: store, calendar: calendar, title: title) {
            return OperationResult(success: true, message: "Completed '\(title)' in '\(listName)'.\nVerified: completion persisted.")
        } else {
            return OperationResult(success: false, message: "Warning: Completion was saved but verification failed.")
        }
    }

    return OperationResult(success: true, message: "Completed '\(title)' in '\(listName)'.")
}
