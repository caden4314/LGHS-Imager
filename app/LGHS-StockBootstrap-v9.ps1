$ErrorActionPreference = 'Stop'

# v9: keep SSH recovery from v8, but do not hold cloud-init open while the full
# LGHS stage-2 payload runs. Also provide a persistent Windows image cache.
. (Join-Path $PSScriptRoot 'LGHS-StockBootstrap-v8.ps1')

function New-LghsCloudInitUserData([string]$Role) {
    $target = if ($Role -eq 'controller') { 'cs_admin' } else { 'lg_cs_cont' }

    $yaml = @'
#cloud-config
# LGHS Trixie bootstrap. Keep cloud-init short: establish the managed primary
# user and SSH, retire the Raspberry Pi setup wizard, then hand stage 2 to
# systemd so the graphical boot is not blocked by long provisioning work.
user:
  name: __LGHS_PRIMARY_USER__
  shell: /bin/bash
  lock_passwd: false

ssh_pwauth: true
disable_root: true

bootcmd:
  - [ /bin/rm, -f, /etc/xdg/autostart/piwiz.desktop ]
  - [ /usr/bin/systemctl, disable, userconfig.service ]
  - [ /usr/bin/systemctl, mask, userconfig.service ]
  - [ /usr/bin/systemctl, unmask, ssh.service ]
  - [ /usr/bin/systemctl, enable, ssh.service ]

write_files:
  - path: /etc/ssh/sshd_config.d/89-lghs-recovery.conf
    owner: root:root
    permissions: '0644'
    content: |
      PubkeyAuthentication yes
      PasswordAuthentication yes
      PermitRootLogin no

  - path: /etc/systemd/system/lghs-stage2-bootstrap.service
    owner: root:root
    permissions: '0644'
    content: |
      [Unit]
      Description=LGHS classroom provisioning
      After=local-fs.target NetworkManager.service ssh.service
      Wants=NetworkManager.service ssh.service
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
  - [ /bin/rm, -f, /etc/xdg/autostart/piwiz.desktop ]
  - [ /usr/bin/systemctl, disable, userconfig.service ]
  - [ /usr/bin/systemctl, mask, userconfig.service ]
  - [ /usr/bin/systemctl, unmask, ssh.service ]
  - [ /usr/bin/systemctl, enable, ssh.service ]
  - [ /usr/bin/systemctl, restart, ssh.service ]
  - [ /usr/bin/systemctl, daemon-reload ]
  - [ /usr/bin/systemctl, enable, lghs-stage2-bootstrap.service ]
  - [ /usr/bin/systemctl, start, --no-block, lghs-stage2-bootstrap.service ]

final_message: "LGHS cloud-init handoff complete; stage 2 continues under systemd"
'@
    return $yaml.Replace('__LGHS_PRIMARY_USER__',$target)
}

function Resolve-LghsCachedImage($Source) {
    if (-not $Source -or [string]::IsNullOrWhiteSpace([string]$Source.Image)) { return $Source }
    $image = [string]$Source.Image
    if ($image -notmatch '^https?://') { return $Source }

    $cacheDir = Join-Path $env:LOCALAPPDATA 'LGHS-Imager\cache\images'
    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null

    $uri = [Uri]$image
    $leaf = [IO.Path]::GetFileName($uri.AbsolutePath)
    if ([string]::IsNullOrWhiteSpace($leaf) -or $leaf -eq 'raspios_arm64_latest') {
        $leaf = 'raspios_arm64_latest.img.xz'
    }
    $safeLeaf = ($leaf -replace '[^A-Za-z0-9._-]','_')
    $cached = Join-Path $cacheDir $safeLeaf
    $meta = "$cached.meta.json"
    $maxAge = [TimeSpan]::FromDays(7)

    if (Test-Path $cached) {
        $item = Get-Item $cached
        if ($item.Length -gt 100MB -and ((Get-Date) - $item.LastWriteTime) -lt $maxAge) {
            if (Get-Command Append-Log -ErrorAction SilentlyContinue) { Append-Log "Image cache hit: $cached" }
            return [pscustomobject]@{Image=$cached;Sha=$Source.Sha;StockBootstrap=$Source.StockBootstrap;Description="$($Source.Description) [cached]"}
        }
    }

    if (Get-Command Append-Log -ErrorAction SilentlyContinue) { Append-Log "Caching image once for faster later flashes: $image" }
    $tmp = "$cached.download"
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    try {
        if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
            Start-BitsTransfer -Source $image -Destination $tmp -DisplayName 'LGHS Raspberry Pi OS image cache' -Description 'Downloading Raspberry Pi OS for repeated classroom flashing'
        } else {
            Invoke-WebRequest -Uri $image -OutFile $tmp -UseBasicParsing
        }
        if (-not (Test-Path $tmp) -or (Get-Item $tmp).Length -lt 100MB) { throw 'Downloaded image cache file is unexpectedly small.' }
        Move-Item $tmp $cached -Force
        @{source=$image;cachedAt=(Get-Date).ToUniversalTime().ToString('o');bytes=(Get-Item $cached).Length} | ConvertTo-Json | Set-Content $meta -Encoding utf8
    } catch {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        if (Test-Path $cached -and (Get-Item $cached).Length -gt 100MB) {
            if (Get-Command Append-Log -ErrorAction SilentlyContinue) { Append-Log "Cache refresh failed; using existing cached image: $($_.Exception.Message)" }
        } else { throw }
    }

    return [pscustomobject]@{Image=$cached;Sha=$Source.Sha;StockBootstrap=$Source.StockBootstrap;Description="$($Source.Description) [cached]"}
}
