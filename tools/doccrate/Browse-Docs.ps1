<# .SYNOPSIS  Open the NewM2 (Modula-2) user guide in DocCrate. #>
param([string]$DocsDir = (Join-Path $PSScriptRoot '..\..\docs\m2-guide'))
$ErrorActionPreference = 'Stop'
$exe  = Join-Path $PSScriptRoot 'doc-crate.exe'
$docs = (Resolve-Path $DocsDir).Path
if (-not (Test-Path $exe))  { throw "doc-crate.exe not found at $exe" }
if (-not (Test-Path $docs)) { throw "docs dir not found: $docs" }
Start-Process -FilePath $exe -ArgumentList @($docs)
Write-Output "DocCrate launched on $docs"
