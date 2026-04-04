import EventKit
import Foundation

func runFixTZ(args: [String]) {
    if hasFlag("--help", in: args) || hasFlag("-h", in: args) {
        print("""
        Usage: eventkit fix-tz [list...] [--dry-run]

        Recreates open reminders that have nil timeZone in dueDateComponents,
        setting TimeZone.current. EventKit locks timezone at creation time, so
        existing reminders can only be fixed by delete-and-recreate.

        If no lists specified, scans: Strategic, Personal, Inbox, Habits.
        Skips completed reminders.

        Options:
          --dry-run    Show what would change without saving
          --help, -h   Show this help
        """)
        exit(0)
    }

    let dryRun = hasFlag("--dry-run", in: args)
    let defaultLists = ["Strategic", "Personal", "Inbox", "Habits"]
    let specifiedLists = args.filter { !$0.hasPrefix("-") }
    let lists = specifiedLists.isEmpty ? defaultLists : specifiedLists

    let store = getAuthorizedStore()
    let calendars = store.calendars(for: .reminder)
    let tz = TimeZone.current
    var totalFixed = 0
    var totalSkipped = 0
    var totalNoDue = 0
    var totalCompleted = 0
    var totalErrors = 0

    for listName in lists {
        guard let calendar = calendars.first(where: { $0.title == listName }) else {
            stderrPrint("Warning: List '\(listName)' not found, skipping.")
            continue
        }

        let reminders = fetchReminders(store: store, in: [calendar])
        var listFixed = 0

        for reminder in reminders {
            if reminder.isCompleted {
                totalCompleted += 1
                continue
            }

            guard let due = reminder.dueDateComponents else {
                totalNoDue += 1
                continue
            }

            if due.timeZone != nil {
                totalSkipped += 1
                continue
            }

            // Build fresh DateComponents with timezone
            var fresh = DateComponents()
            fresh.year = due.year
            fresh.month = due.month
            fresh.day = due.day
            fresh.hour = due.hour
            fresh.minute = due.minute
            fresh.second = due.second
            fresh.timeZone = tz

            if dryRun {
                print("[dry-run] Would recreate: \(reminder.title ?? "(untitled)") in \(listName)")
                listFixed += 1
                totalFixed += 1
                continue
            }

            // Delete and recreate — only way to set timezone on existing reminders
            let result = recreateReminder(
                store: store, calendar: calendar, target: reminder,
                title: reminder.title ?? "",
                notes: reminder.notes,
                dueDateComponents: fresh,
                recurrenceRules: reminder.recurrenceRules,
                priority: reminder.priority
            )

            if result.success {
                listFixed += 1
                totalFixed += 1
            } else {
                stderrPrint("Error: \(reminder.title ?? "(untitled)"): \(result.message)")
                totalErrors += 1
            }
        }

        if listFixed > 0 || !specifiedLists.isEmpty {
            print("\(listName): \(listFixed) fixed")
        }
    }

    print("---")
    print("Fixed: \(totalFixed), Already OK: \(totalSkipped), Completed (skipped): \(totalCompleted), No due date: \(totalNoDue), Errors: \(totalErrors)")
    if dryRun { print("(dry run — no changes saved)") }
}
