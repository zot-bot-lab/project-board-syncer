# Project Board Syncer

A collection of automated workflows for managing GitHub Project Boards across multiple organizations.

## Available Workflows

### `/sync-boards` - Project Board Sync
Syncs tasks from the secondary project boards listed in `sync-config.json` to the main **team-zeroone** (#31) board. That file is the single source of truth for which boards are synced — this README does not duplicate the list.

**Run manually:**
```powershell
powershell -ExecutionPolicy Bypass -File scripts/sync-boards/sync-boards.ps1
```

**Dry run (preview without changes):**
```powershell
powershell -ExecutionPolicy Bypass -File scripts/sync-boards/sync-boards.ps1 -DryRun
```

**Full backfill (sync ALL tickets, ignoring week filter — run once):**
```powershell
powershell -ExecutionPolicy Bypass -File scripts/sync-boards/sync-boards.ps1 -FullSync
```
> Combine with `-DryRun` to preview first: `... -FullSync -DryRun`
> A rollback manifest is saved automatically to `changelogs/full-sync-manifest.json`.

**Rollback last full backfill (emergency revert):**
```powershell
powershell -ExecutionPolicy Bypass -File scripts/sync-boards/sync-boards.ps1 -RollbackFullSync
```
> Only reverts tickets affected by the last `-FullSync` run. Deletes the manifest after success.
> Preview with `-RollbackFullSync -DryRun` before committing.

**What it syncs:** Status, Week (iteration), Priority, Size, Estimate, Start date, Target date (→ End date)

**Config:** `scripts/sync-boards/sync-config.json`

**Run logs:** `changelogs/sync-boards.md`

### Features
- **Smart iteration mapping** — Maps secondary board sprints to the exact matching sprint on the main board (current + recent past sprints within 14 days)
- **Batched GraphQL mutations** — Multiple field updates per item are sent in a single API call
- **Dry-run mode** — Preview all changes without modifying anything (`-DryRun` flag)
- **Full-sync mode** — One-time backfill that bypasses the week filter and syncs every item with a valid status (`-FullSync` flag)
- **Rollback support** — Reverts only the tickets affected by the last `-FullSync` using an auto-saved manifest (`-RollbackFullSync` flag)
- **Rate limit awareness** — Pre-checks GitHub API budget before starting
- **Automatic retry** — Retries transient API failures and rate-limit errors
- **ID caching** — Caches project IDs in config to avoid redundant lookups
- **Clean changelogs** — Only logs additions, updates, and failures; skipped items are summarized by count
- **Auto-cleanup** — Old changelog entries are pruned after 14 days (configurable)

### CI/CD
Runs automatically via GitHub Actions on weekdays at **11:00 AM** and **5:00 PM** (Asia/Colombo).
Can also be triggered manually via `workflow_dispatch`.

## Project Structure
```
project-board-syncer/
├── .agent/
│   ├── rules/          # AI agent rules & context
│   └── workflows/      # Slash command definitions
├── .github/
│   └── workflows/      # GitHub Actions CI definitions
├── changelogs/          # Auto-generated run logs per workflow
├── scripts/
│   └── sync-boards/    # Sync engine + config
└── README.md
```
