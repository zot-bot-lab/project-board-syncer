# Pure helper functions for sync-boards.ps1, split out so they can be unit-tested
# with Pester without executing the main script's side effects (API calls, config I/O).

function Test-HasValue {
    param($Value)
    # [string]$null -> "" and [string]"" -> "" both count as "no value".
    # Anything else - including the number 0 - stringifies to a non-empty string.
    -not [string]::IsNullOrEmpty([string]$Value)
}

function Get-UpdateHash {
    param($mVal, $sVal, $field, $targetId, $flag, $fieldName)
    if (-not $field) { return $null }
    $sHasValue = Test-HasValue $sVal
    $mHasValue = Test-HasValue $mVal
    if ($sHasValue) {
        if (-not $mHasValue -or $mVal -ne $sVal) {
            return @{ fieldId = $field.id; flag = $flag; value = [string]$targetId; clear = $false; name = $fieldName; newValue = $sVal }
        }
    } else {
        if ($mHasValue) {
            return @{ fieldId = $field.id; clear = $true; name = $fieldName; newValue = "None" }
        }
    }
    return $null
}

function Get-WeekWindow {
    param(
        [Parameter(Mandatory)] $Items,
        [Parameter(Mandatory)] [datetime]$Today,
        [int]$RecentPastDays = 14
    )
    $currentWeekTitle = $null
    $previousWeekTitle = $null
    $prevWeekEndDate = [datetime]::MinValue
    $recentPastThreshold = $Today.AddDays(-$RecentPastDays)

    foreach ($item in $Items) {
        if ($item.week -and $item.week.startDate) {
            $start = [datetime]::Parse($item.week.startDate)
            $end = $start.AddDays($item.week.duration)
            if ($Today -ge $start -and $Today -le $end) {
                $currentWeekTitle = $item.week.title
            } elseif ($end -lt $Today -and $end -ge $recentPastThreshold -and $end -gt $prevWeekEndDate) {
                $previousWeekTitle = $item.week.title
                $prevWeekEndDate = $end
            }
        }
    }
    return @{ current = $currentWeekTitle; previous = $previousWeekTitle }
}

function Get-ItemSyncScope {
    param(
        [Parameter(Mandatory)] $Item,
        $CurrentWeekTitle,
        $PreviousWeekTitle,
        [bool]$IsAlreadyInMain,
        [Parameter(Mandatory)] [string[]]$ValidStatuses
    )
    $isCurrentWeek = [bool]($Item.week -and $Item.week.title -eq $CurrentWeekTitle)
    $isLastWeek = [bool]($PreviousWeekTitle -and $Item.week -and $Item.week.title -eq $PreviousWeekTitle)
    $inScope = ($isCurrentWeek -or $isLastWeek -or $IsAlreadyInMain) -and ($Item.status -in $ValidStatuses) -and [bool]$Item.url
    return @{
        inScope    = [bool]$inScope
        isLastWeek = $isLastWeek
        isOrphan   = [bool](-not $isCurrentWeek -and -not $isLastWeek -and $IsAlreadyInMain)
    }
}

function Get-MidpointIterationMatch {
    param(
        $WeekStartDate,
        $WeekDuration,
        [Parameter(Mandatory)] $MainIterations
    )
    if (-not $WeekStartDate) { return $null }
    $start = [datetime]::Parse($WeekStartDate)
    $midPoint = $start.AddDays($WeekDuration / 2)
    foreach ($mIter in $MainIterations) {
        if ($mIter.startDate) {
            $mStart = [datetime]::Parse($mIter.startDate)
            $mEnd = $mStart.AddDays($mIter.duration)
            if ($midPoint -ge $mStart -and $midPoint -le $mEnd) {
                return $mIter.id
            }
        }
    }
    return $null
}

function Test-IterationStartsAligned {
    param($MainStartDate, $SecondaryStartDate)
    if (-not $MainStartDate -or -not $SecondaryStartDate) { return $false }
    return ([datetime]::Parse($MainStartDate) -eq [datetime]::Parse($SecondaryStartDate))
}

# Builds one aliased GraphQL mutation document that applies every field update for a
# single item in one API call, instead of one `gh project item-edit` call per field.
# Field ids/option ids/iteration ids all come from GitHub's own API responses (not
# free-text user input), but values are still escaped defensively.
function New-ItemFieldUpdateMutation {
    param([Parameter(Mandatory)] $Updates)

    $updateList = @($Updates)
    if ($updateList.Count -eq 0) { return $null }

    $valueKeyMap = @{
        "--single-select-option-id" = "singleSelectOptionId"
        "--iteration-id"            = "iterationId"
        "--number"                  = "number"
        "--date"                    = "date"
    }

    $parts = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $updateList.Count; $i++) {
        $u = $updateList[$i]
        $alias = "f$i"
        $fieldIdLiteral = ([string]$u.fieldId) -replace '\\', '\\\\' -replace '"', '\"'
        if ($u.clear) {
            $parts.Add("  $alias`: clearProjectV2ItemFieldValue(input: { projectId: `$projectId, itemId: `$itemId, fieldId: `"$fieldIdLiteral`" }) { projectV2Item { id } }")
        } else {
            $valueKey = $valueKeyMap[$u.flag]
            if (-not $valueKey) { throw "Unknown update flag '$($u.flag)' - cannot build GraphQL mutation." }
            $valueLiteral = if ($valueKey -eq "number") {
                [string]$u.value
            } else {
                $escaped = ([string]$u.value) -replace '\\', '\\\\' -replace '"', '\"'
                "`"$escaped`""
            }
            $parts.Add("  $alias`: updateProjectV2ItemFieldValue(input: { projectId: `$projectId, itemId: `$itemId, fieldId: `"$fieldIdLiteral`", value: { $valueKey`: $valueLiteral } }) { projectV2Item { id } }")
        }
    }

    return "mutation(`$projectId: ID!, `$itemId: ID!) {`n" + ($parts -join "`n") + "`n}"
}

Export-ModuleMember -Function Get-UpdateHash, Test-HasValue, Get-WeekWindow, Get-ItemSyncScope, Get-MidpointIterationMatch, Test-IterationStartsAligned, New-ItemFieldUpdateMutation
