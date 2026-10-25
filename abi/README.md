# abi/

The head unit's cfg80211 ABI, vendored so the driver can be compiled against the *exact*
interface the module already running on the unit exposes.

- **`include/`** — the generated header set from Texas Instruments' compat-wireless release
  `ol_R5.SP8.01`, which is what the unit's own `cfg80211.ko` was built from.
- **`Module.symvers`** — that tree's cfg80211 export list, trimmed to the cfg80211 module and
  rewritten to a relative path. `MODVERSIONS` is off, so the CRC column is zero throughout and
  the file serves only to map symbol to providing module.

`build/build-driver.sh` passes these as `NOSTDINC_FLAGS=-I abi/include/` and
`KBUILD_EXTRA_SYMBOLS=abi/Module.symvers`.

**`struct wiphy` starts with a 2048-byte pad.** `include/net/cfg80211.h` opens the structure
with `u8 padding[WIPHY_COMPAT_PAD_SIZE]`. It is not in mainline: it comes from compat-wireless's
own `patches/09-cfg80211-wext-padding.patch`, which `admin-refresh.sh` applies. Every
`struct wiphy` member offset the driver uses depends on it, so it must survive any
regeneration. `admin-refresh.sh` also leaves `*.orig` copies of the files it patched; those
are not part of the header set.

## Why vendored rather than fetched

These headers are the reason the build works at all. The unit's cfg80211 reports
`LINUX_VERSION_CODE` 3.0.35 but carries members and flags from far later kernels — see
[../docs/ABI-NOTES.md](../docs/ABI-NOTES.md) §8. Compiling against a stock 3.0.35 `cfg80211.h`
produces a module that builds cleanly and then misbehaves at runtime.

They are checked in, rather than fetched during the build, for two reasons: it keeps CI to a
single external download, and `git.ti.com` is not a dependency worth betting a build on.

## Regenerating them

Only necessary if you are targeting a different firmware whose cfg80211 differs. The headers
are not in compat-wireless's git tree — `admin-refresh.sh` populates them from a kernel tree:

```sh
git clone https://git.ti.com/git/wl12xx/compat.git           -b ol_R5.SP8.01 compat
git clone https://git.ti.com/git/wl12xx/compat-wireless.git  -b ol_R5.SP8.01 compat-wireless
git clone https://git.ti.com/git/wl12xx/wl12xx.git           wl12xx     # ol_R5.SP4.01

cd compat-wireless
GIT_TREE=../wl12xx GIT_COMPAT_TREE=../compat ./scripts/admin-refresh.sh
./scripts/driver-select rt2x00        # any target; this only narrows what gets built
make KLIB_BUILD=/path/to/linux-imx6 MODPROBE=/bin/true modules
```

Then copy `include/` here, and filter `Module.symvers` down to the cfg80211 rows:

```sh
awk -F'\t' 'BEGIN{OFS="\t"} $3 ~ /\/cfg80211$/ {print $1, $2, "net/wireless/cfg80211", $4}' \
    compat-wireless/Module.symvers | sort -k2,2 > abi/Module.symvers
```

The `driver-select` target is irrelevant to the result — it only limits which drivers compile.
What is needed from that tree is the header set and cfg80211's exports.
