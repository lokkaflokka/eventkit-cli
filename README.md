# eventkit

A macOS CLI for Apple Reminders built directly on the EventKit framework. Designed for automation pipelines and AI agents where silent failures are unacceptable.

## Why This Exists

Existing Reminders CLIs work well for interactive use but fall short in automation:

- **Mutations can silently fail** — EventKit saves don't always persist (TCC revocation, iCloud sync conflicts). Most tools don't check.
- **Duplicate creation** — Automation scripts that run repeatedly can create the same reminder multiple times.
- **No dry-run** — Hard to test automation without actually modifying data.

eventkit addresses these with **post-save verification**, **dedup-safe adds**, and **dry-run on every mutation**.

## Features

- **8 commands**: `list`, `add`, `complete`, `move`, `edit`, `set-recurrence`, `delete`, `batch`
- **Batch mode**: Execute multiple operations in a single process with shared auth and cached fetches
- **Post-save verification**: Every mutation re-fetches from the store and confirms the change persisted
- **Ambiguity detection**: Fuzzy title matching lists all candidates with IDs when multiple reminders match
- **ID-based targeting**: `--id` flag on mutation commands for precise reminder selection
- **Dedup-safe adds**: Skips creation if an incomplete reminder with the same title exists (`--force` to override)
- **Dry-run on all mutations**: `--dry-run` previews what would happen without saving
- **Double-recurrence protection**: `set-recurrence` refuses to add a rule if one already exists
- **Date-range filtering**: `list --due-before` / `--due-after` for scoped queries (day-level, composable)
- **Cross-list move**: `move` atomically creates in target + completes in source with verification
- **Structured JSON output**: `list --json` produces automation-friendly JSON
- **Body-file support**: `--body-file PATH` reads note content from a file — useful for piping multiline content
- **Per-command help**: `eventkit <command> --help` for detailed usage
- **Zero external dependencies**: Only Foundation + EventKit. Builds anywhere with Xcode.
- **Distinct exit codes**: 0=success, 1=usage, 2=access denied, 3=list not found, 4=fetch failed, 5=reminder not found or ambiguous match, 6=double recurrence, 7=save/verify failed

## Install

```bash
# Homebrew
brew install lokkaflokka/tap/eventkit-cli

# Or from source
git clone https://github.com/lokkaflokka/eventkit-cli.git
cd eventkit-cli
make install
```

Requires macOS 14+ and Xcode command line tools. On first run, macOS will prompt for Reminders access.

## Usage

```bash
# List reminders
eventkit list "My List"
eventkit list "My List" --json
eventkit list "My List" --json --completed
eventkit list "My List" --due-before 2026-02-20      # items due Feb 19 or earlier
eventkit list "My List" --due-after 2026-02-16       # items due Feb 17 or later
eventkit list "My List" --due-before 2026-02-23 --due-after 2026-02-16  # date range

# Add a reminder
eventkit add "My List" "Buy groceries"
eventkit add "My List" "File taxes" --due 2026-03-15 --notes "Federal + state"
eventkit add "My List" "Weekly review" --due 2026-02-22 --time 10:00 --body-file notes.txt
eventkit add "My List" "Buy groceries" --dry-run  # preview only

# Complete a reminder
eventkit complete "My List" "Buy groceries"
eventkit complete "My List" --id "ABC123-..."       # by ID

# Move between lists (atomic: create in target + complete in source)
eventkit move Inbox Personal "Buy groceries" --due 2026-02-20
eventkit move Inbox Strategic "Review proposal" --notes "Updated context"
eventkit move Inbox Personal --id "ABC123-..."      # by ID

# Edit fields selectively (alias: 'update')
eventkit edit "My List" "File taxes" --due 2026-04-01
eventkit edit "My List" --id "ABC123-..." --title "File 2025 taxes" --notes "Updated"
eventkit update "My List" "File taxes" --body "Same as edit"

# Set native recurrence
eventkit set-recurrence "My List" "Weekly review" weekly 1

# Delete a reminder
eventkit delete "My List" "Old reminder"
eventkit delete "My List" --id "ABC123-..."

# Batch mode — multiple operations, single process
echo '[
  {"command": "move", "source": "Inbox", "target": "Personal", "title": "Item", "due": "2026-02-28"},
  {"command": "complete", "list": "Strategic", "title": "Task done"},
  {"command": "add", "list": "Personal", "title": "New item", "body": "Details"}
]' | eventkit batch

eventkit batch --file /tmp/ops.json --dry-run       # preview from file
eventkit batch --file /tmp/ops.json --skip-verify    # faster, skip re-fetch verification

# Per-command help
eventkit complete --help
eventkit batch --help
```

### Aliases

- `update` = `edit` (same command)
- `--notes` = `--body` (on `add`, `edit`, `move`)

### Title Matching

Commands that target a reminder by title use a two-step match:
1. Exact match (case-sensitive)
2. Falls back to `localizedCaseInsensitiveContains` — if exactly one incomplete match, it's used

If multiple reminders match the fuzzy search, eventkit lists all candidates with their IDs and exits 5. Use `--id` to target a specific one.

### ID-Based Targeting

All mutation commands accept `--id ID` to target a reminder by its `calendarItemExternalIdentifier` instead of title. When `--id` is provided, the title argument becomes optional. Get IDs from `eventkit list <list> --json`.

### Batch Mode

The `batch` command reads a JSON array of operations from stdin (or `--file PATH`) and executes them in a single process. Benefits:
- **Single auth**: One EventKit authorization instead of N
- **Cached fetches**: Reminder lists are fetched once and reused (invalidated after mutations)
- **Best-effort**: Continues on failure; each operation independent
- **JSON output**: Structured results for each operation

Flags: `--skip-verify` (skip re-fetch verification), `--dry-run`, `--file PATH`

### Recurrence Frequencies

`set-recurrence` supports: `daily`, `weekly`, `monthly`, `yearly` with an interval (e.g., `weekly 2` = every 2 weeks).

## JSON Schema

`eventkit list <list> --json` outputs:

```json
[
  {
    "dueDate": "2026-02-22T15:00:00Z",
    "id": "ABC123-...",
    "isCompleted": false,
    "listID": "DEF456-...",
    "listName": "My List",
    "notes": "Some notes here",
    "priority": "none",
    "title": "Weekly review"
  }
]
```

- `dueDate`: ISO 8601 UTC. Omitted when no due date is set.
- `completionDate`: Only present on completed items (requires `--completed` flag).
- `notes`: Omitted when empty.
- `priority`: `"none"`, `"high"`, `"medium"`, or `"low"`.

### Batch Output

`eventkit batch` outputs:

```json
[
  {"index": 0, "command": "move", "title": "Item", "status": "ok", "message": "Moved..."},
  {"index": 1, "command": "complete", "title": "Task done", "status": "error", "message": "Not found"}
]
```

Exit code: 0 if all operations succeed, 7 if any failed.

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Usage error (bad arguments) |
| 2 | Reminders access denied |
| 3 | List not found |
| 4 | Fetch failed |
| 5 | Reminder not found or ambiguous match |
| 6 | Double recurrence (rule already exists) |
| 7 | Save or verification failed |

## License

MIT
