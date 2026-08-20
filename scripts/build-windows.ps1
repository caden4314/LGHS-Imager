param(
    [string]$QtRoot = $env:QT6_ROOT,
    [string]$MingwRoot = $env:MINGW64_ROOT,
    [ValidateSet('Debug','Release','MinSizeRel','RelWithDebInfo')]
    [string]$BuildType = 'MinSizeRel',
    [switch]$SkipInstaller
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Upstream = Join-Path $Root 'upstream'
$Build = Join-Path $Root 'build'
$Package = Join-Path $Root 'package'

if (-not (Test-Path (Join-Path $Upstream '.git'))) {
    & (Join-Path $PSScriptRoot 'bootstrap-upstream.ps1')
}
if (-not $QtRoot) { throw 'Set QT6_ROOT to your Qt 6 mingw_64 directory.' }
if (-not $MingwRoot) { throw 'Set MINGW64_ROOT to your MinGW64 toolchain directory.' }

Write-Host 'LGHS Imager Windows build'
Write-Host '  Target hardware: Raspberry Pi 5 8GB'
Write-Host '  Host platform:   Windows x64'
Write-Host "  Build type:      $BuildType"

New-Item -ItemType Directory -Force -Path $Build | Out-Null
cmake -S (Join-Path $Upstream 'src') -B $Build -G Ninja `
    "-DQt6_ROOT=$QtRoot" `
    "-DMINGW64_ROOT=$MingwRoot" `
    "-DCMAKE_BUILD_TYPE=$BuildType"
cmake --build $Build --parallel

$backend = Get-ChildItem $Build -Recurse -Filter 'rpi-imager.exe' | Select-Object -First 1
if (-not $backend) { throw 'Built rpi-imager.exe was not found.' }

Remove-Item $Package -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path (Join-Path $Package 'backend') | Out-Null
Copy-Item $backend.FullName (Join-Path $Package 'backend\rpi-imager.exe')

foreach ($dir in @('app','config','os-list','scripts','updater')) {
    Copy-Item (Join-Path $Root $dir) (Join-Path $Package $dir) -Recurse -Force
}
Copy-Item (Join-Path $Root 'LGHS-Imager.cmd') $Package
Copy-Item (Join-Path $Root 'LGHS-Imager.vbs') $Package
Copy-Item (Join-Path $Root 'VERSION') $Package

# Deploy the Qt runtime used by the writer backend.
$windeployqt = Join-Path $QtRoot 'bin\windeployqt.exe'
if (-not (Test-Path $windeployqt)) { throw "windeployqt.exe not found under $QtRoot" }
& $windeployqt --release --no-translations (Join-Path $Package 'backend\rpi-imager.exe')

Write-Host "Portable package ready: $Package"

if (-not $SkipInstaller) {
    $iscc = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if (-not $iscc) {
        $defaultIscc = 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe'
        if (Test-Path $defaultIscc) { $iscc = Get-Item $defaultIscc }
    }
    if ($iscc) {
        & $iscc.Source "/DSourceRoot=$Package" (Join-Path $Root 'installer\LGHS-Imager.iss')
    } else {
        Write-Warning 'Inno Setup was not found. Portable package was built, installer skipped.'
    }
}
