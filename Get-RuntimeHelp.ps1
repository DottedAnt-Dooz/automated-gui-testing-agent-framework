[CmdletBinding()]
param([string] $Name)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Framework\GeneratedScriptRuntime.ps1')
@(Get-AGTARuntimeHelp -Name $Name) | ConvertTo-Json -Depth 5 -Compress
