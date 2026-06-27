# Building lx2160a_uefi natively on FreeBSD/arm64 (clang + GNU ld)

This directory builds the SolidRun LX2160A CEX7 UEFI firmware (this repo)
**natively on a FreeBSD/aarch64 host** — e.g. the LX2160A board itself — using the
base **clang** compiler and **GNU `ld`**, with no Linux cross-toolchain.

Verified on **FreeBSD 15.1-RELEASE/arm64** on a SolidRun CEX7 (LX2160A), base
clang/lld 19, building this fork (`edk2-stable202105`, commit `ee5c233`). It produces
a bootable image, and the embedded Management Complex (MC) firmware can be upgraded
(a patch to **MC 10.39.0** is included).

> Status: BL2/BL31 (TF-A) and SEC/PEI are solid. The clang-built UEFI boots, but
> occasionally hits a synchronous exception in early DXE (same image, non-deterministic
> — see [Known issues](#known-issues)). MC 10.39.0 has been confirmed live on hardware.

## Why a port is needed

Upstream `runme.sh` assumes Linux plus an x86-hosted `aarch64-none-linux-gnu` GCC.
On an aarch64 FreeBSD host the firmware target is *native*, so we build with base
clang. Two wrinkles:

1. **EDK2 BaseTools / build system expect GNU tools** (`gcc`, `g++`, `make`, `python`)
   → small shims redirect them to `cc`, `c++`, `gmake`, `python3`.
2. **EDK2 image generation needs GNU `ld`, not lld.** `GenFw` + `GccBase.lds` only
   produce correct PE base relocations with GNU ld. With lld the UEFI *links* but
   faults at runtime with corrupted string/data relocations (`SOC: unknown`, empty
   build dates). So EDK2 is linked with **GNU `ld.bfd`** from the `binutils` package.
   TF-A (BL2/BL31) builds fine with clang+lld and is left on lld.

## Prerequisites

```sh
pkg install -y bash gmake binutils dtc acpica-tools gettext-runtime python3 git
```

- `clang`, `lld`, `llvm-objcopy/ar/nm` are in the FreeBSD base system.
- `binutils` provides GNU `ld.bfd` at `/usr/local/bin/ld.bfd` (used for the EDK2 link;
  if yours is elsewhere, adjust patch `01` / `tools_def`).

## Layout

```
freebsd/
  README.md
  patches/        # apply to the EDK2 submodules (see below)
  scripts/
    env-freebsd.sh   # source this (sets WORKSPACE, CLANG38_*, PATH shims)
    build-rcw.sh     # RCW (DDR speed!)
    build-uefi.sh    # BaseTools + EDK2 .fd (clang CLANG38 + GNU ld)
    build-atf.sh     # TF-A BL2/BL31 + FIP + PBL (clang + lld)
    mkimage.sh       # assemble the 8M SD image
    bin/             # gcc g++ make python shims
```

## Build

```sh
# 0. clone this fork + submodules
git submodule update --init
(cd build/tianocore/edk2 && git submodule update --init)

export ROOTDIR=$PWD

# 1. apply the patches (the EDK2 sources are CRLF, so use --ignore-whitespace)
( cd build/tianocore
  git apply --ignore-whitespace "$ROOTDIR"/freebsd/patches/01-edk2-tools_def-clang-gnuld.patch
  git apply --ignore-whitespace "$ROOTDIR"/freebsd/patches/02-edk2-platforms-dsc-wno-error.patch
  git apply --ignore-whitespace "$ROOTDIR"/freebsd/patches/03-edk2-platforms-fspidxe-syntax.patch
  # 04 is the optional MC 10.39 upgrade — see below
)

# 2. build
. freebsd/scripts/env-freebsd.sh
bash freebsd/scripts/build-rcw.sh      # SPEED defaults to DDR 2600 — set for your board
bash freebsd/scripts/build-uefi.sh     # -> .../RELEASE_CLANG38/FV/LX2160ACEX7_EFI.fd
bash freebsd/scripts/build-atf.sh      # -> bl2_sd.pbl, fip.bin
bash freebsd/scripts/mkimage.sh        # -> images/lx2160acex7_freebsd_sd.img
```

## The patches

| File | What |
|------|------|
| `01-edk2-tools_def-clang-gnuld.patch` | `tools_def.template`: drop `-Werror` (clang-19 has new warnings); point CLANG38 AArch64 `DLINK`/`ASLDLINK` at `-fuse-ld=/usr/local/bin/ld.bfd -no-pie`; `-flto -O3` → `-Os` (GNU ld can't do LLVM LTO); add **`-ftrivial-auto-var-init=zero`** (the boot-crash fix — see [Resolved](#resolved-the-intermittent-early-dxe-crash)). |
| `02-edk2-platforms-dsc-wno-error.patch` | Platform DSC: append `-Wno-error` to `CC`/`ASLCC` build options. |
| `03-edk2-platforms-fspidxe-syntax.patch` | `FspiDxe.h`: remove a stray `;` in a prototype that clang rejects (GCC tolerated). |
| `04-edk2-platforms-fdf-mc-10.39.patch` | *(optional)* bundle MC firmware `10.39.0` instead of `10.28.1`. |

## Shims (`freebsd/scripts/bin`, prepended to `PATH`)

| Shim | Redirects to | Why |
|------|--------------|-----|
| `gcc` | `cc` (+`-Wno-error` etc.) | BaseTools hardcodes `gcc`; FreeBSD has clang only |
| `g++` | `c++` (`-std=gnu++14`, `-Wno-register`) | PCCTS C++ uses `register` (removed in C++17) |
| `make` | `gmake` | EDK2 invokes `make tbuild`; FreeBSD `make` is BSD make |
| `python` | `python3` | BaseTools self-tests call `python` |

## MC firmware upgrade (10.39)

The MC is embedded as a RAW FV section in `LX2160aCex7.fdf` (it is **not** a separate
flash region on UEFI builds). To upgrade:

1. Fetch `mc_lx2160a_10.39.0.itb` from
   [`nxp-qoriq/qoriq-mc-binary`](https://github.com/nxp-qoriq/qoriq-mc-binary) tag
   `mc_release_10.39.0` (`lx2160a/`), drop it in
   `build/tianocore/edk2-non-osi/Silicon/NXP/QoriqMcBinary/lx216xa/`.
2. Apply patch `04` (or edit the `SECTION RAW =` line in the FDF).
3. Rebuild EDK2 + repack the FIP (`build-uefi.sh` then `build-atf.sh`).

The new MC is verified at runtime by Linux/FreeBSD: `fsl-mc: ... MC firmware version: 10.39.0`.

## Flashing

Image regions (512-byte blocks): RCW+BL2 PBL `@ seek=8`, DDR-PHY FIP `@ seek=256`,
FIP (BL31+BL33) `@ seek=2048`. Write the whole image to the boot card (`dd if=img
of=/dev/<sd> bs=512`), or flash regions individually. On a running FreeBSD with an
eSDHC/SD driver you can `dd` directly to `/dev/mmcsdX`.

## Resolved: the intermittent early-DXE crash

Early GNU-ld builds booted *once* then hit a `Synchronous Exception` in early DXE at a
**varying** address — the signature of **reading uninitialized stack memory** (cold-boot
DRAM is semi-random and the board runs DDR with **ECC off**). clang left a local
uninitialized where GCC's LTO build didn't. **Fixed** by `-ftrivial-auto-var-init=zero`
in `CLANG38_AARCH64_CC_FLAGS` (patch `01`), which zero-inits all automatic variables.
Verified across repeated cold power-cycles. Full investigation in
[`DEVLOG.md`](DEVLOG.md) §5.

`PcdEmuVariableNvModeEnable|TRUE` (RAM-only UEFI variables, no SPI-NOR writes) was used
while bisecting and is **not** required by the fix — leave it off to keep persistent
variables. It stays a handy option if you ever need the SPI-NOR variable path out of the
picture.

## Notes

- The GNU-ld path means **no LTO**, so modules are a little larger than the upstream
  GCC+LTO build. The compressed FV still fits comfortably (~80% of FVMAIN_COMPACT).

## Credits

FreeBSD-native port and MC 10.39 packaging by **networkextension**, on top of
[SolidRun/lx2160a_uefi](https://github.com/SolidRun/lx2160a_uefi)
(`edk2-stable202105`, commit `ee5c233`).
