#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Load the RTL8811AU 5 GHz USB adapter as wlan1. Run once at boot from the unit's service
# manifest (/jci/sm/sm.conf, or /jci/sm/sm_WCP.conf on units that boot that one).
#
# Ordering matters: this must run after the onboard wl12xx radio is up (wlan0) so the
# adapter enumerates as wlan1. The kernel numbers wlanN by registration order, and whatever
# is run on the adapter relies on wlan1 being the dongle and wlan0 the onboard radio. The
# service entry therefore depends on both start_wifi and stage_usb.
#
# This only loads the driver. It does not configure or start anything on wlan1.
#
# Idempotent: no-ops if the module is already loaded, so an sm retry is safe.

DIR=/data_persist/wl
[ -r "$DIR/dongle.conf" ] || { echo "load-wlan1: ERROR: $DIR/dongle.conf missing"; exit 1; }
. "$DIR/dongle.conf"

log() { echo "load-wlan1: $*"; }

# --- per-boot breadcrumb ---------------------------------------------------------------
# Console output lives in /tmp and dies with the boot, so the worst failure -- the driver
# simply never loading at boot -- is the one that leaves no trace at all. One line per boot
# goes somewhere persistent instead, keyed by the kernel's boot_id. The wall clock cannot
# key it: the unit starts at 1970 every boot, so timestamps repeat. /data_persist/log is the
# only log location that survives a reboot.
BOOTLOG=${BOOTLOG:-/data_persist/log/aaw-boot.log}
BOOT_ID=$(cut -c1-8 /proc/sys/kernel/random/boot_id 2>/dev/null)
[ -z "$BOOT_ID" ] && BOOT_ID=noid

# No USB id is hardcoded here: the full device list shows what actually enumerated, which
# tells "hub down" apart from "adapter absent" and from "present but unbound".
bc_common() {
    bc_up=$(cut -d. -f1 /proc/uptime 2>/dev/null)
    bc_usb=$(ls /sys/bus/usb/devices 2>/dev/null | tr '\n' ',')
    bc_mod=no
    grep -q '^rtl8812au ' /proc/modules 2>/dev/null && bc_mod=rtl8812au
    bc_bound=no
    if [ "$bc_mod" != no ]; then
        set -- /sys/bus/usb/drivers/rtl8812au/*-*:*
        [ -e "$1" ] && bc_bound=${1##*/}
    fi
    bc_wlans=$(ls -d /sys/class/net/wlan* 2>/dev/null | sed 's|.*/||' | tr '\n' ',')
    [ -z "$bc_wlans" ] && bc_wlans=NONE
}

# Filtered dmesg, only on a failing boot: the USB and probe errors that explain why nothing
# enumerated are otherwise gone forever. Bounded, and keyed to the boot it belongs to.
bc_dmesg() {
    dmesg 2>/dev/null | grep -iE 'usb|hub|8812|rtl87|wlan' | tail -40 \
        >> "/data_persist/log/aaw-boot-$BOOT_ID.dmesg" 2>/dev/null
}

RESULT="exited-early"
breadcrumb() {
    bc_common
    echo "id=$BOOT_ID stage=loader up=${bc_up:-?}s mod=$bc_mod bound=$bc_bound" \
         "wlans=$bc_wlans usb=$bc_usb result=$RESULT" >> "$BOOTLOG" 2>/dev/null
    [ "$RESULT" = ok ] || bc_dmesg
}
trap breadcrumb EXIT

# --- do not add a boot-time chip re-probe here -------------------------------------------
# An unbind/bind straight after insmod cannot recover an adapter that comes up with a dead
# radio. The firmware download, efuse read and PHY/RF configuration happen in rtw_hal_init(),
# which is called from _netdev_open() -- on `ifconfig up`, not from the USB probe. At this
# point in the boot nothing has opened the interface, so a rebind here re-runs only the light
# probe. A rebind does recover the radio once something has held the interface open (an
# access point, a client), because then the hal deinit/init path actually re-runs -- so
# recovery belongs to whatever runs on wlan1, not here. See docs/INSTALL.md, "Troubleshooting".
# -----------------------------------------------------------------------------------------

if grep -q '^rtl8812au ' /proc/modules 2>/dev/null; then
    log "rtl8812au already loaded"
else
    if insmod "$DIR/rtl8812au.ko" rtw_channel_plan="$CHANNEL_PLAN" 2>/dev/null; then
        log "insmod rtl8812au.ko (rtw_channel_plan=$CHANNEL_PLAN)"
    else
        RESULT="insmod-failed"
        log "ERROR: insmod rtl8812au.ko failed -- see the dmesg dump beside the breadcrumb"
        exit 1
    fi
fi

# No blocking wait: nothing here uses the interface. Once the module is loaded the driver
# binds by itself whenever the adapter enumerates, so anything that uses wlan1 must wait
# for it on its own. Waiting here would only add boot latency when the adapter is slow or
# absent (the external USB hub is unpowered until ACC/ignition).
if [ -e /sys/class/net/wlan1 ]; then
    log "wlan1 present (MAC $(cat /sys/class/net/wlan1/address 2>/dev/null))"
else
    log "wlan1 not enumerated yet -- the driver binds when the adapter appears (normal for USB)"
fi

# --- move the adapter's USB interrupt off CPU0 -------------------------------------------
# On this two-core i.MX6 every GIC and GPIO interrupt is delivered to CPU0 -- the CPU1 column
# in /proc/interrupts is a flat zero -- and a NIC's RX softirq and the Realtek receive
# tasklet run on whichever CPU took the interrupt. Under load CPU0 measured 89% busy against
# CPU1 at 83% idle, with roughly 690 interrupts per second from this bus alone on top of the
# local timer and UART. Pinning the interrupt to CPU1 freezes CPU0's count and lifts its idle
# time from 11% to 56%. A manual `echo` survives an sm restart but not a reboot, and losing
# it presents as constant small stutter in streamed traffic with otherwise perfect RF.
#
# The interrupt number is derived, not hardcoded: it is 72 on this build, but the line is
# shared ("usb_wakeup, fsl ehci pre interrupt, ehci_hcd:usb2") and could move.
IRQ=$(grep 'ehci_hcd:usb2' /proc/interrupts | cut -d: -f1 | tr -d ' ')
if [ -n "$IRQ" ] && [ -e "/proc/irq/$IRQ/smp_affinity" ]; then
    echo 2 > "/proc/irq/$IRQ/smp_affinity"
    log "IRQ $IRQ (ehci_hcd:usb2) affinity -> CPU1 (reads back $(cat "/proc/irq/$IRQ/smp_affinity"))"
else
    # Loud, not silent: the driver still works, but a miss here costs throughput smoothness.
    log "WARN: ehci_hcd:usb2 IRQ not found or not writable -- the adapter's interrupt stays on CPU0"
fi

# Cheap insurance against bursty traffic. On this unit /proc/net/softnet_stat has never shown
# a backlog overflow with or without it, so treat it as a guard rather than a fix.
if echo 4000 > /proc/sys/net/core/netdev_max_backlog 2>/dev/null; then
    log "netdev_max_backlog -> $(cat /proc/sys/net/core/netdev_max_backlog)"
else
    log "WARN: could not raise netdev_max_backlog"
fi

[ "$RESULT" = insmod-failed ] || RESULT=ok
exit 0
