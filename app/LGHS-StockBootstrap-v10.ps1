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

  - path: /usr/local/bin/lghs-firstboot-progress-ui
    owner: root:root
    permissions: '0755'
    content: |
      #!/bin/bash
      set -u
      NOTIFY_ONLY=0
      [ "${1:-}" = "--notify-only" ] && NOTIFY_ONLY=1
      STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/lghs"
      MARK="$STATE_DIR/install-success-shown"
      mkdir -p "$STATE_DIR"
      [ -f "$MARK" ] && exit 0

      last_phase=""

      draw_bar() {
        local pct="$1" filled empty bar rest
        filled=$((pct / 5)); empty=$((20 - filled))
        printf -v bar '%*s' "$filled" ''
        bar="${bar// /#}"
        printf -v rest '%*s' "$empty" ''
        printf '[%-20s] %3d%%\n' "${bar}${rest}" "$pct"
      }

      send_notice() {
        local title="$1" body="$2" urgency="${3:-normal}" message
        message="$title: $body"
        if command -v wfpanelctl >/dev/null 2>&1; then
          if [ "$urgency" = critical ]; then
            wfpanelctl critical "$message" >/dev/null 2>&1 && return 0
          else
            wfpanelctl notify "$message" >/dev/null 2>&1 && return 0
          fi
        fi
        if command -v notify-send >/dev/null 2>&1; then
          notify-send -a 'LGHS Setup' -u "$urgency" -t 10000 "$title" "$body" >/dev/null 2>&1 || true
        fi
      }

      while true; do
        host="$(hostname 2>/dev/null || echo Raspberry-Pi)"
        stage_state="$(systemctl show lghs-stage2-bootstrap.service -p ActiveState --value 2>/dev/null || true)"
        online_state="$(systemctl show lghs-bootstrap-online.service -p ActiveState --value 2>/dev/null || true)"
        online_result="$(systemctl show lghs-bootstrap-online.service -p Result --value 2>/dev/null || true)"
        online_enabled="$(systemctl is-enabled lghs-bootstrap-online.service 2>/dev/null || true)"
        net="$(nmcli -t -f STATE general status 2>/dev/null | head -n1 || true)"

        pct=10
        phase='Preparing LGHS device setup'
        detail='Creating accounts, SSH recovery, and device identity.'

        if [ "$online_enabled" = "disabled" ] && [ "$online_state" = "inactive" ] && [ "$online_result" = "success" ]; then
          pct=100
          phase='ALL GOOD — LGHS setup complete'
          detail="$host is ready for classroom use."
        elif [ "$online_state" = "failed" ] || { [ -n "$online_result" ] && [ "$online_result" != "success" ] && [ "$online_state" = "inactive" ]; }; then
          pct=35
          phase='Setup needs attention'
          detail='The online installer failed. LGHS will retry automatically; check Wi-Fi if this persists.'
        elif pgrep -x dpkg >/dev/null 2>&1 || pgrep -x apt-get >/dev/null 2>&1; then
          pct=60
          phase='Installing classroom software'
          detail='Installing VS Code, Python tools, and required packages. Do not power off.'
        elif pgrep -af 'lghs-dev-setup' >/dev/null 2>&1; then
          pct=80
          phase='Configuring VS Code and Python'
          detail='Creating the classroom workspace and Python environment.'
        elif pgrep -af 'git (clone|fetch)' >/dev/null 2>&1; then
          pct=45
          phase='Downloading LGHS System'
          detail='Fetching the latest managed classroom software.'
        elif [ "$online_state" = "active" ] || [ "$online_state" = "activating" ]; then
          pct=50
          phase='Installing LGHS System'
          detail='The full Control/Student software stack is being applied.'
        elif [ "$stage_state" = "active" ] || [ "$stage_state" = "activating" ]; then
          pct=20
          phase='Preparing this Raspberry Pi'
          detail='Finishing local first-boot provisioning.'
        elif [ -n "$net" ] && [[ "$net" != connected* ]]; then
          pct=30
          phase='Waiting for Wi-Fi / Internet'
          detail='Connect this Pi to the classroom network; setup will continue automatically.'
        else
          pct=30
          phase='Waiting for installer'
          detail='LGHS is waiting for the next setup stage to start.'
        fi

        if [ "$phase" != "$last_phase" ]; then
          if [ "$NOTIFY_ONLY" -eq 1 ]; then
            urgency=normal
            [[ "$phase" == 'Setup needs attention' ]] && urgency=critical
            send_notice 'LGHS Setup Progress' "$phase — $detail" "$urgency"
          fi
          last_phase="$phase"
        fi

        if [ "$NOTIFY_ONLY" -eq 0 ]; then
          printf '\033[2J\033[H'
          printf '\033[1mLGHS SETUP PROGRESS\033[0m\n'
          printf 'Device: %s\n\n' "$host"
          draw_bar "$pct"
          printf '\n\033[1m%s\033[0m\n%s\n' "$phase" "$detail"
          printf '\nThis window updates automatically. You can keep using the desktop.\n'
        fi

        if [ "$pct" -eq 100 ]; then
          touch "$MARK"
          if [ "$NOTIFY_ONLY" -eq 0 ]; then
            printf '\n\033[1;32mREADY\033[0m — setup finished successfully.\n'
            printf 'This window will close automatically.\n'
            sleep 12
          fi
          exit 0
        fi

        if [ "$phase" = 'Setup needs attention' ]; then
          sleep 5
        else
          sleep 2
        fi
      done

  - path: /usr/local/bin/lghs-firstboot-progress-launch
    owner: root:root
    permissions: '0755'
    content: |
      #!/bin/sh
      STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/lghs"
      [ -f "$STATE_DIR/install-success-shown" ] && exit 0
      if command -v lxterminal >/dev/null 2>&1; then
        exec lxterminal --title='LGHS Setup Progress' -e /usr/local/bin/lghs-firstboot-progress-ui
      fi
      if command -v x-terminal-emulator >/dev/null 2>&1; then
        exec x-terminal-emulator -T 'LGHS Setup Progress' -e /usr/local/bin/lghs-firstboot-progress-ui
      fi
      if command -v xterm >/dev/null 2>&1; then
        exec xterm -T 'LGHS Setup Progress' -e /usr/local/bin/lghs-firstboot-progress-ui
      fi
      exec /usr/local/bin/lghs-firstboot-progress-ui --notify-only

  - path: /etc/xdg/autostart/lghs-firstboot-progress.desktop
    owner: root:root
    permissions: '0644'
    content: |
      [Desktop Entry]
      Type=Application
      Name=LGHS Setup Progress
      Comment=Show first-boot LGHS installation progress
      Exec=/usr/local/bin/lghs-firstboot-progress-launch
      Terminal=false
      NoDisplay=true
      X-GNOME-Autostart-enabled=true

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

final_message: "LGHS cloud-init handoff complete; SSH credentials primed; on-screen progress enabled; stage 2 continues under systemd"
'@
    return $yaml.Replace('__LGHS_PRIMARY_USER__',$target)
}
