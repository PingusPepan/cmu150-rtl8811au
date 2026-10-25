#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Unpack and prepare the target kernel tree the driver is compiled against.
#
# The module is never flashed into this kernel -- it runs on the head unit's own
# 3.0.35. What matters is that the *compile view* (generated/autoconf.h plus the
# headers it gates) produces structure layouts byte-identical to the ones the head
# unit's kernel was built with. Every option set below exists for that reason and is
# explained in docs/ABI-NOTES.md; changing one silently corrupts memory at runtime
# rather than failing the build.
#
# Idempotent: re-running reconfigures from scratch without unpacking again.
#
# Run inside the build container (see build/Dockerfile), from the repo root:
#     docker run --rm -v "$PWD":/build cmu-rtl8811au:latest build/prepare-kernel.sh
set -euo pipefail

REPO=${REPO:-$(cd "$(dirname "$0")/.." && pwd)}
WORK=${WORK:-$REPO/build/.work}
KSRC=${KSRC:-$WORK/linux-imx6}

# Boundary Devices' i.MX6 3.0.35 BSP. The build image downloads it at a pinned commit (see
# KERNEL_SHA in build/Dockerfile), because this Jessie image cannot do the TLS handshake.
# Any tree whose UTS_RELEASE is 3.0.35 and whose headers match would do; this one is pinned so
# the build is reproducible.
KTAR=${KTAR:-/opt/linux-imx6.tar.gz}

echo "############ 0. unpack the kernel tree ############"
if [ -f "$KSRC/Makefile" ]; then
    echo "kernel tree already present at $KSRC"
else
    [ -f "$KTAR" ] || { echo "!! $KTAR missing -- run this inside the build image (build/Dockerfile)"; exit 1; }
    mkdir -p "$KSRC"
    echo "unpacking $KTAR into $KSRC"
    tar -C "$KSRC" --strip-components=1 -xzf "$KTAR"
fi

cd "$KSRC"

echo "############ 1. configure for the head unit's ABI ############"
# An empty .scmversion stops setlocalversion appending "+"/-g<hash>, so UTS_RELEASE stays
# exactly "3.0.35" and the module's vermagic matches the head unit's.
: > .scmversion
make imx6_defconfig >/dev/null

# vermagic: "3.0.35 SMP preempt mod_unload ARMv7"
#   -> SMP + PREEMPT + MODULE_UNLOAD on, MODVERSIONS off, empty LOCALVERSION.
# ftrace: the head unit's kernel was built with tracing, so its modules carry __mcount_loc
#   and `struct module` has the ftrace/tracepoint fields (332 bytes, not 300). The module
#   loader reads that struct at fixed offsets -- a mismatch oopses in sys_init_module.
# ARM_UNWIND: the head unit was built with it off. With it on, the module references
#   __aeabi_unwind_cpp_pr0, which that kernel does not export ("unknown symbol").
# SUSPEND/USB_SUSPEND: the head unit is CONFIG_PM_SLEEP=n. PM_SLEEP=y inserts 24 bytes into
#   dev_pm_info, shifting every struct device field after .power and every usb_device field
#   after .dev -- the probe then reads usb_device->actconfig from the wrong offset and
#   NULL-derefs. That kernel also exports none of the PM_SLEEP/USB_SUSPEND symbols.
# cfg80211/mac80211/lib80211/rfkill are modules, never =y: the head unit ships its own
#   backported cfg80211 and this driver binds against that (see abi/).
scripts/config -e SMP -e PREEMPT -e MODULE_UNLOAD -d MODVERSIONS \
               -e MODULES --set-str LOCALVERSION "" -d LOCALVERSION_AUTO \
               -m CFG80211 -m MAC80211 -m LIB80211 -m RFKILL \
               -d ARM_UNWIND \
               -e FTRACE -e FUNCTION_TRACER -e DYNAMIC_FTRACE \
               -d SUSPEND -d USB_SUSPEND

# sk_buff layout. The head unit's kernel was built with netfilter, sched and secmark, which
# insert 16 bytes of config-gated fields into struct sk_buff between `len` and `data`:
#   +12 before queue_mapping: nfct (NF_CONNTRACK), nfct_reasm (NF_DEFRAG_IPV4),
#                             tc_index/tc_verd (NET_SCHED/NET_CLS_ACT)
#    +4 after flags2:         secmark (NETWORK_SECMARK)
# Without them every inlined skb_reserve/skb_put in this driver uses offsets 16 bytes early,
# so RX URB transfer buffers get garbage pointers. Only the +12/+4 split matters, not which
# exact options supply it, so layout-equivalent alternatives are fine.
scripts/config -e NETFILTER -m NF_CONNTRACK -m NF_CONNTRACK_IPV4 -m NF_DEFRAG_IPV4 \
               -e NET_SCHED -e NET_CLS_ACT -e NETWORK_SECMARK

set +o pipefail          # `yes` takes SIGPIPE when oldconfig closes the pipe; that is fine
yes "" | make oldconfig >/dev/null
set -o pipefail
make modules_prepare >/dev/null
echo "UTS_RELEASE: $(sed -n 's/.*"\(.*\)".*/\1/p' include/generated/utsrelease.h)"

echo "############ 2. match struct net_device / wireless_dev to the head unit ############"
# The head unit is CONFIG_WIRELESS_EXT=n *and* CONFIG_CFG80211_WEXT=y -- an unusual combination,
# and both halves are load-bearing:
#   WIRELESS_EXT=n  -> struct net_device carries no wireless_handlers/wireless_data, so
#                      netdev_ops lands at 0xd8. A WIRELESS_EXT=y build puts it at 0xe0 and
#                      the SoC hangs in register_netdevice.
#   CFG80211_WEXT=y -> struct wireless_dev has a .wext member and the head unit's cfg80211
#                      runs cfg80211_mgd_wext_connect() on NETDEV_UP. Build without it and our
#                      wireless_dev is smaller than the one cfg80211 writes into.
# So strip CONFIG_WIRELESS_EXT[_SYSFS] only, and keep CFG80211_WEXT and WEXT_CORE/PROC/PRIV/SPY.
# This edits the generated compile view, not .config, and always re-derives from a pristine
# backup so it stays idempotent.
AUTOCONF=include/generated/autoconf.h
if [ -f "$AUTOCONF.orig" ]; then cp "$AUTOCONF.orig" "$AUTOCONF"; else cp "$AUTOCONF" "$AUTOCONF.orig"; fi
grep -vE '^#define CONFIG_WIRELESS_EXT(_SYSFS)? ' "$AUTOCONF" > "$AUTOCONF.new"
mv "$AUTOCONF.new" "$AUTOCONF"

# The head unit's cfg80211 was built with CONFIG_NL80211_TESTMODE=y. That puts testmode_cmd
# and testmode_dump into struct cfg80211_ops ahead of dump_survey -- the only config-gated
# fields in the whole ops struct. Build without it and every pointer from dump_survey on sits
# two slots early, so an nl80211 GET_SURVEY lands on del_pmksa and NULL-derefs inside hostapd.
grep -q '^#define CONFIG_NL80211_TESTMODE ' "$AUTOCONF" || \
    echo '#define CONFIG_NL80211_TESTMODE 1' >> "$AUTOCONF"
touch "$AUTOCONF"        # newer than .config, so Kbuild will not regenerate it

grep -q '^#define CONFIG_CFG80211_WEXT '    "$AUTOCONF" || { echo "!! CFG80211_WEXT missing -- wireless_dev would mismatch the head unit";   exit 1; }
grep -q '^#define CONFIG_NL80211_TESTMODE ' "$AUTOCONF" || { echo "!! NL80211_TESTMODE missing -- cfg80211_ops would mismatch the head unit"; exit 1; }
! grep -q '^#define CONFIG_WIRELESS_EXT '   "$AUTOCONF" || { echo "!! WIRELESS_EXT still defined -- net_device would mismatch the head unit"; exit 1; }
echo "autoconf: WIRELESS_EXT off, CFG80211_WEXT on, NL80211_TESTMODE on"
echo "kernel prepared at $KSRC"
