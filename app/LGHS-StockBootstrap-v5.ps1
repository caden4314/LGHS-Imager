$ErrorActionPreference = 'Stop'

# Reuse the proven provisioning payload from v3, but do not execute it through
# Raspberry Pi Imager's legacy firstrun/systemd.run path. Current Raspberry Pi
# OS Trixie uses cloud-init based customisation.
. (Join-Path $PSScriptRoot 'LGHS-StockBootstrap-v3.ps1')

$script:LghsV3StockBootstrap = ${function:New-LghsStockBootstrapScript}
$script:LghsV3WriteProvisioning = ${function:Write-LghsProvisioning}

function New-LghsCloudInitUserData {
    @'
#cloud-config
# LGHS Imager cloud-init bootstrap for current Raspberry Pi OS Trixie.
# The real provisioning payload is staged on the boot partition by Windows and
# is started as an ordinary systemd service during a normal boot.
write_files:
  - path: /etc/systemd/system/lghs-stage2-bootstrap.service
    owner: root:root
    permissions: '0644'
    content: |
      [Unit]
      Description=LGHS classroom provisioning
      After=local-fs.target NetworkManager.service
      Wants=NetworkManager.service
      ConditionPathExists=!/var/lib/lghs/stage2-complete

      [Service]
      Type=oneshot
      ExecStart=/bin/bash -c 'if [ -f /boot/firmware/lghs-stage2.sh ]; then exec /bin/bash /boot/firmware/lghs-stage2.sh; elif [ -f /boot/lghs-stage2.sh ]; then exec /bin/bash /boot/lghs-stage2.sh; else echo "LGHS stage2 payload missing" >&2; exit 1; fi'
      ExecStartPost=/usr/bin/touch /var/lib/lghs/stage2-complete
      Restart=on-failure
      RestartSec=30
      TimeoutStartSec=15min

      [Install]
      WantedBy=multi-user.target
runcmd:
  - [ /usr/bin/mkdir, -p, /var/lib/lghs ]
  - [ /usr/bin/systemctl, daemon-reload ]
  - [ /usr/bin/systemctl, enable, lghs-stage2-bootstrap.service ]
  - [ /usr/bin/systemctl, start, --no-block, lghs-stage2-bootstrap.service ]
final_message: "LGHS cloud-init bootstrap queued"
'@
}

function Write-LghsProvisioning([string]$DriveRoot,[string]$DeviceId,[string]$Role,$Credentials,$Config,[bool]$StockBootstrap) {
    & $script:LghsV3WriteProvisioning $DriveRoot $DeviceId $Role $Credentials $Config $StockBootstrap

    if ($StockBootstrap) {
        $stage2Path = Join-Path $DriveRoot 'lghs-stage2.sh'
        $stage2 = & $script:LghsV3StockBootstrap $Config

        # The v3 payload still contains defensive legacy cmdline cleanup. It is
        # harmless here, but no firstrun/systemd.run tokens are created by v5.
        [IO.File]::WriteAllText($stage2Path,$stage2,[Text.UTF8Encoding]::new($false))

        if (-not (Test-Path $stage2Path)) {
            throw 'LGHS stage-2 payload was not written to the boot partition.'
        }
        $written = Get-Content $stage2Path -Raw
        if ($written -notmatch 'LGHS stock bootstrap starting') {
            throw 'LGHS stage-2 payload verification failed.'
        }

        # Explicitly remove stale legacy files if this card/volume was reused.
        Remove-Item (Join-Path $DriveRoot 'firstrun.sh') -Force -ErrorAction SilentlyContinue
    }
}
