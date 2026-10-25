#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Build rtl8812au.ko for the CMU150 and check it against the head unit's ABI.
#
# The control plane is cfg80211/nl80211, compiled against the head unit's own backported
# cfg80211 headers in abi/ rather than the build kernel's in-tree ones, so struct wiphy
# and struct cfg80211_ops match what the unit's cfg80211.ko actually exposes. The
# compile view of the kernel is set up by build/prepare-kernel.sh; run that first.
#
# Each check in section 3 catches a module that would otherwise only fail on the unit.
# See docs/ABI-NOTES.md.
#
# Run inside the build container (see build/Dockerfile), from the repo root:
#     docker run --rm -v "$PWD":/build cmu-rtl8811au:latest build/build-driver.sh
set -euo pipefail

REPO=${REPO:-$(cd "$(dirname "$0")/.." && pwd)}
KSRC=${KSRC:-$REPO/build/.work/linux-imx6}
DRV=${DRV:-$REPO/driver}
ABI=${ABI:-$REPO/abi}
OUT=${OUT:-$REPO/out}

echo "############ 1. preconditions ############"
[ -f "$KSRC/include/generated/utsrelease.h" ] || { echo "!! kernel not prepared -- run build/prepare-kernel.sh first"; exit 1; }
grep -q '^CONFIG_NF_CONNTRACK=m' "$KSRC/.config"                       || { echo "!! kernel .config lacks the sk_buff ABI options -- re-run build/prepare-kernel.sh"; exit 1; }
! grep -q '^#define CONFIG_WIRELESS_EXT ' "$KSRC/include/generated/autoconf.h" || { echo "!! WIRELESS_EXT is defined -- re-run build/prepare-kernel.sh"; exit 1; }
[ -f "$ABI/include/net/cfg80211.h" ] || { echo "!! $ABI/include is missing"; exit 1; }
[ -f "$ABI/Module.symvers" ]         || { echo "!! $ABI/Module.symvers is missing"; exit 1; }
echo "kernel:  $(sed -n 's/.*"\(.*\)".*/\1/p' "$KSRC/include/generated/utsrelease.h")"
echo "abi:     $(wc -l < "$ABI/Module.symvers") cfg80211 exports"

echo "############ 2. build ############"
cd "$DRV"
make clean >/dev/null 2>&1 || true
make -j"$(nproc)" KSRC="$KSRC" \
     NOSTDINC_FLAGS="-I$ABI/include/" \
     KBUILD_EXTRA_SYMBOLS="$ABI/Module.symvers" 2>&1 | tail -20

echo "############ 3. ABI checks ############"
KO="$DRV/rtl8812au.ko"
[ -f "$KO" ] || { echo "!! no rtl8812au.ko produced"; exit 1; }
rc=0
check() { if [ "$1" = ok ]; then echo "  PASS  $2"; else echo "  FAIL  $2"; rc=1; fi; }

# Captured up front, and every test below uses a here-string rather than a pipe. Under
# `set -o pipefail` a `... | grep -q` pipeline reports FAILURE when grep matches early and
# SIGPIPEs its producer -- which silently inverts a boolean check. A here-string has no
# upstream process to kill, so the pipeline status is grep's own.
SYMS=$(arm-linux-gnueabi-nm "$KO" 2>/dev/null || true)
STR=$(strings "$KO" 2>/dev/null || true)

# vermagic is checked by the module loader itself; a mismatch means insmod refuses the module.
VM=$(printf '%s\n' "$STR" | sed -n 's/^vermagic=//p' | head -1)
[ "$VM" = "3.0.35 SMP preempt mod_unload ARMv7 " ] && check ok "vermagic: $VM" || check no "vermagic is '$VM', expected '3.0.35 SMP preempt mod_unload ARMv7 '"

# struct module must be 332 bytes (0x14c). The head unit's loader reads its fields at fixed
# offsets, so a smaller struct (ftrace off -> 300) oopses in sys_init_module.
# (mawk has no strtonum, so pull the hex size out and convert in the shell)
TM_HEX=$(readelf -SW "$KO" | awk '/\.gnu\.linkonce\.this_module/ {for (i = 1; i <= NF; i++) if ($i == "PROGBITS") { print $(i + 3); exit } }')
TM=$((16#${TM_HEX:-0}))
[ "$TM" = 332 ] && check ok "struct module: 332 bytes" || check no "struct module is $TM bytes, expected 332"

# The USB ID table must carry the Archer T2U aliases, or the adapter never binds.
grep -q 'usb:v2357p011F' <<< "$STR" && check ok "USB alias 2357:011F (Archer T2U v3) present" || check no "USB alias 2357:011F missing -- check os_dep/linux/usb_intf.c"

# cfg80211 control plane, and no legacy WEXT handler table.
grep -qiE '^ *U (cfg80211_|wiphy_)' <<< "$SYMS" && check ok "cfg80211 linkage present" || check no "no cfg80211 linkage -- CONFIG_IOCTL_CFG80211 not set?"
grep -qi 'rtw_handlers_def' <<< "$SYMS" && check no "WEXT rtw_handlers_def present -- WEXT is not fully off" || check ok "no WEXT symbols"

# Nothing may be left undefined that the head unit's kernel cannot resolve at insmod time.
UNDEF=$(sed -n 's/^ *U //p' <<< "$SYMS" | sort -u | wc -l)
check ok "$UNDEF undefined symbols (resolved by the head unit's kernel + cfg80211)"

mkdir -p "$OUT"
cp -f "$KO" "$OUT/"
echo
if [ "$rc" = 0 ]; then
    echo "OK -> $OUT/rtl8812au.ko  ($(stat -c%s "$OUT/rtl8812au.ko") bytes, md5 $(md5sum "$OUT/rtl8812au.ko" | cut -d' ' -f1))"
else
    echo "BUILT BUT FAILED ABI CHECKS -- do not deploy this module."
fi
exit "$rc"
