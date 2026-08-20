$ErrorActionPreference = 'Stop'

# Extend the Trixie/cloud-init path from v5. The Raspberry Pi first-boot wizard
# is suppressed before the graphical session starts, LGHS stage 2 runs to
# completion, and cloud-init performs one controlled reboot into the LGHS user.
. (Join-Path $PSScriptRoot 'LGHS-StockBootstrap-v5.ps1')

function New-LghsCloudInitUserData {
    @'
#cloud-config
# LGHS Imager provisioning for current Raspberry Pi OS Trixie.
# Do not show Raspberry Pi's own first-boot wizard; LGHS owns first boot.
bootcmd:
  - [ /usr/bin/systemctl, mask, userconfig.service ]
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

      # Raspberry Pi OS Trixie normally uses userconf-pi/piwiz until a user is
      # configured. LGHS has already created its managed accounts at this point.
      rm -f /etc/xdg/autostart/piwiz.desktop
      systemctl disable userconfig.service >/dev/null 2>&1 || true
      systemctl mask userconfig.service >/dev/null 2>&1 || true
      systemctl enable getty@tty1.service >/dev/null 2>&1 || true
      rm -f /etc/ssh/sshd_config.d/rename_user.conf
      rm -f /etc/sudoers.d/010_wiz-nopasswd
      rm -f /var/lib/userconf-pi/autologin 2>/dev/null || true

      if command -v raspi-config >/dev/null 2>&1 && id "$target" >/dev/null 2>&1; then
        SUDO_USER="$target" raspi-config nonint do_boot_behaviour B4 >/dev/null 2>&1 || true
      fi

      if id rpi-first-boot-wizard >/dev/null 2>&1; then
        userdel -r rpi-first-boot-wizard >/dev/null 2>&1 || true
      fi

      echo "LGHS first-boot handoff complete for $target"

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
  # Deliberately synchronous: do not reboot until accounts, SSH and networking
  # have been configured and the Raspberry Pi wizard has been retired.
  - [ /usr/bin/systemctl, start, lghs-stage2-bootstrap.service ]

power_state:
  mode: reboot
  message: "LGHS provisioning complete - rebooting into managed desktop"
  timeout: 30
  condition: true

final_message: "LGHS first boot complete"
'@
}
