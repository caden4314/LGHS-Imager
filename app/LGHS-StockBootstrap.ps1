$ErrorActionPreference = 'Stop'

function ConvertTo-LghsBase64Utf8([string]$Value) {
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value))
}

function Get-LghsFleetKeyPair($Config) {
    $keyName = if ($Config.fleet.deploymentKeyName) { [string]$Config.fleet.deploymentKeyName } else { 'controller_ed25519' }
    $dir = Join-Path $env:LOCALAPPDATA 'LGHS-Imager\deployment'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $private = Join-Path $dir $keyName
    $public = "$private.pub"

    if (-not (Test-Path $private) -or -not (Test-Path $public)) {
        $sshKeygen = Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue
        if (-not $sshKeygen) {
            $candidate = Join-Path $env:WINDIR 'System32\OpenSSH\ssh-keygen.exe'
            if (Test-Path $candidate) { $sshKeygen = Get-Item $candidate }
        }
        if (-not $sshKeygen) {
            throw 'Windows OpenSSH ssh-keygen.exe is required to create the LGHS deployment fleet key. Install the Windows OpenSSH Client optional feature and reopen LGHS Imager.'
        }
        Remove-Item $private,$public -Force -ErrorAction SilentlyContinue
        & $sshKeygen.Source -q -t ed25519 -N '' -C 'LGHS fleet controller' -f $private
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $private) -or -not (Test-Path $public)) {
            throw 'Failed to generate the LGHS deployment Ed25519 key.'
        }
    }

    $pubText = (Get-Content $public -Raw).Trim()
    if ($pubText -notmatch '^ssh-ed25519\s+') { throw 'The LGHS fleet public key is not a valid Ed25519 public key.' }
    return [pscustomobject]@{ Private=$private; Public=$public; PublicText=$pubText }
}

function New-LghsStockBootstrapScript($Config) {
    $repo = [string]$Config.repository.bootstrapGitRepository
    $branch = [string]$Config.repository.bootstrapGitBranch
    if ([string]::IsNullOrWhiteSpace($repo)) { $repo = 'https://github.com/caden4314/LGHS-System.git' }
    if ([string]::IsNullOrWhiteSpace($branch)) { $branch = 'main' }

    $script = @'
#!/bin/bash
set -u
LOG=/var/log/lghs-stock-bootstrap.log
exec >>"$LOG" 2>&1
printf '[%s] LGHS stock bootstrap starting\n' "$(date -u +%FT%TZ)"

BOOT=/boot/firmware
[[ -f "$BOOT/lghs-provision.conf" ]] || BOOT=/boot
PUB="$BOOT/lghs-provision.conf"
SEC="$BOOT/lghs-provision-secrets.conf"
[[ -f "$PUB" && -f "$SEC" ]] || { echo 'LGHS provisioning files are missing.'; exit 1; }

readv(){ awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,"");print;exit}' "$2"; }
dec(){ readv "$1" "$SEC" | base64 --decode; }
DEVICE_ID="$(readv DEVICE_ID "$PUB")"
HOST="$(readv TARGET_HOSTNAME "$PUB")"
ROLE="$(readv ROLE "$PUB")"
USER_NAME="$(readv USER_ACCOUNT "$PUB")"
ADMIN_NAME="$(readv ADMIN_ACCOUNT "$PUB")"
ROOT_NAME="$(readv ROOT_ACCOUNT "$PUB")"
USER_PASSWORD="$(dec USER_PASSWORD_B64)"
ADMIN_PASSWORD="$(dec ADMIN_PASSWORD_B64)"
ROOT_PASSWORD="$(dec ROOT_PASSWORD_B64)"

[[ "$ROLE" == student || "$ROLE" == controller ]] || { echo "Invalid role: $ROLE"; exit 1; }
[[ "$USER_NAME" == lg_cs_cont && "$ADMIN_NAME" == cs_admin && "$ROOT_NAME" == root ]] || { echo 'Invalid LGHS account mapping.'; exit 1; }

id lg_cs_cont >/dev/null 2>&1 || useradd -m -s /bin/bash lg_cs_cont
id cs_admin >/dev/null 2>&1 || useradd -m -s /bin/bash cs_admin
usermod -aG sudo cs_admin
if id -nG lg_cs_cont 2>/dev/null | tr ' ' '\n' | grep -qx sudo; then gpasswd -d lg_cs_cont sudo >/dev/null 2>&1 || true; fi
printf '%s:%s\n' lg_cs_cont "$USER_PASSWORD" | chpasswd
printf '%s:%s\n' cs_admin "$ADMIN_PASSWORD" | chpasswd
printf '%s:%s\n' root "$ROOT_PASSWORD" | chpasswd

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
  install -m 0644 "$FLEET_PUB" /etc/lghs/controller_ed25519.pub
  if [[ "$ROLE" == student ]]; then
    install -d -m 0700 -o cs_admin -g cs_admin /home/cs_admin/.ssh
    install -m 0600 -o cs_admin -g cs_admin "$FLEET_PUB" /home/cs_admin/.ssh/authorized_keys
  else
    [[ -f "$FLEET_PRIV" ]] || { echo 'Controller fleet private key missing.'; exit 1; }
    install -m 0600 "$FLEET_PRIV" /etc/lghs/secrets/controller_ed25519
    install -m 0644 "$FLEET_PUB" /etc/lghs/secrets/controller_ed25519.pub
  fi
fi

# Disable the stock first-run wizard and use the role's classroom account.
rm -f /etc/xdg/autostart/piwiz.desktop 2>/dev/null || true
TARGET_USER=lg_cs_cont
[[ "$ROLE" == controller ]] && TARGET_USER=cs_admin
if command -v raspi-config >/dev/null 2>&1; then
  SUDO_USER="$TARGET_USER" raspi-config nonint do_boot_behaviour B4 >/dev/null 2>&1 || true
fi
systemctl enable ssh >/dev/null 2>&1 || true
systemctl start ssh >/dev/null 2>&1 || true

# Install a network-retrying service. Core identity/password/autologin is already
# applied, so the Pi remains usable even if school Wi-Fi is not connected yet.
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
if [[ ! -d "$TARGET/.git" ]]; then
  rm -rf "$TARGET.tmp"
  git clone --depth 1 --branch "$BRANCH" "$REPO" "$TARGET.tmp"
  mkdir -p /opt/lghs
  rm -rf "$TARGET"
  mv "$TARGET.tmp" "$TARGET"
else
  git -C "$TARGET" fetch origin "$BRANCH"
  git -C "$TARGET" reset --hard "origin/$BRANCH"
fi
git -C "$TARGET" rev-parse HEAD >/etc/lghs/source-commit
printf '%s\n' "$(git -C "$TARGET" rev-parse HEAD)" >"$TARGET/.lghs-source-commit"
/bin/bash "$TARGET/install.sh" "$ROLE"
mkdir -p /var/lib/lghs
touch /var/lib/lghs/bootstrap-complete
systemctl disable lghs-bootstrap-online.service >/dev/null 2>&1 || true
EOS
chmod 0755 /usr/local/sbin/lghs-bootstrap-online
cat >/etc/systemd/system/lghs-bootstrap-online.service <<'EOS'
[Unit]
Description=Finish LGHS installation from stock Raspberry Pi OS
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/lghs-bootstrap-online
Restart=on-failure
RestartSec=60

[Install]
WantedBy=multi-user.target
EOS
systemctl daemon-reload
systemctl enable lghs-bootstrap-online.service >/dev/null 2>&1 || true
systemctl start --no-block lghs-bootstrap-online.service >/dev/null 2>&1 || true

install -m 0600 "$PUB" /var/lib/lghs/provisioned.conf
printf '%s\n' "$(date -u +%FT%TZ)" >/var/lib/lghs/provisioned
chmod 0600 /var/lib/lghs/provisioned /var/lib/lghs/provisioned.conf
rm -f "$SEC" "$PUB" "$FLEET_PUB" "$FLEET_PRIV"
unset USER_PASSWORD ADMIN_PASSWORD ROOT_PASSWORD
sync
printf '[%s] Local provisioning complete for %s (%s)\n' "$(date -u +%FT%TZ)" "$DEVICE_ID" "$ROLE"
exit 0
'@
    $script = $script.Replace('__LGHS_REPO__', $repo.Replace("'", "'\''"))
    $script = $script.Replace('__LGHS_BRANCH__', $branch.Replace("'", "'\''"))
    return $script
}

function Write-LghsStockCloudInit([string]$DriveRoot, [string]$Role, $Config) {
    $bootstrap = New-LghsStockBootstrapScript $Config
    $bootstrapB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($bootstrap))

    $first = if ($Role -eq 'controller') { 'cs_admin' } else { 'lg_cs_cont' }
    $second = if ($Role -eq 'controller') { 'lg_cs_cont' } else { 'cs_admin' }
    $firstGroups = if ($first -eq 'cs_admin') { 'users,adm,dialout,cdrom,sudo,audio,video,plugdev,games,input,netdev,gpio,i2c,spi,render' } else { 'users,dialout,cdrom,audio,video,plugdev,games,input,netdev,gpio,i2c,spi,render' }
    $secondGroups = if ($second -eq 'cs_admin') { 'users,adm,dialout,cdrom,sudo,audio,video,plugdev,games,input,netdev,gpio,i2c,spi,render' } else { 'users,dialout,cdrom,audio,video,plugdev,games,input,netdev,gpio,i2c,spi,render' }

    $yaml = @"
#cloud-config
users:
  - name: $first
    groups: $firstGroups
    shell: /bin/bash
    lock_passwd: true
  - name: $second
    groups: $secondGroups
    shell: /bin/bash
    lock_passwd: true
disable_root: false
enable_ssh: true
ssh_pwauth: false
write_files:
  - path: /usr/local/sbin/lghs-stock-bootstrap
    owner: root:root
    permissions: '0700'
    encoding: b64
    content: $bootstrapB64
runcmd:
  - [ /usr/local/sbin/lghs-stock-bootstrap ]
"@
    Set-Content -Path (Join-Path $DriveRoot 'user-data') -Value $yaml -Encoding ascii
    @(
        "instance-id: lghs-$([Guid]::NewGuid().ToString('N'))"
        'local-hostname: lghs-bootstrap'
    ) | Set-Content -Path (Join-Path $DriveRoot 'meta-data') -Encoding ascii
}

function Write-LghsProvisioning([string]$DriveRoot,[string]$DeviceId,[string]$Role,$Credentials,$Config,[bool]$StockBootstrap) {
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

    @(
        'ENCODING=base64-utf8'
        "USER_PASSWORD_B64=$(ConvertTo-LghsBase64Utf8 $Credentials.UserPassword)"
        "ADMIN_PASSWORD_B64=$(ConvertTo-LghsBase64Utf8 $Credentials.AdminPassword)"
        "ROOT_PASSWORD_B64=$(ConvertTo-LghsBase64Utf8 $Credentials.RootPassword)"
    ) | Set-Content -Path (Join-Path $DriveRoot 'lghs-provision-secrets.conf') -Encoding ascii

    $keys = Get-LghsFleetKeyPair $Config
    Copy-Item $keys.Public (Join-Path $DriveRoot 'lghs-controller-key.pub') -Force
    if ($Role -eq 'controller') {
        Copy-Item $keys.Private (Join-Path $DriveRoot 'lghs-controller-key') -Force
    } else {
        Remove-Item (Join-Path $DriveRoot 'lghs-controller-key') -Force -ErrorAction SilentlyContinue
    }

    if ($StockBootstrap) {
        Write-LghsStockCloudInit $DriveRoot $Role $Config
    }
}
