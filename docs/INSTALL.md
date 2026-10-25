# Installing on the head unit

This package installs the driver and loads it at boot. The adapter comes up as `wlan1`; the
onboard radio stays `wlan0` and the unit's own Wi-Fi features keep working. Nothing is
configured or started on `wlan1`. That part is up to you, see [Using wlan1](#using-wlan1).

Everything is installed to `/data_persist/wl`, which survives firmware updates and a factory
reset.

## Requirements

- **A TP-Link Archer T2U v3.** Check `Ver:` on the box or the label. v1 is a different chip
  and will not work. On a PC, `lsusb` must show `2357:011f` (`2357:011e` and `2357:0120`
  are also supported).
- **Firmware 74.00.324A.** This is the only firmware this build was tested on. Check it on the
  screen under **Settings → System → About → Version Information**. On any other firmware the
  module may load and then hang the unit.
- **A root shell on the unit.**

## 1. Install

```sh
# on your PC
scp cmu150-rtl8811au-*.tar.gz <user>@<head-unit-ip>:/tmp/

# on the head unit
cd /tmp
tar xzf cmu150-rtl8811au-*.tar.gz
cd cmu150-rtl8811au-*
sh ./install.sh
```

The installer stops on any error and changes nothing outside `/data_persist/wl`. It prints:

- the firmware version, with a warning if it is not 74.00.324A;
- whether the adapter is on USB right now. "No adapter" is normal with the ACC/ignition off;
- which service manifest the unit boots (`/jci/sm/sm.conf` or `/jci/sm/sm_WCP.conf`). You
  need it in step 3;
- the boot entry to paste in step 3.

Re-running it keeps your existing `dongle.conf` and writes the new one as `dongle.conf.new`.

## 2. Load the driver by hand

With the ACC/ignition on:

```sh
/data_persist/wl/load-wlan1.sh
```

It must report `wlan1 present`. If `wlan1` is missing, wait a few seconds and check
`ifconfig wlan1` again. If the script reports `insmod failed`, see `dmesg | tail -40`.

## 3. Load it at boot

Only once step 2 works. Back up the manifest first: a broken manifest stops the unit from
booting normally.

The commands below use `sm.conf`. If `install.sh` printed `/jci/sm/sm_WCP.conf`, use
`sm_WCP.conf` instead in every command.

```sh
mount -o remount,rw /
cd /jci/sm
cp -a sm.conf sm.conf.bak
vi sm.conf
```

In `vi`, search for the stock Wi-Fi service with `/start_wifi.sh` and press Enter. Paste the
`<service>` block from `sm.conf.snippet` (also printed by the installer) directly after that
service's closing `</service>` line, before `NMS_svc`. It must look like this:

```xml
        <service type="process" name="start_wifi" path="/jci/scripts/start_wifi.sh" ... >
            <dependency type="service" value="stage_wifi"/>
            <dependency type="service" value="start_network"/>
        </service>

        <service type="process" name="load_wlan1" path="/data_persist/wl/load-wlan1.sh" autorun="yes" reset_board="no" retry_count="2" args="" exit_allowed="yes" started_after_exit_allowed="yes" >
            <dependency type="service" value="start_wifi"/>
            <dependency type="service" value="stage_usb"/>
        </service>

        <service type="jci_service" name="NMS_svc" path="/jci/nms/nms.so" ... >
```

Save, then check the manifest with the service manager's own tool. It only reads the file and
prints the services in start order; it changes nothing:

```sh
/jci/sm/smconf -c sm.conf -ot -
```

If any line says `FAILED`, restore the backup with `cp -a sm.conf.bak sm.conf` and paste
again. Do not reboot with a manifest that fails this check. Then:

```sh
mount -o remount,ro /
reboot
```

After the reboot:

```sh
tail -n 1 /data_persist/log/aaw-boot.log
```

`result=ok` means the driver loaded. On any other result, the reason is in that line and a
`dmesg` extract is saved next to it as `aaw-boot-<id>.dmesg`. A line without `wlan1` in
`wlans=` is normal when the unit started with the ACC/ignition off. The adapter appears once
ACC/ignition is on.

## Using wlan1

**Skip this section if you use software that sets up `wlan1` for you**, such as
[oem-aa-mod](https://github.com/VitaliyKurokhtin/oem-aa-mod) for wireless Android Auto. It takes
care of all of this. These notes are only for running `wlan1` your own way.

`wlan1` works with the unit's own `hostapd` and `wpa_supplicant` (`driver=nl80211`). For an
access point:

- **`hw_mode=a`, channel 36, 40, 44 or 48.** No other 5 GHz channel is enabled.
- **`ieee80211d=0`, no `country_code`.** The driver sets its own regulatory domain.
- **Allow `wlan1` through the firewall.** The unit drops all inbound traffic by default,
  including DHCP:

  ```sh
  iptables -C INPUT -i wlan1 -j ACCEPT 2>/dev/null || iptables -I INPUT -i wlan1 -j ACCEPT
  ```
- **The unit runs its own `hostapd`.** Identify yours by its config path in
  `/proc/<pid>/cmdline`, not with `pidof hostapd`.

## Troubleshooting

**The access point starts but no device can see or join it.** The adapter occasionally comes
up with a silent radio. Replug the adapter, or stop whatever uses `wlan1` and rebind it:

```sh
ls /sys/bus/usb/drivers/rtl8812au/                    # e.g. 2-1.3:1.0
echo 2-1.3:1.0 > /sys/bus/usb/drivers/rtl8812au/unbind
echo 2-1.3:1.0 > /sys/bus/usb/drivers/rtl8812au/bind
```

Then start it again once `wlan1` is back. A rebind only helps after `wlan1` has been up at
least once since boot.

**`hostapd` refuses channel 36-48.** Check the channel and the driver's channel plan:

```sh
ifconfig wlan1 up              # skip if something already runs on wlan1
iw phy phy$(iw dev wlan1 info | sed -n 's/.*wiphy //p') info | grep -A2 '5180 MHz'
cat /sys/module/rtl8812au/parameters/rtw_channel_plan
```

Channel 36 (`5180 MHz`) must not say `(disabled)`, `(no IR)` or `(passive scanning)`, and the
last command must print `17`. If it does not, check `CHANNEL_PLAN=0x11` in
`/data_persist/wl/dongle.conf` and reboot.

## Uninstall

Use `sm_WCP.conf` instead of `sm.conf` if that is the manifest your unit boots.

```sh
mount -o remount,rw /
cd /jci/sm
cp -a sm.conf.bak sm.conf     # or remove the load_wlan1 block by hand
mount -o remount,ro /
reboot
```

Nothing loads `/data_persist/wl` after that. Delete the directory if you want it gone.
