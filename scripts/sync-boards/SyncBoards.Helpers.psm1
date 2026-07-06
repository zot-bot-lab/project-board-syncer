# Pure helper functions for sync-boards.ps1, split out so they can be unit-tested
# with Pester without executing the main script's side effects (API calls, config I/O).

function Get-UpdateHash {
    param($mVal, $sVal, $field, $targetId, $flag, $fieldName)
    if (-not $field) { return $null }
    if ($sVal) {
        if (-not $mVal -or $mVal -ne $sVal) {
            return @{ fieldId = $field.id; flag = $flag; value = [string]$targetId; clear = $false; name = $fieldName; newValue = $sVal }
        }
    } else {
        if ($mVal) {
            return @{ fieldId = $field.id; clear = $true; name = $fieldName; newValue = "None" }
        }
    }
    return $null
}

Export-ModuleMember -Function Get-UpdateHash
