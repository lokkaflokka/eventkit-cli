import EventKit
import Foundation

func runSetRecurrence(args: [String]) {
    if hasFlag("--help", in: args) || hasFlag("-h", in: args) {
        print("""
        Usage: eventkit set-recurrence <list> <title> <frequency> <interval> [options]

        Frequency: daily, weekly, monthly, yearly
        Interval: positive integer (1 = every period, 2 = every other)

        Options:
          --id ID          Target by reminder ID instead of title
          --dry-run        Preview without saving
          --help, -h       Show this help

        When --id is provided, <title> is omitted and positional args are:
          eventkit set-recurrence <list> <frequency> <interval> --id ID
        """)
        exit(0)
    }

    let positional = positionalArgs(from: args, valueFlags: ["--id"], boolFlags: ["--dry-run"])
    let idFlag = extractFlag("--id", from: args)
    let dryRun = hasFlag("--dry-run", in: args)

    let listName: String
    let titleArg: String?
    let frequencyStr: String
    let intervalStr: String

    if idFlag != nil {
        // With --id: positional = [list, freq, interval]
        guard positional.count >= 3 else {
            stderrPrint("Usage: eventkit set-recurrence <list> <frequency> <interval> --id ID [--dry-run]")
            exit(1)
        }
        listName = positional[0]
        titleArg = nil
        frequencyStr = positional[1]
        intervalStr = positional[2]
    } else {
        // Without --id: positional = [list, title, freq, interval]
        guard positional.count >= 4 else {
            stderrPrint("Usage: eventkit set-recurrence <list> <title> <frequency> <interval> [--id ID] [--dry-run]")
            stderrPrint("  frequency: daily, weekly, monthly, yearly")
            stderrPrint("  interval: positive integer (1 = every period, 2 = every other)")
            exit(1)
        }
        listName = positional[0]
        titleArg = positional[1]
        frequencyStr = positional[2]
        intervalStr = positional[3]
    }

    let frequencyMap: [String: EKRecurrenceFrequency] = [
        "daily": .daily, "weekly": .weekly, "monthly": .monthly, "yearly": .yearly,
    ]

    guard let frequency = frequencyMap[frequencyStr.lowercased()] else {
        stderrPrint("Error: Invalid frequency '\(frequencyStr)'. Must be: daily, weekly, monthly, yearly.")
        exit(1)
    }

    guard let interval = Int(intervalStr), interval > 0 else {
        stderrPrint("Error: Invalid interval '\(intervalStr)'. Must be a positive integer.")
        exit(1)
    }

    let store = getAuthorizedStore()
    let calendar = findList(store: store, name: listName)
    let reminders = fetchReminders(store: store, in: [calendar])
    let target = resolveReminder(in: reminders, id: idFlag, title: titleArg)

    // Double-recurrence protection
    if let existingRules = target.recurrenceRules, !existingRules.isEmpty {
        let ruleDesc = existingRules.map { "\($0)" }.joined(separator: "; ")
        stderrPrint("Error: '\(target.title ?? titleArg ?? "(untitled)")' already has recurrence: \(ruleDesc)")
        stderrPrint("Remove existing rule first if you want to replace it.")
        exit(6)
    }

    let result = executeSetRecurrence(
        store: store, calendar: calendar, target: target,
        frequencyStr: frequencyStr, frequency: frequency, interval: interval,
        dryRun: dryRun, skipVerify: false
    )

    if result.success {
        print(result.message)
    } else {
        stderrPrint(result.message)
        exit(7)
    }
}

func executeSetRecurrence(
    store: EKEventStore, calendar: EKCalendar, target: EKReminder,
    frequencyStr: String, frequency: EKRecurrenceFrequency, interval: Int,
    dryRun: Bool, skipVerify: Bool
) -> OperationResult {
    let listName = calendar.title
    let title = target.title ?? "(untitled)"

    // Double-recurrence protection
    if let existingRules = target.recurrenceRules, !existingRules.isEmpty {
        let ruleDesc = existingRules.map { "\($0)" }.joined(separator: "; ")
        return OperationResult(success: false, message: "Error: '\(title)' already has recurrence: \(ruleDesc)")
    }

    if dryRun {
        var msg = "DRY RUN \u{2014} would set recurrence on '\(title)' in '\(listName)':"
        msg += "\n  Frequency: \(frequencyStr)"
        msg += "\n  Interval: every \(interval) \(frequencyStr) period(s)"
        msg += "\n  End: never"
        msg += "\nNo changes saved."
        return OperationResult(success: true, message: msg)
    }

    let rule = EKRecurrenceRule(recurrenceWith: frequency, interval: interval, end: nil)
    target.addRecurrenceRule(rule)

    do {
        try store.save(target, commit: true)
    } catch {
        return OperationResult(success: false, message: "Error: Failed to save recurrence rule: \(error.localizedDescription)")
    }

    var msg = "Set recurrence on '\(title)' in '\(listName)':"
    msg += "\n  Frequency: \(frequencyStr)"
    msg += "\n  Interval: every \(interval) \(frequencyStr) period(s)"
    msg += "\n  End: never"
    msg += "\nSaved successfully."

    // Verify recurrence persisted
    if !skipVerify {
        let freshReminders = fetchReminders(store: store, in: [calendar])
        let freshTarget = freshReminders.first(where: { $0.calendarItemExternalIdentifier == target.calendarItemExternalIdentifier })
        if let rules = freshTarget?.recurrenceRules, !rules.isEmpty {
            msg += "\nVerified: recurrence persisted."
        } else {
            return OperationResult(success: false, message: msg + "\nError: Recurrence did not persist after save.")
        }
    }

    return OperationResult(success: true, message: msg)
}
