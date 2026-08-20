$ErrorActionPreference = 'Stop'

# Load the proven v3 provisioning implementation, then wrap it with a minimal
# Raspberry Pi Imager first-run shim. The heavy LGHS provisioning runs on the
# following normal boot as a regular systemd service, not under systemd.run.
. (Join-Path $PSScriptRoot 'LGHS-StockBootstrap-v3.ps1')

$script:LghsV3StockBootstrap = ${function:New-LghsStockBootstrapScript}
$script:LghsV3WriteProvisioning = ${function:Write-LghsProvisioning}

function New-LghsStage2BootstrapScript($Config) {
    return (& $script:LghsV3StockBootstrap $Config)
}

function New-LghsStockBootstrapScript($Config) {
    @'
#!/bin/bash
# LGHS Raspberry Pi Imager first-run shim.
# Keep this intentionally tiny: systemd.run is an early/special boot target.
set -u

LOG=/var/log/lghs-first-run-shim.log
exec >>"$LOG" 2>&1
printf '[%s] LGHS first-run shim starting\n' "$(date -u +%FT%TZ)"

BOOT=/boot/firmware
[[ -f "$BOOT/lghs-stage2.sh" ]] || BOOT=/boot
CMDLINE="$BOOT/cmdline.txt"
STAGE2="$BOOT/lghs-stage2.sh"

# Raspberry Pi Imager --first-run-script adds these kernel command-line tokens.
# Remove them before doing anything else so a failed staging operation cannot
# trap the machine in the special first-run target on its next boot.
if [[ -f "$CMDLINE" ]]; then
  sed -E -i \
    -e 's/[[:space:]]+systemd\.run=[^[:space:]]+//g' \
    -e 's/[[:space:]]+systemd\.run_success_action=[^[:space:]]+//g' \
    -e 's/[[:space:]]+systemd\.run_failure_action=[^[:space:]]+//g' \
    -e 's/[[:space:]]+systemd\.unit=[^[:space:]]+//g' \
    "$CMDLINE" || true
  # Normalize whitespace without depending on non-core tools.
  sed -E -i 's/[[:space:]]+/ /g; s/^ //; s/ $//' "$CMDLINE" || true
  echo 'Removed Raspberry Pi Imager one-shot boot override.'
fi

mkdir -p /var/lib/lghs /usr/local/sbin /etc/systemd/system || true

if [[ -f "$STAGE2" ]]; then
  install -m 0700 "$STAGE2" /usr/local/sbin/lghs-stage2-bootstrap || true
  cat >/etc/systemd/system/lghs-stage2-bootstrap.service <<'EOF'
[Unit]
Description=LGHS stage-2 classroom provisioning
After=local-fs.target NetworkManager.service
Wants=NetworkManager.service
ConditionPathExists=!/var/lib/lghs/stage2-complete

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/lghs-stage2-bootstrap
ExecStartPost=/usr/bin/touch /var/lib/lghs/stage2-complete
Restart=on-failure
RestartSec=30
TimeoutStartSec=10min

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload || true
  systemctl enable lghs-stage2-bootstrap.service || true
  echo 'LGHS stage-2 service installed for the next normal boot.'
else
  echo "WARNING: $STAGE2 is missing; continuing to normal boot for recovery."
  touch /var/lib/lghs/stage2-missing || true
fi

sync || true
printf '[%s] LGHS first-run shim complete; Raspberry Pi Imager may reboot now.\n' "$(date -u +%FT%TZ)"
# Always return success. Raspberry Pi Imager uses systemd.run_success_action=reboot.
exit 0
'@
}

function Write-LghsProvisioning([string]$DriveRoot,[string]$DeviceId,[string]$Role,$Credentials,$Config,[bool]$StockBootstrap) {
    # Preserve all v3 credential/key/network provisioning files and checks.
    & $script:LghsV3WriteProvisioning $DriveRoot $DeviceId $Role $Credentials $Config $StockBootstrap

    if ($StockBootstrap) {
        $stage2 = New-LghsStage2BootstrapScript $Config
        $stage2Path = Join-Path $DriveRoot 'lghs-stage2.sh'
        [IO.File]::WriteAllText($stage2Path,$stage2,[Text.UTF8Encoding]::new($false))
        if (-not (Test-Path $stage2Path)) { throw 'LGHS stage-2 bootstrap was not written to the boot partition.' }
        if ((Get-Item $stage2Path).Length -lt 1024) { throw 'LGHS stage-2 bootstrap is unexpectedly small.' }
    }
}
