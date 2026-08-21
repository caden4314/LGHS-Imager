# LGHS Imager

Windows imaging utility for the LGHS CS2 Raspberry Pi classroom fleet.

## Target hardware

LGHS Imager targets **Raspberry Pi 5** classroom systems and supports both **4 GB and 8 GB RAM profiles**.

Raspberry Pi OS arm64 is shared by both memory capacities. For every managed Control or Student flash, LGHS Imager asks which Pi 5 RAM profile is being prepared and stamps that selection into the LGHS provisioning metadata.

The application is based on the open-source Raspberry Pi Imager codebase, but the LGHS build is designed around a narrow classroom workflow:

- Raspberry Pi 5 only
- Pi 5 4 GB and 8 GB selectable per managed flash
- LGHS Student image
- LGHS Control image
- Optional local image mode
- Stock Raspberry Pi OS arm64 fallback with LGHS cloud-init/bootstrap
- LF-normalized Linux provisioning payloads
- Deployment-specific Ed25519 fleet key generation
- Cached Raspberry Pi OS download for repeat flashes
- Batch flashing with automatic CS-01, CS-02, ... numbering
- First-boot on-screen setup progress through ALL GOOD / ready state
- Windows installer

The Raspberry Pi Imager repository format identifies Raspberry Pi 5 with the `pi5` device identifier. RAM capacity cannot be reliably detected by the Windows SD-card writer before the card is booted, so the operator explicitly chooses 4 GB or 8 GB before each managed flash.

## Repository layout

```text
config/                 LGHS branding and product configuration
os-list/                LGHS image repository manifest
scripts/                Windows launch/bootstrap/build tools
updater/                Installed-Imager update helper
app/                    LGHS Imager UI and stock bootstrap helpers
upstream/                Local clone of raspberrypi/rpi-imager (ignored by Git)
build/                   Local Windows build output (ignored by Git)
```

## Bootstrap on Windows

Open PowerShell:

```powershell
git clone https://github.com/caden4314/LGHS-Imager.git
cd LGHS-Imager
.\scripts\bootstrap-upstream.ps1
```

The launcher can use an installed official Raspberry Pi Imager backend or a locally built backend. Missing published LGHS images currently fall back to official Raspberry Pi OS arm64 and attach the LGHS cloud-init/stage-2 provisioning path. That cloud-init path also stages an XDG desktop progress launcher before the long online software installation begins, so a first boot can visibly show waiting-for-network, download/install, configuration, and completion phases.

## Build

After installing Qt 6 MinGW and Inno Setup, run:

```powershell
.\scripts\build-windows.ps1
```

GitHub Actions builds use the repository `VERSION` as the release line and append the workflow run number as a fourth component so installed-updater version comparisons remain monotonic.

## Relationship to LGHS-System

`LGHS-System` contains the Control/Student runtime, policies, Fleet console, update/reconcile services, and optional custom-image builder. `LGHS-Imager` writes the Pi media and stages the deployment-specific provisioning material.

```text
LGHS-System main
       +
official Raspberry Pi OS arm64
       -> LGHS Imager -> SD card -> Pi 5 4GB/8GB -> LGHS fleet
```

## Security

Do not commit classroom Wi-Fi passwords, fleet SSH private keys, student credentials, or other secrets to this repository. Managed fleet commands use the deployment Ed25519 identity over SSH; Avahi/mDNS is discovery metadata only. Provisioning secrets staged on the boot partition are temporary first-boot material and are removed after successful local provisioning.
