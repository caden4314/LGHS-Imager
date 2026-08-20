$ErrorActionPreference = 'Stop'

# v11: build on v10 SSH-first provisioning, but guarantee every Linux-side
# generated text payload staged on the FAT boot partition uses LF line endings.
# CRLF was proven to break both bash parsing and base64 credential decoding.
. (Join-Path $PSScriptRoot 'LGHS-StockBootstrap-v10.ps1')

$script:LghsV10WriteProvisioning = ${function:Write-LghsProvisioning}

function Convert-LghsFileToLf([string]$Path) {
    if (-not (Test-Path $Path)) { return }
    $text = [IO.File]::ReadAllText($Path)
    $text = $text.Replace("`r`n","`n").Replace("`r","`n")
    [IO.File]::WriteAllText($Path,$text,[Text.UTF8Encoding]::new($false))
}

function Write-LghsProvisioning([string]$DriveRoot,[string]$DeviceId,[string]$Role,$Credentials,$Config,[bool]$StockBootstrap) {
    & $script:LghsV10WriteProvisioning $DriveRoot $DeviceId $Role $Credentials $Config $StockBootstrap

    if ($StockBootstrap) {
        foreach ($name in @(
            'lghs-stage2.sh',
            'lghs-provision.conf',
            'lghs-provision-secrets.conf',
            'lghs-controller-key.pub'
        )) {
            Convert-LghsFileToLf (Join-Path $DriveRoot $name)
        }

        # Fail the flash before eject if CR bytes survived in any critical
        # Linux payload. This turns a boot-time mystery into an imager error.
        foreach ($name in @('lghs-stage2.sh','lghs-provision.conf','lghs-provision-secrets.conf')) {
            $path = Join-Path $DriveRoot $name
            if (Test-Path $path) {
                $bytes = [IO.File]::ReadAllBytes($path)
                if ($bytes -contains 13) { throw "CRLF normalization failed for $name" }
            }
        }
    }
}
