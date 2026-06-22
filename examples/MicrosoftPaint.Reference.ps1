[CmdletBinding()]
param(
    [string] $PotatoCliPath = (Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -ChildPath 'potato_cli\potato.ps1'),
    [string] $TestCaseCsv = (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Microsoft Paint.csv'),
    [string] $RunRoot = (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath ('runs\paint-reference-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))),
    [string] $FrameworkRoot
)

$runtimeCandidates = @()
if ($FrameworkRoot) {
    $runtimeCandidates += (Join-Path -Path $FrameworkRoot -ChildPath 'Framework\GeneratedScriptRuntime.ps1')
}
$probe = $PSScriptRoot
for ($i = 0; $i -lt 6 -and $probe; $i++) {
    $runtimeCandidates += (Join-Path -Path $probe -ChildPath 'Framework\GeneratedScriptRuntime.ps1')
    $probe = Split-Path -Parent $probe
}
$runtimePath = @($runtimeCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)[0]
if (-not $runtimePath) {
    throw "Generated script runtime was not found: $runtimePath"
}
$FrameworkRoot = Split-Path -Parent (Split-Path -Parent $runtimePath)
. $runtimePath

$Context = Initialize-AGTAGeneratedTest -PotatoCliPath $PotatoCliPath -TestCaseCsv $TestCaseCsv -RunRoot $RunRoot
$results = @()
$cleanup = @()

$createdImage = Join-Path -Path $Context.ExecutionEvidenceRoot -ChildPath 'PaintSmoke.png'
$printedPdf = Join-Path -Path $Context.ExecutionEvidenceRoot -ChildPath 'PaintSmoke.pdf'
Register-CreatedExternalPath -Path $createdImage
Register-CreatedExternalPath -Path $printedPdf

try {
    $results += Invoke-RecordedStep -StepIndex 1 -Body {
        param([ref] $Commands, [ref] $Evidence)

        $state = Invoke-StepCommand -Commands $Commands -Command 'state' -Arguments @('-Clear')
        Assert-PotatoOk -Result $state -Message 'Could not clear PoTATo state.'

        $started = Invoke-StepCommand -Commands $Commands -Command 'start' -Arguments @('-ProcessName', 'mspaint.exe', '-WaitForWindowMs', '30000')
        Assert-PotatoOk -Result $started -Message 'Could not start Paint.'
        Register-OpenedProcess -ProcessName 'mspaint'

        Invoke-StepCommand -Commands $Commands -Command 'observe' -Arguments @('-Depth', '2', '-MaxElements', '200') | Out-Null
        Invoke-EvidenceScreenshot -Commands $Commands -Evidence $Evidence -FileName '01-paint-opened.png' | Out-Null
    }

    $results += Invoke-RecordedStep -StepIndex 2 -Body {
        param([ref] $Commands, [ref] $Evidence)

        # Coordinate fallback: current Paint canvas is not consistently exposed with stable selectors across Windows builds.
        Invoke-EvidenceScreenshot -Commands $Commands -Evidence $Evidence -FileName '02-before-drawing.png' | Out-Null
        $draw1 = Invoke-StepCommand -Commands $Commands -Command 'drag' -Arguments @('-StartX', '330', '-StartY', '280', '-EndX', '760', '-EndY', '430', '-Smooth')
        Assert-PotatoOk -Result $draw1 -Message 'Could not draw the first Paint line.'
        $draw2 = Invoke-StepCommand -Commands $Commands -Command 'drag' -Arguments @('-StartX', '350', '-StartY', '440', '-EndX', '820', '-EndY', '300', '-Smooth')
        Assert-PotatoOk -Result $draw2 -Message 'Could not draw the second Paint line.'

        # Paint save routing is not reliably exposed through UI Automation; Ctrl+S opens the standard file dialog.
        $saveHotkey = Invoke-StepCommand -Commands $Commands -Command 'hotkey' -Arguments @('-Keys', '^s', '-Focus')
        Assert-PotatoOk -Result $saveHotkey -Message 'Could not open Paint Save As.'
        Start-Sleep -Milliseconds 700
        Invoke-StepCommand -Commands $Commands -Command 'hotkey' -Arguments @('-Keys', '^a', '-Focus') | Out-Null
        $typed = Invoke-StepCommand -Commands $Commands -Command 'type' -Arguments @('-Text', $createdImage, '-Focus')
        Assert-PotatoOk -Result $typed -Message 'Could not type the Paint output path.'
        $save = Invoke-ClickAny -Commands $Commands -Names @('Save', 'Speichern') -ControlType 'Button'
        Assert-PotatoOk -Result $save -Message 'Could not click Save.'
        $wait = Invoke-StepCommand -Commands $Commands -Command 'wait-file' -Arguments @('-Path', $createdImage, '-TimeoutMs', '10000')
        Assert-FileWait -Result $wait -Path $createdImage
        Add-EvidencePath -Evidence $Evidence -Path $createdImage
    }

    $results += Invoke-RecordedStep -StepIndex 3 -Body {
        param([ref] $Commands, [ref] $Evidence)

        $openHotkey = Invoke-StepCommand -Commands $Commands -Command 'hotkey' -Arguments @('-Keys', '^o', '-Focus')
        Assert-PotatoOk -Result $openHotkey -Message 'Could not open Paint file dialog.'
        Start-Sleep -Milliseconds 700
        Invoke-StepCommand -Commands $Commands -Command 'hotkey' -Arguments @('-Keys', '^a', '-Focus') | Out-Null
        $typed = Invoke-StepCommand -Commands $Commands -Command 'type' -Arguments @('-Text', $createdImage, '-Focus')
        Assert-PotatoOk -Result $typed -Message 'Could not type the Paint input path.'
        $open = Invoke-ClickAny -Commands $Commands -Names @('Open', 'Oeffnen') -ControlType 'Button'
        Assert-PotatoOk -Result $open -Message 'Could not click Open.'
        Invoke-EvidenceScreenshot -Commands $Commands -Evidence $Evidence -FileName '03-image-opened.png' | Out-Null
    }

    $results += Invoke-RecordedStep -StepIndex 4 -Body {
        param([ref] $Commands, [ref] $Evidence)

        # Ctrl+P is the stable Paint command for the print dialog; printer selection is handled through selectors.
        $printHotkey = Invoke-StepCommand -Commands $Commands -Command 'hotkey' -Arguments @('-Keys', '^p', '-Focus')
        Assert-PotatoOk -Result $printHotkey -Message 'Could not open Paint print dialog.'
        Start-Sleep -Milliseconds 1000
        Invoke-StepCommand -Commands $Commands -Command 'observe' -Arguments @('-Depth', '2', '-MaxElements', '250') | Out-Null
        Invoke-StepCommand -Commands $Commands -Command 'click' -Arguments @('-Name', 'Microsoft Print to PDF', '-FindFirst', '-TimeoutMs', '3000') | Out-Null
        $print = Invoke-ClickAny -Commands $Commands -Names @('Print', 'Drucken') -ControlType 'Button'
        Assert-PotatoOk -Result $print -Message 'Could not click Print.'
        Start-Sleep -Milliseconds 1000
        Invoke-StepCommand -Commands $Commands -Command 'hotkey' -Arguments @('-Keys', '^a', '-Focus') | Out-Null
        $typed = Invoke-StepCommand -Commands $Commands -Command 'type' -Arguments @('-Text', $printedPdf, '-Focus')
        Assert-PotatoOk -Result $typed -Message 'Could not type the PDF path.'
        $save = Invoke-ClickAny -Commands $Commands -Names @('Save', 'Speichern') -ControlType 'Button'
        Assert-PotatoOk -Result $save -Message 'Could not save the PDF.'
        $wait = Invoke-StepCommand -Commands $Commands -Command 'wait-file' -Arguments @('-Path', $printedPdf, '-TimeoutMs', '15000')
        Assert-FileWait -Result $wait -Path $printedPdf
        Add-EvidencePath -Evidence $Evidence -Path $printedPdf
    }

    $results += Invoke-RecordedStep -StepIndex 5 -Body {
        param([ref] $Commands, [ref] $Evidence)

        $closed = Invoke-StepCommand -Commands $Commands -Command 'close-window' -Arguments @('-ProcessName', 'mspaint')
        Assert-PotatoOk -Result $closed -Message 'Could not close Paint.'
    }
}
finally {
    $cleanup = @(Invoke-TestCleanup)
}

Complete-AGTAGeneratedTest -StepResults $results -Cleanup $cleanup -ExtraArtifacts @{
    imagePath = $createdImage
    printedPdfPath = $printedPdf
}
