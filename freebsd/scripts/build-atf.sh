#!/usr/bin/env bash
# Build TF-A (BL2/BL31) + FIP + PBL with clang+lld.  Run build-uefi.sh first
# (the UEFI .fd is BL33) and build-rcw.sh (rcw_lx2160acex7.bin).
#
# Non-secure path (no OP-TEE / StandaloneMm).  TF-A links fine with clang+lld;
# only EDK2 needs GNU ld.  Goals are run separately so the recursive tools/fiptool
# make is not invoked concurrently by -j (which races and drops object files).
set -e
: "${ROOTDIR:?export ROOTDIR=/path/to/lx2160a_uefi first}"
. "$ROOTDIR/freebsd/scripts/env-freebsd.sh"
J=$(getconf _NPROCESSORS_ONLN)

export BL33="$WORKSPACE/Build/LX2160aCex7/RELEASE_CLANG38/FV/LX2160ACEX7_EFI.fd"
[ -f "$BL33" ] || { echo "MISSING BL33: $BL33 (run build-uefi.sh first)"; exit 1; }

cd "$ROOTDIR/build/arm-trusted-firmware"
rm -rf build
F="E=0 PLAT=lx2160acex7 CC=clang LD=ld.lld AR=llvm-ar OD=llvm-objdump OC=llvm-objcopy HOSTCC=cc \
   RCW=$ROOTDIR/build/rcw/lx2160acex7/rcws/rcw_lx2160acex7.bin \
   TRUSTED_BOARD_BOOT=0 GENERATE_COT=0 BOOT_MODE=sd SECURE_BOOT=false ENABLE_STACK_PROTECTION=1"

echo "ATF BUILD START $(date)"
# shellcheck disable=SC2086
gmake -j"$J" $F all   # bl2 + bl31 (parallel; no host-tool race here)
# shellcheck disable=SC2086
gmake        $F fip   # serial: fiptool + assemble fip.bin
# shellcheck disable=SC2086
gmake        $F pbl   # serial: bl2 PBL via create_pbl
echo "ATF BUILD DONE rc=$? $(date)"
ls -l build/lx2160acex7/release/bl2_sd.pbl build/lx2160acex7/release/fip.bin
