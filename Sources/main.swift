import Foundation

let version = "1.3.0"
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
case "edit", "update":
    runEdit(args: Array(args.dropFirst()))
case "set-recurrence":
    runSetRecurrence(args: Array(args.dropFirst()))
case "move":
    runMove(args: Array(args.dropFirst()))
case "delete":
    runDelete(args: Array(args.dropFirst()))
case "batch":
    runBatch(args: Array(args.dropFirst()))
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
                                  [--body TEXT | --body-file PATH | --notes TEXT] \\
                                  [--recurrence FREQ] [--interval N] [--force] [--dry-run]
      eventkit complete <list> <title> [--id ID] [--dry-run]
      eventkit move <source-list> <target-list> <title> [--id ID] [--due YYYY-MM-DD] [--time HH:MM] \\
                                                        [--body TEXT | --body-file PATH | --notes TEXT] [--dry-run]
      eventkit edit <list> <title> [--id ID] [--title NEW] [--due YYYY-MM-DD] [--time HH:MM] \\
                                   [--body TEXT | --body-file PATH | --notes TEXT] [--dry-run]
      eventkit set-recurrence <list> <title> <frequency> <interval> [--id ID] [--dry-run]
      eventkit delete <list> <title> [--id ID] [--dry-run]
      eventkit batch [--file PATH] [--skip-verify] [--dry-run]
      eventkit --version

    Aliases: 'update' = 'edit', '--notes' = '--body'
    Frequency: daily, weekly, monthly, yearly

    Use 'eventkit <command> --help' for per-command help.
    """
    print(usage)
}
