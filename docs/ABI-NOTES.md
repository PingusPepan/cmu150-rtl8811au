# ABI notes

Most of the work in this repository is not Wi-Fi. It is making a driver agree with a kernel
it was not built alongside, about the layout of structures it never allocates itself.

The head unit runs Linux 3.0.35 with a vendor configuration unlike any stock build, plus a
cfg80211 backported from much later kernels. The module is compiled against a *reference*
kernel tree, so every config option that gates a structure field has to be set to what the
unit actually used. None of these show up at build time. They present as a hang, an oops in
an unrelated process, or a radio that reports perfect health and never transmits.

## 1. `CONFIG_WIRELESS_EXT=n` — `struct net_device`

The unit's kernel has no Wireless Extensions, so `struct net_device` carries no
`wireless_handlers` or `wireless_data`, and `netdev_ops` lands at **offset 0xd8**. Built the
normal way, with `WIRELESS_EXT=y`, the driver places it at **0xe0**.

**Presents as:** the SoC hangs during `register_netdevice`, on module load, with nothing in
the log. It looks like the adapter hard-freezing the unit, not like a software fault.

**Fix:** `build/prepare-kernel.sh` strips `CONFIG_WIRELESS_EXT` from the generated
`autoconf.h`, and the driver builds its control plane as cfg80211/nl80211 instead
(`-DCONFIG_IOCTL_CFG80211`, set by the `CONFIG_PLATFORM_ARM_CMU` block in `driver/Makefile`).

## 2. `CONFIG_CFG80211_WEXT=y` — `struct wireless_dev`

The counterpart, and easy to get wrong while fixing the first one. Wireless Extensions are
off, but cfg80211's *compatibility* layer for them is on, so `struct wireless_dev` does have a
`.wext` member and the unit's cfg80211 runs `cfg80211_mgd_wext_connect()` on `NETDEV_UP`,
reading `wdev->wext.connect`.

**Presents as:** an oops inside `cfg80211_mgd_wext_connect` the moment the interface is
brought up, because the driver's `wireless_dev` is smaller than the one cfg80211 writes into.

**Fix:** strip only `CONFIG_WIRELESS_EXT[_SYSFS]`; keep `CFG80211_WEXT` and
`WEXT_CORE`/`PROC`/`PRIV`/`SPY`.

## 3. `CONFIG_PM_SLEEP=n` — `struct device` and `struct usb_device`

The unit was built with suspend support off. `PM_SLEEP=y` inserts 24 bytes into
`dev_pm_info` — an `entry`, a `completion` and a `wakeup` pointer, where the unit has a
one-bit `should_wakeup` — which shifts every `struct device` field after `.power`, and with it
every `usb_device` field after `.dev`.

On the unit, `dev.class` in the `struct device` embedded in `struct wiphy` sits at **0x128**; a
`PM_SLEEP=y` build puts it at **0x140**. Delta 0x18.

**Presents as:** the probe reads `usb_device->actconfig` at `dev+0x168` instead of the unit's
`dev+0x150` and NULL-derefs in `rtw_drv_init` while reading `bNumInterfaces`.

The same root cause explains two link errors: that kernel exports none of the PM_SLEEP or
USB_SUSPEND symbols — `device_init_wakeup`, `usb_autopm_*`, `usb_*_autosuspend` — so the calls
guarded by `CONFIG_PM` and `CONFIG_AUTOSUSPEND` are compiled out.

## 4. Netfilter, sched, secmark — `struct sk_buff`

The unit's kernel was built with netfilter, packet scheduling and secmark. Those insert 16
bytes of config-gated fields into `struct sk_buff` between `len` and `data`:

| Region | Bytes | Fields | Gated by |
|---|---|---|---|
| before `queue_mapping` | +12 | `nfct`, `nfct_reasm`, `tc_index`/`tc_verd` | `NF_CONNTRACK`, `NF_DEFRAG_IPV4`, `NET_SCHED`/`NET_CLS_ACT` |
| after `flags2` | +4 | `secmark` | `NETWORK_SECMARK` |

On the unit, `skb->data` is at **0xa8**, `tail` at 0x9c and `queue_mapping` at 0x80. A minimal
`imx6_defconfig` build gives 0x98 / 0x8c / 0x74.

**Presents as:** every inlined `skb_reserve`/`skb_put` uses offsets 16 bytes early, so RX URB
transfer buffers get garbage pointers and `virt_addr_valid()` trips a `BUG_ON` in
`dma-mapping.c` the first time the interface is brought up.

Only the +12/+4 split matters, not which exact options supply it, so layout-equivalent
substitutes are fine.

## 5. ftrace — `struct module`

The unit's kernel was built with tracing, so its modules carry `__mcount_loc` and `struct
module` has the ftrace and tracepoint fields: **332 bytes (0x14c)**, not 300.

**Presents as:** the module loader reads `struct module` fields at the wrong offsets and
oopses in `sys_init_module`.

`build/build-driver.sh` checks this explicitly on every build.

## 6. `CONFIG_ARM_UNWIND=n`

Built with unwind tables, the module references `__aeabi_unwind_cpp_pr0`, which the unit's
kernel does not export.

**Presents as:** `insmod: unknown symbol __aeabi_unwind_cpp_pr0`.

## 7. `CONFIG_NL80211_TESTMODE=y` — `struct cfg80211_ops`

The unit's cfg80211 was built with testmode support, which puts `testmode_cmd` and
`testmode_dump` into `struct cfg80211_ops` ahead of `dump_survey`. They are the only
config-gated members in the whole ops structure.

**Presents as:** without it, every function pointer from `dump_survey` onwards sits two slots
early, so an `nl80211` `GET_SURVEY` lands on `del_pmksa` and NULL-derefs inside hostapd.

`build/prepare-kernel.sh` appends the define to the generated `autoconf.h` and asserts it.

## 8. The backported cfg80211 lies about its version

`LINUX_VERSION_CODE` reports 3.0.35, but the unit's cfg80211 is a backport carrying members
and flags from much later kernels. Several of the driver's version guards are therefore false
negatives — they compile out code the target actually supports:

- **`WIPHY_FLAG_HAVE_AP_SME`** (BIT(17)) is guarded on >= 3.3.0 upstream but exists here.
  Without it, hostapd assumes host-based SME and spins up a monitor interface. This is a
  fullMAC part and cannot do that: the beacon goes out, clients see the SSID, and no
  authentication ever reaches the driver. The driver sets the flag unconditionally.
- **`station_info.assoc_req_ies`** and `STATION_INFO_ASSOC_REQ_IES` are guarded on >= 3.2 but
  are present in `abi/include/net/cfg80211.h`. hostapd needs those IEs out of the
  `NEW_STATION` event to read the client's RSN IE and start the WPA2 handshake; without them
  the client associates, hostapd never sends EAPOL, and the client times out and
  deauthenticates with reason 3. The driver always fills them in.

On this unit a `LINUX_VERSION_CODE` guard says nothing about what cfg80211 provides. Check
`abi/include/` for the member instead.

## 9. Driver-owned SME — the two MLME bugs it exposed

Turning on `HAVE_AP_SME` makes the driver responsible for authentication and association, and
that path had never been exercised in this configuration. Two problems surfaced:

- **`mgt_dispatcher` had lost Realtek's fallthrough.** Realtek's code is a `switch` in which
  `case WIFI_AUTH` picks `OnAuth`/`OnAuthClient` and falls through to the
  `WIFI_ASSOCREQ`/`WIFI_REASSOCREQ` cases, which dispatch. The vendored tree had rewritten it as
  an `if`/`else` that broke both halves:
  - authentication frames were remapped but never dispatched, so every client authentication
    was silently dropped;
  - association requests were remapped to `OnAuth` as well, so the driver parsed an assoc-req
    body as an auth frame and rejected every association with "auth rejected due to bad alg".
    `ptable` points into the global `mlme_sta_tbl`, so that remap also overwrote the
    `OnAssocReq` entry for good.

  The driver now remaps only `WIFI_AUTH` and dispatches all three.

- **`OnAuth` and `OnAssocReq` need the mlme-EXT AP state.** Both drop every frame unless
  `(pmlmeinfo->state & 0x03) == WIFI_FW_AP_STATE`, and Realtek's code sets that only in
  `setopmode_hdl`, on `change_iface` to AP. Any path that clears it before the BSS starts
  (`rtw_mlmeext_disconnect`, for one, sets `WIFI_FW_NULL_STATE`) leaves the AP beaconing but
  ignoring every client. The driver also sets it in `start_bss_network`, where the BSS
  actually starts.

## 10. Regulatory — getting channel 36 beaconable

Three things must hold for the AP to beacon on channel 36:

1. **`CUSTOM_REGULATORY` is set before `wiphy_register()`.** Otherwise the core applies its
   world regdomain at register time, leaving `orig_flags` with `PASSIVE_SCAN|NO_IBSS` across
   5 GHz. The custom regdomain is then OR-ed onto that stale bit in `handle_channel_custom`,
   so channel 36 stays 0x26 and `cfg80211_reg_can_beacon` refuses it.
2. **No `reg_notifier` and no flag pass after the regdomain.** For a `CUSTOM_REGULATORY`
   wiphy the core calls the notifier on the boot world-regdomain event ("notify custom cards
   so they can restore orig reg"). Realtek's notifier re-applies the channel plan's flags
   through `_rtw_reg_apply_flags`, which marks all of 5 GHz `SCAN_PASSIVE`. The driver
   therefore installs no notifier, and `_rtw_reg_apply_flags` is compiled out.
3. **Regdomain rules without flags.** cfg80211 ORs each rule's flags into the channel flags,
   and `PASSIVE_SCAN` (`NO_IR` from 3.14) blocks beaconing. Realtek's single 5150-5850 rule
   carries `PASSIVE_SCAN | NO_IBSS`; the driver's `rtw_regdom_rd` uses two flag-free rules
   instead: 2402-2482 MHz and 5170-5250 MHz.

That regdomain is the only source of channel flags. Channels 1-13 and 36-48 are active, and
cfg80211 disables every channel no rule covers, so DFS 52-140 and UNII-3 149-165 never
transmit. UNII-3 is not permitted for Wi-Fi in the EU in any case.

The regdomain is applied when the interface is opened (`_netdev_open` →
`rtw_cfg80211_init_wiphy` → `rtw_regd_init`), not at module load. Until `wlan1` has been up
once, `iw phy` shows the driver's unregulated defaults (every channel, 30 dBm, no flags).
Nothing transmits while the interface is down, but check channel flags only after bringing it
up.

**Separately**, the driver keeps its own internal channel set, built from a channel plan. The
adapter's efuse plan is 2.4 GHz only, so without an override that set has no 5 GHz channels.
The load script passes `rtw_channel_plan=0x11` (`RT_CHANNEL_DOMAIN_FCC_NO_DFS`) to override it;
the software plan wins in `hal_com_config_channel_plan`. With `_rtw_reg_apply_flags` compiled
out, the channel plan does not reach cfg80211's channel flags, so it does not show in
`iw phy`. `/sys/module/rtl8812au/parameters/rtw_channel_plan` shows the value that was passed.

## 11. `usb_reset_device` on module unload

The vendor code re-enumerates the adapter during `disconnect` as a convenience for the
re-insmod site-survey path.

**Presents as:** re-enumerating mid-teardown corrupts kernel memory and oopses an unrelated
process — "Fixing recursive fault but reboot is needed".

The driver skips the reset when `processing_dev_remove` is set. It is still taken on the
probe-failure path.

## 12. Not an ABI problem, but worth knowing: interrupt affinity

On this two-core i.MX6 every GIC and GPIO interrupt is delivered to CPU0 — the CPU1 column in
`/proc/interrupts` is a flat zero — and a NIC's RX softirq and the Realtek receive tasklet run
on whichever CPU took the interrupt. Under load CPU0 measured 89% busy against CPU1 at 83%
idle, with roughly 690 interrupts per second from the adapter's bus alone.

Pinning that interrupt to CPU1 freezes CPU0's count and lifts its idle time from 11% to 56%.
`install/load-wlan1.sh` does this at boot, deriving the interrupt number rather than
hardcoding it. A manual `echo` to `smp_affinity` survives a service restart but not a reboot,
and losing it presents as constant small video stutter with otherwise perfect RF.
