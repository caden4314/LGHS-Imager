param(
    [switch]$Relaunch,
    [switch]$Force,
    [string]$InstallRoot = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$ConfigPath = Join-Path $RepoRoot 'config\lghs-imager.json'
$VersionPath = Join-Path $RepoRoot 'VERSION'
if (-not (Test-Path $ConfigPath)) { exit 0 }

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
if (-not $config.updater.enabled) { exit 0 }

$current = if (Test-Path $VersionPath) { (Get-Content $VersionPath -Raw).Trim() } else { '0.0.0' }
$headers = @{ 'User-Agent' = 'LGHS-Imager-Updater' }

try {
    $release = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$($config.updater.githubRepository)/releases/latest" -TimeoutSec 10
} catch {
    $response = $_.Exception.Response
    if ($response -and [int]$response.StatusCode -eq 404) {
        # No published release exists yet. This is normal during development.
        exit 0
    }
    throw
}

if (-not $release -or $release.draft -or $release.prerelease) { exit 0 }
$latest = ([string]$release.tag_name).TrimStart('v')

try {
    $needsUpdate = $Force -or ([version]$latest -gt [version]$current)
} catch {
    $needsUpdate = $Force -or ($latest -ne $current)
}
if (-not $needsUpdate) { exit 0 }

$installerAsset = $release.assets | Where-Object { $_.name -eq $config.updater.releaseAsset } | Select-Object -First 1
$checksumAsset = $release.assets | Where-Object { $_.name -eq $config.updater.checksumAsset } | Select-Object -First 1
if (-not $installerAsset -or -not $checksumAsset) { exit 0 }

$tmp = Join-Path $env:TEMP ("LGHS-Imager-Update-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$installer = Join-Path $tmp $installerAsset.name
$checksumFile = Join-Path $tmp $checksumAsset.name

try {
    Invoke-WebRequest -Headers $headers -Uri $installerAsset.browser_download_url -OutFile $installer -UseBasicParsing
    Invoke-WebRequest -Headers $headers -Uri $checksumAsset.browser_download_url -OutFile $checksumFile -UseBasicParsing

    $expected = ((Get-Content $checksumFile -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
    $actual = (Get-FileHash -Algorithm SHA256 $installer).Hash.ToLowerInvariant()
    if (-not $expected -or $expected -ne $actual) {
        throw 'LGHS Imager update checksum mismatch.'
    }

    $args = [string]$config.updater.silentInstallerArguments
    Start-Process -FilePath $installer -ArgumentList $args -Wait

    if ($Relaunch) {
        $launcher = Join-Path $InstallRoot 'LGHS-Imager.cmd'
        if (Test-Path $launcher) { Start-Process $launcher }
    }
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
