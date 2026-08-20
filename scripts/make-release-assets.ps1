param([string]$Installer = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist\LGHS-Imager-Setup-x64.exe'))
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Installer)) { throw "Installer not found: $Installer" }
$hash = (Get-FileHash -Algorithm SHA256 $Installer).Hash.ToLowerInvariant()
$out = "$Installer.sha256"
"$hash  $([IO.Path]::GetFileName($Installer))" | Set-Content -Encoding ascii $out
Write-Host "Release assets ready:"
Write-Host "  $Installer"
Write-Host "  $out"
