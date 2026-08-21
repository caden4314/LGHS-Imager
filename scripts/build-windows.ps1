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
$Version = (Get-Content (Join-Path $Root 'VERSION') -Raw).Trim()

if (-not (Test-Path (Join-Path $Upstream '.git'))) {
    & (Join-Path $PSScriptRoot 'bootstrap-upstream.ps1')
}

function Find-QtRoot {
    $candidates = @()
    if ($env:QT6_ROOT) { $candidates += $env:QT6_ROOT }
    if ($QtRoot) { $candidates += $QtRoot }
    if (Test-Path 'C:\Qt') {
        $candidates += Get-ChildItem 'C:\Qt' -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'mingw_64' }
    }
    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if ($candidate -and (Test-Path (Join-Path $candidate 'bin\windeployqt.exe'))) {
            return $candidate
        }
    }
    return $null
}

function Find-MingwRoot {
    param([string]$Preferred)
    $candidates = @()
    if ($env:MINGW64_ROOT) { $candidates += $env:MINGW64_ROOT }
    if ($Preferred) { $candidates += $Preferred }
    if (Test-Path 'C:\Qt\Tools') {
        $candidates += Get-ChildItem 'C:\Qt\Tools' -Directory -Filter 'mingw*_64' -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object FullName
    }
    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if ($candidate -and (Test-Path (Join-Path $candidate 'bin\g++.exe'))) {
            return $candidate
        }
    }
    return $null
}

$QtRoot = Find-QtRoot
$MingwRoot = Find-MingwRoot $MingwRoot

if (-not $QtRoot -or -not $MingwRoot) {
    Write-Host 'LGHS Imager build dependencies are not fully configured.' -ForegroundColor Yellow
    Write-Host 'Running the Windows setup helper...'
    & (Join-Path $PSScriptRoot 'setup-windows.ps1')
    $QtRoot = Find-QtRoot
    $MingwRoot = Find-MingwRoot $MingwRoot
}

if (-not $QtRoot) { throw 'Qt 6 MinGW kit was not found. Install Qt 6.11.1 mingw_64, then rerun the build.' }
if (-not $MingwRoot) { throw 'MinGW64 compiler was not found under C:\Qt\Tools.' }

$env:QT6_ROOT = $QtRoot
$env:MINGW64_ROOT = $MingwRoot
$env:Path = "$(Join-Path $MingwRoot 'bin');$(Join-Path $QtRoot 'bin');$env:Path"

foreach ($tool in @('cmake','ninja','g++')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "$tool is required but was not found after setup. Open a new PowerShell window and rerun the build."
    }
}

Write-Host 'LGHS Imager Windows build'
Write-Host "  Version:         $Version"
Write-Host '  Target hardware: Raspberry Pi 5 4GB / 8GB'
Write-Host '  Host platform:   Windows x64'
Write-Host "  Build type:      $BuildType"
Write-Host "  Qt:              $QtRoot"
Write-Host "  MinGW:           $MingwRoot"

New-Item -ItemType Directory -Force -Path $Build | Out-Null
cmake -S (Join-Path $Upstream 'src') -B $Build -G Ninja `
    "-DQt6_ROOT=$QtRoot" `
    "-DMINGW64_ROOT=$MingwRoot" `
    "-DCMAKE_C_COMPILER=$(Join-Path $MingwRoot 'bin\gcc.exe')" `
    "-DCMAKE_CXX_COMPILER=$(Join-Path $MingwRoot 'bin\g++.exe')" `
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
        & $iscc.Source "/DSourceRoot=$Package" "/DAppVersion=$Version" (Join-Path $Root 'installer\LGHS-Imager.iss')
    } else {
        Write-Warning 'Inno Setup was not found. Portable package was built, installer skipped.'
    }
}
