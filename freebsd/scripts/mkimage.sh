#!/usr/bin/env bash
# Assemble the 8 MB SD boot image: RCW+BL2 PBL @ block 8, DDR-PHY FIP @ block 256,
# FIP (BL31+BL33) @ block 2048.  Run build-rcw.sh, build-uefi.sh, build-atf.sh first.
set -e
: "${ROOTDIR:?export ROOTDIR=/path/to/lx2160a_uefi first}"
R="$ROOTDIR/build/arm-trusted-firmware/build/lx2160acex7/release"
DDR="$ROOTDIR/build/ddr-phy-binary/lx2160a/fip_ddr.bin"
OUT="${1:-$ROOTDIR/images/lx2160acex7_freebsd_sd.img}"

mkdir -p "$(dirname "$OUT")"
truncate -s 8M "$OUT"
dd if="$R/bl2_sd.pbl" of="$OUT" bs=512 seek=8    conv=notrunc
dd if="$DDR"          of="$OUT" bs=512 seek=256  conv=notrunc
dd if="$R/fip.bin"    of="$OUT" bs=512 seek=2048 conv=notrunc
echo "wrote $OUT"
ls -l "$OUT"
