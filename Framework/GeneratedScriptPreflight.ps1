function Get-AGTARuntimeHelp {
    [CmdletBinding()]
    param([string] $Name)
    $published = @(
        'Initialize-AGTAGeneratedTest', 'Invoke-RecordedStep', 'Invoke-StepCommand',
        'Assert-PotatoOk', 'Assert-PotatoFound', 'Assert-FileWait',
        'Assert-ExpectedResult', 'Read-AGTAArtifactBytes', 'Assert-ArtifactPrefix',
        'Invoke-EvidenceScreenshot', 'Add-EvidencePath', 'Register-OpenedProcess',
        'Register-CreatedExternalPath', 'Invoke-TestCleanup',
        'Complete-AGTAGeneratedTest', 'Get-AGTATestExitCode',
        'Test-AGTAGeneratedScript', 'Assert-AGTAGeneratedScriptPreflight'
    )
    if ($Name -and $Name -notin $published) {
        throw "Unknown generated-runtime helper '$Name'. Call Get-AGTARuntimeHelp without -Name to list helpers."
    }
    $names = if ($Name) { @($Name) } else { $published }
    foreach ($helper in $names) {
        $command = Get-Command -Name $helper -CommandType Function -ErrorAction Stop
        [pscustomobject]@{
            name = $command.Name
            syntax = [string](Get-Command -Syntax -Name $helper)
            sourcePath = $command.ScriptBlock.File
            available = $true
        }
    }
}

function Test-AGTAGeneratedScript {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ScriptPath,
          [string] $TestCaseCsv,
          [string] $PotatoCliPath)
    $issues = @()
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        return [pscustomobject]@{ok=$false;issues=@("Script not found: $ScriptPath");checkedCommands=0}
    }
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$parseErrors)
    foreach ($error in @($parseErrors)) { $issues += "Line $($error.Extent.StartLineNumber): $($error.Message)" }
    if ($PotatoCliPath -and -not (Test-Path -LiteralPath $PotatoCliPath -PathType Leaf)) { $issues += "CLI entry point not found: $PotatoCliPath" }
    if ($TestCaseCsv) {
        if (-not (Test-Path -LiteralPath $TestCaseCsv -PathType Leaf)) { $issues += "Testcase CSV not found: $TestCaseCsv" }
        else {
            try {
                $rows = @(Import-Csv -LiteralPath $TestCaseCsv)
                if (-not $rows.Count) { $issues += 'Testcase CSV is empty.' }
                else {
                    foreach ($column in @('Action','Data','Expected Result')) {
                        if ($column -notin $rows[0].PSObject.Properties.Name) { $issues += "Testcase CSV missing column: $column" }
                    }
                }
            }
            catch { $issues += "Testcase CSV cannot be read: $($_.Exception.Message)" }
        }
    }
    $localFunctions = @{}
    foreach ($definition in @($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]}, $true))) {
        $localFunctions[$definition.Name] = $true
    }
    $checked = 0
    foreach ($call in @($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]}, $true))) {
        $name = $call.GetCommandName()
        if (-not $name -or $localFunctions.ContainsKey($name)) { continue }
        $checked++
        $command = Get-Command -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $command) {
            $issues += "Line $($call.Extent.StartLineNumber): command '$name' is unavailable. Dot-source its helper file or correct the name."
            continue
        }
        if ($command.CommandType -notin @('Function','Cmdlet','Alias')) { continue }
        foreach ($parameter in @($call.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] })) {
            if (-not $command.Parameters.ContainsKey($parameter.ParameterName)) {
                $issues += "Line $($parameter.Extent.StartLineNumber): '$name' has no parameter '-$($parameter.ParameterName)'."
            }
        }
    }
    return [pscustomobject]@{ok=($issues.Count -eq 0);issues=@($issues);checkedCommands=$checked}
}

function Assert-AGTAGeneratedScriptPreflight {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ScriptPath,
          [string] $TestCaseCsv,
          [string] $PotatoCliPath)
    $result = Test-AGTAGeneratedScript -ScriptPath $ScriptPath -TestCaseCsv $TestCaseCsv -PotatoCliPath $PotatoCliPath
    if (-not $result.ok) { throw ('Generated script preflight failed: ' + ($result.issues -join '; ')) }
    return $result
}
