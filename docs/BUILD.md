# Building

Everything happens in a container. The host needs only Docker and about 3 GB of free disk.

```sh
docker build -t cmu-rtl8811au:latest -f build/Dockerfile build/

RUN="docker run --rm --user $(id -u):$(id -g) -v $PWD:/build cmu-rtl8811au:latest"
$RUN build/prepare-kernel.sh     # once; unpacks and configures the reference kernel
$RUN build/build-driver.sh       # produces out/rtl8812au.ko and checks it
$RUN build/package.sh            # produces out/cmu150-rtl8811au-<version>.tar.gz
```

`--user` matters: without it the container writes `out/` and `build/.work/` as root and your
next non-Docker command cannot touch them.

## Why a container, and why Debian Jessie

Two things cannot be had on a modern host:

- **A period-correct cross compiler.** gcc 4.9.4 `arm-linux-gnueabi` soft-float, from
  kernel.org's crosstool collection. It matches the i.MX6 BSP ABI; modern ARM toolchains
  default to hard-float and produce a module the unit's kernel will not load.
- **Period-correct host tools.** A 3.0.35 tree's own build scripts break under current make
  and gcc. Jessie's are contemporary with it.

Jessie can no longer complete a TLS handshake with most hosts, so the first stage of the
Dockerfile, a modern Debian, does every download: the toolchain, and Boundary Devices' i.MX6
3.0.35 BSP at a pinned commit (`KERNEL_SHA`). Both are copied into the final image, which
downloads nothing.

## `prepare-kernel.sh`

Unpacks the BSP from the image into `build/.work/linux-imx6`, configures it to match the head
unit's ABI and runs `modules_prepare`.

**Nothing from this kernel is shipped or flashed.** The module runs on the unit's own kernel.
What matters is the *compile view* — `include/generated/autoconf.h` and the headers it gates —
producing structure layouts identical to the ones the unit's kernel was built with. Every
option the script sets is there for that reason, and each is explained in
[ABI-NOTES.md](ABI-NOTES.md). Changing one does not break the build; it corrupts memory at
runtime.

The last step edits the generated `autoconf.h` directly rather than `.config`: `WIRELESS_EXT`
has to go while `CFG80211_WEXT` stays, and `NL80211_TESTMODE` has to be added. It keeps a
pristine `autoconf.h.orig` and re-derives from it, so re-running is idempotent. The script
asserts all three conditions before returning.

Re-running with `build/.work/linux-imx6` already present skips the unpacking and reconfigures
in place.

## `build-driver.sh`

Builds `driver/` against the prepared kernel, with two overrides that do the real work:

- `NOSTDINC_FLAGS=-I abi/include/` — compile against **the head unit's** cfg80211 headers
  rather than the reference kernel's in-tree ones, so `struct wiphy`, `struct cfg80211_ops`
  and `struct station_info` match the cfg80211 module already running on the unit.
- `KBUILD_EXTRA_SYMBOLS=abi/Module.symvers` — resolve the cfg80211 exports.

`compat-2.6.h` is deliberately *not* force-included, so `COMPAT_KERNEL_RELEASE` stays
undefined and the driver's own guards select the old-API `.add_beacon`/`.del_beacon` ops that
the unit's cfg80211 actually exposes.

Then it checks the result. Each check catches a module that would otherwise only fail on the
unit:

| Check | What it catches |
|---|---|
| `vermagic` is `3.0.35 SMP preempt mod_unload ARMv7` | the module loader refusing it outright |
| `struct module` is 332 bytes | ftrace fields missing, oops in `sys_init_module` |
| USB alias `2357:011F` present | the adapter never binding |
| cfg80211 symbols referenced | a WEXT build slipping through |
| no `rtw_handlers_def` | WEXT not fully off |

Note the shape of those tests: they use here-strings, not pipes. Under `set -o pipefail` a
`... | grep -q` pipeline reports **failure** when grep matches early and SIGPIPEs its
producer, which silently inverts a boolean check — a safety check written that way reports
"clean" precisely when it should fail.

## Changes to `driver/`

The first commit imports the upstream tree unchanged. Every change to it after that is a
commit of its own, so `git log -p dcf7c03.. -- driver/` shows exactly what this repository
changes.

## Reproducibility

The module build is reproducible. The repository is always mounted at `/build`, so the paths
the compiler bakes into `__FILE__` strings for the driver's debug macros do not depend on where
the checkout sits on your disk — renaming or moving it does not change the module. The release
`.tar.gz` around it is not byte-reproducible: it records file times.

Building outside the container, or from a differently named path, changes only those embedded
strings: the code and the symbol table stay identical and only `.rodata.str1.4` differs in
size.

Pinned inputs:

| Input | Pin |
|---|---|
| Kernel | `boundarydevices/linux-imx6` @ `d97f449780544a18ca7c877dfc4742a3d92e4ccf` |
| Toolchain | kernel.org crosstool gcc 4.9.4 nolibc `arm-linux-gnueabi` |
| Host tools | `debian/eol:jessie` |
| cfg80211 ABI | TI compat-wireless `ol_R5.SP8.01` (vendored in `abi/`) |
| Driver base | `abperiasamy/rtl8812AU_8821AU_linux`, imported unchanged in commit `dcf7c03` |

## Releasing

Releases are automated with [release-please](https://github.com/googleapis/release-please).
Commits follow [Conventional Commits](https://www.conventionalcommits.org/), and versions
follow [Semantic Versioning](https://semver.org/), with the bump taken from the commits:

- `fix` → patch
- `feat` → minor
- a breaking change (`type!:` or a `BREAKING CHANGE:` footer) → major

A change is breaking when upgrading needs more than re-running `install.sh`: a new service
block, a new required `dongle.conf` key, a moved install path, or a dropped firmware or
adapter.

On every push to `main`, release-please keeps a release pull request open with the next
version and its `CHANGELOG.md` entry. Merging it creates the tag and the GitHub release, and
CI attaches the built archive and its checksum to that release.
