[CmdletBinding()]
param(
    [string] $PotatoCliPath,
    [string] $TestCaseCsv,
    [string] $RunRoot
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

    [ordered]@{
        timestamp = (Get-Date).ToString('o')
        command = $Command
        arguments = $Arguments
        parsed = $parsed
    } | ConvertTo-Json -Depth 40 -Compress | Add-Content -LiteralPath (Join-Path $logsRoot 'potato-commands.jsonl') -Encoding UTF8

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

$csvSteps = Import-Csv -LiteralPath $TestCaseCsv
$stepResults = @()

# Replace this loop with concrete, explored GUI operations.
for ($i = 0; $i -lt $csvSteps.Count; $i++) {
    $step = $csvSteps[$i]
    $stepResults += New-StepResult `
        -StepIndex ($i + 1) `
        -Action $step.Action `
        -ExpectedResult $step.'Expected Result' `
        -Status 'SKIPPED' `
        -ErrorObject 'Template placeholder: implement this step.'
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
    startedAt = $startedAt.ToString('o')
    finishedAt = (Get-Date).ToString('o')
    steps = $stepResults
    summary = $summary
    artifacts = [ordered]@{
        resultPath = Join-Path -Path $resultsRoot -ChildPath 'result.json'
        evidenceRoot = $evidenceRoot
    }
}

$final | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $final.artifacts.resultPath -Encoding UTF8
$final | ConvertTo-Json -Depth 80 -Compress
