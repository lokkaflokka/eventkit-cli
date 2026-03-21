import EventKit
import Foundation

func runDiag(args: [String]) {
    let positional = positionalArgs(
        from: args,
        valueFlags: ["--id"],
        boolFlags: []
    )
    let idFlag = extractFlag("--id", from: args)

    guard positional.count >= 2 || (positional.count >= 1 && idFlag != nil) else {
        stderrPrint("Usage: eventkit diag <list> <title> [--id ID]")
        exit(1)
    }

    let listName = positional[0]
    let titleArg: String? = positional.count >= 2 ? positional[1] : nil

    let store = getAuthorizedStore()
    let calendar = findList(store: store, name: listName)
    let reminders = fetchReminders(store: store, in: [calendar])
    let target = resolveReminder(in: reminders, id: idFlag, title: titleArg)

    print("=== DIAGNOSTIC DUMP ===")
    print("title: \(target.title ?? "(nil)")")
    print("calendarItemExternalIdentifier: \(target.calendarItemExternalIdentifier ?? "(nil)")")
    print("calendarItemIdentifier: \(target.calendarItemIdentifier)")
    print("calendar: \(target.calendar?.title ?? "(nil)")")
    print("isCompleted: \(target.isCompleted)")
    print("priority: \(target.priority)")

    print("\n--- Date Properties ---")
    if let dc = target.dueDateComponents {
        print("dueDateComponents: year=\(dc.year ?? -1) month=\(dc.month ?? -1) day=\(dc.day ?? -1) hour=\(dc.hour ?? -1) minute=\(dc.minute ?? -1)")
        print("dueDateComponents.calendar: \(dc.calendar.map { "\($0.identifier)" } ?? "nil")")
        print("dueDateComponents.timeZone: \(dc.timeZone?.identifier ?? "nil")")
        if let cal = dc.calendar ?? Calendar.current as Calendar? {
            if let date = cal.date(from: dc) {
                print("dueDateComponents → Date: \(date)")
            } else {
                print("dueDateComponents → Date: FAILED TO RESOLVE")
            }
        }
    } else {
        print("dueDateComponents: nil")
    }

    if let sd = target.startDateComponents {
        print("startDateComponents: year=\(sd.year ?? -1) month=\(sd.month ?? -1) day=\(sd.day ?? -1) hour=\(sd.hour ?? -1) minute=\(sd.minute ?? -1)")
        print("startDateComponents.timeZone: \(sd.timeZone?.identifier ?? "nil")")
    } else {
        print("startDateComponents: nil")
    }

    print("\n--- Alarms ---")
    if let alarms = target.alarms, !alarms.isEmpty {
        for (i, alarm) in alarms.enumerated() {
            print("alarm[\(i)]:")
            print("  absoluteDate: \(alarm.absoluteDate.map { "\($0)" } ?? "nil")")
            print("  relativeOffset: \(alarm.relativeOffset)")
            print("  type: \(alarm.type.rawValue)")
            if let structuredLocation = alarm.structuredLocation {
                print("  structuredLocation: \(structuredLocation.title ?? "nil")")
            }
        }
    } else {
        print("(no alarms)")
    }

    print("\n--- Recurrence ---")
    if let rules = target.recurrenceRules, !rules.isEmpty {
        for (i, rule) in rules.enumerated() {
            print("rule[\(i)]: freq=\(rule.frequency.rawValue) interval=\(rule.interval)")
        }
    } else {
        print("(no recurrence rules)")
    }

    print("\n--- Notes ---")
    print(target.notes ?? "(nil)")

    print("\n--- Other ---")
    print("creationDate: \(target.creationDate.map { "\($0)" } ?? "nil")")
    print("lastModifiedDate: \(target.lastModifiedDate.map { "\($0)" } ?? "nil")")
    print("hasNotes: \(target.hasNotes)")
}
