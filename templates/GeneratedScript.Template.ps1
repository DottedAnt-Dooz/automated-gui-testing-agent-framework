[CmdletBinding()]
param(
    [string] $PotatoCliPath,
    [string] $TestCaseCsv,
    [string] $RunRoot
)

$startedAt = Get-Date
$executionId = Get-Date -Format 'yyyyMMdd_HHmmss_ffff'
$testCaseName = Split-Path -Leaf $TestCaseCsv
$evidenceRoot = Join-Path -Path $RunRoot -ChildPath 'evidence'
$logsRoot = Join-Path -Path $RunRoot -ChildPath 'logs'
$resultsRoot = Join-Path -Path $RunRoot -ChildPath 'results'
$commandLogPath = Join-Path -Path $logsRoot -ChildPath ("potato-commands-$executionId.jsonl")
foreach ($path in @($RunRoot, $evidenceRoot, $logsRoot, $resultsRoot)) {
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -Path $path -ItemType Directory -Force | Out-Null
    }
}

$script:OpenedProcessNames = @()
$script:CreatedExternalPaths = @()
$script:CommandIndex = 0

function Invoke-PotatoJson {
    param(
        [Parameter(Mandatory)]
        [string] $Command,

        [string[]] $Arguments = @()
    )

    $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PotatoCliPath $Command @Arguments
    try {
        $parsed = ([string]$raw).Trim() | ConvertFrom-Json
    }
    catch {
        throw "PoTATo command did not return valid JSON. Output: $raw"
    }

    $script:CommandIndex++
    [ordered]@{
        index = $script:CommandIndex
        timestamp = (Get-Date).ToString('o')
        command = $Command
        arguments = $Arguments
        raw = [string]$raw
        parsed = $parsed
    } | ConvertTo-Json -Depth 60 -Compress | Add-Content -LiteralPath $commandLogPath -Encoding UTF8

    return $parsed
}

function New-CommandSummary {
    param(
        [Parameter(Mandatory)]
        [string] $Command,

        [string[]] $Arguments = @(),

        [Parameter(Mandatory)]
        [object] $Result
    )

    [pscustomobject][ordered]@{
        index = $script:CommandIndex
        command = $Command
        arguments = @($Arguments)
        ok = [bool]$Result.ok
        durationMs = [int]$Result.durationMs
        logPath = $commandLogPath
        error = $(if ($Result.error) { $Result.error.message } else { $null })
    }
}

function Invoke-StepCommand {
    param(
        [Parameter(Mandatory)]
        [ref] $Commands,

        [Parameter(Mandatory)]
        [string] $Command,

        [string[]] $Arguments = @()
    )

    $result = Invoke-PotatoJson -Command $Command -Arguments $Arguments
    $Commands.Value = @($Commands.Value) + (New-CommandSummary -Command $Command -Arguments $Arguments -Result $result)
    return $result
}

function Register-OpenedProcess {
    param(
        [Parameter(Mandatory)]
        [string] $ProcessName
    )

    if ($script:OpenedProcessNames -notcontains $ProcessName) {
        $script:OpenedProcessNames += $ProcessName
    }
}

function Register-CreatedExternalPath {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if ($script:CreatedExternalPaths -notcontains $Path) {
        $script:CreatedExternalPaths += $Path
    }
}

function Test-IsPathUnderRoot {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Root
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    return ($pathFull.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase) -or
        $pathFull.StartsWith($rootFull + '\', [System.StringComparison]::OrdinalIgnoreCase))
}

function Invoke-TestCleanup {
    $records = @()

    foreach ($processName in @($script:OpenedProcessNames | Select-Object -Unique)) {
        try {
            $lookupName = [System.IO.Path]::GetFileNameWithoutExtension($processName)
            if (-not @(Get-Process -Name $lookupName -ErrorAction SilentlyContinue)) {
                $records += [pscustomobject][ordered]@{
                    action = 'close-window'
                    target = $processName
                    ok = $true
                    error = $null
                    note = 'Process was not running.'
                }
                continue
            }
            $result = Invoke-PotatoJson -Command 'close-window' -Arguments @('-ProcessName', $processName)
            $records += [pscustomobject][ordered]@{
                action = 'close-window'
                target = $processName
                ok = [bool]$result.ok
                error = $(if ($result.error) { $result.error.message } else { $null })
            }
        }
        catch {
            $records += [pscustomobject][ordered]@{
                action = 'close-window'
                target = $processName
                ok = $false
                error = $_.Exception.Message
            }
        }
    }

    foreach ($path in @($script:CreatedExternalPaths | Select-Object -Unique)) {
        try {
            if (Test-IsPathUnderRoot -Path $path -Root $RunRoot) {
                $records += [pscustomobject][ordered]@{
                    action = 'preserve-run-artifact'
                    target = $path
                    ok = $true
                    error = $null
                }
                continue
            }
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Recurse -Force
            }
            $records += [pscustomobject][ordered]@{
                action = 'delete-created-path'
                target = $path
                ok = $true
                error = $null
            }
        }
        catch {
            $records += [pscustomobject][ordered]@{
                action = 'delete-created-path'
                target = $path
                ok = $false
                error = $_.Exception.Message
            }
        }
    }

    try {
        $result = Invoke-PotatoJson -Command 'state' -Arguments @('-Clear')
        $records += [pscustomobject][ordered]@{
            action = 'clear-potato-state'
            target = 'session'
            ok = [bool]$result.ok
            error = $(if ($result.error) { $result.error.message } else { $null })
        }
    }
    catch {
        $records += [pscustomobject][ordered]@{
            action = 'clear-potato-state'
            target = 'session'
            ok = $false
            error = $_.Exception.Message
        }
    }

    return $records
}

function New-StepResult {
    param(
        [int] $StepIndex,
        [string] $Action,
        [string] $ExpectedResult,
        [ValidateSet('PASS', 'FAIL', 'SKIPPED')]
        [string] $Status,
        [object[]] $Evidence = @(),
        [object[]] $Commands = @(),
        [object] $ErrorObject = $null
    )

    [pscustomobject][ordered]@{
        stepIndex = $StepIndex
        action = $Action
        expectedResult = $ExpectedResult
        status = $Status
        evidence = @($Evidence)
        commands = @($Commands)
        error = $ErrorObject
    }
}

$csvSteps = Import-Csv -LiteralPath $TestCaseCsv
$stepResults = @()
$cleanup = @()

# Replace this block with concrete, explored GUI operations.
# Register every app started with Register-OpenedProcess.
# Register fixed-path or external files with Register-CreatedExternalPath.
# Use Invoke-StepCommand inside step bodies so result JSON contains compact
# command summaries while full PoTATo responses stay in $commandLogPath.
try {
    for ($i = 0; $i -lt $csvSteps.Count; $i++) {
        $step = $csvSteps[$i]
        $stepResults += New-StepResult `
            -StepIndex ($i + 1) `
            -Action $step.Action `
            -ExpectedResult $step.'Expected Result' `
            -Status 'SKIPPED' `
            -ErrorObject 'Template placeholder: implement this step.'
    }
}
finally {
    $cleanup = @(Invoke-TestCleanup)
}

$summary = [ordered]@{
    total = $stepResults.Count
    passed = @($stepResults | Where-Object { $_.status -eq 'PASS' }).Count
    failed = @($stepResults | Where-Object { $_.status -eq 'FAIL' }).Count
    skipped = @($stepResults | Where-Object { $_.status -eq 'SKIPPED' }).Count
}
$final = [ordered]@{
    ok = ($summary.failed -eq 0 -and $summary.skipped -eq 0)
    testCase = $testCaseName
    runRoot = $RunRoot
    executionId = $executionId
    startedAt = $startedAt.ToString('o')
    finishedAt = (Get-Date).ToString('o')
    steps = $stepResults
    summary = $summary
    artifacts = [ordered]@{
        resultPath = Join-Path -Path $resultsRoot -ChildPath 'result.json'
        evidenceRoot = $evidenceRoot
        commandLogPath = $commandLogPath
        cleanup = $cleanup
    }
    cleanup = $cleanup
}

$final | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $final.artifacts.resultPath -Encoding UTF8
$final | ConvertTo-Json -Depth 80 -Compress
