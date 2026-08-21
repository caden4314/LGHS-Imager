param(
    [string]$QtVersion = '6.9.3',
    [string]$QtBase = 'C:\Qt'
)

$ErrorActionPreference = 'Stop'

function Test-Cmd([string]$name) {
    return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

Write-Host 'LGHS Imager Windows setup'
Write-Host "  Qt target: $QtVersion"
Write-Host "  Qt root:   $QtBase"
Write-Host ''

# Install general build tools with winget where available.
if (Test-Cmd 'winget') {
    $packages = @(
        @{ Id='Kitware.CMake'; Name='CMake' },
        @{ Id='Ninja-build.Ninja'; Name='Ninja' },
        @{ Id='JRSoftware.InnoSetup'; Name='Inno Setup' }
    )
    foreach ($pkg in $packages) {
        Write-Host "Ensuring $($pkg.Name)..."
        winget install --id $pkg.Id -e --silent --accept-package-agreements --accept-source-agreements 2>$null | Out-Host
    }
} else {
    Write-Warning 'winget is not available. Install CMake, Ninja, and Inno Setup manually.'
}

# Refresh PATH for tools installed by winget in this shell where possible.
$machinePath = [Environment]::GetEnvironmentVariable('Path','Machine')
$userPath = [Environment]::GetEnvironmentVariable('Path','User')
$env:Path = "$machinePath;$userPath"

# Keep local builds aligned with the GitHub Actions toolchain. Current upstream
# Raspberry Pi Imager requires Qt 6.9 or newer; LGHS standardizes on 6.9.3.
$qtCandidates = @()
if (Test-Path $QtBase) {
    $qtCandidates = Get-ChildItem $QtBase -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'mingw_64' } |
        Where-Object { Test-Path (Join-Path $_ 'bin\windeployqt.exe') } |
        Sort-Object -Descending
}

if (-not $qtCandidates -or $qtCandidates.Count -eq 0) {
    Write-Host ''
    Write-Host 'Qt MinGW is not installed yet.' -ForegroundColor Yellow
    Write-Host "Install Qt $QtVersion for Windows x64 with the MinGW 64-bit kit using the Qt Online Installer."
    Write-Host 'After installation, rerun this script or build-windows.ps1.'
    Write-Host ''
    Write-Host 'Expected layout:'
    Write-Host "  $QtBase\$QtVersion\mingw_64"
    Write-Host "  $QtBase\Tools\mingw*_64"
    exit 2
}

$QtRoot = $qtCandidates[0]
$mingwCandidates = Get-ChildItem (Join-Path $QtBase 'Tools') -Directory -Filter 'mingw*_64' -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName 'bin\g++.exe') } |
    Sort-Object Name -Descending

if (-not $mingwCandidates -or $mingwCandidates.Count -eq 0) {
    Write-Host ''
    Write-Host 'Qt was found, but the MinGW compiler toolchain was not.' -ForegroundColor Yellow
    Write-Host 'Open Qt Maintenance Tool and add the matching MinGW 64-bit toolchain.'
    exit 3
}

$MingwRoot = $mingwCandidates[0].FullName

[Environment]::SetEnvironmentVariable('QT6_ROOT', $QtRoot, 'User')
[Environment]::SetEnvironmentVariable('MINGW64_ROOT', $MingwRoot, 'User')
$env:QT6_ROOT = $QtRoot
$env:MINGW64_ROOT = $MingwRoot

Write-Host ''
Write-Host 'LGHS Windows build environment is ready.' -ForegroundColor Green
Write-Host "  QT6_ROOT:     $QtRoot"
Write-Host "  MINGW64_ROOT: $MingwRoot"
Write-Host ''
Write-Host 'Next:'
Write-Host '  .\scripts\build-windows.ps1'
