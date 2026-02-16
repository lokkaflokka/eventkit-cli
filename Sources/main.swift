import Foundation

let version = "1.2.0"
let args = Array(CommandLine.arguments.dropFirst())

guard let command = args.first else {
    printUsage()
    exit(1)
}

switch command {
case "list":
    runList(args: Array(args.dropFirst()))
case "add":
    runAdd(args: Array(args.dropFirst()))
case "complete":
    runComplete(args: Array(args.dropFirst()))
case "edit":
    runEdit(args: Array(args.dropFirst()))
case "set-recurrence":
    runSetRecurrence(args: Array(args.dropFirst()))
case "move":
    runMove(args: Array(args.dropFirst()))
case "delete":
    runDelete(args: Array(args.dropFirst()))
case "--version":
    print("eventkit \(version)")
case "--help", "-h":
    printUsage()
default:
    stderrPrint("Unknown command: \(command)")
    printUsage()
    exit(1)
}

func printUsage() {
    let usage = """
    eventkit \u{2014} Apple Reminders CLI via EventKit

    Usage:
      eventkit list <list> [--json] [--completed] [--due-before YYYY-MM-DD] [--due-after YYYY-MM-DD]
      eventkit add <list> <title> [--due YYYY-MM-DD] [--time HH:MM] \\
                                  [--body TEXT | --body-file PATH] \\
                                  [--recurrence FREQ] [--interval N] [--force] [--dry-run]
      eventkit complete <list> <title> [--dry-run]
      eventkit move <source-list> <target-list> <title> [--due YYYY-MM-DD] [--time HH:MM] \\
                                                        [--body TEXT | --body-file PATH] [--dry-run]
      eventkit edit <list> <title> [--title NEW] [--due YYYY-MM-DD] [--time HH:MM] \\
                                   [--body TEXT | --body-file PATH] [--dry-run]
      eventkit set-recurrence <list> <title> <frequency> <interval> [--dry-run]
      eventkit delete <list> <title> [--dry-run]
      eventkit --version

    Frequency: daily, weekly, monthly, yearly
    """
    print(usage)
}
