import EventKit
import Foundation

/// Format an array of reminders as structured JSON for automation consumption.
/// Keys: completionDate (completed only), dueDate, hasRecurrence, id, isCompleted, listID, listName, notes, priority, recurrence (recurring only), title
func formatJSON(reminders: [EKReminder]) -> String {
    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime]

    var items: [[String: Any]] = []

    for reminder in reminders {
        var dict: [String: Any] = [:]

        // completionDate — only present for completed items
        if reminder.isCompleted, let completionDate = reminder.completionDate {
            dict["completionDate"] = isoFormatter.string(from: completionDate)
        }

        // dueDate — omit key entirely when nil
        if let dueDateComponents = reminder.dueDateComponents,
           let dueDate = Calendar.current.date(from: dueDateComponents) {
            dict["dueDate"] = isoFormatter.string(from: dueDate)
        }

        // hasRecurrence
        dict["hasRecurrence"] = reminder.hasRecurrenceRules

        // id
        dict["id"] = reminder.calendarItemExternalIdentifier

        // isCompleted
        dict["isCompleted"] = reminder.isCompleted

        // listID
        dict["listID"] = reminder.calendar.calendarIdentifier

        // listName
        dict["listName"] = reminder.calendar.title

        // notes — omit key entirely when nil
        if let notes = reminder.notes {
            dict["notes"] = notes
        }

        // priority
        dict["priority"] = priorityString(reminder.priority)

        // recurrence — rule summary, omit key entirely when no rules
        if let rules = reminder.recurrenceRules, !rules.isEmpty {
            dict["recurrence"] = rules.map(recurrenceSummary).joined(separator: "; ")
        }

        // title
        dict["title"] = reminder.title ?? ""

        items.append(dict)
    }

    guard let data = try? JSONSerialization.data(
        withJSONObject: items,
        options: [.prettyPrinted, .sortedKeys]
    ) else {
        return "[]"
    }

    return String(data: data, encoding: .utf8) ?? "[]"
}

/// Summarize an EKRecurrenceRule using the set-recurrence frequency vocabulary:
/// "weekly" for interval 1, "weekly interval=2" otherwise.
func recurrenceSummary(_ rule: EKRecurrenceRule) -> String {
    let freq: String
    switch rule.frequency {
    case .daily: freq = "daily"
    case .weekly: freq = "weekly"
    case .monthly: freq = "monthly"
    case .yearly: freq = "yearly"
    @unknown default: freq = "unknown"
    }
    return rule.interval > 1 ? "\(freq) interval=\(rule.interval)" : freq
}

/// Map EKReminder priority int to human-readable string
func priorityString(_ priority: Int) -> String {
    switch priority {
    case 0: return "none"
    case 1...4: return "high"
    case 5: return "medium"
    case 6...9: return "low"
    default: return "none"
    }
}
