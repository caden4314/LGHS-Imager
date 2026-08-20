$ErrorActionPreference = 'Stop'

function ConvertTo-LghsBase64Utf8([string]$Value) {
    if ($null -eq $Value) { $Value = '' }
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value))
}

function Get-LghsLocalWifiConfig {
    $path = Join-Path $env:LOCALAPPDATA 'LGHS-Imager\bootstrap-wifi.json'
    if (-not (Test-Path $path)) { return [pscustomobject]@{ Ssid=''; Password='' } }
    try {
        $cfg = Get-Content $path -Raw | ConvertFrom-Json
        return [pscustomobject]@{ Ssid=[string]$cfg.ssid; Password=[string]$cfg.password }
    } catch {
        throw "Invalid local Wi-Fi configuration: $path"
    }
}

function Get-LghsFleetKeyPair($Config) {
    $keyName = if ($Config.fleet.deploymentKeyName) { [string]$Config.fleet.deploymentKeyName } else { 'controller_ed25519' }
    $dir = Join-Path $env:LOCALAPPDATA 'LGHS-Imager\deployment'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $private = Join-Path $dir $keyName
    $public = "$private.pub"

    if (-not (Test-Path $private) -or -not (Test-Path $public)) {
        $sshPath = $null
        $cmd = Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue
        if ($cmd) { $sshPath = $cmd.Source }
        if (-not $sshPath) {
            $candidate = Join-Path $env:WINDIR 'System32\OpenSSH\ssh-keygen.exe'
            if (Test-Path $candidate) { $sshPath = $candidate }
        }
        if (-not $sshPath) { throw 'Windows OpenSSH Client is required to create the LGHS fleet key.' }

        Remove-Item $private,$public -Force -ErrorAction SilentlyContinue
        $cmdLine = ('"{0}" -q -t ed25519 -N "" -C "LGHS fleet controller" -f "{1}"' -f $sshPath,$private)
        & cmd.exe /d /s /c $cmdLine
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $private) -or -not (Test-Path $public)) {
            throw 'Failed to generate the LGHS deployment Ed25519 key.'
        }
    }

    $pubText = (Get-Content $public -Raw).Trim()
    if ($pubText -notmatch '^ssh-ed25519\s+') { throw 'The LGHS fleet public key is not a valid Ed25519 public key.' }
    [pscustomobject]@{ Private=$private; Public=$public; PublicText=$pubText }
}

function Test-LghsCredentialRoundTrip([string]$SecretFile,$Credentials,$Wifi) {
    if (-not (Test-Path $SecretFile)) { throw 'LGHS credential staging file is missing.' }
    $values = @{}
    foreach ($line in Get-Content $SecretFile) {
        if ($line -match '^([^=]+)=(.*)$') { $values[$matches[1]] = $matches[2] }
    }
    foreach ($check in @(
        @('USER_PASSWORD_B64',[string]$Credentials.UserPassword,'lg_cs_cont'),
        @('ADMIN_PASSWORD_B64',[string]$Credentials.AdminPassword,'cs_admin'),
        @('ROOT_PASSWORD_B64',[string]$Credentials.RootPassword,'root'),
        @('WIFI_SSID_B64',[string]$Wifi.Ssid,'Wi-Fi SSID'),
        @('WIFI_PASSWORD_B64',[string]$Wifi.Password,'Wi-Fi password')
    )) {
        if (-not $values.ContainsKey($check[0])) { throw "Credential staging failed for $($check[2])." }
        try { $actual = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($values[$check[0]])) }
        catch { throw "Credential encoding verification failed for $($check[2])." }
        if (-not [string]::Equals($actual,$check[1],[StringComparison]::Ordinal)) {
            throw "Credential round-trip verification failed for $($check[2])."
        }
    }
}

function New-LghsStockBootstrapScript($Config) {
    $repo = [string]$Config.repository.bootstrapGitRepository
    $branch = [string]$Config.repository.bootstrapGitBranch
    if ([string]::IsNullOrWhiteSpace($repo)) { $repo='https://github.com/caden4314/LGHS-System.git' }
    if ([string]::IsNullOrWhiteSpace($branch)) { $branch='main' }

    $script = @'
#!/bin/bash
set -Eeuo pipefail
LOG=/var/log/lghs-stock-bootstrap.log
exec >>"$LOG" 2>&1
printf '[%s] LGHS stock bootstrap starting\n' "$(date -u +%FT%TZ)"

BOOT=/boot/firmware
[[ -f "$BOOT/lghs-provision.conf" ]] || BOOT=/boot
PUB="$BOOT/lghs-provision.conf"
SEC="$BOOT/lghs-provision-secrets.conf"
[[ -f "$PUB" && -f "$SEC" ]] || { echo 'LGHS provisioning files are missing.'; exit 1; }

# Raspberry Pi Imager's --first-run-script adds systemd.run tokens to cmdline.txt.
# A custom script must remove them itself or every successful first boot re-enters
# firstrun.sh and reboots forever. Remove them immediately so even a later failure
# cannot trap the Pi in that loop.
CMDLINE="$BOOT/cmdline.txt"
if [[ -f "$CMDLINE" ]]; then
  sed -E -i \
    -e 's/[[:space:]]+systemd\.run=[^[:space:]]+//g' \
    -e 's/[[:space:]]+systemd\.run_success_action=[^[:space:]]+//g' \
    -e 's/[[:space:]]+systemd\.run_failure_action=[^[:space:]]+//g' \
    -e 's/[[:space:]]+systemd\.unit=[^[:space:]]+//g' \
    "$CMDLINE"
  echo 'Removed Raspberry Pi Imager one-shot boot override.'
fi

readv(){ awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,"");print;exit}' "$2"; }
dec(){ local v; v="$(readv "$1" "$SEC")"; printf '%s' "$v" | base64 --decode; }
DEVICE_ID="$(readv DEVICE_ID "$PUB")"
HOST="$(readv TARGET_HOSTNAME "$PUB")"
ROLE="$(readv ROLE "$PUB")"
USER_NAME="$(readv USER_ACCOUNT "$PUB")"
ADMIN_NAME="$(readv ADMIN_ACCOUNT "$PUB")"
ROOT_NAME="$(readv ROOT_ACCOUNT "$PUB")"
ROOT_SAME_AS_ADMIN="$(readv ROOT_SAME_AS_ADMIN "$PUB")"
USER_PASSWORD="$(dec USER_PASSWORD_B64)"
ADMIN_PASSWORD="$(dec ADMIN_PASSWORD_B64)"
ROOT_PASSWORD="$(dec ROOT_PASSWORD_B64)"
WIFI_SSID="$(dec WIFI_SSID_B64 || true)"
WIFI_PASSWORD="$(dec WIFI_PASSWORD_B64 || true)"

[[ "$ROLE" == student || "$ROLE" == controller ]] || { echo "Invalid role: $ROLE"; exit 1; }
[[ "$USER_NAME" == lg_cs_cont && "$ADMIN_NAME" == cs_admin && "$ROOT_NAME" == root ]] || { echo 'Invalid LGHS account mapping.'; exit 1; }
[[ -n "$USER_PASSWORD" && -n "$ADMIN_PASSWORD" && -n "$ROOT_PASSWORD" ]] || { echo 'One or more LGHS passwords are empty.'; exit 1; }
[[ "$ROOT_SAME_AS_ADMIN" != 1 || "$ROOT_PASSWORD" == "$ADMIN_PASSWORD" ]] || { echo 'Root/Admin password-link verification failed.'; exit 1; }

id lg_cs_cont >/dev/null 2>&1 || useradd -m -s /bin/bash lg_cs_cont
id cs_admin >/dev/null 2>&1 || useradd -m -s /bin/bash cs_admin
usermod -aG sudo cs_admin
if id -nG lg_cs_cont 2>/dev/null | tr ' ' '\n' | grep -qx sudo; then gpasswd -d lg_cs_cont sudo >/dev/null 2>&1 || true; fi
printf '%s:%s\n' lg_cs_cont "$USER_PASSWORD" | chpasswd
printf '%s:%s\n' cs_admin "$ADMIN_PASSWORD" | chpasswd
printf '%s:%s\n' root "$ROOT_PASSWORD" | chpasswd
passwd -u lg_cs_cont >/dev/null 2>&1 || true
passwd -u cs_admin >/dev/null 2>&1 || true
passwd -u root >/dev/null 2>&1 || true
for account in lg_cs_cont cs_admin root; do
  state="$(passwd -S "$account" 2>/dev/null | awk '{print $2}')"
  [[ "$state" == P ]] || { echo "Password provisioning failed for $account (state=$state)."; exit 1; }
done
id -nG cs_admin | tr ' ' '\n' | grep -qx sudo || { echo 'cs_admin sudo membership failed.'; exit 1; }

cat >/etc/sudoers.d/91-lghs-bootstrap-admin <<'EOF'
Defaults:cs_admin timestamp_timeout=5
cs_admin ALL=(ALL:ALL) ALL
EOF
chmod 0440 /etc/sudoers.d/91-lghs-bootstrap-admin
visudo -cf /etc/sudoers >/dev/null

printf '%s\n' "$HOST" >/etc/hostname
if grep -qE '^127\.0\.1\.1[[:space:]]+' /etc/hosts; then
  sed -i -E "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t${HOST}/" /etc/hosts
else
  printf '127.0.1.1\t%s\n' "$HOST" >>/etc/hosts
fi
hostnamectl set-hostname "$HOST" 2>/dev/null || true

install -d -m 0755 /etc/lghs /var/lib/lghs
install -d -m 0700 /etc/lghs/secrets
printf '%s\n' "$ROLE" >/etc/lghs/role
cat >/etc/lghs/device.conf <<EOF
DEVICE_ID=$DEVICE_ID
ROLE=$ROLE
HOSTNAME=$HOST
BOARD=Raspberry Pi 5
MEMORY_GB=8
ARCH=arm64
EOF

FLEET_PUB="$BOOT/lghs-controller-key.pub"
FLEET_PRIV="$BOOT/lghs-controller-key"
if [[ -f "$FLEET_PUB" ]]; then
  grep -q '^ssh-ed25519 ' "$FLEET_PUB" || { echo 'Invalid fleet public key.'; exit 1; }
  install -m 0644 "$FLEET_PUB" /etc/lghs/controller_ed25519.pub
  install -d -m 0700 -o cs_admin -g cs_admin /home/cs_admin/.ssh
  install -m 0600 -o cs_admin -g cs_admin "$FLEET_PUB" /home/cs_admin/.ssh/authorized_keys
  if [[ "$ROLE" == controller ]]; then
    [[ -f "$FLEET_PRIV" ]] || { echo 'Controller fleet private key missing.'; exit 1; }
    install -m 0600 "$FLEET_PRIV" /etc/lghs/secrets/controller_ed25519
    install -m 0644 "$FLEET_PUB" /etc/lghs/secrets/controller_ed25519.pub
  fi
fi

# Dedicated direct Ethernet management link for the Control Pi.
# Laptop side is configured by LGHS Imager as 192.168.50.1/24.
if [[ "$ROLE" == controller ]] && command -v nmcli >/dev/null 2>&1; then
  ETH_DEV="$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2=="ethernet" && $1!="lo" {print $1; exit}')"
  if [[ -n "$ETH_DEV" ]]; then
    nmcli connection delete 'LGHS Direct Ethernet' >/dev/null 2>&1 || true
    nmcli connection add type ethernet ifname "$ETH_DEV" con-name 'LGHS Direct Ethernet' \
      ipv4.method manual ipv4.addresses 192.168.50.2/24 ipv4.never-default yes \
      ipv6.method disabled connection.autoconnect yes connection.autoconnect-priority 200 >/dev/null
    nmcli connection up 'LGHS Direct Ethernet' >/dev/null 2>&1 || true
    echo "Direct Ethernet configured: $ETH_DEV = 192.168.50.2/24"
  else
    echo 'No wired Ethernet device found yet; NetworkManager will keep normal networking available.'
  fi
fi

if [[ -n "$WIFI_SSID" && -n "$WIFI_PASSWORD" ]] && command -v nmcli >/dev/null 2>&1; then
  rfkill unblock wifi >/dev/null 2>&1 || true
  nmcli radio wifi on >/dev/null 2>&1 || true
  nmcli connection delete 'LGHS Bootstrap WiFi' >/dev/null 2>&1 || true
  if nmcli connection add type wifi ifname wlan0 con-name 'LGHS Bootstrap WiFi' ssid "$WIFI_SSID" >/dev/null 2>&1; then
    nmcli connection modify 'LGHS Bootstrap WiFi' wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$WIFI_PASSWORD" connection.autoconnect yes connection.autoconnect-priority 100 >/dev/null 2>&1 || true
    nmcli connection up 'LGHS Bootstrap WiFi' >/dev/null 2>&1 || true
  fi
fi

rm -f /etc/xdg/autostart/piwiz.desktop 2>/dev/null || true
TARGET_USER=lg_cs_cont
[[ "$ROLE" == controller ]] && TARGET_USER=cs_admin
if command -v raspi-config >/dev/null 2>&1; then SUDO_USER="$TARGET_USER" raspi-config nonint do_boot_behaviour B4 >/dev/null 2>&1 || true; fi

install -d -m 0755 /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/90-lghs-bootstrap.conf <<'EOF'
PubkeyAuthentication yes
PasswordAuthentication yes
PermitRootLogin no
EOF
systemctl enable ssh.service >/dev/null 2>&1 || systemctl enable ssh >/dev/null 2>&1 || true
systemctl restart ssh.service >/dev/null 2>&1 || systemctl restart ssh >/dev/null 2>&1 || true

cat >/usr/local/sbin/lghs-bootstrap-online <<'EOS'
#!/bin/bash
set -euo pipefail
ROLE="$(cat /etc/lghs/role)"
REPO='__LGHS_REPO__'
BRANCH='__LGHS_BRANCH__'
TARGET=/opt/lghs/repo
[[ -f /var/lib/lghs/bootstrap-complete ]] && exit 0
if ! command -v git >/dev/null 2>&1; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y git ca-certificates
fi
mkdir -p /opt/lghs
if [[ ! -d "$TARGET/.git" ]]; then
  rm -rf "$TARGET.tmp"
  git clone --depth 1 --branch "$BRANCH" "$REPO" "$TARGET.tmp"
  rm -rf "$TARGET"
  mv "$TARGET.tmp" "$TARGET"
else
  git -C "$TARGET" fetch --prune origin "$BRANCH"
  git -C "$TARGET" reset --hard "origin/$BRANCH"
fi
COMMIT="$(git -C "$TARGET" rev-parse HEAD)"
printf '%s\n' "$COMMIT" >/etc/lghs/source-commit
printf '%s\n' "$COMMIT" >"$TARGET/.lghs-source-commit"
/bin/bash "$TARGET/install.sh" "$ROLE"
touch /var/lib/lghs/bootstrap-complete
systemctl disable lghs-bootstrap-online.service >/dev/null 2>&1 || true
EOS
chmod 0755 /usr/local/sbin/lghs-bootstrap-online
cat >/etc/systemd/system/lghs-bootstrap-online.service <<'EOS'
[Unit]
Description=Finish LGHS installation from stock Raspberry Pi OS
After=local-fs.target NetworkManager.service
StartLimitIntervalSec=0
ConditionPathExists=!/var/lib/lghs/bootstrap-complete
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/lghs-bootstrap-online
Restart=on-failure
RestartSec=60
TimeoutStartSec=15min
[Install]
WantedBy=multi-user.target
EOS
systemctl daemon-reload
systemctl enable lghs-bootstrap-online.service >/dev/null 2>&1 || true
systemctl start --no-block lghs-bootstrap-online.service >/dev/null 2>&1 || true

install -m 0600 "$PUB" /var/lib/lghs/provisioned.conf
printf '%s\n' "$(date -u +%FT%TZ)" >/var/lib/lghs/provisioned
chmod 0600 /var/lib/lghs/provisioned /var/lib/lghs/provisioned.conf
rm -f "$SEC" "$PUB" "$FLEET_PUB" "$FLEET_PRIV" "$BOOT/firstrun.sh"
unset USER_PASSWORD ADMIN_PASSWORD ROOT_PASSWORD WIFI_SSID WIFI_PASSWORD
sync
printf '[%s] Local provisioning complete for %s (%s)\n' "$(date -u +%FT%TZ)" "$DEVICE_ID" "$ROLE"
exit 0
'@
    $script = $script.Replace('__LGHS_REPO__',$repo.Replace("'","'\''"))
    $script = $script.Replace('__LGHS_BRANCH__',$branch.Replace("'","'\''"))
    return $script
}

function Write-LghsProvisioning([string]$DriveRoot,[string]$DeviceId,[string]$Role,$Credentials,$Config,[bool]$StockBootstrap) {
    $wifi = Get-LghsLocalWifiConfig
    @(
        "DEVICE_ID=$DeviceId"
        "TARGET_HOSTNAME=$DeviceId"
        "ROLE=$Role"
        'BOARD=Raspberry Pi 5'
        'MEMORY_GB=8'
        'ARCH=arm64'
        "USER_ACCOUNT=$($Credentials.UserName)"
        "ADMIN_ACCOUNT=$($Credentials.AdminName)"
        "ROOT_ACCOUNT=$($Credentials.RootName)"
        "ROOT_SAME_AS_ADMIN=$([int]$Credentials.RootSameAsAdmin)"
        "PROVISIONED_AT=$((Get-Date).ToUniversalTime().ToString('o'))"
    ) | Set-Content -Path (Join-Path $DriveRoot 'lghs-provision.conf') -Encoding ascii

    $secretFile = Join-Path $DriveRoot 'lghs-provision-secrets.conf'
    @(
        'ENCODING=base64-utf8'
        "USER_PASSWORD_B64=$(ConvertTo-LghsBase64Utf8 $Credentials.UserPassword)"
        "ADMIN_PASSWORD_B64=$(ConvertTo-LghsBase64Utf8 $Credentials.AdminPassword)"
        "ROOT_PASSWORD_B64=$(ConvertTo-LghsBase64Utf8 $Credentials.RootPassword)"
        "WIFI_SSID_B64=$(ConvertTo-LghsBase64Utf8 $wifi.Ssid)"
        "WIFI_PASSWORD_B64=$(ConvertTo-LghsBase64Utf8 $wifi.Password)"
    ) | Set-Content -Path $secretFile -Encoding ascii
    Test-LghsCredentialRoundTrip $secretFile $Credentials $wifi

    $keys = Get-LghsFleetKeyPair $Config
    Copy-Item $keys.Public (Join-Path $DriveRoot 'lghs-controller-key.pub') -Force
    if ($Role -eq 'controller') { Copy-Item $keys.Private (Join-Path $DriveRoot 'lghs-controller-key') -Force }
    else { Remove-Item (Join-Path $DriveRoot 'lghs-controller-key') -Force -ErrorAction SilentlyContinue }
}
