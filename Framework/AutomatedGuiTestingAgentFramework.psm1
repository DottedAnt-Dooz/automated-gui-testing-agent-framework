$script:ModuleRoot = Split-Path -Parent $PSCommandPath
$script:FrameworkRoot = Split-Path -Parent $script:ModuleRoot

function Get-AGTAFrameworkRoot {
    [CmdletBinding()]
    param()

    return $script:FrameworkRoot
}

function Resolve-AGTADefaultPotatoCliPath {
    [CmdletBinding()]
    param()

    $candidate = Join-Path -Path (Split-Path -Parent $script:FrameworkRoot) -ChildPath 'potato_cli\potato.ps1'
    return $candidate
}

function Read-AGTATestCaseCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Testcase CSV not found: $Path"
    }

    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $rows = Import-Csv -LiteralPath $resolved
    if (-not $rows) {
        throw "Testcase CSV is empty: $resolved"
    }

    $headers = @($rows[0].PSObject.Properties.Name)
    foreach ($required in @('Action', 'Data', 'Expected Result')) {
        if ($headers -notcontains $required) {
            throw "Testcase CSV must contain '$required'."
        }
    }

    $steps = @()
    $index = 0
    foreach ($row in $rows) {
        $index++
        $stepId = $null
        if ($headers -contains 'StepId' -and $row.StepId) { $stepId = [string]$row.StepId }
        if (-not $stepId) { $stepId = [string]$index }

        $data = ''
        if ($headers -contains 'Data') { $data = [string]$row.Data }

        $application = ''
        if ($headers -contains 'Application') { $application = [string]$row.Application }

        $notes = ''
        if ($headers -contains 'Notes') { $notes = [string]$row.Notes }

        $steps += [pscustomobject][ordered]@{
            stepIndex = $index
            stepId = $stepId
            action = [string]$row.Action
            data = $data
            expectedResult = [string]$row.'Expected Result'
            application = $application
            notes = $notes
            sourcePath = $resolved
        }
    }

    return $steps
}

function New-AGTARunDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $TestCaseCsv,

        [string] $RunsRoot = (Join-Path -Path (Get-AGTAFrameworkRoot) -ChildPath 'runs'),

        [string] $RunId
    )

    if (-not $RunId) {
        $RunId = '{0}_{1}' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), (New-Guid).Guid
    }

    $runRoot = Join-Path -Path $RunsRoot -ChildPath $RunId
    $paths = [ordered]@{
        runRoot = $runRoot
        input = Join-Path -Path $runRoot -ChildPath 'input'
        generated = Join-Path -Path $runRoot -ChildPath 'generated'
        evidence = Join-Path -Path $runRoot -ChildPath 'evidence'
        logs = Join-Path -Path $runRoot -ChildPath 'logs'
        results = Join-Path -Path $runRoot -ChildPath 'results'
    }

    foreach ($path in $paths.Values) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -Path $path -ItemType Directory -Force | Out-Null
        }
    }

    if (Test-Path -LiteralPath $TestCaseCsv) {
        Copy-Item -LiteralPath $TestCaseCsv -Destination (Join-Path -Path $paths.input -ChildPath (Split-Path -Leaf $TestCaseCsv)) -Force
    }

    $manifest = [ordered]@{
        runId = $RunId
        createdAt = (Get-Date).ToString('o')
        testCaseCsv = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TestCaseCsv)
        paths = $paths
    }
    $manifestPath = Join-Path -Path $paths.runRoot -ChildPath 'run.json'
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    return [pscustomobject][ordered]@{
        runId = $RunId
        runRoot = $paths.runRoot
        input = $paths.input
        generated = $paths.generated
        evidence = $paths.evidence
        logs = $paths.logs
        results = $paths.results
        manifestPath = $manifestPath
    }
}

function ConvertFrom-AGTAPotatoJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $RawOutput
    )

    $trimmed = $RawOutput.Trim()
    if (-not $trimmed) {
        throw 'PoTATo CLI returned empty output.'
    }

    try {
        $parsed = $trimmed | ConvertFrom-Json
    }
    catch {
        throw "PoTATo CLI returned invalid JSON. Output: $trimmed"
    }

    if ($null -eq $parsed.ok -or $null -eq $parsed.command) {
        throw 'PoTATo CLI JSON is missing required fields: ok, command.'
    }

    return $parsed
}

function Join-AGTAProcessArgument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments
    )

    $escaped = foreach ($arg in $Arguments) {
        if ($null -eq $arg) {
            '""'
        }
        elseif ($arg -match '[\s"]') {
            $escapedArg = $arg -replace '\\', '\\'
            $escapedArg = $escapedArg -replace '"', '\"'
            '"' + $escapedArg + '"'
        }
        else {
            $arg
        }
    }
    return ($escaped -join ' ')
}

function Invoke-AGTAProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $FilePath,

        [string[]] $Arguments = @()
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = Join-AGTAProcessArgument -Arguments $Arguments
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    return [pscustomobject][ordered]@{
        exitCode = $process.ExitCode
        stdout = $stdout
        stderr = $stderr
        commandLine = "$FilePath $($psi.Arguments)"
    }
}

function Write-AGTAJsonLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [object] $Object
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }
    $Object | ConvertTo-Json -Depth 30 -Compress | Add-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-AGTAPotatoJson {
    [CmdletBinding()]
    param(
        [string] $PotatoCliPath = (Resolve-AGTADefaultPotatoCliPath),

        [Parameter(Mandatory)]
        [string] $Command,

        [string[]] $Arguments = @(),

        [Parameter(Mandatory)]
        [string] $RunRoot
    )

    if (-not (Test-Path -LiteralPath $PotatoCliPath)) {
        throw "PoTATo CLI entrypoint not found: $PotatoCliPath"
    }

    $logPath = Join-Path -Path $RunRoot -ChildPath 'logs\potato-commands.jsonl'
    $processArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PotatoCliPath, $Command) + $Arguments
    $startedAt = Get-Date
    $processResult = Invoke-AGTAProcess -FilePath 'powershell.exe' -Arguments $processArgs
    $finishedAt = Get-Date

    $record = [ordered]@{
        startedAt = $startedAt.ToString('o')
        finishedAt = $finishedAt.ToString('o')
        command = $Command
        arguments = $Arguments
        exitCode = $processResult.exitCode
        stdout = $processResult.stdout
        stderr = $processResult.stderr
    }

    $parsed = $null
    try {
        $parsed = ConvertFrom-AGTAPotatoJson -RawOutput $processResult.stdout
        $record.parsed = $parsed
    }
    catch {
        $record.parseError = $_.Exception.Message
        Write-AGTAJsonLine -Path $logPath -Object $record
        throw
    }

    Write-AGTAJsonLine -Path $logPath -Object $record
    return $parsed
}

function New-AGTAStepResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Step,

        [ValidateSet('PASS', 'FAIL', 'SKIPPED')]
        [string] $Status = 'SKIPPED',

        [object[]] $Evidence = @(),

        [object[]] $Commands = @(),

        [object] $ErrorObject = $null
    )

    return [pscustomobject][ordered]@{
        stepIndex = [int]$Step.stepIndex
        action = [string]$Step.action
        expectedResult = [string]$Step.expectedResult
        status = $Status
        evidence = @($Evidence)
        commands = @($Commands)
        error = $ErrorObject
    }
}

function Test-AGTAGeneratedResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Result
    )

    $requiredTopLevel = @('ok', 'testCase', 'runRoot', 'startedAt', 'finishedAt', 'steps', 'summary', 'artifacts')
    foreach ($field in $requiredTopLevel) {
        if ($Result.PSObject.Properties.Name -notcontains $field) { return $false }
    }

    foreach ($step in @($Result.steps)) {
        foreach ($field in @('stepIndex', 'action', 'expectedResult', 'status', 'evidence', 'commands', 'error')) {
            if ($step.PSObject.Properties.Name -notcontains $field) { return $false }
        }
        if ($step.status -notin @('PASS', 'FAIL', 'SKIPPED')) { return $false }
    }

    return $true
}

function Get-AGTASystemPrompt {
    [CmdletBinding()]
    param()

    @'
You generate repeatable PowerShell GUI test scripts from CSV testcases.
Use only the provided tools for filesystem access, PoTATo CLI execution, and script validation.
The generated script must accept -PotatoCliPath, -TestCaseCsv, and -RunRoot.
The generated script must call potato_cli through a helper that parses one JSON object per command.
Each CSV row maps to one final step result with stepIndex, action, expectedResult, status, evidence, commands, and error.
The final generated script must write exactly one JSON object to stdout and save it to results\result.json.
Coordinate clicks are allowed only as documented fallbacks with screenshots.
Do not import old PoTATo testcases or legacy subsystems.
'@
}

function Get-AGTAUserPrompt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $Steps
    )

    $stepJson = $Steps | ConvertTo-Json -Depth 10
    @"
Create a repeatable PowerShell GUI test script for these testcase steps:

$stepJson

First inspect the environment with PoTATo commands as needed. Then write the generated script under the run folder. If execution is available, validate it once and fix concrete issues.
"@
}

function Get-AGTAOpenAITools {
    [CmdletBinding()]
    param()

    @(
        @{
            type = 'function'
            name = 'read_testcase'
            description = 'Return the parsed testcase CSV steps.'
            parameters = @{ type = 'object'; properties = @{}; additionalProperties = $false }
        },
        @{
            type = 'function'
            name = 'run_potato'
            description = 'Run an allowlisted PoTATo CLI command and return parsed JSON.'
            parameters = @{
                type = 'object'
                required = @('command')
                properties = @{
                    command = @{ type = 'string' }
                    arguments = @{ type = 'array'; items = @{ type = 'string' } }
                }
                additionalProperties = $false
            }
        },
        @{
            type = 'function'
            name = 'write_generated_script'
            description = 'Write or replace the generated PowerShell script under the run generated folder.'
            parameters = @{
                type = 'object'
                required = @('relativePath', 'content')
                properties = @{
                    relativePath = @{ type = 'string' }
                    content = @{ type = 'string' }
                }
                additionalProperties = $false
            }
        },
        @{
            type = 'function'
            name = 'run_generated_script'
            description = 'Run a generated script under the run generated folder.'
            parameters = @{
                type = 'object'
                required = @('relativePath')
                properties = @{ relativePath = @{ type = 'string' } }
                additionalProperties = $false
            }
        },
        @{
            type = 'function'
            name = 'read_artifact'
            description = 'Read a text artifact from the run folder.'
            parameters = @{
                type = 'object'
                required = @('relativePath')
                properties = @{
                    relativePath = @{ type = 'string' }
                    maxChars = @{ type = 'integer' }
                }
                additionalProperties = $false
            }
        },
        @{
            type = 'function'
            name = 'finalize'
            description = 'Finalize authoring with a summary and generated script path.'
            parameters = @{
                type = 'object'
                required = @('summary')
                properties = @{
                    summary = @{ type = 'string' }
                    scriptPath = @{ type = 'string' }
                }
                additionalProperties = $false
            }
        }
    )
}

function Assert-AGTASafeRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [string] $RelativePath
    )

    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "Path must be relative to the run folder: $RelativePath"
    }
    if ($RelativePath -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "Path may not traverse outside the run folder: $RelativePath"
    }

    $combined = Join-Path -Path $Root -ChildPath $RelativePath
    $rootFull = [System.IO.Path]::GetFullPath($Root)
    $combinedFull = [System.IO.Path]::GetFullPath($combined)
    if (-not $combinedFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path resolved outside run folder: $RelativePath"
    }
    return $combinedFull
}

function Invoke-AGTAAgentTool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [object] $Arguments,

        [Parameter(Mandatory)]
        [object] $Context
    )

    switch ($Name) {
        'read_testcase' {
            return @{ steps = @($Context.Steps) }
        }
        'run_potato' {
            $command = [string]$Arguments.command
            $allowed = @('state','windows','start','focus','observe','select','click','click-coordinate','type','hotkey','drag','hover','wait-element','wait-file','read','screenshot','close-window','report')
            if ($command -notin $allowed) { throw "PoTATo command is not allowed: $command" }
            $args = @()
            if ($Arguments.arguments) { $args = @($Arguments.arguments | ForEach-Object { [string]$_ }) }
            return Invoke-AGTAPotatoJson -PotatoCliPath $Context.PotatoCliPath -Command $command -Arguments $args -RunRoot $Context.Run.runRoot
        }
        'write_generated_script' {
            $path = Assert-AGTASafeRelativePath -Root $Context.Run.generated -RelativePath ([string]$Arguments.relativePath)
            $parent = Split-Path -Parent $path
            if (-not (Test-Path -LiteralPath $parent)) { New-Item -Path $parent -ItemType Directory -Force | Out-Null }
            Set-Content -LiteralPath $path -Value ([string]$Arguments.content) -Encoding UTF8
            return @{ path = $path; length = ([string]$Arguments.content).Length }
        }
        'run_generated_script' {
            if (-not $Context.Execute) { return @{ skipped = $true; reason = 'Execution disabled.' } }
            $path = Assert-AGTASafeRelativePath -Root $Context.Run.generated -RelativePath ([string]$Arguments.relativePath)
            if (-not (Test-Path -LiteralPath $path)) { throw "Generated script not found: $path" }
            $proc = Invoke-AGTAProcess -FilePath 'powershell.exe' -Arguments @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $path,
                '-PotatoCliPath', $Context.PotatoCliPath,
                '-TestCaseCsv', $Context.TestCaseCsv,
                '-RunRoot', $Context.Run.runRoot
            )
            $logPath = Join-Path -Path $Context.Run.logs -ChildPath 'generated-script-run.json'
            $proc | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $logPath -Encoding UTF8
            return @{ exitCode = $proc.exitCode; stdout = $proc.stdout; stderr = $proc.stderr; logPath = $logPath }
        }
        'read_artifact' {
            $maxChars = 4000
            if ($Arguments.maxChars) { $maxChars = [int]$Arguments.maxChars }
            $path = Assert-AGTASafeRelativePath -Root $Context.Run.runRoot -RelativePath ([string]$Arguments.relativePath)
            if (-not (Test-Path -LiteralPath $path)) { throw "Artifact not found: $path" }
            $content = Get-Content -LiteralPath $path -Raw
            if ($content.Length -gt $maxChars) { $content = $content.Substring(0, $maxChars) }
            return @{ path = $path; content = $content }
        }
        'finalize' {
            return @{ final = $true; summary = [string]$Arguments.summary; scriptPath = [string]$Arguments.scriptPath }
        }
        default {
            throw "Unknown tool: $Name"
        }
    }
}

function ConvertFrom-AGTAJsonObject {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $Value
    )

    if ($null -eq $Value) { return @{} }
    if ($Value -is [string]) {
        if (-not $Value) { return @{} }
        return $Value | ConvertFrom-Json
    }
    return $Value
}

function Get-AGTAResponseText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Response
    )

    if ($Response.output_text) { return [string]$Response.output_text }
    $parts = @()
    foreach ($item in @($Response.output)) {
        foreach ($content in @($item.content)) {
            if ($content.text) { $parts += [string]$content.text }
            elseif ($content.type -eq 'output_text' -and $content.PSObject.Properties.Name -contains 'text') { $parts += [string]$content.text }
        }
    }
    return ($parts -join [Environment]::NewLine)
}

function Get-AGTAFunctionCalls {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Response
    )

    $calls = @()
    foreach ($item in @($Response.output)) {
        if ($item.type -in @('function_call', 'tool_call')) {
            $calls += $item
        }
    }
    return $calls
}

function Invoke-AGTAOpenAIAuthoring {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Context,

        [Parameter(Mandatory)]
        [string] $Model,

        [int] $MaxIterations = 20,

        [string] $SystemPrompt,

        [string] $UserPrompt
    )

    $apiKey = $env:OPENAI_API_KEY
    if (-not $apiKey) { throw 'OPENAI_API_KEY is not set.' }

    $headers = @{
        Authorization = "Bearer $apiKey"
        'Content-Type' = 'application/json'
    }
    $uri = 'https://api.openai.com/v1/responses'
    $transcriptPath = Join-Path -Path $Context.Run.logs -ChildPath 'openai-responses.jsonl'
    $previousResponseId = $null
    if (-not $SystemPrompt) { $SystemPrompt = Get-AGTASystemPrompt }
    if (-not $UserPrompt) { $UserPrompt = Get-AGTAUserPrompt -Steps $Context.Steps }
    $input = @(
        @{ role = 'user'; content = $UserPrompt }
    )
    $final = $null

    for ($iteration = 1; $iteration -le $MaxIterations; $iteration++) {
        $body = [ordered]@{
            model = $Model
            instructions = $SystemPrompt
            input = $input
            tools = Get-AGTAOpenAITools
            tool_choice = 'auto'
            parallel_tool_calls = $false
        }
        if ($previousResponseId) {
            $body.previous_response_id = $previousResponseId
        }

        $response = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body ($body | ConvertTo-Json -Depth 80)
        Write-AGTAJsonLine -Path $transcriptPath -Object @{ iteration = $iteration; response = $response }
        $previousResponseId = $response.id
        $calls = @(Get-AGTAFunctionCalls -Response $response)

        if ($calls.Count -eq 0) {
            $final = [ordered]@{
                provider = 'OpenAI'
                model = $Model
                iterations = $iteration
                outputText = Get-AGTAResponseText -Response $response
                responseId = $response.id
                run = $Context.Run
            }
            break
        }

        $toolOutputs = @()
        foreach ($call in $calls) {
            $arguments = ConvertFrom-AGTAJsonObject -Value $call.arguments
            $toolResult = $null
            try {
                $toolResult = Invoke-AGTAAgentTool -Name ([string]$call.name) -Arguments $arguments -Context $Context
            }
            catch {
                $toolResult = @{ error = $_.Exception.Message }
            }
            $toolOutputs += @{
                type = 'function_call_output'
                call_id = $call.call_id
                output = ($toolResult | ConvertTo-Json -Depth 50 -Compress)
            }
        }
        $input = $toolOutputs
    }

    if (-not $final) {
        throw "OpenAI authoring did not finish within $MaxIterations iterations."
    }
    return $final
}

function Get-AGTAMockPaintScript {
    [CmdletBinding()]
    param()

    $path = Join-Path -Path (Get-AGTAFrameworkRoot) -ChildPath 'examples\MicrosoftPaint.Reference.ps1'
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Mock reference script not found: $path"
    }
    return Get-Content -LiteralPath $path -Raw
}

function Invoke-AGTAMockAuthoring {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Context
    )

    $scriptText = Get-AGTAMockPaintScript
    $toolResult = Invoke-AGTAAgentTool -Name 'write_generated_script' -Arguments ([pscustomobject]@{
        relativePath = 'MicrosoftPaint.Generated.ps1'
        content = $scriptText
    }) -Context $Context

    $execution = $null
    if ($Context.Execute) {
        $execution = Invoke-AGTAAgentTool -Name 'run_generated_script' -Arguments ([pscustomobject]@{
            relativePath = 'MicrosoftPaint.Generated.ps1'
        }) -Context $Context
    }

    return [pscustomobject][ordered]@{
        provider = 'Mock'
        scriptPath = $toolResult.path
        execution = $execution
        run = $Context.Run
        summary = 'Mock provider wrote the Paint reference script.'
    }
}

function Invoke-AGTAAgentAuthoring {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $TestCaseCsv,

        [ValidateSet('OpenAI', 'Mock')]
        [string] $Provider = 'OpenAI',

        [string] $Model = $(if ($env:OPENAI_MODEL) { $env:OPENAI_MODEL } else { 'gpt-5.5' }),

        [string] $PotatoCliPath = (Resolve-AGTADefaultPotatoCliPath),

        [switch] $Execute,

        [int] $MaxIterations = 20,

        [string] $SystemPrompt,

        [string] $UserPrompt
    )

    $steps = @(Read-AGTATestCaseCsv -Path $TestCaseCsv)
    $run = New-AGTARunDirectory -TestCaseCsv $TestCaseCsv
    $context = [pscustomobject][ordered]@{
        TestCaseCsv = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TestCaseCsv)
        Steps = $steps
        Run = $run
        PotatoCliPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PotatoCliPath)
        Execute = [bool]$Execute
    }

    switch ($Provider) {
        'Mock' { $result = Invoke-AGTAMockAuthoring -Context $context }
        'OpenAI' {
            $result = Invoke-AGTAOpenAIAuthoring `
                -Context $context `
                -Model $Model `
                -MaxIterations $MaxIterations `
                -SystemPrompt $SystemPrompt `
                -UserPrompt $UserPrompt
        }
    }

    $resultPath = Join-Path -Path $run.results -ChildPath 'authoring-result.json'
    $result | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $resultPath -Encoding UTF8
    return [pscustomobject][ordered]@{
        ok = $true
        provider = $Provider
        model = $Model
        runRoot = $run.runRoot
        resultPath = $resultPath
        result = $result
    }
}

Export-ModuleMember -Function `
    Get-AGTAFrameworkRoot, `
    Resolve-AGTADefaultPotatoCliPath, `
    Read-AGTATestCaseCsv, `
    New-AGTARunDirectory, `
    ConvertFrom-AGTAPotatoJson, `
    Invoke-AGTAPotatoJson, `
    New-AGTAStepResult, `
    Test-AGTAGeneratedResult, `
    Get-AGTASystemPrompt, `
    Invoke-AGTAAgentAuthoring, `
    Invoke-AGTAAgentTool, `
    Get-AGTAOpenAITools
