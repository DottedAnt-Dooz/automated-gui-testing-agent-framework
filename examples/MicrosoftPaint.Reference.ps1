[CmdletBinding()]
param(
    [string] $PotatoCliPath = (Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -ChildPath 'potato_cli\potato.ps1'),
    [string] $TestCaseCsv = (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Microsoft Paint.csv'),
    [string] $RunRoot = (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath ('runs\paint-reference-' + (Get-Date -Format 'yyyyMMdd-HHmmss')))
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

function ConvertFrom-PotatoOutput {
    param(
        [Parameter(Mandatory)]
        [string] $RawOutput
    )

    try {
        return ($RawOutput.Trim() | ConvertFrom-Json)
    }
    catch {
        throw "PoTATo command did not return valid JSON. Output: $RawOutput"
    }
}

function Invoke-PotatoJson {
    param(
        [Parameter(Mandatory)]
        [string] $Command,

        [string[]] $Arguments = @()
    )

    $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PotatoCliPath $Command @Arguments
    $parsed = ConvertFrom-PotatoOutput -RawOutput ([string]$raw)
    $script:CommandIndex++
    $record = [ordered]@{
        index = $script:CommandIndex
        timestamp = (Get-Date).ToString('o')
        command = $Command
        arguments = $Arguments
        raw = [string]$raw
        parsed = $parsed
    }
    $record | ConvertTo-Json -Depth 60 -Compress | Add-Content -LiteralPath $commandLogPath -Encoding UTF8
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

function Invoke-ClickAny {
    param(
        [Parameter(Mandatory)]
        [ref] $Commands,

        [string[]] $Names,
        [string] $ControlType = 'Button',
        [int] $TimeoutMs = 5000
    )

    foreach ($name in $Names) {
        $result = Invoke-StepCommand -Commands $Commands -Command 'click' -Arguments @('-Name', $name, '-ControlType', $ControlType, '-FindFirst', '-TimeoutMs', "$TimeoutMs")
        if ($result.ok -and $result.data.clicked) {
            return $result
        }
    }
    return $result
}

$steps = Import-Csv -LiteralPath $TestCaseCsv
$results = @()
$createdImage = Join-Path -Path $evidenceRoot -ChildPath 'PaintSmoke.png'
$printedPdf = Join-Path -Path $evidenceRoot -ChildPath 'PaintSmoke.pdf'
$cleanup = @()
Register-CreatedExternalPath -Path $createdImage
Register-CreatedExternalPath -Path $printedPdf

try {
    try {
        $commands = @()
        Invoke-StepCommand -Commands ([ref]$commands) -Command 'state' -Arguments @('-Clear') | Out-Null
        Invoke-StepCommand -Commands ([ref]$commands) -Command 'start' -Arguments @('-ProcessName', 'mspaint.exe', '-WaitForWindowMs', '30000') | Out-Null
        Register-OpenedProcess -ProcessName 'mspaint'
        Invoke-StepCommand -Commands ([ref]$commands) -Command 'observe' -Arguments @('-Depth', '2', '-MaxElements', '200') | Out-Null
        $shot = Invoke-StepCommand -Commands ([ref]$commands) -Command 'screenshot'
        $results += New-StepResult -StepIndex 1 -Action $steps[0].Action -ExpectedResult $steps[0].'Expected Result' -Status 'PASS' -Evidence @($shot.data.path) -Commands $commands
    }
    catch {
        $results += New-StepResult -StepIndex 1 -Action $steps[0].Action -ExpectedResult $steps[0].'Expected Result' -Status 'FAIL' -ErrorObject $_.Exception.Message
    }

    try {
        $commands = @()
        # Coordinate fallback: current Paint canvas is not consistently exposed with stable selectors across Windows builds.
        Invoke-StepCommand -Commands ([ref]$commands) -Command 'screenshot' | Out-Null
        Invoke-StepCommand -Commands ([ref]$commands) -Command 'drag' -Arguments @('-StartX', '330', '-StartY', '280', '-EndX', '760', '-EndY', '430', '-Smooth') | Out-Null
        Invoke-StepCommand -Commands ([ref]$commands) -Command 'drag' -Arguments @('-StartX', '350', '-StartY', '440', '-EndX', '820', '-EndY', '300', '-Smooth') | Out-Null
        Invoke-StepCommand -Commands ([ref]$commands) -Command 'hotkey' -Arguments @('-Keys', '^s', '-Focus') | Out-Null
        Start-Sleep -Milliseconds 700
        Invoke-StepCommand -Commands ([ref]$commands) -Command 'hotkey' -Arguments @('-Keys', '^a', '-Focus') | Out-Null
        Invoke-StepCommand -Commands ([ref]$commands) -Command 'type' -Arguments @('-Text', $createdImage, '-Focus') | Out-Null
        Invoke-ClickAny -Commands ([ref]$commands) -Names @('Save', 'Speichern') -ControlType 'Button' | Out-Null
        $wait = Invoke-StepCommand -Commands ([ref]$commands) -Command 'wait-file' -Arguments @('-Path', $createdImage, '-TimeoutMs', '10000')
        $status = if ($wait.data.conditionMet) { 'PASS' } else { 'FAIL' }
        $results += New-StepResult -StepIndex 2 -Action $steps[1].Action -ExpectedResult $steps[1].'Expected Result' -Status $status -Evidence @($createdImage) -Commands $commands
    }
    catch {
        $results += New-StepResult -StepIndex 2 -Action $steps[1].Action -ExpectedResult $steps[1].'Expected Result' -Status 'FAIL' -Evidence @($createdImage) -ErrorObject $_.Exception.Message
    }

    try {
        $commands = @()
        Invoke-StepCommand -Commands ([ref]$commands) -Command 'hotkey' -Arguments @('-Keys', '^o', '-Focus') | Out-Null
        Start-Sleep -Milliseconds 700
        Invoke-StepCommand -Commands ([ref]$commands) -Command 'hotkey' -Arguments @('-Keys', '^a', '-Focus') | Out-Null
        Invoke-StepCommand -Commands ([ref]$commands) -Command 'type' -Arguments @('-Text', $createdImage, '-Focus') | Out-Null
        Invoke-ClickAny -Commands ([ref]$commands) -Names @('Open', 'Oeffnen') -ControlType 'Button' | Out-Null
        $shot = Invoke-StepCommand -Commands ([ref]$commands) -Command 'screenshot'
        $results += New-StepResult -StepIndex 3 -Action $steps[2].Action -ExpectedResult $steps[2].'Expected Result' -Status 'PASS' -Evidence @($shot.data.path) -Commands $commands
    }
    catch {
        $results += New-StepResult -StepIndex 3 -Action $steps[2].Action -ExpectedResult $steps[2].'Expected Result' -Status 'FAIL' -ErrorObject $_.Exception.Message
    }

    try {
        $commands = @()
        Invoke-StepCommand -Commands ([ref]$commands) -Command 'hotkey' -Arguments @('-Keys', '^p', '-Focus') | Out-Null
        Start-Sleep -Milliseconds 1000
        Invoke-StepCommand -Commands ([ref]$commands) -Command 'observe' -Arguments @('-Depth', '2', '-MaxElements', '250') | Out-Null
        Invoke-StepCommand -Commands ([ref]$commands) -Command 'click' -Arguments @('-Name', 'Microsoft Print to PDF', '-FindFirst', '-TimeoutMs', '3000') | Out-Null
        Invoke-ClickAny -Commands ([ref]$commands) -Names @('Print', 'Drucken') -ControlType 'Button' | Out-Null
        Start-Sleep -Milliseconds 1000
        Invoke-StepCommand -Commands ([ref]$commands) -Command 'hotkey' -Arguments @('-Keys', '^a', '-Focus') | Out-Null
        Invoke-StepCommand -Commands ([ref]$commands) -Command 'type' -Arguments @('-Text', $printedPdf, '-Focus') | Out-Null
        Invoke-ClickAny -Commands ([ref]$commands) -Names @('Save', 'Speichern') -ControlType 'Button' | Out-Null
        $wait = Invoke-StepCommand -Commands ([ref]$commands) -Command 'wait-file' -Arguments @('-Path', $printedPdf, '-TimeoutMs', '15000')
        $status = if ($wait.data.conditionMet) { 'PASS' } else { 'FAIL' }
        $results += New-StepResult -StepIndex 4 -Action $steps[3].Action -ExpectedResult $steps[3].'Expected Result' -Status $status -Evidence @($printedPdf) -Commands $commands
    }
    catch {
        $results += New-StepResult -StepIndex 4 -Action $steps[3].Action -ExpectedResult $steps[3].'Expected Result' -Status 'FAIL' -Evidence @($printedPdf) -ErrorObject $_.Exception.Message
    }

    try {
        $commands = @()
        Invoke-StepCommand -Commands ([ref]$commands) -Command 'close-window' -Arguments @('-ProcessName', 'mspaint') | Out-Null
        $results += New-StepResult -StepIndex 5 -Action $steps[4].Action -ExpectedResult $steps[4].'Expected Result' -Status 'PASS' -Commands $commands
    }
    catch {
        $results += New-StepResult -StepIndex 5 -Action $steps[4].Action -ExpectedResult $steps[4].'Expected Result' -Status 'FAIL' -ErrorObject $_.Exception.Message
    }
}
finally {
    $cleanup = @(Invoke-TestCleanup)
}

$finishedAt = Get-Date
$summary = [ordered]@{
    total = $results.Count
    passed = @($results | Where-Object { $_.status -eq 'PASS' }).Count
    failed = @($results | Where-Object { $_.status -eq 'FAIL' }).Count
    skipped = @($results | Where-Object { $_.status -eq 'SKIPPED' }).Count
}
$final = [ordered]@{
    ok = ($summary.failed -eq 0)
    testCase = $testCaseName
    runRoot = $RunRoot
    executionId = $executionId
    startedAt = $startedAt.ToString('o')
    finishedAt = $finishedAt.ToString('o')
    steps = $results
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
