[CmdletBinding()]
param(
    [string] $InitialCsv = (Join-Path -Path $PSScriptRoot -ChildPath 'Microsoft Paint.csv'),

    [string] $PotatoCliPath = '',

    [ValidateSet('OpenAI', 'Mock')]
    [string] $Provider = 'OpenAI',

    [string] $Model = $(if ($env:OPENAI_MODEL) { $env:OPENAI_MODEL } else { 'gpt-5.5' }),

    [switch] $NoAutoLoad
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Data

$script:FrameworkRoot = $PSScriptRoot
$script:ModulePath = Join-Path -Path $script:FrameworkRoot -ChildPath 'Framework\AutomatedGuiTestingAgentFramework.psm1'
$script:EntryPointPath = Join-Path -Path $script:FrameworkRoot -ChildPath 'Invoke-AgentAuthoring.ps1'
Import-Module $script:ModulePath -Force

if (-not $PotatoCliPath) {
    $PotatoCliPath = Resolve-AGTADefaultPotatoCliPath
}

$script:StepsTable = $null
$script:StepsBindingSource = $null
$script:CurrentCsvPath = $null
$script:CurrentProcess = $null
$script:LastRunRoot = $null
$script:LastResultPath = $null

function New-AGTAGuiSize {
    param([int] $Width, [int] $Height)
    return New-Object System.Drawing.Size($Width, $Height)
}

function New-AGTAGuiPoint {
    param([int] $X, [int] $Y)
    return New-Object System.Drawing.Point($X, $Y)
}

function New-AGTAGuiPadding {
    param([int] $All)
    return New-Object System.Windows.Forms.Padding($All)
}

function Join-AGTAGuiProcessArgument {
    param([string[]] $Arguments)

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

function New-AGTAGuiButton {
    param(
        [string] $Text,
        [int] $Width = 96
    )

    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Width = $Width
    $button.Height = 30
    $button.Margin = New-AGTAGuiPadding 4
    return $button
}

function New-AGTAGuiLabel {
    param([string] $Text)

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.AutoSize = $true
    $label.Margin = New-AGTAGuiPadding 4
    $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    return $label
}

function New-AGTAStepTable {
    param([object[]] $Rows)

    $table = New-Object System.Data.DataTable
    foreach ($name in @('StepId', 'Action', 'Data', 'Expected Result')) {
        [void]$table.Columns.Add($name, [string])
    }

    $index = 0
    foreach ($row in @($Rows)) {
        $index++
        $dataRow = $table.NewRow()
        foreach ($name in @('StepId', 'Action', 'Data', 'Expected Result')) {
            $value = ''
            if ($row.PSObject.Properties.Name -contains $name) {
                $value = [string]$row.$name
            }
            elseif ($name -eq 'StepId') {
                $value = [string]$index
            }
            $dataRow[$name] = $value
        }
        [void]$table.Rows.Add($dataRow)
    }

    return ,$table
}

function Set-AGTAGuiStepsTable {
    param([System.Data.DataTable] $Table)

    $script:StepsTable = $Table
    if ($null -eq $script:StepsBindingSource) {
        $script:StepsBindingSource = New-Object System.Windows.Forms.BindingSource
    }

    $script:StepsBindingSource.DataSource = $script:StepsTable.DefaultView
    $stepsGrid.AutoGenerateColumns = $true
    $stepsGrid.DataSource = $script:StepsBindingSource
    $stepsGrid.Refresh()
}

function Get-AGTAGuiStepRecords {
    param([System.Data.DataTable] $Table)

    $records = @()
    $index = 0
    foreach ($row in $Table.Rows) {
        if ($row.RowState -eq [System.Data.DataRowState]::Deleted) { continue }

        $action = [string]$row['Action']
        $data = [string]$row['Data']
        $expected = [string]$row['Expected Result']
        if (-not $action -and -not $data -and -not $expected) { continue }

        $index++
        $stepId = [string]$row['StepId']
        if (-not $stepId) { $stepId = [string]$index }

        $records += [pscustomobject][ordered]@{
            StepId = $stepId
            Action = $action
            Data = $data
            'Expected Result' = $expected
        }
    }
    return $records
}

function Export-AGTAGuiStepCsv {
    param(
        [System.Data.DataTable] $Table,
        [string] $Path
    )

    $records = @(Get-AGTAGuiStepRecords -Table $Table)
    if ($records.Count -eq 0) {
        throw 'The testcase must contain at least one step.'
    }

    foreach ($record in $records) {
        if (-not [string]$record.Action) { throw 'Every step must have an Action value.' }
        if (-not [string]$record.'Expected Result') { throw 'Every step must have an Expected Result value.' }
    }

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }
    $records | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
    return $records
}

function New-AGTAGuiStatePath {
    param(
        [string] $ChildFolder,
        [string] $Extension
    )

    $root = Join-Path -Path $script:FrameworkRoot -ChildPath '.state\gui'
    $folder = Join-Path -Path $root -ChildPath $ChildFolder
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -Path $folder -ItemType Directory -Force | Out-Null
    }

    $name = '{0}_{1}{2}' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), ([guid]::NewGuid().ToString('N')), $Extension
    return Join-Path -Path $folder -ChildPath $name
}

function Get-AGTAGuiPathForExplorer {
    param([string] $Path)

    if (-not $Path) { return $null }
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return Split-Path -Parent $Path }
    if (Test-Path -LiteralPath $Path -PathType Container) { return $Path }
    return $null
}

[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Automated GUI Testing Agent Framework'
$form.Size = New-AGTAGuiSize 1180 780
$form.MinimumSize = New-AGTAGuiSize 980 650
$form.StartPosition = 'CenterScreen'

$root = New-Object System.Windows.Forms.TableLayoutPanel
$root.Dock = 'Fill'
$root.ColumnCount = 1
$root.RowCount = 3
$root.Padding = New-AGTAGuiPadding 8
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 46)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 168)))
$form.Controls.Add($root)

$filePanel = New-Object System.Windows.Forms.TableLayoutPanel
$filePanel.Dock = 'Fill'
$filePanel.ColumnCount = 5
$filePanel.RowCount = 1
[void]$filePanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 38)))
[void]$filePanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$filePanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 94)))
[void]$filePanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 86)))
[void]$filePanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 120)))
[void]$root.Controls.Add($filePanel, 0, 0)

$csvLabel = New-AGTAGuiLabel 'CSV'
$csvTextBox = New-Object System.Windows.Forms.TextBox
$csvTextBox.Dock = 'Fill'
$csvTextBox.Margin = New-AGTAGuiPadding 4
$browseCsvButton = New-AGTAGuiButton 'Browse' 86
$loadCsvButton = New-AGTAGuiButton 'Load' 78
$saveCsvButton = New-AGTAGuiButton 'Save Copy' 110
[void]$filePanel.Controls.Add($csvLabel, 0, 0)
[void]$filePanel.Controls.Add($csvTextBox, 1, 0)
[void]$filePanel.Controls.Add($browseCsvButton, 2, 0)
[void]$filePanel.Controls.Add($loadCsvButton, 3, 0)
[void]$filePanel.Controls.Add($saveCsvButton, 4, 0)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$tabs.Margin = New-AGTAGuiPadding 4
[void]$root.Controls.Add($tabs, 0, 1)

$testcaseTab = New-Object System.Windows.Forms.TabPage
$testcaseTab.Text = 'Testcase'
$testcaseTab.UseVisualStyleBackColor = $true
$promptTab = New-Object System.Windows.Forms.TabPage
$promptTab.Text = 'Prompts'
$promptTab.UseVisualStyleBackColor = $true
$apiTab = New-Object System.Windows.Forms.TabPage
$apiTab.Text = 'API Run'
$apiTab.UseVisualStyleBackColor = $true
[void]$tabs.TabPages.Add($testcaseTab)
[void]$tabs.TabPages.Add($promptTab)
[void]$tabs.TabPages.Add($apiTab)

$testcaseLayout = New-Object System.Windows.Forms.TableLayoutPanel
$testcaseLayout.Dock = 'Fill'
$testcaseLayout.RowCount = 2
$testcaseLayout.ColumnCount = 1
[void]$testcaseLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$testcaseLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 44)))
$testcaseTab.Controls.Add($testcaseLayout)

$stepsGrid = New-Object System.Windows.Forms.DataGridView
$stepsGrid.Dock = 'Fill'
$stepsGrid.AllowUserToAddRows = $true
$stepsGrid.AllowUserToDeleteRows = $true
$stepsGrid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
$stepsGrid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$stepsGrid.MultiSelect = $true
$stepsGrid.RowHeadersWidth = 34
$stepsGrid.AutoGenerateColumns = $true
$stepsGrid.BackgroundColor = [System.Drawing.SystemColors]::Window
$stepsGrid.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
[void]$testcaseLayout.Controls.Add($stepsGrid, 0, 0)

$stepButtonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$stepButtonPanel.Dock = 'Fill'
$stepButtonPanel.FlowDirection = 'LeftToRight'
$addStepButton = New-AGTAGuiButton 'Add Step' 92
$deleteStepButton = New-AGTAGuiButton 'Delete Step' 104
$renumberButton = New-AGTAGuiButton 'Renumber' 96
[void]$stepButtonPanel.Controls.Add($addStepButton)
[void]$stepButtonPanel.Controls.Add($deleteStepButton)
[void]$stepButtonPanel.Controls.Add($renumberButton)
[void]$testcaseLayout.Controls.Add($stepButtonPanel, 0, 1)

$promptSplit = New-Object System.Windows.Forms.SplitContainer
$promptSplit.Dock = 'Fill'
$promptSplit.Orientation = [System.Windows.Forms.Orientation]::Horizontal
$promptSplit.SplitterDistance = 230
$promptTab.Controls.Add($promptSplit)

$systemPromptPanel = New-Object System.Windows.Forms.TableLayoutPanel
$systemPromptPanel.Dock = 'Fill'
$systemPromptPanel.RowCount = 2
$systemPromptPanel.ColumnCount = 1
[void]$systemPromptPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 34)))
[void]$systemPromptPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$promptSplit.Panel1.Controls.Add($systemPromptPanel)

$systemPromptHeader = New-Object System.Windows.Forms.FlowLayoutPanel
$systemPromptHeader.Dock = 'Fill'
$systemPromptLabel = New-AGTAGuiLabel 'System prompt'
$resetSystemPromptButton = New-AGTAGuiButton 'Reset' 74
[void]$systemPromptHeader.Controls.Add($systemPromptLabel)
[void]$systemPromptHeader.Controls.Add($resetSystemPromptButton)
[void]$systemPromptPanel.Controls.Add($systemPromptHeader, 0, 0)

$systemPromptTextBox = New-Object System.Windows.Forms.TextBox
$systemPromptTextBox.Dock = 'Fill'
$systemPromptTextBox.Multiline = $true
$systemPromptTextBox.ScrollBars = 'Both'
$systemPromptTextBox.AcceptsReturn = $true
$systemPromptTextBox.AcceptsTab = $true
$systemPromptTextBox.Font = New-Object System.Drawing.Font('Consolas', 9)
[void]$systemPromptPanel.Controls.Add($systemPromptTextBox, 0, 1)

$userPromptPanel = New-Object System.Windows.Forms.TableLayoutPanel
$userPromptPanel.Dock = 'Fill'
$userPromptPanel.RowCount = 2
$userPromptPanel.ColumnCount = 1
[void]$userPromptPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 34)))
[void]$userPromptPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$promptSplit.Panel2.Controls.Add($userPromptPanel)

$userPromptHeader = New-Object System.Windows.Forms.FlowLayoutPanel
$userPromptHeader.Dock = 'Fill'
$userPromptLabel = New-AGTAGuiLabel 'User prompt override'
$clearUserPromptButton = New-AGTAGuiButton 'Clear' 74
[void]$userPromptHeader.Controls.Add($userPromptLabel)
[void]$userPromptHeader.Controls.Add($clearUserPromptButton)
[void]$userPromptPanel.Controls.Add($userPromptHeader, 0, 0)

$userPromptTextBox = New-Object System.Windows.Forms.TextBox
$userPromptTextBox.Dock = 'Fill'
$userPromptTextBox.Multiline = $true
$userPromptTextBox.ScrollBars = 'Both'
$userPromptTextBox.AcceptsReturn = $true
$userPromptTextBox.AcceptsTab = $true
$userPromptTextBox.Font = New-Object System.Drawing.Font('Consolas', 9)
[void]$userPromptPanel.Controls.Add($userPromptTextBox, 0, 1)

$apiPanel = New-Object System.Windows.Forms.Panel
$apiPanel.Dock = 'Fill'
$apiPanel.AutoScroll = $true
$apiPanel.Padding = New-AGTAGuiPadding 8
$apiTab.Controls.Add($apiPanel)

$apiLayout = New-Object System.Windows.Forms.TableLayoutPanel
$apiLayout.Dock = 'Fill'
$apiLayout.Padding = New-AGTAGuiPadding 8
$apiLayout.ColumnCount = 4
$apiLayout.RowCount = 6
[void]$apiLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 120)))
[void]$apiLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
[void]$apiLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 120)))
[void]$apiLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
foreach ($height in @(42, 42, 42, 42, 48, 0)) {
    if ($height -eq 0) {
        [void]$apiLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    }
    else {
        [void]$apiLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, $height)))
    }
}
$apiPanel.Controls.Add($apiLayout)

$providerCombo = New-Object System.Windows.Forms.ComboBox
$providerCombo.DropDownStyle = 'DropDownList'
$providerCombo.Items.AddRange(@('OpenAI', 'Mock'))
$providerCombo.SelectedItem = $Provider
$providerCombo.Dock = 'Fill'

$modelTextBox = New-Object System.Windows.Forms.TextBox
$modelTextBox.Text = $Model
$modelTextBox.Dock = 'Fill'

$apiKeyTextBox = New-Object System.Windows.Forms.TextBox
$apiKeyTextBox.UseSystemPasswordChar = $true
$apiKeyTextBox.Dock = 'Fill'
if ($env:OPENAI_API_KEY) { $apiKeyTextBox.Text = $env:OPENAI_API_KEY }

$maxIterationsUpDown = New-Object System.Windows.Forms.NumericUpDown
$maxIterationsUpDown.Minimum = 1
$maxIterationsUpDown.Maximum = 200
$maxIterationsUpDown.Value = 20
$maxIterationsUpDown.Dock = 'Left'
$maxIterationsUpDown.Width = 90

$executeCheckBox = New-Object System.Windows.Forms.CheckBox
$executeCheckBox.Text = 'Run generated script after authoring'
$executeCheckBox.AutoSize = $true
$executeCheckBox.Margin = New-AGTAGuiPadding 4

$potatoTextBox = New-Object System.Windows.Forms.TextBox
$potatoTextBox.Text = $PotatoCliPath
$potatoTextBox.Dock = 'Fill'
$browsePotatoButton = New-AGTAGuiButton 'Browse' 86

$runButton = New-AGTAGuiButton 'Run Authoring' 124
$stopButton = New-AGTAGuiButton 'Stop' 74
$stopButton.Enabled = $false
$openRunButton = New-AGTAGuiButton 'Open Run Folder' 132
$openRunButton.Enabled = $false
$openResultButton = New-AGTAGuiButton 'Open Result JSON' 132
$openResultButton.Enabled = $false

[void]$apiLayout.Controls.Add((New-AGTAGuiLabel 'Vendor'), 0, 0)
[void]$apiLayout.Controls.Add($providerCombo, 1, 0)
[void]$apiLayout.Controls.Add((New-AGTAGuiLabel 'Model'), 2, 0)
[void]$apiLayout.Controls.Add($modelTextBox, 3, 0)
[void]$apiLayout.Controls.Add((New-AGTAGuiLabel 'API key'), 0, 1)
[void]$apiLayout.Controls.Add($apiKeyTextBox, 1, 1)
[void]$apiLayout.Controls.Add((New-AGTAGuiLabel 'Iterations'), 2, 1)
[void]$apiLayout.Controls.Add($maxIterationsUpDown, 3, 1)
[void]$apiLayout.Controls.Add((New-AGTAGuiLabel 'PoTATo CLI'), 0, 2)
[void]$apiLayout.Controls.Add($potatoTextBox, 1, 2)
[void]$apiLayout.Controls.Add($browsePotatoButton, 2, 2)
[void]$apiLayout.Controls.Add($executeCheckBox, 1, 3)

$runButtonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$runButtonPanel.Dock = 'Fill'
[void]$runButtonPanel.Controls.Add($runButton)
[void]$runButtonPanel.Controls.Add($stopButton)
[void]$runButtonPanel.Controls.Add($openRunButton)
[void]$runButtonPanel.Controls.Add($openResultButton)
[void]$apiLayout.Controls.Add($runButtonPanel, 1, 4)
$apiLayout.SetColumnSpan($runButtonPanel, 3)

$outputTextBox = New-Object System.Windows.Forms.TextBox
$outputTextBox.Dock = 'Fill'
$outputTextBox.Multiline = $true
$outputTextBox.ReadOnly = $true
$outputTextBox.ScrollBars = 'Both'
$outputTextBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$outputTextBox.Margin = New-AGTAGuiPadding 4
[void]$root.Controls.Add($outputTextBox, 0, 2)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500

function Write-AGTAGuiLog {
    param([string] $Message)

    $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    $outputTextBox.AppendText($line + [Environment]::NewLine)
}

function Set-AGTAGuiRunningState {
    param([bool] $Running)

    $runButton.Enabled = -not $Running
    $stopButton.Enabled = $Running
    $browseCsvButton.Enabled = -not $Running
    $loadCsvButton.Enabled = -not $Running
    $saveCsvButton.Enabled = -not $Running
    $stepsGrid.ReadOnly = $Running
}

function Load-AGTAGuiCsv {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "CSV file not found: $Path"
    }

    $rows = @(Import-Csv -LiteralPath $Path)
    Set-AGTAGuiStepsTable -Table (New-AGTAStepTable -Rows $rows)
    $script:CurrentCsvPath = $Path
    $csvTextBox.Text = $Path
    Write-AGTAGuiLog ("Loaded {0} step(s) from {1}" -f $script:StepsTable.Rows.Count, $Path)
}

function Save-AGTAGuiPromptFiles {
    $systemPath = New-AGTAGuiStatePath -ChildFolder 'prompts' -Extension '.system.txt'
    $userPath = New-AGTAGuiStatePath -ChildFolder 'prompts' -Extension '.user.txt'
    Set-Content -LiteralPath $systemPath -Value $systemPromptTextBox.Text -Encoding UTF8

    $userPromptPath = ''
    if ($userPromptTextBox.Text.Trim()) {
        Set-Content -LiteralPath $userPath -Value $userPromptTextBox.Text -Encoding UTF8
        $userPromptPath = $userPath
    }

    return [pscustomobject]@{
        systemPromptPath = $systemPath
        userPromptPath = $userPromptPath
    }
}

function Start-AGTAGuiAuthoring {
    if ($null -eq $script:StepsTable) {
        throw 'Load or create a testcase before running authoring.'
    }
    if (-not (Test-Path -LiteralPath $script:EntryPointPath)) {
        throw "Authoring entrypoint not found: $script:EntryPointPath"
    }
    if (-not (Test-Path -LiteralPath $potatoTextBox.Text)) {
        throw "PoTATo CLI not found: $($potatoTextBox.Text)"
    }
    if ($providerCombo.SelectedItem -eq 'OpenAI' -and -not $apiKeyTextBox.Text) {
        throw 'OPENAI_API_KEY is required for the OpenAI provider.'
    }

    $stagedCsv = New-AGTAGuiStatePath -ChildFolder 'inputs' -Extension '.csv'
    $records = Export-AGTAGuiStepCsv -Table $script:StepsTable -Path $stagedCsv
    $promptFiles = Save-AGTAGuiPromptFiles

    $args = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $script:EntryPointPath,
        '-TestCaseCsv', $stagedCsv,
        '-Provider', [string]$providerCombo.SelectedItem,
        '-Model', $modelTextBox.Text,
        '-PotatoCliPath', $potatoTextBox.Text,
        '-MaxIterations', [string][int]$maxIterationsUpDown.Value,
        '-SystemPromptPath', $promptFiles.systemPromptPath
    )
    if ($executeCheckBox.Checked) { $args += '-Execute' }
    if ($promptFiles.userPromptPath) { $args += @('-UserPromptPath', $promptFiles.userPromptPath) }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = Join-AGTAGuiProcessArgument -Arguments $args
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    if ($apiKeyTextBox.Text) {
        $psi.EnvironmentVariables['OPENAI_API_KEY'] = $apiKeyTextBox.Text
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()
    $script:CurrentProcess = $process
    $script:LastRunRoot = $null
    $script:LastResultPath = $null
    $openRunButton.Enabled = $false
    $openResultButton.Enabled = $false
    Set-AGTAGuiRunningState -Running $true
    $timer.Start()

    Write-AGTAGuiLog ("Started {0} authoring for {1} staged step(s)." -f $providerCombo.SelectedItem, $records.Count)
    Write-AGTAGuiLog ("Staged CSV: {0}" -f $stagedCsv)
}

$browseCsvButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
    $dialog.InitialDirectory = $script:FrameworkRoot
    if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $csvTextBox.Text = $dialog.FileName
    }
})

$loadCsvButton.Add_Click({
    try {
        Load-AGTAGuiCsv -Path $csvTextBox.Text
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'CSV load failed', 'OK', 'Error') | Out-Null
        Write-AGTAGuiLog $_.Exception.Message
    }
})

$saveCsvButton.Add_Click({
    try {
        if ($null -eq $script:StepsTable) { throw 'No testcase is loaded.' }
        $dialog = New-Object System.Windows.Forms.SaveFileDialog
        $dialog.Filter = 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
        $dialog.InitialDirectory = $script:FrameworkRoot
        $dialog.FileName = if ($script:CurrentCsvPath) { Split-Path -Leaf $script:CurrentCsvPath } else { 'testcase.csv' }
        if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            [void](Export-AGTAGuiStepCsv -Table $script:StepsTable -Path $dialog.FileName)
            Write-AGTAGuiLog ("Saved CSV copy: {0}" -f $dialog.FileName)
        }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'CSV save failed', 'OK', 'Error') | Out-Null
        Write-AGTAGuiLog $_.Exception.Message
    }
})

$addStepButton.Add_Click({
    if ($null -eq $script:StepsTable) {
        Set-AGTAGuiStepsTable -Table (New-AGTAStepTable -Rows @())
    }
    $row = $script:StepsTable.NewRow()
    $row['StepId'] = [string]($script:StepsTable.Rows.Count + 1)
    $script:StepsTable.Rows.Add($row)
})

$deleteStepButton.Add_Click({
    foreach ($row in @($stepsGrid.SelectedRows)) {
        if (-not $row.IsNewRow) {
            $stepsGrid.Rows.Remove($row)
        }
    }
})

$renumberButton.Add_Click({
    if ($null -eq $script:StepsTable) { return }
    $index = 0
    foreach ($row in $script:StepsTable.Rows) {
        if ($row.RowState -eq [System.Data.DataRowState]::Deleted) { continue }
        $index++
        $row['StepId'] = [string]$index
    }
    Write-AGTAGuiLog 'Renumbered StepId values.'
})

$resetSystemPromptButton.Add_Click({
    $systemPromptTextBox.Text = Get-AGTASystemPrompt
})

$clearUserPromptButton.Add_Click({
    $userPromptTextBox.Clear()
})

$browsePotatoButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = 'PowerShell scripts (*.ps1)|*.ps1|All files (*.*)|*.*'
    $dialog.InitialDirectory = Split-Path -Parent $potatoTextBox.Text
    if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $potatoTextBox.Text = $dialog.FileName
    }
})

$providerCombo.Add_SelectedIndexChanged({
    $isOpenAI = $providerCombo.SelectedItem -eq 'OpenAI'
    $apiKeyTextBox.Enabled = $isOpenAI
    $modelTextBox.Enabled = $isOpenAI
})

$runButton.Add_Click({
    try {
        Start-AGTAGuiAuthoring
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Authoring failed to start', 'OK', 'Error') | Out-Null
        Write-AGTAGuiLog $_.Exception.Message
    }
})

$stopButton.Add_Click({
    if ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited) {
        $script:CurrentProcess.Kill()
        Write-AGTAGuiLog 'Stopped authoring process.'
    }
})

$openRunButton.Add_Click({
    $folder = Get-AGTAGuiPathForExplorer -Path $script:LastRunRoot
    if ($folder) { Start-Process explorer.exe $folder }
})

$openResultButton.Add_Click({
    $folder = Get-AGTAGuiPathForExplorer -Path $script:LastResultPath
    if ($folder) { Start-Process explorer.exe $folder }
})

$timer.Add_Tick({
    if (-not $script:CurrentProcess) { return }
    if (-not $script:CurrentProcess.HasExited) { return }

    $timer.Stop()
    $stdout = $script:CurrentProcess.StandardOutput.ReadToEnd()
    $stderr = $script:CurrentProcess.StandardError.ReadToEnd()
    $exitCode = $script:CurrentProcess.ExitCode
    $script:CurrentProcess.Dispose()
    $script:CurrentProcess = $null
    Set-AGTAGuiRunningState -Running $false

    Write-AGTAGuiLog ("Authoring finished with exit code {0}." -f $exitCode)
    if ($stderr.Trim()) {
        Write-AGTAGuiLog 'stderr:'
        $outputTextBox.AppendText($stderr + [Environment]::NewLine)
    }
    if ($stdout.Trim()) {
        Write-AGTAGuiLog 'stdout:'
        $outputTextBox.AppendText($stdout + [Environment]::NewLine)
        try {
            $parsed = $stdout.Trim() | ConvertFrom-Json
            if ($parsed.runRoot) {
                $script:LastRunRoot = [string]$parsed.runRoot
                $openRunButton.Enabled = Test-Path -LiteralPath $script:LastRunRoot
            }
            if ($parsed.resultPath) {
                $script:LastResultPath = [string]$parsed.resultPath
                $openResultButton.Enabled = Test-Path -LiteralPath $script:LastResultPath
            }
            if ($parsed.ok -eq $true) {
                Write-AGTAGuiLog 'Authoring result: ok=true'
            }
            else {
                Write-AGTAGuiLog ("Authoring result: ok=false; {0}" -f $parsed.error)
            }
        }
        catch {
            Write-AGTAGuiLog ("Could not parse authoring stdout as JSON: {0}" -f $_.Exception.Message)
        }
    }
})

$form.Add_FormClosing({
    if ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited) {
        $answer = [System.Windows.Forms.MessageBox]::Show($form, 'Authoring is still running. Stop it and close?', 'Close', 'YesNo', 'Warning')
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            $_.Cancel = $true
            return
        }
        $script:CurrentProcess.Kill()
    }
})

$systemPromptTextBox.Text = Get-AGTASystemPrompt
$csvTextBox.Text = $InitialCsv
if (-not $NoAutoLoad -and $InitialCsv -and (Test-Path -LiteralPath $InitialCsv)) {
    try {
        Load-AGTAGuiCsv -Path $InitialCsv
    }
    catch {
        Write-AGTAGuiLog $_.Exception.Message
    }
}
$providerCombo.SelectedItem = $Provider
Write-AGTAGuiLog 'Ready.'

[void]$form.ShowDialog()
