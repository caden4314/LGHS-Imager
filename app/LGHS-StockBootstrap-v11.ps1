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
    $raw = & $script:LghsV10CloudInit $Role
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

    # Replace the legacy 8 GB metadata with the explicitly selected profile.
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
            $stage2 = $stage2.Replace('MEMORY_GB=8',"MEMORY_GB=$ram")
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

    # Fail before card release if CR bytes survive in any critical Linux
    # payload. This is the exact class of failure that broke the earlier flash.
    foreach ($name in @('lghs-stage2.sh','lghs-provision.conf','lghs-provision-secrets.conf')) {
        $path = Join-Path $DriveRoot $name
        if (Test-Path $path) {
            $bytes = [IO.File]::ReadAllBytes($path)
            if ($bytes -contains 13) { throw "CRLF normalization failed for $name" }
        }
    }
}
