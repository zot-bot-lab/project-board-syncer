---
description: Sync tasks from a secondary project board to the main ZOT Team board
---

# Sync Project Boards

This workflow executes the `sync-boards.ps1` script to automatically sync tasks from secondary project boards across multiple GitHub organizations to the main **team-zeroone** (Project #31) board.

The script runs instantly and determines the current week, filters items, checks statuses, and manages all GitHub GraphQL API operations without agent interaction.

## Run Instruction

// turbo-all
1. Run the automated sync script using PowerShell:
   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts/sync-boards/sync-boards.ps1
   ```

## Dry Run (Preview Only)
To preview what changes would be made without modifying anything:
```powershell
powershell -ExecutionPolicy Bypass -File scripts/sync-boards/sync-boards.ps1 -DryRun
```
