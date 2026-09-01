$ErrorActionPreference = 'Stop'

# v11: SSH-first cloud-init plus LF-safe Linux payloads. The Pi 5 RAM profile
# is selected for every managed Control/Student flash. Raspberry Pi OS arm64 is
# shared by Pi 5 4 GB and 8 GB hardware; only LGHS hardware metadata differs.
. (Join-Path $PSScriptRoot 'LGHS-StockBootstrap-v10.ps1')

$script:LghsV10WriteProvisioning = ${function:Write-LghsProvisioning}
$script:LghsV10CloudInit = ${function:New-LghsCloudInitUserData}

function Convert-LghsTextToLf([string]$Text) {
    if ($null -eq $Text) { return '' }
    return $Text.Replace("`r`n","`n").Replace("`r","`n")
}

function Convert-LghsFileToLf([string]$Path) {
    if (-not (Test-Path $Path)) { return }
    $text = Convert-LghsTextToLf ([IO.File]::ReadAllText($Path))
    [IO.File]::WriteAllText($Path,$text,[Text.UTF8Encoding]::new($false))
}

function New-LghsFleetApiToken {
    $bytes = New-Object byte[] 48
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
}

function Get-LghsSshClient {
    $cmd = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidate = Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
    if (Test-Path $candidate) { return $candidate }
    throw 'Windows OpenSSH Client is required for LGHS Fleet token enrollment.'
}

function Register-LghsFleetApiToken([string]$DeviceId,[string]$Token,$Config) {
    if ([string]::IsNullOrWhiteSpace($DeviceId) -or [string]::IsNullOrWhiteSpace($Token)) { throw 'Fleet token enrollment requires a device ID and token.' }
    $host = [string]$Config.fleet.controllerHost
    if ([string]::IsNullOrWhiteSpace($host)) { $host = 'LGCSCONT-CF' }
    $user = [string]$Config.fleet.controllerUser
    if ([string]::IsNullOrWhiteSpace($user)) { $user = 'cs_admin' }
    $keys = Get-LghsFleetKeyPair $Config
    $ssh = Get-LghsSshClient
    $known = Join-Path $env:ProgramData 'LGHS-Imager\deployment\controller_known_hosts'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $known) | Out-Null
    if (-not (Test-Path $known)) { [IO.File]::WriteAllText($known,'',[Text.UTF8Encoding]::new($false)) }

    $remote = "sudo -n /usr/bin/python3 /opt/lghs/repo/controller/lghs-imager-enroll $DeviceId"
    $args = @(
        '-i',$keys.Private,
        '-o','IdentitiesOnly=yes',
        '-o',"UserKnownHostsFile=$known",
        '-o','StrictHostKeyChecking=accept-new',
        '-o','BatchMode=yes',
        '-o','ConnectTimeout=8',
        "$user@$host",
        $remote
    )
    $output = @($Token | & $ssh @args 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $detail = (($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
        if ($detail.Length -gt 700) { $detail = $detail.Substring($detail.Length-700) }
        throw "LGCSCONT Fleet token enrollment failed for $DeviceId at $host. $detail"
    }
    $joined = (($output | ForEach-Object { [string]$_ }) -join "`n")
    if ($joined -notmatch "ENROLLED\s+$([regex]::Escape($DeviceId))") {
        throw "LGCSCONT did not confirm Fleet token enrollment for $DeviceId."
    }
    if (Get-Command Append-Log -ErrorAction SilentlyContinue) { Append-Log "Fleet identity registered with LGCSCONT for $DeviceId." }
}

function New-LghsCloudInitUserData([string]$Role) {
    $raw = & $script:LghsV10CloudInit $Role

    # If the desktop is already up but the Pi has not joined a network, report
    # that state before interpreting the retrying online installer as active.
    $needle = @'
        elif pgrep -x dpkg >/dev/null 2>&1 || pgrep -x apt-get >/dev/null 2>&1; then
'@
    $offline = @'
        elif [ -n "$net" ] && [[ "$net" != connected* ]]; then
          pct=30
          phase='Waiting for Wi-Fi / Internet'
          detail='Connect this Pi to the classroom network; setup will continue automatically.'
        elif pgrep -x dpkg >/dev/null 2>&1 || pgrep -x apt-get >/dev/null 2>&1; then
'@
    if ($raw.Contains($needle)) { $raw = $raw.Replace($needle,$offline) }

    # First boot accepts the verified backup payload if the primary filename is
    # unexpectedly unavailable.
    $old = 'if [ -f /boot/firmware/lghs-stage2.sh ]; then exec /bin/bash /boot/firmware/lghs-stage2.sh; elif [ -f /boot/lghs-stage2.sh ]; then exec /bin/bash /boot/lghs-stage2.sh; else echo "LGHS stage2 payload missing" >&2; exit 1; fi'
    $new = 'if [ -f /boot/firmware/lghs-stage2.sh ]; then exec /bin/bash /boot/firmware/lghs-stage2.sh; elif [ -f /boot/firmware/lghs-stage2-backup.sh ]; then exec /bin/bash /boot/firmware/lghs-stage2-backup.sh; elif [ -f /boot/lghs-stage2.sh ]; then exec /bin/bash /boot/lghs-stage2.sh; elif [ -f /boot/lghs-stage2-backup.sh ]; then exec /bin/bash /boot/lghs-stage2-backup.sh; else echo "LGHS stage2 payload missing" >&2; exit 1; fi'
    if (-not $raw.Contains($old)) { throw 'Could not harden cloud-init stage2 fallback path.' }
    $raw = $raw.Replace($old,$new)

    return (Convert-LghsTextToLf $raw)
}

function Select-LghsPi5RamProfile {
    if ($script:LghsHardwareRamGb -in @(4,8)) { return [int]$script:LghsHardwareRamGb }
    $choice = [System.Windows.MessageBox]::Show(
        "Select the Raspberry Pi 5 RAM profile for this flash.`n`nYES = Pi 5 4 GB`nNO  = Pi 5 8 GB`n`nBoth use the same Raspberry Pi OS 64-bit image.",
        'LGHS Pi 5 hardware profile',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )
    if ($choice -eq [System.Windows.MessageBoxResult]::Yes) { $script:LghsHardwareRamGb=4; return 4 }
    $script:LghsHardwareRamGb=8
    return 8
}

function Write-LghsProvisioning([string]$DriveRoot,[string]$DeviceId,[string]$Role,$Credentials,$Config,[bool]$StockBootstrap) {
    $ram = Select-LghsPi5RamProfile
    & $script:LghsV10WriteProvisioning $DriveRoot $DeviceId $Role $Credentials $Config $StockBootstrap

    $publicPath = Join-Path $DriveRoot 'lghs-provision.conf'
    if (Test-Path $publicPath) {
        $text = [IO.File]::ReadAllText($publicPath)
        if ($text -match '(?m)^MEMORY_GB=') { $text = [regex]::Replace($text,'(?m)^MEMORY_GB=.*$',"MEMORY_GB=$ram") }
        else { $text = $text.TrimEnd("`r","`n") + "`nMEMORY_GB=$ram`n" }
        if ($Role -eq 'student') {
            if ($text -match '(?m)^DISPLAY_ID=') { $text = [regex]::Replace($text,'(?m)^DISPLAY_ID=.*$',"DISPLAY_ID=$DeviceId") }
            else { $text = $text.TrimEnd("`r","`n") + "`nDISPLAY_ID=$DeviceId`n" }
            $fleetApiUrl = [string]$Config.fleet.fleetApiUrl
            if ([string]::IsNullOrWhiteSpace($fleetApiUrl)) { $fleetApiUrl = 'https://fleet-api.scenicrouteservers.com' }
            if ($fleetApiUrl -notmatch '^https://') { throw 'Fleet API URL must use HTTPS.' }
            if ($text -match '(?m)^FLEET_API_URL=') { $text = [regex]::Replace($text,'(?m)^FLEET_API_URL=.*$',"FLEET_API_URL=$fleetApiUrl") }
            else { $text = $text.TrimEnd("`r","`n") + "`nFLEET_API_URL=$fleetApiUrl`n" }
        }
        [IO.File]::WriteAllText($publicPath,(Convert-LghsTextToLf $text),[Text.UTF8Encoding]::new($false))
    }

    if ($Role -eq 'student') {
        $secretPath = Join-Path $DriveRoot 'lghs-provision-secrets.conf'
        if (-not (Test-Path $secretPath)) { throw 'Student provisioning secret file is missing.' }
        $fleetToken = New-LghsFleetApiToken
        $encodedToken = ConvertTo-LghsBase64Utf8 $fleetToken
        $secretText = [IO.File]::ReadAllText($secretPath)
        if ($secretText -match '(?m)^FLEET_API_TOKEN_B64=') { $secretText = [regex]::Replace($secretText,'(?m)^FLEET_API_TOKEN_B64=.*$',"FLEET_API_TOKEN_B64=$encodedToken") }
        else { $secretText = $secretText.TrimEnd("`r","`n") + "`nFLEET_API_TOKEN_B64=$encodedToken`n" }
        [IO.File]::WriteAllText($secretPath,(Convert-LghsTextToLf $secretText),[Text.UTF8Encoding]::new($false))

        try {
            $roundTrip = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedToken))
            if (-not [string]::Equals($roundTrip,$fleetToken,[StringComparison]::Ordinal)) { throw 'Fleet token round-trip mismatch.' }
            Register-LghsFleetApiToken $DeviceId $fleetToken $Config
        } finally {
            $fleetToken = $null
            $roundTrip = $null
        }
    }

    if ($StockBootstrap) {
        $stage2Path = Join-Path $DriveRoot 'lghs-stage2.sh'
        if (-not (Test-Path $stage2Path)) { throw 'LGHS stage-2 payload was not staged. Refusing to release this SD card.' }

        $stage2 = [IO.File]::ReadAllText($stage2Path)
        $stage2 = $stage2.Replace('MEMORY_GB=8',"MEMORY_GB=$ram")

        if ($Role -eq 'student' -and $stage2 -notmatch 'LGHS student display identity') {
            $needle2 = 'DEVICE_ID="$(readv DEVICE_ID "$PUB")"'
            $replacement = @'
DEVICE_ID="$(readv DEVICE_ID "$PUB")"
# LGHS student display identity. Keep the service account stable for policy and
# sudo rules, but make the desktop/account description identify the physical Pi.
usermod -c "$DEVICE_ID" lg_cs_cont >/dev/null 2>&1 || true
'@
            if (-not $stage2.Contains($needle2)) { throw 'Could not stamp Student Pi identity into stage 2.' }
            $stage2 = $stage2.Replace($needle2,$replacement.TrimEnd())
        }

        $stage2 = Convert-LghsTextToLf $stage2
        [IO.File]::WriteAllText($stage2Path,$stage2,[Text.UTF8Encoding]::new($false))
        $backupPath = Join-Path $DriveRoot 'lghs-stage2-backup.sh'
        [IO.File]::WriteAllText($backupPath,$stage2,[Text.UTF8Encoding]::new($false))

        foreach ($path in @($stage2Path,$backupPath)) {
            if (-not (Test-Path $path)) { throw "Required stage-2 payload missing after write: $path" }
            $bytes = [IO.File]::ReadAllBytes($path)
            if ($bytes.Length -lt 1024) { throw "Stage-2 payload is unexpectedly small: $path" }
            if ($bytes -contains 13) { throw "CRLF normalization failed for $([IO.Path]::GetFileName($path))" }
            $verify = [IO.File]::ReadAllText($path)
            if ($verify -notmatch 'LGHS stock bootstrap starting' -or $verify -notmatch 'lghs-bootstrap-online') { throw "Stage-2 payload verification failed: $path" }
        }
        if ((Get-FileHash $stage2Path -Algorithm SHA256).Hash -ne (Get-FileHash $backupPath -Algorithm SHA256).Hash) { throw 'Primary and backup stage-2 payload hashes do not match.' }
    }

    foreach ($name in @('lghs-stage2.sh','lghs-stage2-backup.sh','lghs-provision.conf','lghs-provision-secrets.conf','lghs-controller-key.pub','lghs-controller-key')) {
        Convert-LghsFileToLf (Join-Path $DriveRoot $name)
    }

    foreach ($name in @('lghs-stage2.sh','lghs-stage2-backup.sh','lghs-provision.conf','lghs-provision-secrets.conf','lghs-controller-key.pub','lghs-controller-key')) {
        $path = Join-Path $DriveRoot $name
        if (Test-Path $path) {
            $bytes = [IO.File]::ReadAllBytes($path)
            if ($bytes -contains 13) { throw "CRLF normalization failed for $name" }
        }
    }

    if ($StockBootstrap) {
        foreach ($required in @('lghs-stage2.sh','lghs-stage2-backup.sh','lghs-provision.conf','lghs-provision-secrets.conf')) {
            if (-not (Test-Path (Join-Path $DriveRoot $required))) { throw "Required LGHS boot payload is missing: $required" }
        }
    }
}
