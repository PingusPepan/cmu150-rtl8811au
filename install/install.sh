#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Install the RTL8811AU driver and its loader onto a CMU150.
#
# Run this ON THE HEAD UNIT, from the directory the release archive unpacked into:
#
#     cd /tmp/cmu150-rtl8811au-<version> && sh ./install.sh
#
# Everything lands in /data_persist/wl, which survives both firmware updates and a factory
# reset. Nothing under /jci is touched: the boot entry is printed at the end for you to paste
# into the unit's service manifest yourself, because a bad edit there costs a recovery.
#
# The driver only: nothing is configured or started on wlan1.
#
# This script never deletes anything. If a step cannot be completed it stops and says so
# rather than continuing with a half-installed set of files.

set -e
SRC=$(dirname "$0")
DEST=/data_persist/wl
KVER=3.0.35

say()  { echo "install: $*"; }
die()  { echo "install: ERROR: $*" >&2; exit 1; }

# --- 1. is this the right machine? --------------------------------------------------------
[ "$(id -u)" = 0 ] || die "must run as root"
[ -d /jci ]        || die "/jci not found -- this does not look like a CMU150 head unit"
[ "$(uname -r)" = "$KVER" ] || die "kernel is $(uname -r), this build targets $KVER"
[ -d /data_persist ] || die "/data_persist not found"

# Different firmware versions can report the same kernel, 3.0.35, so the check above cannot
# tell them apart. The module is built for 74.00.324A: report what this unit runs and warn
# loudly on anything else. Nothing is loaded here, so a warning is enough.
FW=$(sed -n 's/^JCI_SW_VER="\(.*\)"$/\1/p' /jci/version.ini 2>/dev/null)
FW="$FW$(sed -n 's/^JCI_SW_VER_PATCH="\(.*\)"$/\1/p' /jci/version.ini 2>/dev/null)"
case "$FW" in
    *_74.00.324A) say "firmware $FW -- the version this module was built and tested for" ;;
    "")           say "WARN: could not read the firmware version from /jci/version.ini" ;;
    *)            say "WARN: firmware $FW is UNTESTED -- this module was built for 74.00.324A." \
                      "It may load and then hang the unit. See README, 'Firmware'." ;;
esac

# --- 2. is the payload complete? ----------------------------------------------------------
for f in rtl8812au.ko dongle.conf load-wlan1.sh; do
    [ -f "$SRC/$f" ] || die "$f missing from $SRC -- incomplete archive"
done

# The module loader refuses a vermagic mismatch, so check it here where the message is
# useful rather than letting insmod fail at boot with "invalid module format".
if command -v strings >/dev/null 2>&1; then
    VM=$(strings "$SRC/rtl8812au.ko" | sed -n 's/^vermagic=//p' | head -1)
    case "$VM" in
        "$KVER SMP preempt mod_unload ARMv7"*) say "module vermagic OK ($VM)" ;;
        "") say "WARN: could not read the module's vermagic -- continuing" ;;
        *)  die "module vermagic is '$VM', expected '$KVER SMP preempt mod_unload ARMv7 '" ;;
    esac
else
    say "WARN: 'strings' is not available -- skipped the module vermagic check"
fi

# --- 3. is the adapter one this driver binds? ---------------------------------------------
# Informational only: the adapter is often unpowered at install time because the external USB
# hub follows ACC/ignition, so a miss here is not a failure.
if [ -d /sys/bus/usb/devices ]; then
    FOUND=
    for d in /sys/bus/usb/devices/*; do
        [ -r "$d/idVendor" ] || continue
        V=$(cat "$d/idVendor" 2>/dev/null); P=$(cat "$d/idProduct" 2>/dev/null)
        case "$V:$P" in
            2357:011e|2357:011f|2357:0120) FOUND="$V:$P (${d##*/})" ;;
        esac
    done
    if [ -n "$FOUND" ]; then
        say "found a supported adapter: $FOUND"
    else
        say "no supported adapter on USB right now -- expected if ACC/ignition is off"
    fi
fi

# --- 4. install ---------------------------------------------------------------------------
mkdir -p "$DEST" || die "cannot create $DEST"

# dongle.conf may carry a changed interface or channel plan, so never overwrite one that is
# already there. A new one is dropped alongside it for comparison instead.
if [ -f "$DEST/dongle.conf" ]; then
    cp -f "$SRC/dongle.conf" "$DEST/dongle.conf.new" || die "cannot write $DEST/dongle.conf.new"
    say "kept your existing dongle.conf (new template written as dongle.conf.new)"
else
    cp -f "$SRC/dongle.conf" "$DEST/" || die "cannot write $DEST/dongle.conf"
fi

cp -f "$SRC/rtl8812au.ko" "$DEST/" || die "cannot write $DEST/rtl8812au.ko"
chmod 644 "$DEST/rtl8812au.ko" "$DEST/dongle.conf"
cp -f "$SRC/load-wlan1.sh" "$DEST/" || die "cannot write $DEST/load-wlan1.sh"
chmod 755 "$DEST/load-wlan1.sh"
say "installed into $DEST"

# The unit boots one of two service manifests; the boot entry goes into whichever it runs.
# Read it off the running service manager rather than assume one.
MANIFEST=
if ps w 2>/dev/null | grep -q '[/]jci/sm/sm -f /jci/sm/sm_WCP.conf'; then
    MANIFEST=/jci/sm/sm_WCP.conf
elif ps w 2>/dev/null | grep -q '[/]jci/sm/sm -f /jci/sm/sm.conf'; then
    MANIFEST=/jci/sm/sm.conf
fi
if [ -n "$MANIFEST" ]; then
    say "this unit boots $MANIFEST"
else
    say "WARN: could not tell which service manifest this unit boots -- check with:"
    say "        ps w | grep 'jci/sm/sm -f'"
    MANIFEST="<manifest>"
fi
MFILE=${MANIFEST##*/}

# --- 5. what is left for you to do --------------------------------------------------------
# Mirrors docs/INSTALL.md steps 2 and 3; keep the two in step.
echo
echo "----------------------------------------------------------------------"
echo "Installed. Loading at boot is still manual, on purpose:"
echo
echo "  1. With ACC/ignition on, load the driver by hand:"
echo "       $DEST/load-wlan1.sh"
echo "     It must report 'wlan1 present'."
echo
echo "  2. Only once that works, add the boot entry by hand:"
echo "       mount -o remount,rw /"
echo "       cd /jci/sm"
echo "       cp -a $MFILE $MFILE.bak"
echo "       vi $MFILE"
echo "     Find the start_wifi service (/start_wifi.sh in vi) and paste the block below"
echo "     right after its closing </service> line, before NMS_svc. Save, then check it"
echo "     with the service manager's own tool (read-only, prints the start order):"
echo "       /jci/sm/smconf -c $MFILE -ot -"
echo "     If any line says FAILED, restore with 'cp -a $MFILE.bak $MFILE' and paste again."
echo "     Never reboot with a manifest that fails this check. Then:"
echo "       mount -o remount,ro /"
echo "       reboot"
echo "     After the reboot, this must end in result=ok:"
echo "       tail -n 1 /data_persist/log/aaw-boot.log"
echo
echo "This package loads the driver only. Nothing is configured or started on wlan1."
echo "----------------------------------------------------------------------"
if [ -f "$SRC/sm.conf.snippet" ]; then
    echo
    cat "$SRC/sm.conf.snippet"
fi
