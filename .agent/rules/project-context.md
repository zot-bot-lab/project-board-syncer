---
description: Project context and configuration for project-board-syncer
---

# Project Board Syncer

This project contains agent workflows for project management automation across GitHub organizations.

## GitHub Organizations

| Role | Org Login | Notes |
|------|-----------|-------|
| **Main** (destination) | `team-zeroone` | Central project board — ZOT Team, project #31 |
| **Secondary** (source) | multiple orgs | Individual product boards — read-only sync sources |

## Project Boards

The main board and full list of secondary boards (org, project number, cached GraphQL IDs)
live in `scripts/sync-boards/sync-config.json` — treat that file as the single source of
truth. Do not duplicate the board list here; it changes often and a second copy will drift.

## Project Structure

- **`.agent/rules/`** — AI agent rules & context
- **`.agent/workflows/`** — Slash command definitions (triggers only)
- **`scripts/`** — All executable automation scripts and their configs
- **`changelogs/`** — Auto-generated run logs per workflow
- **`README.md`** — Project documentation

## Important Rules

1. **Never delete items** on any project board.
2. **Never modify** the secondary boards — they are read-only for sync purposes.
3. **Statuses** across all boards: see `validStatuses` in `sync-config.json` (the canonical list).
4. **Iteration field** is named "Week" on all boards.
5. **When adding a new workflow** (not just a board — boards only need a `sync-config.json` entry), update `README.md` at the project root to describe it.

