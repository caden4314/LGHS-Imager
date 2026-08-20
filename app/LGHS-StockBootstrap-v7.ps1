$ErrorActionPreference = 'Stop'

# Build on the Trixie/cloud-init path, but explicitly claim Raspberry Pi OS's
# distro default user through cloud-init's singular `user:` stanza. Current
# Raspberry Pi Imager uses this pattern so the default account is renamed and
# keeps the distro's normal desktop groups/settings.
. (Join-Path $PSScriptRoot 'LGHS-StockBootstrap-v5.ps1')

function New-LghsCloudInitUserData([string]$Role) {
    $target = if ($Role -eq 'controller') { 'cs_admin' } else { 'lg_cs_cont' }

    $yaml = @'
#cloud-config
# LGHS Imager provisioning for Raspberry Pi OS Trixie.
# LGHS owns first boot and names the distro default desktop user here.
user:
  name: __LGHS_PRIMARY_USER__
  shell: /bin/bash
  lock_passwd: false

bootcmd:
  - [ /usr/bin/systemctl, mask, userconfig.service ]
  - [ /usr/bin/systemctl, mask, display-manager.service ]
  - [ /bin/rm, -f, /etc/xdg/autostart/piwiz.desktop ]

write_files:
  - path: /usr/local/sbin/lghs-finish-firstboot
    owner: root:root
    permissions: '0755'
    content: |
      #!/bin/bash
      set -u
      role="$(cat /etc/lghs/role 2>/dev/null || true)"
      target=lg_cs_cont
      [ "$role" = controller ] && target=cs_admin

      id "$target" >/dev/null 2>&1 || { echo "LGHS target user missing: $target" >&2; exit 1; }
      rm -f /etc/xdg/autostart/piwiz.desktop

      # Raspberry Pi OS ships this helper specifically to finish the first-user
      # rename/setup path cleanly. Prefer it over duplicating its internals.
      if [ -x /usr/bin/cancel-rename ]; then
        /usr/bin/cancel-rename "$target" >/var/log/lghs-cancel-rename.log 2>&1 || true
      else
        systemctl disable userconfig.service >/dev/null 2>&1 || true
        systemctl enable getty@tty1.service >/dev/null 2>&1 || true
        rm -f /etc/ssh/sshd_config.d/rename_user.conf
      fi

      if command -v raspi-config >/dev/null 2>&1; then
        SUDO_USER="$target" raspi-config nonint do_boot_behaviour B4 >/dev/null 2>&1 || true
      fi

      systemctl unmask display-manager.service >/dev/null 2>&1 || true
      systemctl set-default graphical.target >/dev/null 2>&1 || true
      echo "LGHS first-boot handoff complete for $target"

  - path: /etc/systemd/system/lghs-stage2-bootstrap.service
    owner: root:root
    permissions: '0644'
    content: |
      [Unit]
      Description=LGHS classroom provisioning
      After=local-fs.target NetworkManager.service
      Wants=NetworkManager.service
      Before=display-manager.service graphical.target
      ConditionPathExists=!/var/lib/lghs/stage2-complete

      [Service]
      Type=oneshot
      ExecStart=/bin/bash -c 'if [ -f /boot/firmware/lghs-stage2.sh ]; then exec /bin/bash /boot/firmware/lghs-stage2.sh; elif [ -f /boot/lghs-stage2.sh ]; then exec /bin/bash /boot/lghs-stage2.sh; else echo "LGHS stage2 payload missing" >&2; exit 1; fi'
      ExecStartPost=/usr/local/sbin/lghs-finish-firstboot
      ExecStartPost=/usr/bin/touch /var/lib/lghs/stage2-complete
      Restart=on-failure
      RestartSec=30
      TimeoutStartSec=15min

      [Install]
      WantedBy=multi-user.target

runcmd:
  - [ /usr/bin/mkdir, -p, /var/lib/lghs ]
  - [ /bin/rm, -f, /etc/xdg/autostart/piwiz.desktop ]
  - [ /usr/bin/systemctl, daemon-reload ]
  - [ /usr/bin/systemctl, enable, lghs-stage2-bootstrap.service ]
  - [ /usr/bin/systemctl, start, lghs-stage2-bootstrap.service ]

power_state:
  mode: reboot
  message: "LGHS provisioning complete - rebooting into managed desktop"
  timeout: 30
  condition: true

final_message: "LGHS first boot complete"
'@

    return $yaml.Replace('__LGHS_PRIMARY_USER__',$target)
}
