BeforeAll {
    $ConfigPath = Join-Path $PSScriptRoot "..\sync-config.json"
    $RawConfig = Get-Content -Raw $ConfigPath
}

Describe "sync-config.json" {

    It "is valid JSON" {
        { $RawConfig | ConvertFrom-Json } | Should -Not -Throw
    }

    Context "shape" {
        BeforeAll {
            $Config = $RawConfig | ConvertFrom-Json
        }

        It "has a mainBoard with org and projectNumber" {
            $Config.mainBoard.org | Should -Not -BeNullOrEmpty
            $Config.mainBoard.projectNumber | Should -BeOfType [int]
        }

        It "has at least one secondary board" {
            $Config.secondaryBoards.Count | Should -BeGreaterThan 0
        }

        It "gives every secondary board an org and a numeric projectNumber" {
            foreach ($board in $Config.secondaryBoards) {
                $board.org | Should -Not -BeNullOrEmpty -Because "every board entry must declare its org"
                $board.projectNumber | Should -BeOfType [int] -Because "$($board.org) is missing a numeric projectNumber"
            }
        }

        It "has no duplicate (org, projectNumber) pairs across secondary boards" {
            $keys = $Config.secondaryBoards | ForEach-Object { "$($_.org)#$($_.projectNumber)" }
            $duplicates = $keys | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name }
            $duplicates | Should -BeNullOrEmpty -Because "duplicate board entries would sync the same board twice"
        }

        It "has a non-empty validStatuses list" {
            $Config.validStatuses.Count | Should -BeGreaterThan 0
        }

        It "has a numeric changelogRetentionDays" {
            $Config.changelogRetentionDays | Should -BeOfType [int]
        }
    }
}
