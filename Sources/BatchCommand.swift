import EventKit
import Foundation

// MARK: - Batch context (lazy-cached store access)

struct BatchContext {
    let store: EKEventStore
    private var lists: [String: EKCalendar] = [:]
    private var reminders: [String: [EKReminder]] = [:]

    init(store: EKEventStore) {
        self.store = store
    }

    mutating func getList(_ name: String) -> EKCalendar? {
        if let cached = lists[name] { return cached }
        let calendars = store.calendars(for: .reminder)
        guard let calendar = calendars.first(where: { $0.title == name }) else { return nil }
        lists[name] = calendar
        return calendar
    }

    mutating func getReminders(for listName: String) -> [EKReminder]? {
        if let cached = reminders[listName] { return cached }
        guard let calendar = getList(listName) else { return nil }
        let fetched = fetchReminders(store: store, in: [calendar])
        reminders[listName] = fetched
        return fetched
    }

    mutating func invalidate(_ listName: String) {
        reminders.removeValue(forKey: listName)
    }
}

// MARK: - Batch operation (JSON input)

struct BatchOperation: Decodable {
    let command: String
    // Common
    let list: String?
    let title: String?
    let id: String?
    // add / edit / move
    let due: String?
    let time: String?
    let body: String?
    // add
    let recurrence: String?
    let interval: String?
    let force: Bool?
    // move
    let source: String?
    let target: String?
    // set-recurrence
    let frequency: String?
    // edit
    let newTitle: String?

    enum CodingKeys: String, CodingKey {
        case command, list, title, id, due, time, body
        case recurrence, interval, force
        case source, target
        case frequency
        case newTitle = "new_title"
    }
}

// MARK: - Batch result (JSON output)

struct BatchResult: Encodable {
    let index: Int
    let command: String
    let title: String?
    let status: String   // "ok" or "error"
    let message: String
}

// MARK: - Batch dispatcher

func runBatch(args: [String]) {
    if hasFlag("--help", in: args) || hasFlag("-h", in: args) {
        print("""
        Usage: eventkit batch [options]

        Executes multiple operations in a single process with shared auth and cached fetches.
        Reads JSON from stdin, or from a file with --file.

        JSON format (array of operations):
        [
          {"command": "move", "source": "Inbox", "target": "Personal", "title": "Item", "due": "2026-02-28"},
          {"command": "complete", "list": "Strategic", "title": "Task done"},
          {"command": "add", "list": "Personal", "title": "New item", "due": "2026-03-01", "body": "Details"},
          {"command": "edit", "list": "Strategic", "id": "ABC-123", "due": "2026-03-05"},
          {"command": "set-recurrence", "list": "Personal", "title": "Weekly review", "frequency": "weekly", "interval": "1"},
          {"command": "delete", "list": "Personal", "title": "Old item"}
        ]

        Options:
          --file PATH      Read JSON from file instead of stdin
          --skip-verify    Skip post-save verification (faster)
          --dry-run        Preview all operations without saving
          --help, -h       Show this help

        Output: JSON array of results with index, command, title, status, message.
        Exit code: 0 if all succeed, 7 if any failed.
        """)
        exit(0)
    }

    let filePath = extractFlag("--file", from: args)
    let skipVerify = hasFlag("--skip-verify", in: args)
    let dryRun = hasFlag("--dry-run", in: args)

    // Read JSON input
    let jsonData: Data
    if let filePath = filePath {
        guard let data = FileManager.default.contents(atPath: filePath) else {
            stderrPrint("Error: Cannot read file '\(filePath)'.")
            exit(1)
        }
        jsonData = data
    } else {
        // Read from stdin
        var stdinData = Data()
        while let line = readLine(strippingNewline: false) {
            stdinData.append(Data(line.utf8))
        }
        guard !stdinData.isEmpty else {
            stderrPrint("Error: No input. Pipe JSON to stdin or use --file PATH.")
            exit(1)
        }
        jsonData = stdinData
    }

    // Parse operations
    let operations: [BatchOperation]
    do {
        operations = try JSONDecoder().decode([BatchOperation].self, from: jsonData)
    } catch {
        stderrPrint("Error: Invalid JSON input: \(error.localizedDescription)")
        exit(1)
    }

    guard !operations.isEmpty else {
        stderrPrint("Error: Empty operations array.")
        exit(1)
    }

    // Single auth
    let store = getAuthorizedStore()
    var ctx = BatchContext(store: store)
    var results: [BatchResult] = []
    var anyFailed = false

    for (index, op) in operations.enumerated() {
        let result = dispatchOperation(index: index, op: op, ctx: &ctx, skipVerify: skipVerify, dryRun: dryRun)
        if result.status == "error" { anyFailed = true }
        results.append(result)
    }

    // Output JSON results
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(results),
       let json = String(data: data, encoding: .utf8) {
        print(json)
    }

    exit(anyFailed ? 7 : 0)
}

private func dispatchOperation(
    index: Int, op: BatchOperation, ctx: inout BatchContext,
    skipVerify: Bool, dryRun: Bool
) -> BatchResult {
    switch op.command {
    case "add":
        return dispatchAdd(index: index, op: op, ctx: &ctx, skipVerify: skipVerify, dryRun: dryRun)
    case "complete":
        return dispatchComplete(index: index, op: op, ctx: &ctx, skipVerify: skipVerify, dryRun: dryRun)
    case "edit", "update":
        return dispatchEdit(index: index, op: op, ctx: &ctx, skipVerify: skipVerify, dryRun: dryRun)
    case "move":
        return dispatchMove(index: index, op: op, ctx: &ctx, skipVerify: skipVerify, dryRun: dryRun)
    case "set-recurrence":
        return dispatchSetRecurrence(index: index, op: op, ctx: &ctx, skipVerify: skipVerify, dryRun: dryRun)
    case "delete":
        return dispatchDelete(index: index, op: op, ctx: &ctx, skipVerify: skipVerify, dryRun: dryRun)
    default:
        return BatchResult(index: index, command: op.command, title: op.title, status: "error", message: "Unknown command '\(op.command)'")
    }
}

// MARK: - Batch dispatchers

private func dispatchAdd(
    index: Int, op: BatchOperation, ctx: inout BatchContext,
    skipVerify: Bool, dryRun: Bool
) -> BatchResult {
    guard let listName = op.list, let title = op.title else {
        return BatchResult(index: index, command: "add", title: op.title, status: "error", message: "Missing required field: 'list' and 'title'")
    }
    guard let calendar = ctx.getList(listName) else {
        return BatchResult(index: index, command: "add", title: title, status: "error", message: "List '\(listName)' not found")
    }
    guard let reminders = ctx.getReminders(for: listName) else {
        return BatchResult(index: index, command: "add", title: title, status: "error", message: "Failed to fetch reminders for '\(listName)'")
    }

    let result = executeAdd(
        store: ctx.store, calendar: calendar, reminders: reminders,
        title: title, dueStr: op.due, timeStr: op.time, body: op.body,
        recurrenceStr: op.recurrence, intervalStr: op.interval,
        force: op.force ?? false, dryRun: dryRun, skipVerify: skipVerify
    )
    ctx.invalidate(listName)
    return BatchResult(index: index, command: "add", title: title, status: result.success ? "ok" : "error", message: result.message)
}

private func dispatchComplete(
    index: Int, op: BatchOperation, ctx: inout BatchContext,
    skipVerify: Bool, dryRun: Bool
) -> BatchResult {
    guard let listName = op.list ?? op.source else {
        return BatchResult(index: index, command: "complete", title: op.title, status: "error", message: "Missing required field: 'list'")
    }
    guard let calendar = ctx.getList(listName) else {
        return BatchResult(index: index, command: "complete", title: op.title, status: "error", message: "List '\(listName)' not found")
    }
    guard let reminders = ctx.getReminders(for: listName) else {
        return BatchResult(index: index, command: "complete", title: op.title, status: "error", message: "Failed to fetch reminders for '\(listName)'")
    }

    // Resolve target
    let target: EKReminder
    if let id = op.id {
        guard let r = findReminderByIDOptional(in: reminders, id: id) else {
            return BatchResult(index: index, command: "complete", title: op.title, status: "error", message: "No reminder with id '\(id)'")
        }
        target = r
    } else if let title = op.title {
        switch lookupReminder(in: reminders, title: title) {
        case .found(let r): target = r
        case .ambiguous(let matches):
            let ids = matches.map { "\"\(($0.title ?? "?"))\" (id: \($0.calendarItemExternalIdentifier ?? "?"))" }.joined(separator: ", ")
            return BatchResult(index: index, command: "complete", title: title, status: "error", message: "Ambiguous match: \(ids)")
        case .notFound:
            return BatchResult(index: index, command: "complete", title: title, status: "error", message: "No incomplete reminder matching '\(title)'")
        }
    } else {
        return BatchResult(index: index, command: "complete", title: nil, status: "error", message: "Missing 'title' or 'id'")
    }

    let result = executeComplete(store: ctx.store, calendar: calendar, target: target, dryRun: dryRun, skipVerify: skipVerify)
    ctx.invalidate(listName)
    return BatchResult(index: index, command: "complete", title: target.title, status: result.success ? "ok" : "error", message: result.message)
}

private func dispatchEdit(
    index: Int, op: BatchOperation, ctx: inout BatchContext,
    skipVerify: Bool, dryRun: Bool
) -> BatchResult {
    guard let listName = op.list else {
        return BatchResult(index: index, command: "edit", title: op.title, status: "error", message: "Missing required field: 'list'")
    }
    guard let calendar = ctx.getList(listName) else {
        return BatchResult(index: index, command: "edit", title: op.title, status: "error", message: "List '\(listName)' not found")
    }
    guard let reminders = ctx.getReminders(for: listName) else {
        return BatchResult(index: index, command: "edit", title: op.title, status: "error", message: "Failed to fetch reminders for '\(listName)'")
    }

    // Resolve target
    let target: EKReminder
    if let id = op.id {
        guard let r = findReminderByIDOptional(in: reminders, id: id) else {
            return BatchResult(index: index, command: "edit", title: op.title, status: "error", message: "No reminder with id '\(id)'")
        }
        target = r
    } else if let title = op.title {
        switch lookupReminder(in: reminders, title: title) {
        case .found(let r): target = r
        case .ambiguous(let matches):
            let ids = matches.map { "\"\(($0.title ?? "?"))\" (id: \($0.calendarItemExternalIdentifier ?? "?"))" }.joined(separator: ", ")
            return BatchResult(index: index, command: "edit", title: title, status: "error", message: "Ambiguous match: \(ids)")
        case .notFound:
            return BatchResult(index: index, command: "edit", title: title, status: "error", message: "No incomplete reminder matching '\(title)'")
        }
    } else {
        return BatchResult(index: index, command: "edit", title: nil, status: "error", message: "Missing 'title' or 'id'")
    }

    let result = executeEdit(
        store: ctx.store, calendar: calendar, target: target,
        newTitle: op.newTitle, dueStr: op.due, timeStr: op.time, newBody: op.body,
        dryRun: dryRun, skipVerify: skipVerify
    )
    ctx.invalidate(listName)
    return BatchResult(index: index, command: "edit", title: target.title, status: result.success ? "ok" : "error", message: result.message)
}

private func dispatchMove(
    index: Int, op: BatchOperation, ctx: inout BatchContext,
    skipVerify: Bool, dryRun: Bool
) -> BatchResult {
    guard let sourceListName = op.source, let targetListName = op.target else {
        return BatchResult(index: index, command: "move", title: op.title, status: "error", message: "Missing required fields: 'source' and 'target'")
    }
    guard let sourceCalendar = ctx.getList(sourceListName) else {
        return BatchResult(index: index, command: "move", title: op.title, status: "error", message: "Source list '\(sourceListName)' not found")
    }
    guard let targetCalendar = ctx.getList(targetListName) else {
        return BatchResult(index: index, command: "move", title: op.title, status: "error", message: "Target list '\(targetListName)' not found")
    }
    guard let sourceReminders = ctx.getReminders(for: sourceListName) else {
        return BatchResult(index: index, command: "move", title: op.title, status: "error", message: "Failed to fetch reminders for '\(sourceListName)'")
    }

    // Resolve source reminder
    let source: EKReminder
    if let id = op.id {
        guard let r = findReminderByIDOptional(in: sourceReminders, id: id) else {
            return BatchResult(index: index, command: "move", title: op.title, status: "error", message: "No reminder with id '\(id)'")
        }
        source = r
    } else if let title = op.title {
        switch lookupReminder(in: sourceReminders, title: title) {
        case .found(let r): source = r
        case .ambiguous(let matches):
            let ids = matches.map { "\"\(($0.title ?? "?"))\" (id: \($0.calendarItemExternalIdentifier ?? "?"))" }.joined(separator: ", ")
            return BatchResult(index: index, command: "move", title: title, status: "error", message: "Ambiguous match: \(ids)")
        case .notFound:
            return BatchResult(index: index, command: "move", title: title, status: "error", message: "No incomplete reminder matching '\(title)'")
        }
    } else {
        return BatchResult(index: index, command: "move", title: nil, status: "error", message: "Missing 'title' or 'id'")
    }

    let result = executeMove(
        store: ctx.store, sourceCalendar: sourceCalendar, targetCalendar: targetCalendar,
        source: source, dueStr: op.due, timeStr: op.time, body: op.body,
        dryRun: dryRun, skipVerify: skipVerify
    )
    ctx.invalidate(sourceListName)
    ctx.invalidate(targetListName)
    return BatchResult(index: index, command: "move", title: source.title, status: result.success ? "ok" : "error", message: result.message)
}

private func dispatchSetRecurrence(
    index: Int, op: BatchOperation, ctx: inout BatchContext,
    skipVerify: Bool, dryRun: Bool
) -> BatchResult {
    guard let listName = op.list else {
        return BatchResult(index: index, command: "set-recurrence", title: op.title, status: "error", message: "Missing required field: 'list'")
    }
    guard let frequencyStr = op.frequency else {
        return BatchResult(index: index, command: "set-recurrence", title: op.title, status: "error", message: "Missing required field: 'frequency'")
    }
    guard let calendar = ctx.getList(listName) else {
        return BatchResult(index: index, command: "set-recurrence", title: op.title, status: "error", message: "List '\(listName)' not found")
    }
    guard let reminders = ctx.getReminders(for: listName) else {
        return BatchResult(index: index, command: "set-recurrence", title: op.title, status: "error", message: "Failed to fetch reminders for '\(listName)'")
    }

    let frequencyMap: [String: EKRecurrenceFrequency] = [
        "daily": .daily, "weekly": .weekly, "monthly": .monthly, "yearly": .yearly,
    ]
    guard let frequency = frequencyMap[frequencyStr.lowercased()] else {
        return BatchResult(index: index, command: "set-recurrence", title: op.title, status: "error", message: "Invalid frequency '\(frequencyStr)'")
    }
    let interval = Int(op.interval ?? "1") ?? 1
    guard interval > 0 else {
        return BatchResult(index: index, command: "set-recurrence", title: op.title, status: "error", message: "Invalid interval")
    }

    // Resolve target
    let target: EKReminder
    if let id = op.id {
        guard let r = findReminderByIDOptional(in: reminders, id: id) else {
            return BatchResult(index: index, command: "set-recurrence", title: op.title, status: "error", message: "No reminder with id '\(id)'")
        }
        target = r
    } else if let title = op.title {
        switch lookupReminder(in: reminders, title: title) {
        case .found(let r): target = r
        case .ambiguous(let matches):
            let ids = matches.map { "\"\(($0.title ?? "?"))\" (id: \($0.calendarItemExternalIdentifier ?? "?"))" }.joined(separator: ", ")
            return BatchResult(index: index, command: "set-recurrence", title: title, status: "error", message: "Ambiguous match: \(ids)")
        case .notFound:
            return BatchResult(index: index, command: "set-recurrence", title: title, status: "error", message: "No incomplete reminder matching '\(title)'")
        }
    } else {
        return BatchResult(index: index, command: "set-recurrence", title: nil, status: "error", message: "Missing 'title' or 'id'")
    }

    let result = executeSetRecurrence(
        store: ctx.store, calendar: calendar, target: target,
        frequencyStr: frequencyStr, frequency: frequency, interval: interval,
        dryRun: dryRun, skipVerify: skipVerify
    )
    ctx.invalidate(listName)
    return BatchResult(index: index, command: "set-recurrence", title: target.title, status: result.success ? "ok" : "error", message: result.message)
}

private func dispatchDelete(
    index: Int, op: BatchOperation, ctx: inout BatchContext,
    skipVerify: Bool, dryRun: Bool
) -> BatchResult {
    guard let listName = op.list else {
        return BatchResult(index: index, command: "delete", title: op.title, status: "error", message: "Missing required field: 'list'")
    }
    guard let calendar = ctx.getList(listName) else {
        return BatchResult(index: index, command: "delete", title: op.title, status: "error", message: "List '\(listName)' not found")
    }
    guard let reminders = ctx.getReminders(for: listName) else {
        return BatchResult(index: index, command: "delete", title: op.title, status: "error", message: "Failed to fetch reminders for '\(listName)'")
    }

    // Resolve target
    let target: EKReminder
    if let id = op.id {
        guard let r = findReminderByIDOptional(in: reminders, id: id) else {
            return BatchResult(index: index, command: "delete", title: op.title, status: "error", message: "No reminder with id '\(id)'")
        }
        target = r
    } else if let title = op.title {
        switch lookupReminder(in: reminders, title: title) {
        case .found(let r): target = r
        case .ambiguous(let matches):
            let ids = matches.map { "\"\(($0.title ?? "?"))\" (id: \($0.calendarItemExternalIdentifier ?? "?"))" }.joined(separator: ", ")
            return BatchResult(index: index, command: "delete", title: title, status: "error", message: "Ambiguous match: \(ids)")
        case .notFound:
            return BatchResult(index: index, command: "delete", title: title, status: "error", message: "No incomplete reminder matching '\(title)'")
        }
    } else {
        return BatchResult(index: index, command: "delete", title: nil, status: "error", message: "Missing 'title' or 'id'")
    }

    let result = executeDelete(store: ctx.store, calendar: calendar, target: target, dryRun: dryRun, skipVerify: skipVerify)
    ctx.invalidate(listName)
    return BatchResult(index: index, command: "delete", title: target.title, status: result.success ? "ok" : "error", message: result.message)
}
