$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

# Development/source checkouts follow main automatically when they are clean.
if (Test-Path (Join-Path $Root '.git')) {
    try {
        $dirty = git -C $Root status --porcelain
        if (-not $dirty) {
            git -C $Root fetch origin main --quiet
            $local = (git -C $Root rev-parse HEAD).Trim()
            $remote = (git -C $Root rev-parse origin/main).Trim()
            if ($local -ne $remote) {
                git -C $Root pull --ff-only origin main --quiet
            }
        }
    } catch { }
}

# Installed builds silently check signed/checksummed GitHub release assets.
try {
    & (Join-Path $Root 'updater\LGHS-Imager-Updater.ps1')
} catch { }

# Raw-disk enumeration and post-write provisioning require elevation.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',
        ('"' + (Join-Path $Root 'app\LGHS-Imager.ps1') + '"'),
        '-SkipUpdate'
    )
    exit
}

& (Join-Path $Root 'app\LGHS-Imager.ps1') -SkipUpdate
