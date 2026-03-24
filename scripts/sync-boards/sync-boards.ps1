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
#>

$ErrorActionPreference = "Stop"
$GH = if (Get-Command "gh" -ErrorAction SilentlyContinue) { "gh" } else { "C:\Program Files\GitHub CLI\gh.exe" }
$MAX_RETRIES = 1

# --- Load Config ---
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
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
    
    $minRequired = 20 + ($config.secondaryBoards.Count * 5)
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
function Invoke-GHWithRetry {
    param(
        [string[]]$Arguments,
        [switch]$JsonOutput,
        [switch]$SuppressError
    )
    for ($attempt = 0; $attempt -le $MAX_RETRIES; $attempt++) {
        try {
            $output = & $GH @Arguments 2>&1
            $stderr = $output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }
            $stdout = $output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }
            
            if ($stderr -and -not $SuppressError) {
                $errMsg = ($stderr | ForEach-Object { $_.ToString() }) -join "`n"
                if ($errMsg -match "rate limit") {
                    if ($attempt -lt $MAX_RETRIES) {
                        Write-Host "      Rate limited, retrying in 5s..." -ForegroundColor Yellow
                        Start-Sleep -Seconds 5
                        continue
                    }
                }
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
            if (-not $SuppressError) { throw }
            return $null
        }
    }
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
    $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath
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
          fieldValues(first: 10) {
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
    $allItems = @()
    $cursor = $null
    $page = 0
    
    $queryFile = [System.IO.Path]::GetTempFileName()
    $itemsQuery | Set-Content -Path $queryFile
    
    do {
        $page++
        $args = @("api", "graphql", "-F", "id=$projId", "-F", "query=@$queryFile")
        if ($cursor) { $args += @("-F", "cursor=$cursor") }
        
        $result = Invoke-GHWithRetry -Arguments $args -JsonOutput
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
            $allItems += $item
        }
        
        $cursor = if ($itemsData.pageInfo.hasNextPage) { $itemsData.pageInfo.endCursor } else { $null }
    } while ($cursor)
    
    Remove-Item $queryFile
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
          configuration { iterations { id title startDate duration } }
        }
      }
    }
  }
}
"@
$graphqlQueryFile = [System.IO.Path]::GetTempFileName()
$graphqlQuery | Set-Content -Path $graphqlQueryFile
$mainWeekConfigJson = Invoke-GHWithRetry -Arguments @("api", "graphql", "-F", "id=$mainProjId", "-F", "query=@$graphqlQueryFile") -JsonOutput
Remove-Item $graphqlQueryFile

if (-not $mainWeekConfigJson -or -not $mainWeekConfigJson.data) {
    Write-Error "Failed to fetch iteration data from main board."
    exit 1
}

$mainWeekConfig = $mainWeekConfigJson.data.node.field.configuration.iterations
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

Write-Host "[MAIN] Setup complete. $($mainItemsJson.items.Count) items cached.`n"

# ============================================================
# Helper function
# ============================================================
function Get-UpdateHash {
    param($mVal, $sVal, $field, $targetId, $flag, $fieldName)
    if (-not $field) { return $null }
    if ($sVal) {
        if (-not $mVal -or $mVal -ne $sVal) {
            return @{ fieldId = $field.id; flag = $flag; value = [string]$targetId; clear = $false; name = $fieldName }
        }
    } else {
        if ($mVal) {
            return @{ fieldId = $field.id; clear = $true; name = $fieldName }
        }
    }
    return $null
}

# ============================================================
# PHASE B: Loop over each secondary board
# ============================================================
$totalAdded = 0
$totalUpdated = 0
$totalSkipped = 0
$runLog = [System.Collections.Generic.List[string]]::new()

for ($bi = 0; $bi -lt $config.secondaryBoards.Count; $bi++) {
    $board = $config.secondaryBoards[$bi]
    $secOrg = $board.org
    $secNum = $board.projectNumber
    
    Write-Host "--------------------------------------------"
    Write-Host "  Board $($bi + 1)/$($config.secondaryBoards.Count): $secOrg (#$secNum)"
    Write-Host "--------------------------------------------"
    
    # Resolve secondary board project ID and Name (cached in config)
    $secProjId = $board.projectId
    $secProjName = $board.projectName
    if (-not $secProjId -or -not $secProjName) {
        Write-Host "  Resolving project Name/ID (will be cached)..."
        $secProjListJson = Invoke-GHWithRetry -Arguments @("project", "list", "--owner", $secOrg, "--format", "json") -JsonOutput
        $secProj = $secProjListJson.projects | Where-Object { $_.number -eq $secNum }
        
        if (-not $secProj) {
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
        $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath
    }
    
    if (-not $secProjName) { $secProjName = "$secOrg (#$secNum)" }
    
    # Fetch secondary items via optimized GraphQL
    Write-Host "  Fetching items (GraphQL)..."
    $secItems = Fetch-ProjectItems $secProjId $secProjName
    
    # Detect current week and previous week on this secondary board
    $currentWeekTitle = $null
    $previousWeekTitle = $null
    $prevWeekEndDate = [datetime]::MinValue
    foreach ($item in $secItems) {
        if ($item.week -and $item.week.startDate) {
            $start = [datetime]::Parse($item.week.startDate)
            $end = $start.AddDays($item.week.duration)
            if ($today -ge $start -and $today -le $end) {
                $currentWeekTitle = $item.week.title
            } elseif ($end -lt $today -and $end -gt $prevWeekEndDate) {
                $previousWeekTitle = $item.week.title
                $prevWeekEndDate = $end
            }
        }
    }
    
    if (-not $currentWeekTitle) {
        Write-Host "  No items found in the current week. Skipping.`n"
        $runLog.Add("")
        $runLog.Add("#### $secProjName - Skipped")
        $runLog.Add("*No items found in the current week.*")
        continue
    }
    Write-Host "  Current iteration: $currentWeekTitle"
    
    # Filter items
    $itemsToSync = @()
    foreach ($item in $secItems) {
        $isCurrentWeek = ($item.week -and $item.week.title -eq $currentWeekTitle)
        $isLastWeek = ($previousWeekTitle -and $item.week -and $item.week.title -eq $previousWeekTitle)
        if (($isCurrentWeek -or $isLastWeek) -and $item.status -in $ValidStatuses) {
            if ($item.url) {
                $item.isLastWeek = $isLastWeek
                $itemsToSync += $item
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
        
        # 1. Status
        $tid = if ($sItem.status) { ($mainStatusField.options | Where-Object { $_.name -eq $sItem.status }).id } else { $null }
        $mv = if ($mItem) { $mItem.status } else { $null }
        $u = Get-UpdateHash $mv $sItem.status $mainStatusField $tid "--single-select-option-id" "Status"
        if ($u) { $updates.Add($u) }
        
        # 2. Iteration
        if (-not $sItem.isLastWeek) {
            $mv = if ($mItem -and $mItem.week) { $mItem.week.iterationId } else { $null }
            $u = Get-UpdateHash $mv $targetIterationId $mainWeekField $targetIterationId "--iteration-id" "Week"
            if ($u) { $updates.Add($u) }
        }
        
        # 3. Priority
        $sv = $sItem.priority
        $tid = if ($sv) { ($mainPriorityField.options | Where-Object { $_.name -eq $sv }).id } else { $null }
        $mv = if ($mItem) { $mItem.priority } else { $null }
        $u = Get-UpdateHash $mv $sv $mainPriorityField $tid "--single-select-option-id" "Priority"
        if ($u) { $updates.Add($u) }
        
        # 4. Size
        $sv = $sItem.size
        $tid = if ($sv) { ($mainSizeField.options | Where-Object { $_.name -eq $sv }).id } else { $null }
        $mv = if ($mItem) { $mItem.size } else { $null }
        $u = Get-UpdateHash $mv $sv $mainSizeField $tid "--single-select-option-id" "Size"
        if ($u) { $updates.Add($u) }
        
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
            Write-Host "    [ADD] $title$weekLabel"
            $addOutput = Invoke-GHWithRetry -Arguments @("project", "item-add", "$MainProjNum", "--owner", $MainOrg, "--url", $url, "--format", "json") -JsonOutput -SuppressError
            
            if ($addOutput -and $addOutput.id) {
                $newItemId = $addOutput.id
                foreach ($upd in $updates) {
                    $cmdArgs = @("project", "item-edit", "--id", $newItemId, "--project-id", $mainProjId, "--field-id", $upd.fieldId)
                    if ($upd.clear) { $cmdArgs += "--clear" }
                    else { $cmdArgs += $upd.flag; $cmdArgs += $upd.value }
                    Invoke-GHWithRetry -Arguments $cmdArgs -SuppressError > $null
                }
                $mainUrlMap[$url] = @{ id = $newItemId; url = $url; status = $sItem.status }
                $boardAdded++
                $fieldNames = ($updates | ForEach-Object { $_.name }) -join ", "
                $runLog.Add("  - **[ADD]** $title$weekLabel - fields set: $fieldNames")
            } else {
                Write-Warning "    Failed to add $url"
                $runLog.Add("  - **[FAIL]** Could not add: $title$weekLabel")
            }
        } else {
            if ($updates.Count -gt 0) {
                Write-Host "    [UPDATE] $($updates.Count) field(s): $title$weekLabel"
                foreach ($upd in $updates) {
                    $cmdArgs = @("project", "item-edit", "--id", $mItem.id, "--project-id", $mainProjId, "--field-id", $upd.fieldId)
                    if ($upd.clear) { $cmdArgs += "--clear" }
                    else { $cmdArgs += $upd.flag; $cmdArgs += $upd.value }
                    Invoke-GHWithRetry -Arguments $cmdArgs -SuppressError > $null
                }
                $boardUpdated++
                $fieldNames = ($updates | ForEach-Object { $_.name }) -join ", "
                $runLog.Add("  - **[UPDATE]** $title$weekLabel - changed: $fieldNames")
            } else {
                $boardSkipped++
                $runLog.Add("  - **[SKIP]** $title$weekLabel (already in sync)")
            }
        }
    }
    
    $runLog.Insert(($runLog.Count - $boardAdded - $boardUpdated - $boardSkipped), "")
    $runLog.Insert(($runLog.Count - $boardAdded - $boardUpdated - $boardSkipped), "#### $secProjName - +$boardAdded added, ~$boardUpdated updated, =$boardSkipped skipped")
    Write-Host "  Results: +$boardAdded added, ~$boardUpdated updated, =$boardSkipped skipped`n"
    $totalAdded += $boardAdded
    $totalUpdated += $boardUpdated
    $totalSkipped += $boardSkipped
}

# ============================================================
# PHASE C: Combined summary
# ============================================================
Write-Host "============================================"
Write-Host "  SYNC COMPLETE"
Write-Host "  Added:   $totalAdded"
Write-Host "  Updated: $totalUpdated"
Write-Host "  Skipped: $totalSkipped"
Write-Host "============================================"

# ============================================================
# PHASE D: Write to Changelog
# ============================================================
$repoRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
$changelogPath = Join-Path (Join-Path $repoRoot "changelogs") "sync-boards.md"
$changelogDir = Split-Path -Parent $changelogPath
if (-not (Test-Path $changelogDir)) { New-Item -ItemType Directory -Path $changelogDir -Force > $null }

$todayStr = $today.ToString("yyyy-MM-dd")
$timeStr = $today.ToString("hh:mm tt")
$dateHeader = "## $todayStr"

# Build the new version entry
$entryLines = [System.Collections.Generic.List[string]]::new()
# Version placeholder — will be replaced after we determine the version number
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
    # Today's date section exists — insert the new version right after the date header
    $datePos = $body.IndexOf($dateHeader)
    $insertPos = $datePos + $dateHeader.Length
    $newBody = $body.Substring(0, $insertPos) + "`n`n" + $entryText + $body.Substring($insertPos)
} else {
    # New date — prepend a new section above everything
    $newBody = $dateHeader + "`n`n" + $entryText + "`n`n---`n`n" + $body
}

$finalContent = $headerBlock + "`n" + $newBody.TrimEnd("`r", "`n") + "`n"
$finalContent | Set-Content -Path $changelogPath -Encoding UTF8
Write-Host "`n[LOG] Changelog updated: $changelogPath"

# ============================================================
# PHASE E: Changelog Cleanup (trim old entries)
# ============================================================
$retentionDays = if ($config.changelogRetentionDays) { $config.changelogRetentionDays } else { 14 }
$cutoffDate = $today.AddDays(-$retentionDays).Date

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
