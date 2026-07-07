BeforeAll {
    Import-Module (Join-Path $PSScriptRoot "..\SyncBoards.Helpers.psm1") -Force
    $Field = @{ id = "FIELD_ID_1" }
}

Describe "Get-UpdateHash" {

    It "returns null when the field doesn't exist on the main board" {
        $result = Get-UpdateHash "Old" "New" $null "TARGET_ID" "--single-select-option-id" "Status"
        $result | Should -BeNullOrEmpty
    }

    It "returns null when the value is already in sync" {
        $result = Get-UpdateHash "Same" "Same" $Field "TARGET_ID" "--single-select-option-id" "Status"
        $result | Should -BeNullOrEmpty
    }

    It "returns an update hash when the main board value differs from the secondary value" {
        $result = Get-UpdateHash "Old" "New" $Field "TARGET_ID" "--single-select-option-id" "Status"
        $result.fieldId | Should -Be "FIELD_ID_1"
        $result.flag | Should -Be "--single-select-option-id"
        $result.value | Should -Be "TARGET_ID"
        $result.clear | Should -BeFalse
        $result.name | Should -Be "Status"
        $result.newValue | Should -Be "New"
    }

    It "returns an update hash when the main board has no value yet" {
        $result = Get-UpdateHash $null "New" $Field "TARGET_ID" "--number" "Estimate"
        $result.clear | Should -BeFalse
        $result.newValue | Should -Be "New"
    }

    It "returns a clear hash when the secondary value is empty but the main board still has one" {
        $result = Get-UpdateHash "Old" $null $Field "TARGET_ID" "--date" "Start date"
        $result.clear | Should -BeTrue
        $result.fieldId | Should -Be "FIELD_ID_1"
        $result.newValue | Should -Be "None"
    }

    It "returns null when both the main and secondary values are empty" {
        $result = Get-UpdateHash $null $null $Field "TARGET_ID" "--date" "Start date"
        $result | Should -BeNullOrEmpty
    }

    It "treats a secondary Estimate of 0 as a real value, not an empty one" {
        $result = Get-UpdateHash $null 0 $Field "TARGET_ID" "--number" "Estimate"
        $result | Should -Not -BeNullOrEmpty
        $result.clear | Should -BeFalse
        $result.newValue | Should -Be 0
    }

    It "does not clear an existing Estimate of 0 just because it looks falsy" {
        $result = Get-UpdateHash 0 0 $Field "TARGET_ID" "--number" "Estimate"
        $result | Should -BeNullOrEmpty
    }

    It "clears the field when the secondary value is an empty string" {
        $result = Get-UpdateHash "Old" "" $Field "TARGET_ID" "--single-select-option-id" "Status"
        $result.clear | Should -BeTrue
    }
}

Describe "Get-WeekWindow" {

    It "finds the current week from an item whose date range includes today" {
        $today = Get-Date "2026-07-07"
        $items = @(@{ week = @{ title = "Week 1"; startDate = "2026-07-04"; duration = 7 } })
        $result = Get-WeekWindow -Items $items -Today $today
        $result.current | Should -Be "Week 1"
    }

    It "finds the most recent previous week within the recent-past window" {
        $today = Get-Date "2026-07-07"
        $items = @(
            @{ week = @{ title = "Week Old"; startDate = "2026-06-15"; duration = 7 } }
            @{ week = @{ title = "Week Prev"; startDate = "2026-06-29"; duration = 7 } }
        )
        $result = Get-WeekWindow -Items $items -Today $today -RecentPastDays 14
        $result.previous | Should -Be "Week Prev"
    }

    It "ignores weeks that ended before the recent-past threshold" {
        $today = Get-Date "2026-07-07"
        $items = @(@{ week = @{ title = "Ancient"; startDate = "2026-01-01"; duration = 7 } })
        $result = Get-WeekWindow -Items $items -Today $today -RecentPastDays 14
        $result.previous | Should -BeNullOrEmpty
    }

    It "returns nulls when no items have week data" {
        $result = Get-WeekWindow -Items @(@{}) -Today (Get-Date "2026-07-07")
        $result.current | Should -BeNullOrEmpty
        $result.previous | Should -BeNullOrEmpty
    }
}

Describe "Get-ItemSyncScope" {
    BeforeAll {
        $validStatuses = @("Backlog", "In progress", "Done")
    }

    It "includes an item in the current week with a valid status" {
        $item = @{ week = @{ title = "W1" }; status = "In progress"; url = "https://x" }
        $result = Get-ItemSyncScope -Item $item -CurrentWeekTitle "W1" -PreviousWeekTitle $null -IsAlreadyInMain $false -ValidStatuses $validStatuses
        $result.inScope | Should -BeTrue
        $result.isLastWeek | Should -BeFalse
        $result.isOrphan | Should -BeFalse
    }

    It "includes a last-week item and flags isLastWeek" {
        $item = @{ week = @{ title = "W0" }; status = "Done"; url = "https://x" }
        $result = Get-ItemSyncScope -Item $item -CurrentWeekTitle "W1" -PreviousWeekTitle "W0" -IsAlreadyInMain $false -ValidStatuses $validStatuses
        $result.inScope | Should -BeTrue
        $result.isLastWeek | Should -BeTrue
    }

    It "includes an orphan item already on the main board even if its week doesn't match" {
        $item = @{ week = @{ title = "Ancient" }; status = "Done"; url = "https://x" }
        $result = Get-ItemSyncScope -Item $item -CurrentWeekTitle "W1" -PreviousWeekTitle "W0" -IsAlreadyInMain $true -ValidStatuses $validStatuses
        $result.inScope | Should -BeTrue
        $result.isOrphan | Should -BeTrue
    }

    It "excludes an out-of-window item that isn't already on the main board" {
        $item = @{ week = @{ title = "Ancient" }; status = "Done"; url = "https://x" }
        $result = Get-ItemSyncScope -Item $item -CurrentWeekTitle "W1" -PreviousWeekTitle "W0" -IsAlreadyInMain $false -ValidStatuses $validStatuses
        $result.inScope | Should -BeFalse
    }

    It "excludes an item with an invalid status" {
        $item = @{ week = @{ title = "W1" }; status = "Not A Real Status"; url = "https://x" }
        $result = Get-ItemSyncScope -Item $item -CurrentWeekTitle "W1" -PreviousWeekTitle $null -IsAlreadyInMain $false -ValidStatuses $validStatuses
        $result.inScope | Should -BeFalse
    }

    It "excludes an item with no URL" {
        $item = @{ week = @{ title = "W1" }; status = "Done"; url = $null }
        $result = Get-ItemSyncScope -Item $item -CurrentWeekTitle "W1" -PreviousWeekTitle $null -IsAlreadyInMain $false -ValidStatuses $validStatuses
        $result.inScope | Should -BeFalse
    }
}

Describe "Get-MidpointIterationMatch" {
    BeforeAll {
        $mainIterations = @(
            @{ id = "ITER_A"; startDate = "2026-06-29"; duration = 7 }
            @{ id = "ITER_B"; startDate = "2026-07-06"; duration = 7 }
        )
    }

    It "matches the main iteration whose range contains the secondary week's midpoint" {
        $result = Get-MidpointIterationMatch -WeekStartDate "2026-07-06" -WeekDuration 7 -MainIterations $mainIterations
        $result | Should -Be "ITER_B"
    }

    It "returns null when no main iteration contains the midpoint" {
        $result = Get-MidpointIterationMatch -WeekStartDate "2026-01-01" -WeekDuration 7 -MainIterations $mainIterations
        $result | Should -BeNullOrEmpty
    }

    It "returns null when there is no start date" {
        $result = Get-MidpointIterationMatch -WeekStartDate $null -WeekDuration 7 -MainIterations $mainIterations
        $result | Should -BeNullOrEmpty
    }
}

Describe "Test-IterationStartsAligned" {

    It "returns true when both iterations start on the same day" {
        Test-IterationStartsAligned -MainStartDate "2026-07-06" -SecondaryStartDate "2026-07-06" | Should -BeTrue
    }

    It "returns false when start dates differ" {
        Test-IterationStartsAligned -MainStartDate "2026-07-06" -SecondaryStartDate "2026-06-29" | Should -BeFalse
    }

    It "returns false when either date is missing" {
        Test-IterationStartsAligned -MainStartDate $null -SecondaryStartDate "2026-06-29" | Should -BeFalse
    }
}

Describe "New-ItemFieldUpdateMutation" {

    It "returns null for an empty update list" {
        New-ItemFieldUpdateMutation -Updates @() | Should -BeNullOrEmpty
    }

    It "builds an aliased mutation for a single-select update" {
        $updates = @(@{ fieldId = "FIELD_1"; flag = "--single-select-option-id"; value = "OPT_1"; clear = $false })
        $q = New-ItemFieldUpdateMutation -Updates $updates
        $q | Should -Match 'f0: updateProjectV2ItemFieldValue'
        $q | Should -Match 'singleSelectOptionId: "OPT_1"'
        $q | Should -Match '\$projectId: ID!, \$itemId: ID!'
    }

    It "builds a clear mutation" {
        $updates = @(@{ fieldId = "FIELD_1"; clear = $true })
        $q = New-ItemFieldUpdateMutation -Updates $updates
        $q | Should -Match 'f0: clearProjectV2ItemFieldValue'
    }

    It "aliases multiple updates uniquely in one mutation document" {
        $updates = @(
            @{ fieldId = "F1"; flag = "--number"; value = "5"; clear = $false }
            @{ fieldId = "F2"; flag = "--date"; value = "2026-07-07"; clear = $false }
        )
        $q = New-ItemFieldUpdateMutation -Updates $updates
        $q | Should -Match 'f0: updateProjectV2ItemFieldValue'
        $q | Should -Match 'f1: updateProjectV2ItemFieldValue'
        $q | Should -Match 'number: 5'
        $q | Should -Match 'date: "2026-07-07"'
    }

    It "escapes double quotes in values" {
        $updates = @(@{ fieldId = 'F1'; flag = "--date"; value = 'weird"value'; clear = $false })
        $q = New-ItemFieldUpdateMutation -Updates $updates
        $q | Should -Match 'weird\\"value'
    }
}
