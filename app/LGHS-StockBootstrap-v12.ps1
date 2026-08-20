$ErrorActionPreference = 'Stop'

# v12: build on the LF-safe v11 path and make the Raspberry Pi 5 memory
# profile selectable per flash. Raspberry Pi OS arm64 is common to Pi 5 4 GB
# and 8 GB hardware; the selected profile is stamped into provisioning and the
# resulting /etc/lghs/device.conf instead of hard-coding 8 GB.
. (Join-Path $PSScriptRoot 'LGHS-StockBootstrap-v11.ps1')

$script:LghsV11WriteProvisioning = ${function:Write-LghsProvisioning}

function Get-LghsSelectedRamGb {
    $ram = 8
    try {
        if ($null -ne $script:LghsHardwareRamGb) { $ram = [int]$script:LghsHardwareRamGb }
    } catch { $ram = 8 }
    if ($ram -notin @(4,8)) { throw "Unsupported Raspberry Pi 5 memory profile: $ram GB. Select 4 GB or 8 GB." }
    return $ram
}

function Write-LghsProvisioning([string]$DriveRoot,[string]$DeviceId,[string]$Role,$Credentials,$Config,[bool]$StockBootstrap) {
    & $script:LghsV11WriteProvisioning $DriveRoot $DeviceId $Role $Credentials $Config $StockBootstrap

    $ram = Get-LghsSelectedRamGb
    $publicPath = Join-Path $DriveRoot 'lghs-provision.conf'
    if (Test-Path $publicPath) {
        $text = [IO.File]::ReadAllText($publicPath)
        if ($text -match '(?m)^MEMORY_GB=') {
            $text = [regex]::Replace($text,'(?m)^MEMORY_GB=.*$',"MEMORY_GB=$ram")
        } else {
            $text = $text.TrimEnd("`r","`n") + "`nMEMORY_GB=$ram`n"
        }
        $text = $text.Replace("`r`n","`n").Replace("`r","`n")
        [IO.File]::WriteAllText($publicPath,$text,[Text.UTF8Encoding]::new($false))
    }

    if ($StockBootstrap) {
        $stage2Path = Join-Path $DriveRoot 'lghs-stage2.sh'
        if (Test-Path $stage2Path) {
            $stage2 = [IO.File]::ReadAllText($stage2Path)
            $stage2 = $stage2.Replace('MEMORY_GB=8',"MEMORY_GB=$ram")

            # Do not fail a classroom build for firmware-reserved RAM, but leave
            # an explicit first-boot warning if the selected profile clearly does
            # not match the physical Pi. /proc/meminfo is lower than marketed RAM,
            # so classify >= 6 GiB usable as the 8 GB model and everything else
            # in the Pi 5 test range as 4 GB.
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
            $check = $check.Replace("`r`n","`n").Replace("`r","`n").TrimEnd("`n")
            if ($stage2.Contains($marker) -and -not $stage2.Contains('ACTUAL_MEM_KB=')) {
                $stage2 = $stage2.Replace($marker,$check)
            }
            $stage2 = $stage2.Replace("`r`n","`n").Replace("`r","`n")
            [IO.File]::WriteAllText($stage2Path,$stage2,[Text.UTF8Encoding]::new($false))
        }
    }

    # Re-run the LF safety check after v12 edits.
    foreach ($name in @('lghs-stage2.sh','lghs-provision.conf','lghs-provision-secrets.conf')) {
        $path = Join-Path $DriveRoot $name
        if (Test-Path $path) {
            $bytes = [IO.File]::ReadAllBytes($path)
            if ($bytes -contains 13) { throw "CRLF normalization failed for $name after hardware-profile staging." }
        }
    }
}
