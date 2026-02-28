import EventKit
import Foundation

func runList(args: [String]) {
    if hasFlag("--help", in: args) || hasFlag("-h", in: args) {
        print("""
        Usage: eventkit list <list> [options]

        Options:
          --json               Output as structured JSON
          --completed          Include completed reminders
          --due-before DATE    Only reminders due before DATE (YYYY-MM-DD)
          --due-after DATE     Only reminders due after DATE (YYYY-MM-DD)
          --help, -h           Show this help
        """)
        exit(0)
    }

    let positional = positionalArgs(
        from: args,
        valueFlags: ["--due-before", "--due-after"],
        boolFlags: ["--json", "--completed"]
    )

    guard let listName = positional.first else {
        stderrPrint("Usage: eventkit list <list> [--json] [--completed] [--due-before YYYY-MM-DD] [--due-after YYYY-MM-DD]")
        exit(1)
    }

    let jsonMode = hasFlag("--json", in: args)
    let includeCompleted = hasFlag("--completed", in: args)
    let dueBeforeStr = extractFlag("--due-before", from: args)
    let dueAfterStr = extractFlag("--due-after", from: args)

    let store = getAuthorizedStore()
    let calendar = findList(store: store, name: listName)
    var reminders = fetchReminders(store: store, in: [calendar])

    // Filter: default is incomplete only
    if !includeCompleted {
        reminders = reminders.filter { !$0.isCompleted }
    }

    // Filter by date range (day-level comparison)
    let cal = Calendar.current
    if let beforeStr = dueBeforeStr {
        guard let beforeComps = parseDateComponents(beforeStr) else {
            stderrPrint("Error: Invalid --due-before date '\(beforeStr)'. Use YYYY-MM-DD.")
            exit(1)
        }
        guard let beforeDate = cal.date(from: beforeComps) else {
            stderrPrint("Error: Cannot resolve --due-before date '\(beforeStr)'.")
            exit(1)
        }
        let beforeDay = cal.startOfDay(for: beforeDate)
        reminders = reminders.filter { r in
            guard let dueComps = r.dueDateComponents,
                  let dueDate = cal.date(from: dueComps) else { return false }
            return cal.startOfDay(for: dueDate) < beforeDay
        }
    }
    if let afterStr = dueAfterStr {
        guard let afterComps = parseDateComponents(afterStr) else {
            stderrPrint("Error: Invalid --due-after date '\(afterStr)'. Use YYYY-MM-DD.")
            exit(1)
        }
        guard let afterDate = cal.date(from: afterComps) else {
            stderrPrint("Error: Cannot resolve --due-after date '\(afterStr)'.")
            exit(1)
        }
        let afterDay = cal.startOfDay(for: afterDate)
        reminders = reminders.filter { r in
            guard let dueComps = r.dueDateComponents,
                  let dueDate = cal.date(from: dueComps) else { return false }
            return cal.startOfDay(for: dueDate) > afterDay
        }
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
