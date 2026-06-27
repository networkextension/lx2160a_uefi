# LX2160A CEX7 — FreeBSD-native UEFI build, MC 10.39 upgrade, and debugging log

A detailed record of building the SolidRun LX2160A CEX7 UEFI firmware **natively on
the board itself (FreeBSD/arm64, clang + GNU ld)**, upgrading the Management Complex
(MC) firmware to **10.39.0**, and root-causing the intermittent boot crash that the
clang toolchain introduced. Companion to [`README.md`](README.md) (the how-to) — this
file is the *why* and the *journey*.

- **Source:** fork of `SolidRun/lx2160a_uefi` @ commit `ee5c233` (`edk2-stable202105`).
- **Build host = target:** SolidRun CEX7, NXP **LX2160A** (16× A72), **FreeBSD 15.1-RELEASE/arm64**, base **clang/lld 19.1.7**, GNU **binutils 2.44** (`ld.bfd`).
- **Result:** a FreeBSD-built firmware that boots reliably with **MC 10.39.0** and 10 GbE up.

---

## 1. Goal

Rebuild this firmware **without a Linux cross-toolchain** — directly on the aarch64
FreeBSD board — and use it to **upgrade the embedded MC firmware** (the board shipped
MC 10.28.1). On UEFI builds the MC is *embedded inside the EDK2 firmware volume*, not a
separate flash region, so changing it means rebuilding the `.fd`. Doing that build on
FreeBSD is the whole challenge.

## 2. Hardware / environment notes

- LX2160A boots via **UEFI/EDK2** (not u-boot). Root filesystem is on **NVMe (`nda0`) / ZFS (`zroot`)**; the UEFI boot firmware lives on a **TF/SD card** (`/dev/mmcsd0`, raw — no partition table). The eMMC (`/dev/mmcsd1`) holds *independent* firmware and acts as a fallback boot source.
- **DDR runs with ECC OFF** (the DIMM `16ATF4G64HZ-2G6B3` is non-ECC). This matters — see §5.3.
- DDR speed is **2600 MT/s** on this board (upstream `runme.sh` defaults to 2400; using the wrong value means memory won't train).
- Internet on the board is via a slow HTTP proxy; large git clones are done on a fast host and `tar`-streamed over SSH.

## 3. The FreeBSD-native build (clang + GNU ld)

### 3.1 Why a port was needed

Upstream `runme.sh` assumes Linux + an x86-hosted `aarch64-none-linux-gnu` GCC. On an
aarch64 FreeBSD host the firmware target is *native*, so we build with base clang — but
EDK2's build system and BaseTools expect GNU tooling.

### 3.2 The critical pivot: lld → GNU ld

The single most important discovery. EDK2 first built fine with base **clang + lld**,
and it even *ran* through SEC/PEI — but every absolute data/string reference resolved to
the wrong address at runtime (`SOC: unknown` instead of `SOC: LX2160ACE Rev2.0`, empty
build dates, build-path strings leaking into output). Cause: **`GenFw`'s ELF→PE
base-relocation conversion only produces correct output from GNU `ld`, not lld.** With
lld the PE relocations are subtly wrong.

Switching the EDK2 link to **GNU `ld.bfd`** (`pkg install binutils`) fixed the strings
immediately and let us drop a stack of lld-only workarounds (a GenFw `.text`
classification patch, `-no-pie` hacks, 4 KB XIP alignment). **TF-A (BL2/BL31) builds
fine with clang + lld; only EDK2 needs GNU ld.** GNU ld can't do LLVM LTO, so EDK2 is
built `-Os` without LTO (the compressed FV still fits at ~80 %).

### 3.3 The build fixes (each found by iterating real errors)

| # | Hurdle | Fix |
|---|--------|-----|
| 1 | no `gcc`/`g++`/`as` on FreeBSD | shims → `cc`/`c++` (gnu++14, neutralize clang-strict errors) |
| 2 | EDK2 calls `make` = BSD make | `make`→`gmake` shim |
| 3 | `python` self-tests | `python`→`python3` shim |
| 4 | `-Werror` + clang-19's new warnings | strip `-Werror` from `GCC_ALL_CC_FLAGS`; `-Wno-error` in platform DSC |
| 5 | PCCTS C++ uses `register` (illegal in C++17) | BaseTools C++ built `-std=gnu++14` |
| 6 | EDK2 PE relocations wrong with lld | **link EDK2 with GNU `ld.bfd`** (§3.2) |
| 7 | no LLVM LTO under GNU ld | CLANG38 RELEASE `-flto -O3` → `-Os` |
| 8 | NXP source typo (`FspiDxe.h` stray `;`) | clang rejects what GCC tolerated — drop the `;` |
| 9 | TF-A `-Werror` + `-j` fiptool race | ATF `E=0`; run `all` / `fip` / `pbl` as separate goals |
| 10 | clang-19 ICE on `I2cLib.c` (DEBUG build) | **transient** (didn't reproduce on saved `.i`) — likely a build-time DDR bit flip (ECC off); just retry |

### 3.4 Pipeline

`build-rcw.sh` (DDR **2600**) → `build-uefi.sh` (BaseTools + EDK2 `-t CLANG38`, GNU ld)
→ `build-atf.sh` (TF-A BL2/BL31 + FIP + PBL, clang+lld) → `mkimage.sh` (8 MB SD image:
RCW+BL2 @ blk 8, DDR-PHY-FIP @ blk 256, FIP @ blk 2048).

## 4. MC firmware upgrade to 10.39

The MC + DPL + DPC are embedded as RAW FV sections in `LX2160aCex7.fdf`
(line 253 = `Silicon/NXP/QoriqMcBinary/lx216xa/mc_lx2160a_10.28.1.itb`). To upgrade:

1. Fetch `mc_lx2160a_10.39.0.itb` from `nxp-qoriq/qoriq-mc-binary` tag
   `mc_release_10.39.0` (`lx2160a/`), drop it in
   `edk2-non-osi/Silicon/NXP/QoriqMcBinary/lx216xa/`.
2. Point the FDF `SECTION RAW =` line at it.
3. Rebuild the `.fd` (FVMAIN_COMPACT goes 78 %→79 %, +111 KB MC) and repack the FIP.

Confirmed live on hardware: `dpaa2_rc0: MC firmware version: 10.39.0`.

## 5. The boot-bug saga

### 5.1 Symptom progression

1. **lld build** — booted through PEI but with corrupted strings (`SOC: unknown`). → fixed by GNU ld (§3.2).
2. **GNU-ld build** — SEC/PEI strings now correct; **first cold boot succeeded** (MC 10.39 confirmed over SSH), but it then hit a **`Synchronous Exception` in early DXE** that *appeared* intermittent, then reproduced. The crash **PC varied** between builds and between boots (`0xFAB45698`, `0xEE2B41B0`, …).
3. A **DEBUG build** (to log per-driver load addresses) **hung at the PEI→DXE handoff** (decompressing the larger 12 MB FV) and never reached the driver-load log — a dead end for that approach.

### 5.2 Dead ends (each ruled out)

- **Outline atomics** — clang `-target …-linux-gnu` can emit `__aarch64_*` atomic helpers that don't belong in firmware. Checked the linked image: **none present.** Not it.
- **SPI-NOR UEFI variable store** — strong theory: the platform stores variables in **SPI-NOR** (`VariableRuntimeDxe` + `FaultTolerantWriteDxe` + `SpiNorFlashDxe`), a chip the SD reflash never touches, which neatly explained "boots once, then crashes" (boot #1 writes/corrupts the store; later boots crash reading it). **Tested by disabling SPI-NOR writes entirely** (`PcdEmuVariableNvModeEnable|TRUE` → variables kept in RAM). **Still crashed on boot #2** (at a new address `0xEE2B41B0`). So the variable store was *not* the cause — but emu-var is a clean way to take SPI-NOR out of the picture.

### 5.3 Root cause: uninitialized stack memory

The tell was the **varying crash address** — a deterministic miscompile would fault at
boot #1 too and at a fixed PC. "Boots once, then crashes at a *different* address each
cold boot" is the signature of **reading an uninitialized stack variable**: cold-boot
DRAM powers up to semi-random content (and **ECC is OFF**, so nothing scrubs it), so an
uninitialized local gets a benign value one boot and a fatal one the next. clang and
GCC differ in exactly which locals they leave uninitialized (and GCC's LTO build
happened to avoid it).

### 5.4 The fix

Add **`-ftrivial-auto-var-init=zero`** to `DEFINE CLANG38_AARCH64_CC_FLAGS` — clang
zero-initializes every otherwise-uninitialized automatic (stack) variable. Cheap, safe,
and it directly neutralizes the entire bug class.

**Verified:** rebuilt, reflashed, and **cold power-cycled 3×, booting cleanly every
time** with MC 10.39.0. (The verified build also still had emu-var enabled from §5.2;
`auto-var-init` is believed to be the sole necessary fix — see §8.2.)

## 6. Flashing & recovery

- **SD image regions** (512-byte blocks): RCW+BL2 PBL @ `seek=8`, DDR-PHY FIP @ `seek=256`, FIP (BL31+UEFI) @ `seek=2048`. The image's first 8 sectors are zeros (matches stock), so writing the whole image from sector 0 is safe.
- **Remote flashing** works from the running FreeBSD: `doas dd if=img of=/dev/mmcsd0 bs=512`, then read back and compare sha1. The RCW we build is **byte-identical** to the board's live RCW (same DDR-2600 config), a good sanity anchor.
- **The SPI-NOR insight (§5.2):** UEFI variables persist in SPI-NOR across SD reflashes, and FreeBSD currently exposes **no flash device** for it — so you cannot clear UEFI variables from the OS. A FreeBSD FlexSPI-NOR driver would be useful infrastructure (inspect/clear the store, manage firmware from the OS) but is a separate project.
- **Recovery:** keep a known-good image (`ee5c233`) to `dd` back; the eMMC's independent firmware is a fallback boot source if the SD firmware won't boot.

## 7. Published artifacts

- Repo: `github.com/networkextension/lx2160a_uefi`, `freebsd/` directory — patches `01–04`, build scripts, `gcc/g++/make/python` shims, `README.md`, this `DEVLOG.md`.
- Release `freebsd-clang-mc10.39.0` — the MC-10.39 SD image + sha256.

## 8. Open items

### 8.1 PCIe / Thunderbolt-3 card not enumerating

A Thunderbolt-3 add-in card in the **x8 slot** doesn't appear in `pciconf`. State:

- FreeBSD relies on **UEFI** to train PCIe links; it only reads what the firmware set up.
- Firmware exposes **2 of 6** PCIe controllers in ACPI: `pcib0` (ECAM `…9000100000` = **PCIe #1** = M.2/NVMe, works) and `pcib1` (ECAM `…a000100000` = **PCIe #2**, empty).
- An Intel `ix` (ixgbe) SFP+ NIC **worked in that x8 slot previously**, proving the slot, SerDes lanes, controller and ACPI are all fine — then it "was lost."

Working hypotheses:
- **TB3 = force-power.** TB3 add-in cards keep their controller (Alpine/Titan Ridge) powered **off** until a force-power signal (TBT header / on-card jumper) is asserted; with none, the controller is off → no PCIe link → invisible. This board has no BIOS TBT option or `thunderbolt` driver to assert it, so it must come from the card. This matches the "no power" read and explains why a normal NIC works but the TB3 doesn't.
- **Intel NIC "lost"** — to be resolved: did it vanish spontaneously (slot power/stability) or after switching from stock `ee5c233` to our custom firmware (PCIe init regression)? Test: re-seat the known-good NIC and `pciconf -l`; boot stock firmware to compare.

### 8.2 emu-var vs auto-var-init (minimal fix)

The confirmed-working build carried **both** `auto-var-init=zero` (the real fix) **and**
`PcdEmuVariableNvModeEnable` (added while chasing §5.2). `auto-var-init` alone is almost
certainly sufficient; dropping emu-var would **restore persistent UEFI variables**.
One build+boot cycle would confirm. Until then, the published patch enables
`auto-var-init` and documents emu-var as an optional fallback.

## 9. Lessons

- **For EDK2 on clang/FreeBSD, link with GNU `ld`, not lld** — GenFw's PE relocation path depends on it. Strings-resolve-wrong-but-code-runs is the tell.
- **Varying crash PC across boots ⇒ uninitialized memory**, not a miscompile; `-ftrivial-auto-var-init=zero` is the blunt, effective cure (especially with ECC off).
- **Same source, different compiler ⇒ different uninitialized-data behavior.** The GCC reference "worked" partly by luck of stack layout.
- Keep an independent recovery path (stock image + eMMC fallback) — firmware bring-up means many crash/recover cycles.
