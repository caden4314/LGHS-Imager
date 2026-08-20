$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
$Upstream = Join-Path $Root 'upstream'
$State = Join-Path $Root 'config\upstream-state.txt'

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'git is required and was not found in PATH.'
}

if (-not (Test-Path (Join-Path $Upstream '.git'))) {
    Write-Host 'Cloning official Raspberry Pi Imager source...'
    git clone --recurse-submodules https://github.com/raspberrypi/rpi-imager.git $Upstream
} else {
    Write-Host 'Updating existing Raspberry Pi Imager checkout...'
    git -C $Upstream fetch origin
    git -C $Upstream checkout main
    git -C $Upstream pull --ff-only origin main
    git -C $Upstream submodule update --init --recursive
}

$Commit = (git -C $Upstream rev-parse HEAD).Trim()
$Describe = (git -C $Upstream describe --tags --always).Trim()
"commit=$Commit`ndescribe=$Describe`n" | Set-Content -Encoding ascii $State

Write-Host "Upstream ready: $Describe ($Commit)"
Write-Host 'LGHS target: Raspberry Pi 5 8GB / arm64'
