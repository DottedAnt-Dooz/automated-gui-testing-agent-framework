$projectRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path -Path $projectRoot -ChildPath 'Framework\AutomatedGuiTestingAgentFramework.psm1'
Import-Module $modulePath -Force

Describe 'Framework CSV parsing' {
    It 'reads the sample Paint testcase' {
        $csv = Join-Path -Path $projectRoot -ChildPath 'Microsoft Paint.csv'
        $steps = @(Read-AGTATestCaseCsv -Path $csv)
        $steps.Count | Should Be 5
        $steps[0].stepIndex | Should Be 1
        $steps[0].action | Should Be 'Open Paint'
        $steps[0].expectedResult | Should Be 'Paint opened'
    }

    It 'rejects CSV files without required columns' {
        $badCsv = Join-Path -Path $TestDrive -ChildPath 'bad.csv'
        "Action,Data`nOpen app," | Set-Content -LiteralPath $badCsv -Encoding UTF8
        { Read-AGTATestCaseCsv -Path $badCsv } | Should Throw
    }

    It 'requires the Data column even when values are empty' {
        $badCsv = Join-Path -Path $TestDrive -ChildPath 'missing-data.csv'
        "Action,Expected Result`nOpen app,Opened" | Set-Content -LiteralPath $badCsv -Encoding UTF8
        { Read-AGTATestCaseCsv -Path $badCsv } | Should Throw
    }
}

Describe 'Framework run folders' {
    It 'creates the required run directory structure' {
        $csv = Join-Path -Path $projectRoot -ChildPath 'Microsoft Paint.csv'
        $runsRoot = Join-Path -Path $TestDrive -ChildPath 'runs'
        $run = New-AGTARunDirectory -TestCaseCsv $csv -RunsRoot $runsRoot -RunId 'test-run'

        Test-Path -LiteralPath $run.runRoot | Should Be $true
        Test-Path -LiteralPath $run.input | Should Be $true
        Test-Path -LiteralPath $run.generated | Should Be $true
        Test-Path -LiteralPath $run.evidence | Should Be $true
        Test-Path -LiteralPath $run.logs | Should Be $true
        Test-Path -LiteralPath $run.results | Should Be $true
        Test-Path -LiteralPath $run.manifestPath | Should Be $true
    }
}

Describe 'Framework PoTATo JSON parsing' {
    It 'parses a valid PoTATo CLI response' {
        $json = '{"ok":true,"command":"state","data":{"value":1}}'
        $parsed = ConvertFrom-AGTAPotatoJson -RawOutput $json
        $parsed.ok | Should Be $true
        $parsed.command | Should Be 'state'
        $parsed.data.value | Should Be 1
    }

    It 'fails clearly on invalid PoTATo CLI JSON' {
        { ConvertFrom-AGTAPotatoJson -RawOutput 'not json' } | Should Throw
    }
}

Describe 'Framework generated result schema' {
    It 'accepts a compliant generated result object' {
        $result = [pscustomobject][ordered]@{
            ok = $true
            testCase = 'x.csv'
            runRoot = 'C:\run'
            startedAt = (Get-Date).ToString('o')
            finishedAt = (Get-Date).ToString('o')
            steps = @(
                [pscustomobject][ordered]@{
                    stepIndex = 1
                    action = 'Open Paint'
                    expectedResult = 'Paint opened'
                    status = 'PASS'
                    evidence = @()
                    commands = @()
                    error = $null
                }
            )
            summary = [pscustomobject]@{ total = 1; passed = 1; failed = 0; skipped = 0 }
            artifacts = [pscustomobject]@{ resultPath = 'C:\run\results\result.json'; evidenceRoot = 'C:\run\evidence' }
        }

        Test-AGTAGeneratedResult -Result $result | Should Be $true
    }

    It 'rejects a result with an invalid step status' {
        $result = [pscustomobject][ordered]@{
            ok = $true
            testCase = 'x.csv'
            runRoot = 'C:\run'
            startedAt = ''
            finishedAt = ''
            steps = @(
                [pscustomobject][ordered]@{
                    stepIndex = 1
                    action = 'A'
                    expectedResult = 'B'
                    status = 'DONE'
                    evidence = @()
                    commands = @()
                    error = $null
                }
            )
            summary = @{}
            artifacts = @{}
        }

        Test-AGTAGeneratedResult -Result $result | Should Be $false
    }
}

Describe 'Framework mock authoring' {
    It 'writes a generated Paint script without live API calls' {
        $csv = Join-Path -Path $projectRoot -ChildPath 'Microsoft Paint.csv'
        $potato = Join-Path -Path (Split-Path -Parent $projectRoot) -ChildPath 'potato_cli\potato.ps1'
        $result = Invoke-AGTAAgentAuthoring -TestCaseCsv $csv -Provider Mock -PotatoCliPath $potato

        $result.ok | Should Be $true
        $result.provider | Should Be 'Mock'
        Test-Path -LiteralPath $result.result.scriptPath | Should Be $true
        Test-Path -LiteralPath $result.resultPath | Should Be $true
    }

    It 'accepts custom prompt arguments on the authoring function' {
        $csv = Join-Path -Path $projectRoot -ChildPath 'Microsoft Paint.csv'
        $potato = Join-Path -Path (Split-Path -Parent $projectRoot) -ChildPath 'potato_cli\potato.ps1'
        $result = Invoke-AGTAAgentAuthoring `
            -TestCaseCsv $csv `
            -Provider Mock `
            -PotatoCliPath $potato `
            -SystemPrompt 'custom system prompt' `
            -UserPrompt 'custom user prompt'

        $result.ok | Should Be $true
        $result.provider | Should Be 'Mock'
    }
}

Describe 'Framework GUI source' {
    It 'parses the WinForms launcher without starting it' {
        $gui = Join-Path -Path $projectRoot -ChildPath 'Invoke-AgentAuthoringGui.ps1'
        $content = Get-Content -LiteralPath $gui -Raw
        [scriptblock]::Create($content) | Out-Null
    }

    It 'exports the default system prompt for the GUI' {
        (Get-AGTASystemPrompt) | Should Match 'repeatable PowerShell GUI test scripts'
    }

    It 'binds CSV preview rows through a stable binding source' {
        $gui = Join-Path -Path $projectRoot -ChildPath 'Invoke-AgentAuthoringGui.ps1'
        $content = Get-Content -LiteralPath $gui -Raw
        $content | Should Match ([regex]::Escape('return ,$table'))
        $content | Should Match 'System\.Windows\.Forms\.BindingSource'
        $content | Should Match ([regex]::Escape('$script:StepsTable.DefaultView'))
        $content | Should Match ([regex]::Escape('$stepsGrid.DataSource = $script:StepsBindingSource'))
    }

    It 'shows only core testcase columns in the GUI editor' {
        $gui = Join-Path -Path $projectRoot -ChildPath 'Invoke-AgentAuthoringGui.ps1'
        $content = Get-Content -LiteralPath $gui -Raw
        $content | Should Match ([regex]::Escape("@('StepId', 'Action', 'Data', 'Expected Result')"))
        $content | Should Not Match ([regex]::Escape("Application = [string]`$row['Application']"))
        $content | Should Not Match ([regex]::Escape("Notes = [string]`$row['Notes']"))
    }

    It 'keeps the API settings page scrollable and fill-docked' {
        $gui = Join-Path -Path $projectRoot -ChildPath 'Invoke-AgentAuthoringGui.ps1'
        $content = Get-Content -LiteralPath $gui -Raw
        $content | Should Match ([regex]::Escape('$apiPanel.AutoScroll = $true'))
        $content | Should Match ([regex]::Escape('$apiPanel.Dock = ''Fill'''))
        $content | Should Match ([regex]::Escape('$apiLayout.Dock = ''Fill'''))
    }
}

Describe 'Framework static exclusions' {
    It 'does not import excluded legacy automation subsystems from PowerShell source' {
        $excluded = @(
            ('Import-Module ' + 'Potato'),
            ('Get-Potato' + 'CoreFile'),
            ('Selen' + 'ium'),
            ('Image' + 'Recognition'),
            ('Use-' + 'NavigateBrowser'),
            ('Ji' + 'ra'),
            ('Hyper' + 'V'),
            ('VS' + 'phere'),
            ('ME' + 'MCM')
        )
        $sourceFiles = Get-ChildItem -Path $projectRoot -Recurse -File |
            Where-Object {
                $_.Extension -in @('.ps1', '.psm1', '.psd1') -and
                $_.FullName -notmatch '\\tests\\' -and
                $_.FullName -notmatch '\\runs\\'
            }

        foreach ($file in $sourceFiles) {
            $content = Get-Content -LiteralPath $file.FullName -Raw
            foreach ($term in $excluded) {
                $content | Should Not Match ([regex]::Escape($term))
            }
        }
    }
}
