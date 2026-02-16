# eventkit

A macOS CLI for Apple Reminders built directly on the EventKit framework. Designed for automation pipelines and AI agents where silent failures are unacceptable.

## Why This Exists

Existing Reminders CLIs work well for interactive use but fall short in automation:

- **Mutations can silently fail** — EventKit saves don't always persist (TCC revocation, iCloud sync conflicts). Most tools don't check.
- **Duplicate creation** — Automation scripts that run repeatedly can create the same reminder multiple times.
- **No dry-run** — Hard to test automation without actually modifying data.

eventkit addresses these with **post-save verification**, **dedup-safe adds**, and **dry-run on every mutation**.

## Features

- **6 commands**: `list`, `add`, `complete`, `edit`, `set-recurrence`, `delete`
- **Post-save verification**: Every mutation re-fetches from the store and confirms the change persisted
- **Dedup-safe adds**: Skips creation if an incomplete reminder with the same title exists (`--force` to override)
- **Dry-run on all mutations**: `--dry-run` previews what would happen without saving
- **Double-recurrence protection**: `set-recurrence` refuses to add a rule if one already exists
- **Structured JSON output**: `list --json` produces automation-friendly JSON
- **Body-file support**: `--body-file PATH` reads note content from a file — useful for piping multiline content
- **Zero external dependencies**: Only Foundation + EventKit. Builds anywhere with Xcode.
- **Distinct exit codes**: 0=success, 1=usage, 2=access denied, 3=list not found, 4=fetch failed, 5=reminder not found, 6=double recurrence, 7=save/verify failed

## Install

```bash
# Clone and install
git clone https://github.com/yourusername/eventkit-cli.git
cd eventkit-cli
make install

# Or manually
swift build -c release --build-path /tmp/eventkit-build
cp /tmp/eventkit-build/release/eventkit ~/.local/bin/
```

Requires macOS 14+ and Xcode command line tools. On first run, macOS will prompt for Reminders access.

## Usage

```bash
# List reminders
eventkit list "My List"
eventkit list "My List" --json
eventkit list "My List" --json --completed

# Add a reminder
eventkit add "My List" "Buy groceries"
eventkit add "My List" "File taxes" --due 2026-03-15 --body "Federal + state"
eventkit add "My List" "Weekly review" --due 2026-02-22 --time 10:00 --body-file notes.txt
eventkit add "My List" "Buy groceries" --dry-run  # preview only

# Complete a reminder
eventkit complete "My List" "Buy groceries"

# Edit fields selectively
eventkit edit "My List" "File taxes" --due 2026-04-01
eventkit edit "My List" "File taxes" --title "File 2025 taxes" --body "Updated notes"

# Set native recurrence
eventkit set-recurrence "My List" "Weekly review" weekly 1

# Delete a reminder
eventkit delete "My List" "Old reminder"
```

### Title Matching

Commands that target a reminder by title use a two-step match:
1. Exact match (case-sensitive)
2. Falls back to `localizedCaseInsensitiveContains` — first incomplete match wins

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

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Usage error (bad arguments) |
| 2 | Reminders access denied |
| 3 | List not found |
| 4 | Fetch failed |
| 5 | Reminder not found |
| 6 | Double recurrence (rule already exists) |
| 7 | Save or verification failed |

## License

MIT
