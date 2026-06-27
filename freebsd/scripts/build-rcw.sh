#!/usr/bin/env bash
# Build the RCW (Reset Configuration Word) for LX2160A CEX7.
#
# DDR_SPEED defaults to 2600 (SolidRun CEX7 with the shipped DIMM). Upstream
# runme.sh defaults to 2400 -- set SPEED to match YOUR board or memory will not
# train.  SERDES 8_5_2 = 8x10G (matches the dpl-eth.8x10g DPL the FDF embeds).
set -e
: "${ROOTDIR:?export ROOTDIR=/path/to/lx2160a_uefi first}"
. "$ROOTDIR/freebsd/scripts/env-freebsd.sh"

SERDES=${SERDES:-8_5_2}
SPEED=${SPEED:-2000_700_2600}

cd "$ROOTDIR/build/rcw/lx2160acex7"
IFS=_ read -r SP1 SP2 SP3 <<< "$SERDES"
export SP1 SP2 SP3 SRC1=1 SCL1=2 SPD1=1
envsubst < configs/lx2160a_serdes.def > configs/lx2160a_serdes.rcwi

IFS=_ read -r CPU SYS MEM <<< "$SPEED"
export CPU=${CPU::2}
export SYS=$(( 2 * ${SYS::2} )); export SYS=${SYS::-1}
export MEM=${MEM::2}
envsubst < configs/lx2160a_timings.def > configs/lx2160a_timings.rcwi
echo "RCW: SERDES=$SERDES SPEED=$SPEED -> MEM_PLL_RAT=$MEM"

rm -f rcws/*.bin
gmake
ls -l rcws/rcw_lx2160acex7.bin
