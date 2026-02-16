import EventKit
import Foundation

func runSetRecurrence(args: [String]) {
    let positional = positionalArgs(from: args, boolFlags: ["--dry-run"])

    guard positional.count >= 4 else {
        stderrPrint("Usage: eventkit set-recurrence <list> <title> <frequency> <interval> [--dry-run]")
        stderrPrint("  frequency: daily, weekly, monthly, yearly")
        stderrPrint("  interval: positive integer (1 = every period, 2 = every other)")
        exit(1)
    }

    let listName = positional[0]
    let title = positional[1]
    let frequencyStr = positional[2]
    let intervalStr = positional[3]
    let dryRun = hasFlag("--dry-run", in: args)

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
    let target = findReminder(in: reminders, title: title)

    // Double-recurrence protection
    if let existingRules = target.recurrenceRules, !existingRules.isEmpty {
        let ruleDesc = existingRules.map { "\($0)" }.joined(separator: "; ")
        stderrPrint("Error: '\(target.title ?? title)' already has recurrence: \(ruleDesc)")
        stderrPrint("Remove existing rule first if you want to replace it.")
        exit(6)
    }

    if dryRun {
        print("DRY RUN \u{2014} would set recurrence on '\(target.title ?? title)' in '\(listName)':")
        print("  Frequency: \(frequencyStr)")
        print("  Interval: every \(interval) \(frequencyStr) period(s)")
        print("  End: never")
        print("No changes saved.")
        exit(0)
    }

    let rule = EKRecurrenceRule(recurrenceWith: frequency, interval: interval, end: nil)
    target.addRecurrenceRule(rule)

    do {
        try store.save(target, commit: true)
    } catch {
        stderrPrint("Error: Failed to save recurrence rule: \(error.localizedDescription)")
        exit(7)
    }

    print("Set recurrence on '\(target.title ?? title)' in '\(listName)':")
    print("  Frequency: \(frequencyStr)")
    print("  Interval: every \(interval) \(frequencyStr) period(s)")
    print("  End: never")
    print("Saved successfully.")
}
