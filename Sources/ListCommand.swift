import EventKit
import Foundation

func runList(args: [String]) {
    let positional = positionalArgs(
        from: args,
        boolFlags: ["--json", "--completed"]
    )

    guard let listName = positional.first else {
        stderrPrint("Usage: eventkit list <list> [--json] [--completed]")
        exit(1)
    }

    let jsonMode = hasFlag("--json", in: args)
    let includeCompleted = hasFlag("--completed", in: args)

    let store = getAuthorizedStore()
    let calendar = findList(store: store, name: listName)
    var reminders = fetchReminders(store: store, in: [calendar])

    // Filter: default is incomplete only
    if !includeCompleted {
        reminders = reminders.filter { !$0.isCompleted }
    }

    // Sort by due date ascending, no-date items last
    reminders.sort { a, b in
        let dateA = a.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
        let dateB = b.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
        switch (dateA, dateB) {
        case let (a?, b?): return a < b
        case (nil, _): return false
        case (_, nil): return true
        }
    }

    if jsonMode {
        print(formatJSON(reminders: reminders))
    } else {
        if reminders.isEmpty {
            print("No reminders in '\(listName)'.")
            return
        }
        for (index, reminder) in reminders.enumerated() {
            let num = index + 1
            let status = reminder.isCompleted ? "x" : " "
            let title = reminder.title ?? "(untitled)"
            let datePart: String
            if let formatted = formatHumanDate(reminder.dueDateComponents) {
                datePart = " \u{2014} \(formatted)"
            } else {
                datePart = ""
            }
            print("[\(num)] [\(status)] \(title) [\(listName)]\(datePart)")
        }
    }
}
