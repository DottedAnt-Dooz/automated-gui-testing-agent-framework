[CmdletBinding()]
param(
    [string] $PotatoCliPath = (Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -ChildPath 'potato_cli\potato.ps1'),
    [string] $TestCaseCsv = (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Microsoft Paint.csv'),
    [string] $RunRoot = (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath ('runs\paint-reference-' + (Get-Date -Format 'yyyyMMdd-HHmmss')))
)

$startedAt = Get-Date
$testCaseName = Split-Path -Leaf $TestCaseCsv
$evidenceRoot = Join-Path -Path $RunRoot -ChildPath 'evidence'
$logsRoot = Join-Path -Path $RunRoot -ChildPath 'logs'
$resultsRoot = Join-Path -Path $RunRoot -ChildPath 'results'
foreach ($path in @($RunRoot, $evidenceRoot, $logsRoot, $resultsRoot)) {
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -Path $path -ItemType Directory -Force | Out-Null
    }
}

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
    $record = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        command = $Command
        arguments = $Arguments
        raw = [string]$raw
        parsed = $parsed
    }
    $record | ConvertTo-Json -Depth 40 -Compress | Add-Content -LiteralPath (Join-Path $logsRoot 'potato-commands.jsonl') -Encoding UTF8
    return $parsed
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
        [string[]] $Names,
        [string] $ControlType = 'Button',
        [int] $TimeoutMs = 5000
    )

    foreach ($name in $Names) {
        $result = Invoke-PotatoJson -Command 'click' -Arguments @('-Name', $name, '-ControlType', $ControlType, '-FindFirst', '-TimeoutMs', "$TimeoutMs")
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

try {
    $commands = @()
    $commands += Invoke-PotatoJson -Command 'state' -Arguments @('-Clear')
    $commands += Invoke-PotatoJson -Command 'start' -Arguments @('-ProcessName', 'mspaint.exe', '-WaitForWindowMs', '30000')
    $commands += Invoke-PotatoJson -Command 'observe' -Arguments @('-Depth', '2', '-MaxElements', '200')
    $shot = Invoke-PotatoJson -Command 'screenshot'
    $results += New-StepResult -StepIndex 1 -Action $steps[0].Action -ExpectedResult $steps[0].'Expected Result' -Status 'PASS' -Evidence @($shot.data.path) -Commands $commands
}
catch {
    $results += New-StepResult -StepIndex 1 -Action $steps[0].Action -ExpectedResult $steps[0].'Expected Result' -Status 'FAIL' -ErrorObject $_.Exception.Message
}

try {
    $commands = @()
    # Coordinate fallback: current Paint canvas is not consistently exposed with stable selectors across Windows builds.
    $commands += Invoke-PotatoJson -Command 'screenshot'
    $commands += Invoke-PotatoJson -Command 'drag' -Arguments @('-StartX', '330', '-StartY', '280', '-EndX', '760', '-EndY', '430', '-Smooth')
    $commands += Invoke-PotatoJson -Command 'drag' -Arguments @('-StartX', '350', '-StartY', '440', '-EndX', '820', '-EndY', '300', '-Smooth')
    $commands += Invoke-PotatoJson -Command 'hotkey' -Arguments @('-Keys', '^s', '-Focus')
    Start-Sleep -Milliseconds 700
    $commands += Invoke-PotatoJson -Command 'hotkey' -Arguments @('-Keys', '^a', '-Focus')
    $commands += Invoke-PotatoJson -Command 'type' -Arguments @('-Text', $createdImage, '-Focus')
    $commands += Invoke-ClickAny -Names @('Save', 'Speichern') -ControlType 'Button'
    $wait = Invoke-PotatoJson -Command 'wait-file' -Arguments @('-Path', $createdImage, '-TimeoutMs', '10000')
    $status = if ($wait.data.conditionMet) { 'PASS' } else { 'FAIL' }
    $results += New-StepResult -StepIndex 2 -Action $steps[1].Action -ExpectedResult $steps[1].'Expected Result' -Status $status -Evidence @($createdImage) -Commands ($commands + $wait)
}
catch {
    $results += New-StepResult -StepIndex 2 -Action $steps[1].Action -ExpectedResult $steps[1].'Expected Result' -Status 'FAIL' -Evidence @($createdImage) -ErrorObject $_.Exception.Message
}

try {
    $commands = @()
    $commands += Invoke-PotatoJson -Command 'hotkey' -Arguments @('-Keys', '^o', '-Focus')
    Start-Sleep -Milliseconds 700
    $commands += Invoke-PotatoJson -Command 'hotkey' -Arguments @('-Keys', '^a', '-Focus')
    $commands += Invoke-PotatoJson -Command 'type' -Arguments @('-Text', $createdImage, '-Focus')
    $commands += Invoke-ClickAny -Names @('Open', 'Oeffnen') -ControlType 'Button'
    $shot = Invoke-PotatoJson -Command 'screenshot'
    $results += New-StepResult -StepIndex 3 -Action $steps[2].Action -ExpectedResult $steps[2].'Expected Result' -Status 'PASS' -Evidence @($shot.data.path) -Commands $commands
}
catch {
    $results += New-StepResult -StepIndex 3 -Action $steps[2].Action -ExpectedResult $steps[2].'Expected Result' -Status 'FAIL' -ErrorObject $_.Exception.Message
}

try {
    $commands = @()
    $commands += Invoke-PotatoJson -Command 'hotkey' -Arguments @('-Keys', '^p', '-Focus')
    Start-Sleep -Milliseconds 1000
    $commands += Invoke-PotatoJson -Command 'observe' -Arguments @('-Depth', '2', '-MaxElements', '250')
    $commands += Invoke-PotatoJson -Command 'click' -Arguments @('-Name', 'Microsoft Print to PDF', '-FindFirst', '-TimeoutMs', '3000')
    $commands += Invoke-ClickAny -Names @('Print', 'Drucken') -ControlType 'Button'
    Start-Sleep -Milliseconds 1000
    $commands += Invoke-PotatoJson -Command 'hotkey' -Arguments @('-Keys', '^a', '-Focus')
    $commands += Invoke-PotatoJson -Command 'type' -Arguments @('-Text', $printedPdf, '-Focus')
    $commands += Invoke-ClickAny -Names @('Save', 'Speichern') -ControlType 'Button'
    $wait = Invoke-PotatoJson -Command 'wait-file' -Arguments @('-Path', $printedPdf, '-TimeoutMs', '15000')
    $status = if ($wait.data.conditionMet) { 'PASS' } else { 'FAIL' }
    $results += New-StepResult -StepIndex 4 -Action $steps[3].Action -ExpectedResult $steps[3].'Expected Result' -Status $status -Evidence @($printedPdf) -Commands ($commands + $wait)
}
catch {
    $results += New-StepResult -StepIndex 4 -Action $steps[3].Action -ExpectedResult $steps[3].'Expected Result' -Status 'FAIL' -Evidence @($printedPdf) -ErrorObject $_.Exception.Message
}

try {
    $commands = @()
    $commands += Invoke-PotatoJson -Command 'close-window' -Arguments @('-ProcessName', 'mspaint')
    $results += New-StepResult -StepIndex 5 -Action $steps[4].Action -ExpectedResult $steps[4].'Expected Result' -Status 'PASS' -Commands $commands
}
catch {
    $results += New-StepResult -StepIndex 5 -Action $steps[4].Action -ExpectedResult $steps[4].'Expected Result' -Status 'FAIL' -ErrorObject $_.Exception.Message
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
    startedAt = $startedAt.ToString('o')
    finishedAt = $finishedAt.ToString('o')
    steps = $results
    summary = $summary
    artifacts = [ordered]@{
        resultPath = Join-Path -Path $resultsRoot -ChildPath 'result.json'
        evidenceRoot = $evidenceRoot
    }
}

$final | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $final.artifacts.resultPath -Encoding UTF8
$final | ConvertTo-Json -Depth 80 -Compress
