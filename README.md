# cmu150-rtl8811au

An RTL8811AU USB Wi-Fi driver, and the script that loads it at boot, for the
**CMU150** head unit — i.MX6, **Linux 3.0.35**, with a backported TI
compat-wireless cfg80211.

> **Scope:** this targets that exact kernel and cfg80211 pairing, not the chip in general.
> On any modern kernel use [aircrack-ng/rtl8812au](https://github.com/aircrack-ng/rtl8812au)
> or [morrownr/8821au](https://github.com/morrownr/8821au-20210708) instead — those dropped
> support for kernels this old, which is why this repository exists.

The head unit's built-in Wi-Fi radio is 2.4 GHz only. This adds a 5 GHz radio on USB, brought
up as `wlan1`, while the onboard radio keeps `wlan0` and every OEM Wi-Fi feature, plus SSH over
USB-ethernet, continues to work untouched. The driver speaks nl80211, so the unit's own
`hostapd` and `wpa_supplicant` drive it; what runs on `wlan1` is up to you — this repository
ships the driver and its loader only.

## Status

Working and in daily use as a WPA2 access point on channel 36, on a CMU150 running firmware
**74.00.324A**. The module loads at boot, WPA2-CCMP runs in the adapter's hardware, and
throughput and latency measure at parity with a wired USB link.

## Firmware

Built and tested against **74.00.324A** only. The EU and NA builds of 74.00.324A ship the same
kernel and Wi-Fi modules, so both are supported. Check your unit's firmware on the screen
under **Settings → System → About → Version Information**.

Different firmware versions can report the same kernel, `3.0.35`, so neither `uname -r` nor
the module's `vermagic` tells them apart. What the module actually has to match is the unit's
kernel configuration and its cfg80211 module (see
[below](#why-this-is-not-just-build-the-vendor-driver)), and both match 74.00.324A.
On a firmware where either differs, the module can load cleanly and then hang the unit or
corrupt memory. `install.sh` prints the firmware it finds and warns on anything other than
74.00.324A. If you try another version, please open an issue with the result.

## Hardware

**TP-Link Archer T2U v3** — USB `2357:011f`. **Check the hardware revision**: v1 is a
MediaTek MT7610U and this driver will not touch it. The `Ver:` field on the box or the label
is the only reliable way to tell them apart.

Two more adapters are in the USB ID table and use the same silicon, but are untested here:
Archer T2U Nano (`2357:011e`) and Archer T2U Plus (`2357:0120`).

## Regulatory

The driver uses a fixed regulatory domain, whatever the country: 2.4 GHz channels 1-13 and
5 GHz channels 36-48. It does not follow a country setting. Make sure operating on these
channels is permitted where you use it.

## Install

Grab the latest archive from [Releases](../../releases), copy it to the head unit and run the
installer **on the unit**:

```sh
# on your PC
scp cmu150-rtl8811au-*.tar.gz <user>@<head-unit-ip>:/tmp/

# on the head unit
cd /tmp && tar xzf cmu150-rtl8811au-*.tar.gz && cd cmu150-rtl8811au-*
sh ./install.sh
```

Everything lands in `/data_persist/wl`, which survives both firmware updates and a factory
reset. The installer does **not** edit the unit's service manifest (`/jci/sm/sm.conf`, or
`sm_WCP.conf` on units that boot that one) — it prints the boot entry for you to paste in once
you have confirmed the driver loads by hand. A bad edit to the manifest costs a recovery, so
that stays a deliberate step.

Full procedure, checks and uninstall: **[docs/INSTALL.md](docs/INSTALL.md)**.

## Build

```sh
docker build -t cmu-rtl8811au:latest -f build/Dockerfile build/
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD":/build cmu-rtl8811au:latest build/prepare-kernel.sh
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD":/build cmu-rtl8811au:latest build/build-driver.sh
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD":/build cmu-rtl8811au:latest build/package.sh
```

CI runs the same steps on every push and attaches the archive to tagged releases.

## Why this is not just "build the vendor driver"

Almost all of the work here is ABI matching, not Wi-Fi. The head unit's kernel is configured
unlike any stock 3.0.35, and its cfg80211 is a backport from much later kernels. The driver
has to match both on the layout of structures it never allocates itself. Get one wrong and
nothing fails at build time: the module corrupts memory or hangs the unit at runtime.

Every one of these differences, and how it presents, is in
**[docs/ABI-NOTES.md](docs/ABI-NOTES.md)**.

## Layout

```
driver/     vendored upstream tree with this repository's changes -- this is what gets built
abi/        the head unit's cfg80211 headers and export list, compiled against
build/      Dockerfile and build scripts (kernel prep, driver, packaging)
install/    what is deployed to the head unit, plus the installer that puts it there
docs/       build notes, install guide, and the ABI findings
```

The first commit imports the upstream driver unchanged. Every change to it after that is a
commit of its own, so `git log -p dcf7c03.. -- driver/` shows exactly what this repository
changes.

## Licence

**GPL-2.0-only**, for the whole repository. The driver derives from Realtek's vendor code,
released under version 2 with no "or later" clause, so there was no other option — and the
rest is licensed to match. Upstream attribution is in [NOTICE](NOTICE).
