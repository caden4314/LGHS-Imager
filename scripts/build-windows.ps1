param(
    [string]$QtRoot = $env:QT6_ROOT,
    [string]$MingwRoot = $env:MINGW64_ROOT,
    [ValidateSet('Debug','Release','MinSizeRel','RelWithDebInfo')]
    [string]$BuildType = 'MinSizeRel'
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Upstream = Join-Path $Root 'upstream'
$Build = Join-Path $Root 'build'

if (-not (Test-Path (Join-Path $Upstream '.git'))) {
    & (Join-Path $PSScriptRoot 'bootstrap-upstream.ps1')
}

if (-not $QtRoot) {
    throw 'Set QT6_ROOT to your Qt 6 mingw_64 directory, e.g. C:\Qt\6.x.x\mingw_64.'
}
if (-not $MingwRoot) {
    throw 'Set MINGW64_ROOT to your MinGW64 toolchain directory.'
}

Write-Host 'LGHS Imager Windows build'
Write-Host '  Target hardware: Raspberry Pi 5 8GB'
Write-Host '  Architecture:    arm64 images'
Write-Host '  Host platform:   Windows x64'
Write-Host "  Build type:      $BuildType"

New-Item -ItemType Directory -Force -Path $Build | Out-Null

cmake -S (Join-Path $Upstream 'src') -B $Build -G Ninja `
    "-DQt6_ROOT=$QtRoot" `
    "-DMINGW64_ROOT=$MingwRoot" `
    '-DENABLE_INNO_INSTALLER=ON' `
    "-DCMAKE_BUILD_TYPE=$BuildType"

cmake --build $Build --parallel

Write-Host ''
Write-Host 'Base upstream build complete.'
Write-Host 'Next LGHS phase applies branding, Pi 5-only UI, custom repository, and batch flashing patches.'
