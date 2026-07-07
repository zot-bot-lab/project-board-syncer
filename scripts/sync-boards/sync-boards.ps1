<#
.SYNOPSIS
Syncs GitHub Project Board tasks from multiple secondary boards to one main board.

.DESCRIPTION
Reads sync-config.json, fetches the main board data ONCE, then loops over each
secondary board to sync items. Supports Status, Week, Priority, Size, Estimate,
Start date, and Target date -> End date mapping.

Optimizations:
- Caches the main project GraphQL ID (PVT_) in sync-config.json after first fetch
- Pre-checks GitHub API rate limit before starting
- Retries transient API failures once before giving up
- Batches every field update for an item into a single aliased GraphQL mutation
- Smart iteration mapping with completed iterations support

.PARAMETER DryRun
When specified, the script runs all comparison logic but skips any write operations
(item-add, item-edit). Useful for previewing what changes would be made.

.PARAMETER FullSync
When specified, the week/iteration filter is bypassed and ALL items with valid statuses
are synced from every secondary board to the main board. Use once for a full backfill.

.PARAMETER Rollback
Reverts the most recent live (non-DryRun) run - regular or full sync - using the saved
manifest. Removes items that were added and restores previous field values for items
that were updated. Deletes the manifest after a successful rollback.
-RollbackFullSync is accepted as a legacy alias for the same switch.
#>

param(
    [switch]$DryRun,
    [switch]$FullSync,
    [Alias("RollbackFullSync")]
    [switch]$Rollback
)

$ErrorActionPreference = "Stop"
$GH = if (Get-Command "gh" -ErrorAction SilentlyContinue) {
    "gh"
} elseif (Test-Path "C:\Program Files\GitHub CLI\gh.exe") {
    "C:\Program Files\GitHub CLI\gh.exe"
} else {
    Write-Error "GitHub CLI ('gh') was not found on PATH or at the default Windows install location. Install it from https://cli.github.com/ and run 'gh auth login'."
    exit 1
}
$MAX_RETRIES = 1

if ($DryRun) {
    Write-Host "[DRY-RUN] Mode enabled - no changes will be made to GitHub.`n" -ForegroundColor Cyan
}
if ($FullSync) {
    Write-Host "[FULL-SYNC] Mode enabled - ALL items with valid statuses will be synced (no week filter).`n" -ForegroundColor Magenta
}
if ($Rollback) {
    Write-Host "[ROLLBACK] Mode enabled - will revert the last live sync run using the saved manifest.`n" -ForegroundColor Yellow
}

# --- Load Config ---
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $scriptDir "SyncBoards.Helpers.psm1") -Force
$configPath = Join-Path $scriptDir "sync-config.json"
if (-not (Test-Path $configPath)) {
    Write-Error "Config file not found: $configPath"
    exit 1
}
$config = Get-Content -Raw $configPath | ConvertFrom-Json

$MainOrg = $config.mainBoard.org
$MainProjNum = $config.mainBoard.projectNumber
$ValidStatuses = $config.validStatuses
$today = Get-Date

# ============================================================
# Rate Limit Pre-Check
# ============================================================
Write-Host "[PRE] Checking GitHub API rate limit..."
try {
    $rateLimitJson = & $GH api graphql -f query='{ rateLimit { remaining resetAt } }' | ConvertFrom-Json
    $remaining = $rateLimitJson.data.rateLimit.remaining
    $resetAt = [datetime]::Parse($rateLimitJson.data.rateLimit.resetAt).ToLocalTime()
    Write-Host "[PRE] Rate limit: $remaining points remaining (resets at $($resetAt.ToString('HH:mm')))"

    # Realistic budget: ~5 calls for setup, plus a per-board estimate. Batched writes mean
    # a touched item now costs ~1-2 calls instead of up to 8, but -FullSync touches far more
    # items per board (a full backfill, not just the current/last week), so it gets a higher
    # per-board allowance.
    $perBoardEstimate = if ($FullSync) { 60 } else { 20 }
    $minRequired = 50 + ($config.secondaryBoards.Count * $perBoardEstimate)
    if ($remaining -lt $minRequired) {
        Write-Error "Insufficient API quota ($remaining remaining, need ~$minRequired). Resets at $($resetAt.ToString('HH:mm')). Try again later."
        exit 1
    }
} catch {
    Write-Warning "Could not check rate limit. Proceeding anyway..."
}

# ============================================================
# Retry Helper
# ============================================================
# Sets $script:LastGHSucceeded so callers using -SuppressError can still tell whether
# the call actually worked, without a warning being printed for expected-failure paths
# (e.g. probing for a concurrent add).
function Invoke-GHWithRetry {
    param(
        [string[]]$Arguments,
        [switch]$JsonOutput,
        [switch]$SuppressError
    )
    $script:LastGHSucceeded = $true
    for ($attempt = 0; $attempt -le $MAX_RETRIES; $attempt++) {
        try {
            $output = & $GH @Arguments 2>&1
            $stderr = $output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }
            $stdout = $output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }

            if ($stderr) {
                $errMsg = ($stderr | ForEach-Object { $_.ToString() }) -join "`n"
                $isRateLimit = $errMsg -match "rate limit"
                if ($attempt -lt $MAX_RETRIES) {
                    $waitSecs = if ($isRateLimit) { 5 } else { 3 }
                    $reason = if ($isRateLimit) { "Rate limited" } else { "API error" }
                    Write-Host "      $reason, retrying in ${waitSecs}s... ($errMsg)" -ForegroundColor Yellow
                    Start-Sleep -Seconds $waitSecs
                    continue
                }
                $script:LastGHSucceeded = $false
                if (-not $SuppressError) { Write-Warning "      GH command failed: $errMsg" }
            }

            if ($JsonOutput) {
                $joined = ($stdout | ForEach-Object { $_.ToString() }) -join "`n"
                if ($joined) { return $joined | ConvertFrom-Json }
                return $null
            } else {
                return ($stdout | ForEach-Object { $_.ToString() }) -join "`n"
            }
        } catch {
            if ($attempt -lt $MAX_RETRIES) {
                Write-Host "      Transient error, retrying in 3s..." -ForegroundColor Yellow
                Start-Sleep -Seconds 3
                continue
            }
            $script:LastGHSucceeded = $false
            if (-not $SuppressError) { throw }
            return $null
        }
    }
}

# Applies every field update for one item as a single aliased GraphQL mutation instead
# of one `gh project item-edit` call per field.
function Invoke-BatchedFieldUpdate {
    param($ItemId, $ProjectId, $Updates)
    $updateList = @($Updates)
    if ($updateList.Count -eq 0) { return $true }

    $mutation = New-ItemFieldUpdateMutation -Updates $updateList
    $mutFile = [System.IO.Path]::GetTempFileName()
    try {
        $mutation | Set-Content -Path $mutFile -Encoding UTF8
        $result = Invoke-GHWithRetry -Arguments @("api", "graphql", "-F", "query=@$mutFile", "-F", "projectId=$ProjectId", "-F", "itemId=$ItemId") -JsonOutput -SuppressError
        if (-not $script:LastGHSucceeded -or -not $result -or -not $result.data) {
            Write-Warning "      Failed to apply $($updateList.Count) field update(s) for item $ItemId"
            return $false
        }
        return $true
    } finally {
        if (Test-Path $mutFile) { Remove-Item $mutFile }
    }
}

# ============================================================
# ROLLBACK: Execute and exit early if -Rollback
# ============================================================
if ($Rollback) {
    $repoRootForRollback = Split-Path -Parent (Split-Path -Parent $scriptDir)
    $manifestPath = Join-Path (Join-Path $repoRootForRollback "changelogs") "last-sync-manifest.json"
    if (-not (Test-Path $manifestPath)) {
        Write-Error "No sync manifest found at: $manifestPath`nRun a live sync first to generate one."
        exit 1
    }
    $manifest = Get-Content -Raw $manifestPath | ConvertFrom-Json
    $rbOrg     = $manifest.mainOrg
    $rbProjNum = $manifest.mainProjNum
    $rbProjId  = $manifest.mainProjId
    $rbMode    = if ($manifest.mode) { $manifest.mode } else { "Unknown" }
    Write-Host "[ROLLBACK] Manifest from: $($manifest.timestamp) (mode: $rbMode)" -ForegroundColor Yellow
    Write-Host "[ROLLBACK] Reverting $($manifest.entries.Count) change(s) on $rbOrg (#$rbProjNum)...`n" -ForegroundColor Yellow
    $rvAdd = 0; $rvUpd = 0; $rvFail = 0
    foreach ($entry in $manifest.entries) {
        if ($entry.action -eq "add") {
            Write-Host "  [REMOVE] $($entry.title)"
            if ($DryRun) {
                Write-Host "    [DRY-RUN] Would delete item: $($entry.itemId)" -ForegroundColor Cyan
                $rvAdd++
            } else {
                Invoke-GHWithRetry -Arguments @("project", "item-delete", "$rbProjNum", "--owner", $rbOrg, "--id", $entry.itemId) -SuppressError | Out-Null
                if ($script:LastGHSucceeded) { $rvAdd++ } else { $rvFail++; Write-Warning "    Failed to remove: $($entry.title)" }
            }
        } elseif ($entry.action -eq "update") {
            Write-Host "  [RESTORE] $($entry.title)"
            if ($DryRun) {
                Write-Host "    [DRY-RUN] Would restore $($entry.previousValues.Count) field(s)" -ForegroundColor Cyan
                $rvUpd++
            } else {
                $restored = Invoke-BatchedFieldUpdate -ItemId $entry.itemId -ProjectId $rbProjId -Updates $entry.previousValues
                if ($restored) { $rvUpd++ } else { $rvFail++; Write-Warning "    Failed to restore: $($entry.title)" }
            }
        }
    }
    Write-Host ""
    Write-Host "============================================"
    if ($DryRun) { Write-Host "  ROLLBACK COMPLETE (DRY RUN)" } else { Write-Host "  ROLLBACK COMPLETE" }
    Write-Host "  Removed (adds rolled back): $rvAdd"
    Write-Host "  Restored (updates rolled back): $rvUpd"
    Write-Host "  Failed: $rvFail"
    Write-Host "============================================"
    if (-not $DryRun) {
        Remove-Item $manifestPath -Force
        Write-Host "`n[ROLLBACK] Manifest deleted. The slate is clean." -ForegroundColor Green
    }
    exit 0
}

Write-Host "`n============================================"
Write-Host "  Multi-Board Sync to $MainOrg (#$MainProjNum)"
Write-Host "  $($config.secondaryBoards.Count) secondary board(s) configured"
Write-Host "============================================`n"

# ============================================================
# PHASE A: Fetch main board data ONCE
# ============================================================

# --- Resolve Main Project ID (cached in config) ---
$mainProjId = $config.mainBoard.projectId
if (-not $mainProjId) {
    Write-Host "[MAIN] Resolving project ID (first run, will be cached)..."
    $mainProjIdJson = Invoke-GHWithRetry -Arguments @("project", "list", "--owner", $MainOrg, "--format", "json") -JsonOutput
    $mainProjId = ($mainProjIdJson.projects | Where-Object { $_.number -eq $MainProjNum }).id

    if (-not $mainProjId) {
        Write-Error "Could not resolve project ID for $MainOrg #$MainProjNum"
        exit 1
    }

    # Cache it in sync-config.json
    $config.mainBoard | Add-Member -NotePropertyName "projectId" -NotePropertyValue $mainProjId -Force
    $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath -Encoding UTF8
    Write-Host "[MAIN] Cached project ID: $mainProjId"
} else {
    Write-Host "[MAIN] Using cached project ID: $mainProjId"
}

Write-Host "[MAIN] Fetching main board metadata..."
$mainFieldsJson = Invoke-GHWithRetry -Arguments @("project", "field-list", "$MainProjNum", "--owner", $MainOrg, "--format", "json") -JsonOutput
if (-not $mainFieldsJson) {
    Write-Error "Failed to fetch main board fields."
    exit 1
}

$mainStatusField    = $mainFieldsJson.fields | Where-Object { $_.name -eq "Status" }
$mainWeekField      = $mainFieldsJson.fields | Where-Object { $_.name -eq "Week" }
$mainPriorityField  = $mainFieldsJson.fields | Where-Object { $_.name -eq "Priority" }
$mainSizeField      = $mainFieldsJson.fields | Where-Object { $_.name -eq "Size" }
$mainEstimateField  = $mainFieldsJson.fields | Where-Object { $_.name -eq "Estimate" }
$mainStartDateField = $mainFieldsJson.fields | Where-Object { $_.name -eq "Start date" }
$mainEndDateField   = $mainFieldsJson.fields | Where-Object { $_.name -eq "End date" }

if (-not $mainStatusField -or -not $mainWeekField) {
    Write-Error "Missing required fields (Status/Week) on the main board."
    exit 1
}

# Custom GraphQL item fetcher - much cheaper than gh project item-list
$itemsQuery = @"
query(`$id: ID!, `$cursor: String) {
  node(id: `$id) {
    ... on ProjectV2 {
      items(first: 100, after: `$cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          content {
            ... on Issue { url title }
            ... on PullRequest { url title }
          }
          fieldValues(first: 20) {
            pageInfo { hasNextPage }
            nodes {
              ... on ProjectV2ItemFieldSingleSelectValue {
                name
                field { ... on ProjectV2SingleSelectField { name } }
              }
              ... on ProjectV2ItemFieldIterationValue {
                iterationId
                title
                startDate
                duration
                field { ... on ProjectV2IterationField { name } }
              }
              ... on ProjectV2ItemFieldNumberValue {
                number
                field { ... on ProjectV2Field { name } }
              }
              ... on ProjectV2ItemFieldDateValue {
                date
                field { ... on ProjectV2Field { name } }
              }
            }
          }
        }
      }
    }
  }
}
"@

function Fetch-ProjectItems {
    param($projId, $label)
    $allItems = [System.Collections.Generic.List[hashtable]]::new()
    $cursor = $null
    $page = 0

    $queryFile = [System.IO.Path]::GetTempFileName()
    try {
        $itemsQuery | Set-Content -Path $queryFile

        do {
            $page++
            $apiArgs = @("api", "graphql", "-F", "id=$projId", "-F", "query=@$queryFile")
            if ($cursor) { $apiArgs += @("-F", "cursor=$cursor") }

            $result = Invoke-GHWithRetry -Arguments $apiArgs -JsonOutput
            if (-not $result -or -not $result.data) {
                Write-Warning "  Failed to fetch $label items page $page."
                break
            }

            $itemsData = $result.data.node.items
            foreach ($node in $itemsData.nodes) {
                $itemUrl = $null
                $itemTitle = $null
                if ($node.content) {
                    if ($node.content.url) { $itemUrl = $node.content.url }
                    if ($node.content.title) { $itemTitle = $node.content.title }
                }
                $item = @{ id = $node.id; url = $itemUrl; title = $itemTitle }

                if ($node.fieldValues.pageInfo.hasNextPage) {
                    Write-Warning "  Item '$itemTitle' in $label has more than 20 tracked fields - some field values may not be synced."
                }

                # Parse field values
                foreach ($fv in $node.fieldValues.nodes) {
                    if (-not $fv.field) { continue }
                    $fname = $fv.field.name
                    switch ($fname) {
                        "Status"     { $item.status = $fv.name }
                        "Priority"   { $item.priority = $fv.name }
                        "Size"       { $item.size = $fv.name }
                        "Week"       { $item.week = @{ iterationId = $fv.iterationId; title = $fv.title; startDate = $fv.startDate; duration = $fv.duration } }
                        "Estimate"   { $item.estimate = $fv.number }
                        "Start date" { $item.'start date' = $fv.date }
                        "End date"   { $item.'end date' = $fv.date }
                        "Target date" { $item.'target date' = $fv.date }
                    }
                }
                $allItems.Add($item)
            }

            $cursor = if ($itemsData.pageInfo.hasNextPage) { $itemsData.pageInfo.endCursor } else { $null }
        } while ($cursor)
    } finally {
        if (Test-Path $queryFile) { Remove-Item $queryFile }
    }
    return $allItems
}

# Fetch main board items via optimized GraphQL
Write-Host "[MAIN] Fetching main board items (GraphQL)..."
$mainItems = Fetch-ProjectItems $mainProjId "main board"
Write-Host "[MAIN] Fetched $($mainItems.Count) items."

$mainUrlMap = @{}
foreach ($i in $mainItems) {
    if ($i.url) { $mainUrlMap[$i.url] = $i }
}

# Fetch main board iteration config via GraphQL
Write-Host "[MAIN] Resolving current week iteration..."
$graphqlQuery = @"
query(`$id: ID!) {
  node(id: `$id) {
    ... on ProjectV2 {
      field(name: `"Week`") {
        ... on ProjectV2IterationField {
          configuration {
            iterations { id title startDate duration }
            completedIterations { id title startDate duration }
          }
        }
      }
    }
  }
}
"@
$graphqlQueryFile = [System.IO.Path]::GetTempFileName()
try {
    $graphqlQuery | Set-Content -Path $graphqlQueryFile
    $mainWeekConfigJson = Invoke-GHWithRetry -Arguments @("api", "graphql", "-F", "id=$mainProjId", "-F", "query=@$graphqlQueryFile") -JsonOutput
} finally {
    if (Test-Path $graphqlQueryFile) { Remove-Item $graphqlQueryFile }
}

if (-not $mainWeekConfigJson -or -not $mainWeekConfigJson.data) {
    Write-Error "Failed to fetch iteration data from main board."
    exit 1
}

$mainWeekConfig = @()
if ($mainWeekConfigJson.data.node.field.configuration.iterations) {
    $mainWeekConfig += $mainWeekConfigJson.data.node.field.configuration.iterations
}
if ($mainWeekConfigJson.data.node.field.configuration.completedIterations) {
    $mainWeekConfig += $mainWeekConfigJson.data.node.field.configuration.completedIterations
}
$targetIterationId = $null
$targetIterationTitle = $null
foreach ($mIter in $mainWeekConfig) {
    if ($mIter.startDate) {
        $mStart = [datetime]::Parse($mIter.startDate)
        $mEnd = $mStart.AddDays($mIter.duration)
        if ($today -ge $mStart -and $today -le $mEnd) {
            $targetIterationId = $mIter.id
            $targetIterationTitle = $mIter.title
            break
        }
    }
}

if (-not $targetIterationId) {
    Write-Warning "No iteration on the main board encompasses today's date. Iteration field won't be set."
} else {
    Write-Host "[MAIN] Current iteration: $targetIterationTitle"
}

Write-Host "[MAIN] Setup complete. $($mainItems.Count) items cached.`n"

# ============================================================
# PHASE B: Loop over each secondary board
# ============================================================
$totalAdded = 0
$totalUpdated = 0
$totalSkipped = 0
$runLog = [System.Collections.Generic.List[string]]::new()

# Manifest tracking: built for any live (non-dry-run) run, regular or full, so a
# -Rollback is always available for whatever the last live run did.
$repoRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
$manifestPath = Join-Path (Join-Path $repoRoot "changelogs") "last-sync-manifest.json"
$syncManifest = if (-not $DryRun) { [System.Collections.Generic.List[hashtable]]::new() } else { $null }

try {
for ($bi = 0; $bi -lt $config.secondaryBoards.Count; $bi++) {
    $board = $config.secondaryBoards[$bi]
    $secOrg = $board.org
    $secNum = $board.projectNumber

    try {
        # Resolve secondary board project ID and Name (cached in config)
        $secProjId = $board.projectId
        $secProjName = $board.projectName
        if (-not $secProjId -or -not $secProjName) {
            Write-Host "  Resolving project Name/ID for $secOrg (#$secNum) (will be cached)..."
            $secProjListJson = Invoke-GHWithRetry -Arguments @("project", "list", "--owner", $secOrg, "--format", "json") -JsonOutput
            $secProj = $secProjListJson.projects | Where-Object { $_.number -eq $secNum }

            if (-not $secProj) {
                Write-Host "--------------------------------------------"
                Write-Host "  Board $($bi + 1)/$($config.secondaryBoards.Count): $secOrg (#$secNum)"
                Write-Host "--------------------------------------------"
                Write-Warning "  Could not resolve project for $secOrg #$secNum. Skipping."
                continue
            }
            if (-not $secProjId) {
                $secProjId = $secProj.id
                $board | Add-Member -NotePropertyName "projectId" -NotePropertyValue $secProjId -Force
            }
            if (-not $secProjName) {
                $secProjName = $secProj.title
                $board | Add-Member -NotePropertyName "projectName" -NotePropertyValue $secProjName -Force
            }
            $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath -Encoding UTF8
        }

        if (-not $secProjName) { $secProjName = "$secOrg (#$secNum)" }

        Write-Host "--------------------------------------------"
        Write-Host "  Board $($bi + 1)/$($config.secondaryBoards.Count): $secProjName"
        Write-Host "--------------------------------------------"

        # Fetch secondary items via optimized GraphQL
        Write-Host "  Fetching items (GraphQL)..."
        $secItems = Fetch-ProjectItems $secProjId $secProjName

        # Detect current week and previous week on this secondary board
        $weekWindow = Get-WeekWindow -Items $secItems -Today $today -RecentPastDays 14
        $currentWeekTitle = $weekWindow.current
        $previousWeekTitle = $weekWindow.previous

        # Filter items
        $itemsToSync = [System.Collections.Generic.List[hashtable]]::new()

        if ($FullSync) {
            # Full backfill: sync every item with a valid status, regardless of week
            Write-Host "  [FULL-SYNC] Including all items (no week filter)."
            foreach ($item in $secItems) {
                if ($item.status -in $ValidStatuses -and $item.url) {
                    $item.isLastWeek = $false
                    $itemsToSync.Add($item)
                }
            }
        } else {
            if (-not $currentWeekTitle) {
                Write-Host "  No items found in the current week. Skipping.`n"
                $runLog.Add("")
                $runLog.Add("#### $secProjName - Skipped")
                $runLog.Add("*No items found in the current week.*")
                continue
            }
            Write-Host "  Current iteration: $currentWeekTitle"
            foreach ($item in $secItems) {
                $isAlreadyInMain = if ($item.url) { $mainUrlMap.ContainsKey($item.url) } else { $false }
                $scope = Get-ItemSyncScope -Item $item -CurrentWeekTitle $currentWeekTitle -PreviousWeekTitle $previousWeekTitle -IsAlreadyInMain $isAlreadyInMain -ValidStatuses $ValidStatuses
                if ($scope.inScope) {
                    $item.isLastWeek = $scope.isLastWeek
                    # Items included only because they're already on the main board (not in current/last week)
                    # should NOT have their iteration updated
                    $item | Add-Member -NotePropertyName 'isOrphan' -NotePropertyValue $scope.isOrphan -Force
                    $itemsToSync.Add($item)
                }
            }
        }

        Write-Host "  Items to sync: $($itemsToSync.Count)"
        if ($itemsToSync.Count -eq 0) {
            Write-Host ""
            $runLog.Add("")
            $runLog.Add("#### $secProjName - Skipped")
            $runLog.Add("*No items with valid statuses in current week.*")
            continue
        }

        # Sync each item
        $boardAdded = 0
        $boardUpdated = 0
        $boardSkipped = 0

        foreach ($sItem in $itemsToSync) {
            $url = $sItem.url
            $title = $sItem.title
            $mItem = $mainUrlMap[$url]
            $isNew = (-not $mItem)

            $updates = [System.Collections.Generic.List[Hashtable]]::new()

            # 1. Status (with option ID validation)
            $tid = $null
            if ($sItem.status) {
                $tid = ($mainStatusField.options | Where-Object { $_.name -eq $sItem.status }).id
                if (-not $tid) {
                    Write-Warning "      Status '$($sItem.status)' not found on main board - skipping Status field for: $title"
                }
            }
            if ($tid) {
                $mv = if ($mItem) { $mItem.status } else { $null }
                $u = Get-UpdateHash $mv $sItem.status $mainStatusField $tid "--single-select-option-id" "Status"
                if ($u) { $updates.Add($u) }
            }

            # 2. Iteration - only sync the Week field in normal (non-FullSync) mode.
            # In -FullSync we are importing tickets, not re-assigning them to sprints.
            # Orphan items (included only because they're already on the main board) also skip iteration updates.
            if (-not $FullSync -and -not $sItem.isOrphan) {
                $sTargetIterationId = $null
                if ($sItem.week -and $sItem.week.startDate) {
                    $sTargetIterationId = Get-MidpointIterationMatch -WeekStartDate $sItem.week.startDate -WeekDuration $sItem.week.duration -MainIterations $mainWeekConfig
                }
                # Fallback for current week items if time-period matching failed
                if (-not $sTargetIterationId -and -not $sItem.isLastWeek) {
                    $sTargetIterationId = $targetIterationId
                }
                if (-not $sTargetIterationId) {
                    Write-Warning "      Could not map iteration for: $title (secondary week: '$($sItem.week.title)') - Week field left unchanged"
                }
                # Prevent iteration ping-pong: skip update if sprints start on the same day
                if ($sTargetIterationId) {
                    $mv = if ($mItem -and $mItem.week) { $mItem.week.iterationId } else { $null }
                    $needsIterationUpdate = $true
                    if ($mv -and $mItem.week -and $mItem.week.startDate -and $sItem.week -and $sItem.week.startDate) {
                        if (Test-IterationStartsAligned -MainStartDate $mItem.week.startDate -SecondaryStartDate $sItem.week.startDate) { $needsIterationUpdate = $false }
                    }
                    if ($needsIterationUpdate) {
                        $u = Get-UpdateHash $mv $sTargetIterationId $mainWeekField $sTargetIterationId "--iteration-id" "Week"
                        if ($u) { $updates.Add($u) }
                    }
                }
            }

            # 3. Priority
            $sv = $sItem.priority
            $tid = $null
            if ($sv) {
                $tid = ($mainPriorityField.options | Where-Object { $_.name -eq $sv }).id
                if (-not $tid) { Write-Warning "      Priority '$sv' not found on main board - skipping for: $title" }
            }
            if ($tid) {
                $mv = if ($mItem) { $mItem.priority } else { $null }
                $u = Get-UpdateHash $mv $sv $mainPriorityField $tid "--single-select-option-id" "Priority"
                if ($u) { $updates.Add($u) }
            }

            # 4. Size
            $sv = $sItem.size
            $tid = $null
            if ($sv) {
                $tid = ($mainSizeField.options | Where-Object { $_.name -eq $sv }).id
                if (-not $tid) { Write-Warning "      Size '$sv' not found on main board - skipping for: $title" }
            }
            if ($tid) {
                $mv = if ($mItem) { $mItem.size } else { $null }
                $u = Get-UpdateHash $mv $sv $mainSizeField $tid "--single-select-option-id" "Size"
                if ($u) { $updates.Add($u) }
            }

            # 5. Estimate
            $sv = $sItem.estimate
            $mv = if ($mItem) { $mItem.estimate } else { $null }
            $u = Get-UpdateHash $mv $sv $mainEstimateField $sv "--number" "Estimate"
            if ($u) { $updates.Add($u) }

            # 6. Start Date
            $sv = $sItem.'start date'
            $mv = if ($mItem) { $mItem.'start date' } else { $null }
            $u = Get-UpdateHash $mv $sv $mainStartDateField $sv "--date" "Start date"
            if ($u) { $updates.Add($u) }

            # 7. Target Date / End Date -> End Date
            $sv = if ($sItem.'target date') { $sItem.'target date' } else { $sItem.'end date' }
            $mv = if ($mItem) { $mItem.'end date' } else { $null }
            $u = Get-UpdateHash $mv $sv $mainEndDateField $sv "--date" "End date"
            if ($u) { $updates.Add($u) }

            $weekLabel = if ($sItem.isLastWeek) { " (last week)" } else { "" }
            if ($isNew) {
                if ($DryRun) {
                    Write-Host "    [DRY-RUN ADD] $title$weekLabel" -ForegroundColor Cyan
                    $boardAdded++
                    $fieldNames = ($updates | ForEach-Object { $_.name }) -join ", "
                    $runLog.Add("  - **[ADD]** $title$weekLabel - fields set: $fieldNames")
                } else {
                    Write-Host "    [ADD] $title$weekLabel"
                    $addOutput = Invoke-GHWithRetry -Arguments @("project", "item-add", "$MainProjNum", "--owner", $MainOrg, "--url", $url, "--format", "json") -JsonOutput -SuppressError

                    if ($addOutput -and $addOutput.id) {
                        $newItemId = $addOutput.id
                        Invoke-BatchedFieldUpdate -ItemId $newItemId -ProjectId $mainProjId -Updates $updates | Out-Null
                        $mainUrlMap[$url] = @{ id = $newItemId; url = $url; status = $sItem.status }
                        $boardAdded++
                        $fieldSummaries = @()
                        foreach ($upd in $updates) {
                            if ($upd.name -eq "Status") { $fieldSummaries += "Status: $($upd.newValue)" }
                            else { $fieldSummaries += $upd.name }
                        }
                        $fieldNames = $fieldSummaries -join ", "
                        $runLog.Add("  - **[ADD]** $title$weekLabel - fields set: $fieldNames")
                        # Record in manifest for potential rollback
                        if ($syncManifest -ne $null) {
                            $syncManifest.Add(@{ action = "add"; itemId = $newItemId; url = $url; title = $title })
                        }
                    } else {
                        # Handle concurrent add: item may have been added between fetch and now
                        $existingItem = $mainUrlMap[$url]
                        if ($existingItem) {
                            Write-Host "      Item already on main board, treating as update."
                            $mItem = $existingItem
                            $isNew = $false
                        } else {
                            Write-Warning "    Failed to add $url"
                            $runLog.Add("  - **[FAIL]** Could not add: $title$weekLabel")
                        }
                    }
                }
            }
            # Handle existing items (or items that fell through from concurrent-add above)
            if (-not $isNew) {
                if ($updates.Count -gt 0) {
                    if ($DryRun) {
                        Write-Host "    [DRY-RUN UPDATE] $($updates.Count) field(s): $title$weekLabel" -ForegroundColor Cyan
                    } else {
                        Write-Host "    [UPDATE] $($updates.Count) field(s): $title$weekLabel"
                        # Capture previous state for rollback manifest before overwriting
                        if ($syncManifest -ne $null) {
                            $prevValues = [System.Collections.Generic.List[hashtable]]::new()
                            foreach ($upd in $updates) {
                                switch ($upd.name) {
                                    "Status"     { $prevOptId = if ($mItem.status) { ($mainStatusField.options | Where-Object { $_.name -eq $mItem.status }).id } else { $null }
                                                   if ($prevOptId) { $prevValues.Add(@{ fieldId = $mainStatusField.id;    flag = "--single-select-option-id"; value = $prevOptId;                    clear = $false }) }
                                                   else            { $prevValues.Add(@{ fieldId = $mainStatusField.id;    clear = $true }) } }
                                    "Week"       { if ($mItem.week -and $mItem.week.iterationId) { $prevValues.Add(@{ fieldId = $mainWeekField.id;    flag = "--iteration-id";           value = $mItem.week.iterationId;    clear = $false }) }
                                                   else                                           { $prevValues.Add(@{ fieldId = $mainWeekField.id;    clear = $true }) } }
                                    "Priority"   { $prevOptId = if ($mItem.priority) { ($mainPriorityField.options | Where-Object { $_.name -eq $mItem.priority }).id } else { $null }
                                                   if ($prevOptId) { $prevValues.Add(@{ fieldId = $mainPriorityField.id; flag = "--single-select-option-id"; value = $prevOptId;                    clear = $false }) }
                                                   else            { $prevValues.Add(@{ fieldId = $mainPriorityField.id; clear = $true }) } }
                                    "Size"       { $prevOptId = if ($mItem.size) { ($mainSizeField.options | Where-Object { $_.name -eq $mItem.size }).id } else { $null }
                                                   if ($prevOptId) { $prevValues.Add(@{ fieldId = $mainSizeField.id;     flag = "--single-select-option-id"; value = $prevOptId;                    clear = $false }) }
                                                   else            { $prevValues.Add(@{ fieldId = $mainSizeField.id;     clear = $true }) } }
                                    "Estimate"   { if (Test-HasValue $mItem.estimate) { $prevValues.Add(@{ fieldId = $mainEstimateField.id;  flag = "--number"; value = [string]$mItem.estimate;    clear = $false }) }
                                                   else                                { $prevValues.Add(@{ fieldId = $mainEstimateField.id;  clear = $true }) } }
                                    "Start date" { if ($mItem.'start date')       { $prevValues.Add(@{ fieldId = $mainStartDateField.id; flag = "--date";   value = $mItem.'start date';         clear = $false }) }
                                                   else                           { $prevValues.Add(@{ fieldId = $mainStartDateField.id; clear = $true }) } }
                                    "End date"   { if ($mItem.'end date')         { $prevValues.Add(@{ fieldId = $mainEndDateField.id;   flag = "--date";   value = $mItem.'end date';           clear = $false }) }
                                                   else                           { $prevValues.Add(@{ fieldId = $mainEndDateField.id;   clear = $true }) } }
                                }
                            }
                            $syncManifest.Add(@{ action = "update"; itemId = $mItem.id; url = $url; title = $title; previousValues = @($prevValues) })
                        }
                        Invoke-BatchedFieldUpdate -ItemId $mItem.id -ProjectId $mainProjId -Updates $updates | Out-Null
                    }
                    $boardUpdated++
                    $fieldSummaries = @()
                    foreach ($upd in $updates) {
                        if ($upd.name -eq "Status") { $fieldSummaries += "Status: $($upd.newValue)" }
                        else { $fieldSummaries += $upd.name }
                    }
                    $fieldNames = $fieldSummaries -join ", "
                    $runLog.Add("  - **[UPDATE]** $title$weekLabel - changed: $fieldNames")
                } else {
                    $boardSkipped++
                    # Skips are not logged individually - only the count is shown per board
                }
            }
        }

        $runLog.Insert(($runLog.Count - $boardAdded - $boardUpdated), "")
        $runLog.Insert(($runLog.Count - $boardAdded - $boardUpdated), "#### $secProjName - +$boardAdded added, ~$boardUpdated updated, =$boardSkipped skipped")
        Write-Host "  Results: +$boardAdded added, ~$boardUpdated updated, =$boardSkipped skipped`n"
        $totalAdded += $boardAdded
        $totalUpdated += $boardUpdated
        $totalSkipped += $boardSkipped
    } catch {
        Write-Warning "  Unexpected error syncing board $secOrg (#$secNum): $($_.Exception.Message)"
        $runLog.Add("")
        $runLog.Add("#### $secProjName - [ERROR] Sync failed")
        $runLog.Add("  - $($_.Exception.Message)")
    }
} # end board loop
} finally {
    # Save manifest here so it's always written, even if the script crashes mid-run
    if ($syncManifest -ne $null -and $syncManifest.Count -gt 0) {
        $manifestData = @{
            timestamp   = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            mode        = if ($FullSync) { "FullSync" } else { "Regular" }
            mainOrg     = $MainOrg
            mainProjNum = $MainProjNum
            mainProjId  = $mainProjId
            entries     = @($syncManifest)
        }
        $changelogDir = Join-Path $repoRoot "changelogs"
        if (-not (Test-Path $changelogDir)) { New-Item -ItemType Directory -Path $changelogDir -Force | Out-Null }
        $manifestData | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8
        Write-Host "`n[MANIFEST] Rollback manifest saved ($($syncManifest.Count) entries): $manifestPath" -ForegroundColor Magenta
        Write-Host "[MANIFEST] To rollback, run: .\sync-boards.ps1 -Rollback" -ForegroundColor Magenta
    }
}

# ============================================================
# PHASE C: Combined summary
# ============================================================
Write-Host "============================================"
if ($DryRun) { Write-Host "  SYNC COMPLETE (DRY RUN)" } else { Write-Host "  SYNC COMPLETE" }
Write-Host "  Added:   $totalAdded"
Write-Host "  Updated: $totalUpdated"
Write-Host "  Skipped: $totalSkipped"
Write-Host "============================================"

if ($DryRun) {
    Write-Host "`n[DRY-RUN] No changes were written. Changelog not updated." -ForegroundColor Cyan
    exit 0
}

$retentionDays = if ($config.changelogRetentionDays) { $config.changelogRetentionDays } else { 14 }
$cutoffDate = $today.AddDays(-$retentionDays).Date

if (-not $FullSync) {
    # ============================================================
    # PHASE D: Write to Changelog
    # ============================================================
    $changelogPath = Join-Path (Join-Path $repoRoot "changelogs") "sync-boards.md"
    $changelogDir = Split-Path -Parent $changelogPath
    if (-not (Test-Path $changelogDir)) { New-Item -ItemType Directory -Path $changelogDir -Force > $null }

    $todayStr = $today.ToString("yyyy-MM-dd")
    $timeStr = $today.ToString("hh:mm tt")
    $dateHeader = "## $todayStr"

    # Build the new version entry
    $entryLines = [System.Collections.Generic.List[string]]::new()
    # Version placeholder -- will be replaced after we determine the version number
    $entryLines.Add("VPLACEHOLDER")
    $entryLines.Add("")
    $entryLines.Add("| Added | Updated | Skipped |")
    $entryLines.Add("|-------|---------|---------|")
    $entryLines.Add("| $totalAdded     | $totalUpdated       | $totalSkipped       |")
    $entryLines.Add("")
    foreach ($logLine in $runLog) {
        $entryLines.Add($logLine)
    }

    # Read existing changelog or create fresh
    $headerBlock = "# Sync Boards - Run Log`n"
    if (Test-Path $changelogPath) {
        $existingContent = Get-Content -Raw $changelogPath
    } else {
        $existingContent = $headerBlock
    }

    # Strip the top header if present (we'll re-add it)
    $body = $existingContent -replace "^# Sync Boards - Run Log\r?\n?", ""
    $body = $body.TrimStart("`r", "`n")

    # Determine version number for today
    $versionNum = 1
    if ($body -match [regex]::Escape($dateHeader)) {
        # Count existing versions under today's date
        $pattern = '### V(\d+)'
        $todaySection = $body.Substring($body.IndexOf($dateHeader))
        # Only look until the next date header or end of file
        $nextDateMatch = [regex]::Match($todaySection.Substring($dateHeader.Length), '(?m)^## \d{4}-\d{2}-\d{2}')
        if ($nextDateMatch.Success) {
            $todaySection = $todaySection.Substring(0, $dateHeader.Length + $nextDateMatch.Index)
        }
        $vMatches = [regex]::Matches($todaySection, $pattern)
        if ($vMatches.Count -gt 0) {
            $maxV = 0
            foreach ($vm in $vMatches) {
                $v = [int]$vm.Groups[1].Value
                if ($v -gt $maxV) { $maxV = $v }
            }
            $versionNum = $maxV + 1
        }
    }

    # Replace placeholder with actual version header
    $entryLines[0] = "### V$versionNum - $timeStr"
    $entryText = ($entryLines -join "`n")

    # Insert into the changelog
    if ($body -match [regex]::Escape($dateHeader)) {
        # Today's date section exists -- insert the new version right after the date header
        $datePos = $body.IndexOf($dateHeader)
        $insertPos = $datePos + $dateHeader.Length
        $newBody = $body.Substring(0, $insertPos) + "`n`n" + $entryText + $body.Substring($insertPos)
    } else {
        # New date -- prepend a new section above everything
        $newBody = $dateHeader + "`n`n" + $entryText + "`n`n---`n`n" + $body
    }

    $finalContent = $headerBlock + "`n" + $newBody.TrimEnd("`r", "`n") + "`n"
    $finalContent | Set-Content -Path $changelogPath -Encoding UTF8
    Write-Host "`n[LOG] Changelog updated: $changelogPath"

    # ============================================================
    # PHASE E: Changelog Cleanup (trim old entries)
    # ============================================================
    Write-Host "[CLEANUP] Retaining entries from last $retentionDays days (cutoff: $($cutoffDate.ToString('yyyy-MM-dd')))"

    $rawContent = Get-Content -Raw $changelogPath
    $header = "# Sync Boards - Run Log`n"
    $rawBody = $rawContent -replace "^# Sync Boards - Run Log\r?\n?", ""
    $rawBody = $rawBody.TrimStart("`r", "`n")

    # Split the body by date sections (## YYYY-MM-DD)
    $dateSections = [regex]::Split($rawBody, '(?m)(?=^## \d{4}-\d{2}-\d{2})')
    $keptSections = [System.Collections.Generic.List[string]]::new()

    foreach ($section in $dateSections) {
        $section = $section.Trim()
        if (-not $section) { continue }
        $dateMatch = [regex]::Match($section, '^## (\d{4}-\d{2}-\d{2})')
        if ($dateMatch.Success) {
            $sectionDate = [datetime]::Parse($dateMatch.Groups[1].Value)
            if ($sectionDate -ge $cutoffDate) {
                # Strip out any trailing dividers and whitespace so they don't duplicate when joining
                $section = $section -replace '(?s)(\s+---)+\s*$', ''
                $keptSections.Add($section)
            } else {
                Write-Host "[CLEANUP] Removing entries from $($dateMatch.Groups[1].Value)"
            }
        }
    }

    $cleanedBody = ($keptSections -join "`n`n---`n`n")
    $cleanedContent = $header + "`n" + $cleanedBody.TrimEnd("`r", "`n") + "`n"
    $cleanedContent | Set-Content -Path $changelogPath -Encoding UTF8
    Write-Host "[CLEANUP] Done. Kept $($keptSections.Count) date section(s)."
} else {
    Write-Host "`n[FULL-SYNC] Skipping main changelog update. Logging to full-sync.log..." -ForegroundColor Yellow
    $fullSyncLogPath = Join-Path (Join-Path $repoRoot "changelogs") "full-sync.log"
    $logEntry = @"

============================================
  FULL SYNC: $((Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
============================================
  Added:   $totalAdded
  Updated: $totalUpdated
  Skipped: $totalSkipped
--------------------------------------------
"@
    Add-Content -Path $fullSyncLogPath -Value $logEntry -Encoding UTF8
    Write-Host "[LOG] Full Sync log updated: $fullSyncLogPath"

    # ============================================================
    # PHASE E (Full-Sync variant): prune full-sync.log the same way sync-boards.md is pruned
    # ============================================================
    if (Test-Path $fullSyncLogPath) {
        $fsRaw = Get-Content -Raw $fullSyncLogPath
        $fsEntries = [regex]::Split($fsRaw, '(?=\r?\n?============================================\r?\n  FULL SYNC:)') | Where-Object { $_.Trim() }
        $fsKept = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in $fsEntries) {
            $m = [regex]::Match($entry, 'FULL SYNC:\s*(\d{4}-\d{2}-\d{2})')
            if ($m.Success) {
                $entryDate = [datetime]::Parse($m.Groups[1].Value)
                if ($entryDate -ge $cutoffDate) { $fsKept.Add($entry.Trim()) } else { Write-Host "[CLEANUP] Removing full-sync.log entry from $($m.Groups[1].Value)" }
            } else {
                $fsKept.Add($entry.Trim())
            }
        }
        $fsContent = (($fsKept -join "`n`n").Trim()) + "`n"
        $fsContent | Set-Content -Path $fullSyncLogPath -Encoding UTF8
        Write-Host "[CLEANUP] full-sync.log: kept $($fsKept.Count) entr$(if ($fsKept.Count -eq 1) {'y'} else {'ies'})."
    }
}

exit 0
