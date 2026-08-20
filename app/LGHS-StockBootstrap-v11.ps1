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

function New-LghsCloudInitUserData([string]$Role) {
    # Keep the cloud-init YAML LF-only as well as the FAT provisioning payloads.
    $raw = & $script:LghsV10CloudInit $Role
    return (Convert-LghsTextToLf $raw)
}

function Select-LghsPi5RamProfile {
    $choice = [System.Windows.MessageBox]::Show(
        "Select the Raspberry Pi 5 RAM profile for this flash.`n`nYES = Pi 5 4 GB`nNO  = Pi 5 8 GB`n`nBoth use the same Raspberry Pi OS 64-bit image.",
        'LGHS Pi 5 hardware profile',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )
    if ($choice -eq [System.Windows.MessageBoxResult]::Yes) { return 4 }
    return 8
}

function Write-LghsProvisioning([string]$DriveRoot,[string]$DeviceId,[string]$Role,$Credentials,$Config,[bool]$StockBootstrap) {
    # The image itself is common to both RAM capacities, so choosing the profile
    # during provisioning is safe and still happens once for every managed flash.
    $ram = Select-LghsPi5RamProfile
    & $script:LghsV10WriteProvisioning $DriveRoot $DeviceId $Role $Credentials $Config $StockBootstrap

    $publicPath = Join-Path $DriveRoot 'lghs-provision.conf'
    if (Test-Path $publicPath) {
        $text = [IO.File]::ReadAllText($publicPath)
        if ($text -match '(?m)^MEMORY_GB=') {
            $text = [regex]::Replace($text,'(?m)^MEMORY_GB=.*$',"MEMORY_GB=$ram")
        } else {
            $text = $text.TrimEnd("`r","`n") + "`nMEMORY_GB=$ram`n"
        }
        [IO.File]::WriteAllText($publicPath,(Convert-LghsTextToLf $text),[Text.UTF8Encoding]::new($false))
    }

    if ($StockBootstrap) {
        $stage2Path = Join-Path $DriveRoot 'lghs-stage2.sh'
        if (Test-Path $stage2Path) {
            $stage2 = [IO.File]::ReadAllText($stage2Path)
            # Older bootstrap source hard-coded 8 GB in /etc/lghs/device.conf.
            $stage2 = $stage2.Replace('MEMORY_GB=8',"MEMORY_GB=$ram")

            # Record a non-fatal first-boot sanity check. Usable RAM is below the
            # marketed capacity, so >= 6 GiB MemTotal is classified as the 8 GB
            # model; lower Pi 5 test units are classified as 4 GB.
            $marker = 'ARCH=arm64'
            $check = @"
ARCH=arm64
ACTUAL_MEM_KB=`$(awk '/MemTotal:/ {print `$2}' /proc/meminfo 2>/dev/null || echo 0)
if [[ "`$ACTUAL_MEM_KB" =~ ^[0-9]+`$ ]]; then
  if (( ACTUAL_MEM_KB >= 6291456 )); then ACTUAL_PROFILE_GB=8; else ACTUAL_PROFILE_GB=4; fi
  if [[ "`$ACTUAL_PROFILE_GB" != "$ram" ]]; then
    echo "WARNING: Imager selected Raspberry Pi 5 $ram GB profile, but detected approximately `$ACTUAL_PROFILE_GB GB. Continuing for test use."
  else
    echo "Raspberry Pi 5 memory profile verified: $ram GB."
  fi
fi
"@
            $check = (Convert-LghsTextToLf $check).TrimEnd("`n")
            if ($stage2.Contains($marker) -and -not $stage2.Contains('ACTUAL_MEM_KB=')) {
                $stage2 = $stage2.Replace($marker,$check)
            }
            [IO.File]::WriteAllText($stage2Path,(Convert-LghsTextToLf $stage2),[Text.UTF8Encoding]::new($false))
        }
    }

    foreach ($name in @(
        'lghs-stage2.sh',
        'lghs-provision.conf',
        'lghs-provision-secrets.conf',
        'lghs-controller-key.pub'
    )) {
        Convert-LghsFileToLf (Join-Path $DriveRoot $name)
    }

    # Fail before card release if CR bytes survive in a Linux payload. This was
    # the cause of the earlier bash/base64 first-boot failure.
    foreach ($name in @('lghs-stage2.sh','lghs-provision.conf','lghs-provision-secrets.conf')) {
        $path = Join-Path $DriveRoot $name
        if (Test-Path $path) {
            $bytes = [IO.File]::ReadAllBytes($path)
            if ($bytes -contains 13) { throw "CRLF normalization failed for $name" }
        }
    }
}
