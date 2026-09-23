function Initialize-AGTAGeneratedTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $PotatoCliPath,

        [Parameter(Mandatory)]
        [string] $TestCaseCsv,

        [Parameter(Mandatory)]
        [string] $RunRoot,

        [string] $ExecutionId = (Get-Date -Format 'yyyyMMdd_HHmmss_ffff'),

        [switch] $RequireAssertions
    )

    if (-not (Test-Path -LiteralPath $PotatoCliPath)) {
        throw "PoTATo CLI was not found: $PotatoCliPath"
    }
    if (-not (Test-Path -LiteralPath $TestCaseCsv)) {
        throw "Testcase CSV was not found: $TestCaseCsv"
    }

    $steps = @(Import-Csv -LiteralPath $TestCaseCsv)
    if ($steps.Count -eq 0) { throw 'Testcase CSV must contain at least one step.' }
    foreach ($column in @('Action', 'Data', 'Expected Result')) {
        if ($steps[0].PSObject.Properties.Name -notcontains $column) { throw "Testcase CSV must contain '$column'." }
    }
    $startedAt = Get-Date
    $testCaseName = Split-Path -Leaf $TestCaseCsv
    $evidenceRoot = Join-Path -Path $RunRoot -ChildPath 'evidence'
    $logsRoot = Join-Path -Path $RunRoot -ChildPath 'logs'
    $resultsRoot = Join-Path -Path $RunRoot -ChildPath 'results'
    $executionEvidenceRoot = Join-Path -Path $evidenceRoot -ChildPath $ExecutionId
    $commandLogPath = Join-Path -Path $logsRoot -ChildPath ("potato-commands-$ExecutionId.jsonl")
    $resultPath = Join-Path -Path $resultsRoot -ChildPath 'result.json'

    foreach ($path in @($RunRoot, $evidenceRoot, $logsRoot, $resultsRoot, $executionEvidenceRoot)) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -Path $path -ItemType Directory -Force | Out-Null
        }
    }

    $script:AGTAGeneratedTestContext = [pscustomobject][ordered]@{
        PotatoCliPath = $PotatoCliPath
        TestCaseCsv = $TestCaseCsv
        TestCaseName = $testCaseName
        RunRoot = $RunRoot
        EvidenceRoot = $evidenceRoot
        LogsRoot = $logsRoot
        ResultsRoot = $resultsRoot
        ExecutionEvidenceRoot = $executionEvidenceRoot
        CommandLogPath = $commandLogPath
        ResultPath = $resultPath
        ExecutionId = $ExecutionId
        StartedAt = $startedAt
        Steps = $steps
        RequireAssertions = [bool]$RequireAssertions
    }
    $script:AGTAOpenedProcessNames = @()
    $script:AGTACreatedExternalPaths = @()
    $script:AGTACommandIndex = 0

    return $script:AGTAGeneratedTestContext
}

function Get-AGTAGeneratedTestContext {
    [CmdletBinding()]
    param()

    if (-not $script:AGTAGeneratedTestContext) {
        throw 'Generated test runtime is not initialized. Call Initialize-AGTAGeneratedTest first.'
    }
    return $script:AGTAGeneratedTestContext
}

function ConvertFrom-PotatoOutput {
    [CmdletBinding()]
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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Command,

        [string[]] $Arguments = @()
    )

    $context = Get-AGTAGeneratedTestContext
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $raw = @()
    $exitCode = 0
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $context.PotatoCliPath $Command @Arguments 2>&1 | ForEach-Object { $raw += $_ }
        $exitCode = $LASTEXITCODE
    }
    catch { $raw += $_.ToString(); $exitCode = 1 }
    $watch.Stop()
    $rawText = (@($raw) -join [Environment]::NewLine)
    try {
        $parsed = ConvertFrom-PotatoOutput -RawOutput $rawText
        if ($exitCode -ne 0) { throw "PoTATo process exited with code $exitCode." }
    }
    catch {
        $parsed = [pscustomobject]@{
            ok = $false; command = $Command; data = $null; durationMs = [int]$watch.ElapsedMilliseconds
            error = @{ message = "PoTATo returned invalid output or exited unsuccessfully (exit code $exitCode). See $($context.CommandLogPath)."; type = 'TransportError' }
        }
    }

    $script:AGTACommandIndex++
    [ordered]@{
        index = $script:AGTACommandIndex
        timestamp = (Get-Date).ToString('o')
        command = $Command
        arguments = @($Arguments)
        raw = $rawText
        parsed = $parsed
        wrapperDurationMs = [int]$watch.ElapsedMilliseconds
        exitCode = $exitCode
    } | ConvertTo-Json -Depth 80 -Compress | Add-Content -LiteralPath $context.CommandLogPath -Encoding UTF8

    return $parsed
}

function New-CommandSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Command,

        [string[]] $Arguments = @(),

        [Parameter(Mandatory)]
        [object] $Result
    )

    $context = Get-AGTAGeneratedTestContext
    [pscustomobject][ordered]@{
        index = $script:AGTACommandIndex
        command = $Command
        arguments = @($Arguments)
        ok = [bool]$Result.ok
        durationMs = [int]$Result.durationMs
        logPath = $context.CommandLogPath
        error = $(if ($Result.error) { $Result.error.message } else { $null })
    }
}

function Invoke-StepCommand {
    [CmdletBinding()]
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

function Assert-PotatoOk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Result,

        [string] $Message = 'PoTATo command failed.'
    )

    if (-not [bool]$Result.ok -or ($Result.data.verificationPerformed -and $Result.data.verified -eq $false)) {
        $detail = if ($Result.error) { $Result.error.message } else { 'No error detail returned.' }
        throw "$Message $detail"
    }
}

function Test-PotatoFound {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Result
    )

    if (-not [bool]$Result.ok) { return $false }
    if ($null -ne $Result.data.exists) { return [bool]$Result.data.exists }
    if ($null -ne $Result.data.count) { return ([int]$Result.data.count -gt 0) }
    if ($null -ne $Result.data.element) { return $true }
    if ($null -ne $Result.data.selected) { return $true }
    return $false
}

function Assert-PotatoFound {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Result,

        [string] $Message = 'Expected GUI element was not found.'
    )

    Assert-PotatoOk -Result $Result -Message $Message
    Assert-ExpectedResult -Condition (Test-PotatoFound -Result $Result) -Message $Message
}

function Assert-FileWait {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Result,

        [Parameter(Mandatory)]
        [string] $Path
    )

    Assert-PotatoOk -Result $Result -Message "Waiting for file failed: $Path"
    $conditionMet = $false
    if ($null -ne $Result.data.conditionMet) { $conditionMet = [bool]$Result.data.conditionMet }
    elseif ($null -ne $Result.data.exists) { $conditionMet = [bool]$Result.data.exists }
    Assert-ExpectedResult -Condition $conditionMet -Message "File condition must be met: $Path"
}

function Assert-ExpectedResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [bool] $Condition,
        [Parameter(Mandatory)] [string] $Message
    )
    $script:AGTAStepAssertions = @($script:AGTAStepAssertions) + [pscustomobject]@{ description = $Message; passed = $Condition }
    if (-not $Condition) { throw $Message }
}

function Add-EvidencePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ref] $Evidence,

        [string] $Path
    )

    if ($Path) {
        $Evidence.Value = @($Evidence.Value) + $Path
    }
}

function Invoke-EvidenceScreenshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ref] $Commands,

        [Parameter(Mandatory)]
        [ref] $Evidence,

        [Parameter(Mandatory)]
        [string] $FileName
    )

    $context = Get-AGTAGeneratedTestContext
    $path = Join-Path -Path $context.ExecutionEvidenceRoot -ChildPath $FileName
    $shot = Invoke-StepCommand -Commands $Commands -Command 'screenshot' -Arguments @('-OutFile', $path)
    Assert-PotatoOk -Result $shot -Message 'Screenshot capture failed.'
    Add-EvidencePath -Evidence $Evidence -Path $shot.data.path
    return $shot
}

function Invoke-ClickAny {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ref] $Commands,

        [Parameter(Mandatory)]
        [string[]] $Names,

        [string] $ControlType = 'Button',

        [int] $TimeoutMs = 3000
    )

    $last = $null
    foreach ($name in $Names) {
        $arguments = @('-Name', $name, '-FindFirst', '-TimeoutMs', "$TimeoutMs")
        if ($ControlType) {
            $arguments += @('-ControlType', $ControlType)
        }
        $last = Invoke-StepCommand -Commands $Commands -Command 'click' -Arguments $arguments
        if ($last.ok -and $last.data.clicked) {
            return $last
        }
    }
    return $last
}

function Register-OpenedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ProcessName
    )

    if ($script:AGTAOpenedProcessNames -notcontains $ProcessName) {
        $script:AGTAOpenedProcessNames += $ProcessName
    }
}

function Register-CreatedExternalPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if ($script:AGTACreatedExternalPaths -notcontains $Path) {
        $script:AGTACreatedExternalPaths += $Path
    }
}

function Test-IsPathUnderRoot {
    [CmdletBinding()]
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

function Invoke-OptionalCleanupClick {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $Names,

        [string] $ControlType = 'Button',

        [int] $TimeoutMs = 600
    )

    foreach ($name in $Names) {
        try {
            $selectArgs = @('-Name', $name, '-ControlType', $ControlType, '-FindFirst', '-TimeoutMs', "$TimeoutMs")
            $found = Invoke-PotatoJson -Command 'select' -Arguments $selectArgs
            if (Test-PotatoFound -Result $found) {
                $clickArgs = @('-Name', $name, '-ControlType', $ControlType, '-FindFirst', '-TimeoutMs', "$TimeoutMs")
                $clicked = Invoke-PotatoJson -Command 'click' -Arguments $clickArgs
                return [pscustomobject][ordered]@{
                    action = 'optional-click'
                    target = $name
                    ok = [bool]$clicked.ok
                    error = $(if ($clicked.error) { $clicked.error.message } else { $null })
                }
            }
        }
        catch {
            return [pscustomobject][ordered]@{
                action = 'optional-click'
                target = $name
                ok = $false
                error = $_.Exception.Message
            }
        }
    }
    return $null
}

function Invoke-TestCleanup {
    [CmdletBinding()]
    param(
        [string[]] $DiscardPromptNames = @("Don't Save", 'Do Not Save', 'No'),

        [string] $DiscardPromptControlType = 'Button',

        [int] $CloseTimeoutMs = 2500,

        [int] $PromptTimeoutMs = 600
    )

    $context = Get-AGTAGeneratedTestContext
    $records = @()

    foreach ($processName in @($script:AGTAOpenedProcessNames | Select-Object -Unique)) {
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

            $result = Invoke-PotatoJson -Command 'close-window' -Arguments @('-ProcessName', $lookupName, '-TimeoutMs', "$CloseTimeoutMs")
            $records += [pscustomobject][ordered]@{
                action = 'close-window'
                target = $lookupName
                ok = [bool]$result.ok
                error = $(if ($result.error) { $result.error.message } else { $null })
            }

            Start-Sleep -Milliseconds 250
            if (-not @(Get-Process -Name $lookupName -ErrorAction SilentlyContinue)) {
                continue
            }

            $discard = Invoke-OptionalCleanupClick -Names $DiscardPromptNames -ControlType $DiscardPromptControlType -TimeoutMs $PromptTimeoutMs
            if ($discard) {
                $records += $discard
                Start-Sleep -Milliseconds 250
                if (@(Get-Process -Name $lookupName -ErrorAction SilentlyContinue)) {
                    $retry = Invoke-PotatoJson -Command 'close-window' -Arguments @('-ProcessName', $lookupName, '-TimeoutMs', "$CloseTimeoutMs")
                    $records += [pscustomobject][ordered]@{
                        action = 'close-window'
                        target = $lookupName
                        ok = [bool]$retry.ok
                        error = $(if ($retry.error) { $retry.error.message } else { $null })
                        note = 'Retry after optional discard prompt.'
                    }
                }
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

    foreach ($path in @($script:AGTACreatedExternalPaths | Select-Object -Unique)) {
        try {
            if (Test-IsPathUnderRoot -Path $path -Root $context.RunRoot) {
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
    [CmdletBinding()]
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

function Get-TestStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int] $StepIndex
    )

    $context = Get-AGTAGeneratedTestContext
    if ($StepIndex -gt 0 -and $StepIndex -le $context.Steps.Count) {
        return $context.Steps[$StepIndex - 1]
    }

    return [pscustomobject][ordered]@{
        Action = "Step $StepIndex"
        'Expected Result' = ''
    }
}

function Invoke-RecordedStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int] $StepIndex,

        [Parameter(Mandatory)]
        [scriptblock] $Body
    )

    $step = Get-TestStep -StepIndex $StepIndex
    $commands = @()
    $evidence = @()
    $script:AGTAStepAssertions = @()

    try {
        & $Body ([ref]$commands) ([ref]$evidence) | Out-Null
        if ((Get-AGTAGeneratedTestContext).RequireAssertions -and $script:AGTAStepAssertions.Count -eq 0) {
            throw 'No expected-result assertion was recorded. Command success or a screenshot alone cannot pass a step.'
        }
        if (@($script:AGTAStepAssertions | Where-Object { -not $_.passed }).Count) { throw 'An expected-result assertion failed.' }
        $result = New-StepResult -StepIndex $StepIndex -Action $step.Action -ExpectedResult $step.'Expected Result' -Status 'PASS' -Evidence $evidence -Commands $commands
    }
    catch {
        $failure = $_.Exception.Message
        # Preserve the failing state before cleanup; a capture error must not mask it.
        try { Invoke-EvidenceScreenshot -Commands ([ref]$commands) -Evidence ([ref]$evidence) -FileName ("step-{0}-failure.png" -f $StepIndex) | Out-Null } catch {}
        $result = New-StepResult -StepIndex $StepIndex -Action $step.Action -ExpectedResult $step.'Expected Result' -Status 'FAIL' -Evidence $evidence -Commands $commands -ErrorObject $failure
    }
    $result | Add-Member -NotePropertyName assertions -NotePropertyValue @($script:AGTAStepAssertions)
    return $result
}

function Complete-AGTAGeneratedTest {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]] $StepResults = @(),

        [AllowEmptyCollection()]
        [object[]] $Cleanup = @(),

        [switch] $AllowSkipped,

        [object] $ExtraArtifacts = $null
    )

    $context = Get-AGTAGeneratedTestContext
    $summary = [ordered]@{
        total = @($StepResults).Count
        passed = @($StepResults | Where-Object { $_.status -eq 'PASS' }).Count
        failed = @($StepResults | Where-Object { $_.status -eq 'FAIL' }).Count
        skipped = @($StepResults | Where-Object { $_.status -eq 'SKIPPED' }).Count
    }

    $artifacts = [ordered]@{
        resultPath = $context.ResultPath
        evidenceRoot = $context.EvidenceRoot
        executionEvidenceRoot = $context.ExecutionEvidenceRoot
        commandLogPath = $context.CommandLogPath
        cleanup = @($Cleanup)
    }
    $extraArtifactTable = @{}
    if ($ExtraArtifacts -is [hashtable]) {
        $extraArtifactTable = $ExtraArtifacts
    }
    elseif ($ExtraArtifacts -and $ExtraArtifacts -is [System.Collections.Specialized.OrderedDictionary]) {
        foreach ($key in $ExtraArtifacts.Keys) {
            $extraArtifactTable[$key] = $ExtraArtifacts[$key]
        }
    }
    foreach ($key in @($extraArtifactTable.Keys)) {
        $artifacts[$key] = $extraArtifactTable[$key]
    }

    $coverageOk = ($summary.total -eq $context.Steps.Count)
    for ($index = 1; $index -le $context.Steps.Count; $index++) {
        if (@($StepResults | Where-Object { $_.stepIndex -eq $index -and $_.action -ceq $context.Steps[$index - 1].Action -and $_.expectedResult -ceq $context.Steps[$index - 1].'Expected Result' }).Count -ne 1) { $coverageOk = $false }
    }
    $validStatuses = @($StepResults | Where-Object { $_.status -notin @('PASS', 'FAIL', 'SKIPPED') }).Count -eq 0
    $cleanupOk = @($Cleanup | Where-Object { $_.ok -ne $true }).Count -eq 0
    $assertionsOk = $true
    if ($context.RequireAssertions) {
        foreach ($step in $StepResults) {
            if ($step.status -eq 'PASS' -and (@($step.assertions).Count -eq 0 -or $null -eq $step.assertions -or @($step.assertions | Where-Object { $_.passed -ne $true }).Count -gt 0)) { $assertionsOk = $false }
        }
    }
    $ok = ($coverageOk -and $validStatuses -and $cleanupOk -and $assertionsOk -and $summary.failed -eq 0 -and $summary.skipped -eq 0)
    $final = [ordered]@{
        ok = $ok
        testCase = $context.TestCaseName
        runRoot = $context.RunRoot
        executionId = $context.ExecutionId
        startedAt = $context.StartedAt.ToString('o')
        finishedAt = (Get-Date).ToString('o')
        steps = @($StepResults)
        summary = $summary
        artifacts = $artifacts
        cleanup = @($Cleanup)
        coverageOk = $coverageOk
        cleanupOk = $cleanupOk
        assertionsOk = $assertionsOk
    }

    $final | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $context.ResultPath -Encoding UTF8
    $final | ConvertTo-Json -Depth 80 -Compress
}
