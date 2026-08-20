# LGHS Imager

Windows imaging utility for the LGHS CS2 Raspberry Pi classroom fleet.

## Target hardware

**LGHS Imager is intentionally restricted to Raspberry Pi 5 8GB deployments.**

The application is based on the open-source Raspberry Pi Imager codebase, but the LGHS build is designed around a narrow classroom workflow:

- Raspberry Pi 5 only
- 8GB classroom hardware target
- LGHS Student image
- LGHS Control image
- Optional local LGHS image
- SHA-256 verification before/after write
- Batch flashing with automatic CS-01, CS-02, ... numbering
- No Raspberry Pi Imager telemetry in the LGHS build
- Windows installer

The Raspberry Pi Imager repository format identifies Raspberry Pi 5 with the `pi5` device identifier. RAM capacity cannot be determined from an SD card writer before the card is booted in a Pi, so the LGHS OS also performs a first-boot Pi 5 / memory validation.

## Repository layout

```text
config/                 LGHS branding and product configuration
os-list/                LGHS image repository manifest
patches/                Maintained changes applied to upstream Imager
scripts/                Windows bootstrap/build tools
docs/                   Architecture and maintenance notes
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

This clones the official `raspberrypi/rpi-imager` repository into `upstream/` and records the upstream commit used by the LGHS build.

## Build

After installing Qt 6 MinGW and Inno Setup, run:

```powershell
.\scripts\build-windows.ps1
```

The upstream project currently documents Windows builds using Qt 6, MinGW64, CMake, and Inno Setup.

## Relationship to LGHS-System

`LGHS-System` builds and publishes the Pi images. `LGHS-Imager` downloads/verifies/writes those images from Windows.

```text
LGHS-System -> image + manifest -> LGHS Imager -> SD card -> Pi 5 8GB -> LGHS fleet
```

## Security

Do not store classroom Wi-Fi passwords, fleet SSH private keys, student credentials, or other secrets in this repository. Image download hashes are public integrity metadata and belong in the OS manifest.
