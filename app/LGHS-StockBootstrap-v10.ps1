$ErrorActionPreference = 'Stop'

# v10: build on the cached/nonblocking v9 path, but make SSH authentication
# usable before stage 2. The password and fleet public key are already staged
# on the FAT boot partition by the Windows imager; cloud-init primes the primary
# account from those files before sshd is restarted.
. (Join-Path $PSScriptRoot 'LGHS-StockBootstrap-v9.ps1')

function New-LghsCloudInitUserData([string]$Role) {
    $target = if ($Role -eq 'controller') { 'cs_admin' } else { 'lg_cs_cont' }

    $yaml = @'
#cloud-config
# LGHS Trixie bootstrap. Establish a usable SSH recovery account first, retire
# the Raspberry Pi setup wizard, then hand the long LGHS work to systemd.
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
      KbdInteractiveAuthentication yes
      PermitRootLogin no
      UsePAM yes

  - path: /usr/local/sbin/lghs-prime-ssh-access
    owner: root:root
    permissions: '0755'
    content: |
      #!/bin/bash
      set -euo pipefail
      exec >>/var/log/lghs-prime-ssh.log 2>&1
      echo "[$(date -u +%FT%TZ)] Priming LGHS SSH access"

      BOOT=/boot/firmware
      [ -f "$BOOT/lghs-provision.conf" ] || BOOT=/boot
      PUB="$BOOT/lghs-provision.conf"
      SEC="$BOOT/lghs-provision-secrets.conf"
      [ -f "$PUB" ] && [ -f "$SEC" ] || { echo 'LGHS provisioning files missing'; exit 1; }

      readv(){ awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,"");print;exit}' "$2"; }
      ROLE="$(readv ROLE "$PUB")"
      if [ "$ROLE" = controller ]; then
        TARGET=cs_admin
        PASSKEY=ADMIN_PASSWORD_B64
      else
        TARGET=lg_cs_cont
        PASSKEY=USER_PASSWORD_B64
      fi

      id "$TARGET" >/dev/null 2>&1 || { echo "Primary user missing: $TARGET"; exit 1; }
      PW_B64="$(readv "$PASSKEY" "$SEC")"
      [ -n "$PW_B64" ] || { echo "Password value missing: $PASSKEY"; exit 1; }
      PASSWORD="$(printf '%s' "$PW_B64" | base64 --decode)"
      [ -n "$PASSWORD" ] || { echo 'Decoded password is empty'; exit 1; }
      printf '%s:%s\n' "$TARGET" "$PASSWORD" | chpasswd
      passwd -u "$TARGET" >/dev/null 2>&1 || true
      unset PASSWORD PW_B64

      HOME_DIR="$(getent passwd "$TARGET" | cut -d: -f6)"
      GROUP="$(id -gn "$TARGET")"
      KEY="$BOOT/lghs-controller-key.pub"
      if [ -f "$KEY" ] && grep -q '^ssh-ed25519 ' "$KEY"; then
        install -d -m 0700 -o "$TARGET" -g "$GROUP" "$HOME_DIR/.ssh"
        install -m 0600 -o "$TARGET" -g "$GROUP" "$KEY" "$HOME_DIR/.ssh/authorized_keys"
      fi

      sshd -t
      systemctl unmask ssh.service >/dev/null 2>&1 || true
      systemctl enable ssh.service >/dev/null 2>&1 || true
      systemctl restart ssh.service
      echo "[$(date -u +%FT%TZ)] SSH ready for $TARGET"

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
  - [ /usr/local/sbin/lghs-prime-ssh-access ]
  - [ /usr/bin/systemctl, daemon-reload ]
  - [ /usr/bin/systemctl, enable, lghs-stage2-bootstrap.service ]
  - [ /usr/bin/systemctl, start, --no-block, lghs-stage2-bootstrap.service ]

final_message: "LGHS cloud-init handoff complete; SSH credentials primed; stage 2 continues under systemd"
'@
    return $yaml.Replace('__LGHS_PRIMARY_USER__',$target)
}
