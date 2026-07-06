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
}
