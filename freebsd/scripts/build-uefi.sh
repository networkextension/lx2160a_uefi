#!/usr/bin/env bash
# Build EDK2 BaseTools + the LX2160aCex7 UEFI firmware (.fd) with clang (CLANG38
# toolchain) and GNU ld.  Apply the patches in freebsd/patches/ first.
set -e
: "${ROOTDIR:?export ROOTDIR=/path/to/lx2160a_uefi first}"
. "$ROOTDIR/freebsd/scripts/env-freebsd.sh"
J=$(getconf _NPROCESSORS_ONLN)

cd "$WORKSPACE"
# BaseTools C utilities (GenFw, GenFv, ...) build with the gcc->clang shim.
gmake -C edk2/BaseTools -j"$J" PYTHON_COMMAND=python3
# shellcheck disable=SC1091
source edk2/edksetup.sh BaseTools

echo "UEFI BUILD START $(date)"
build -p "edk2-platforms/Platform/SolidRun/LX2160aCex7/LX2160aCex7.dsc" \
  -a AARCH64 -t CLANG38 -b RELEASE -n "$J" \
  -y "$ROOTDIR/build-report.log" -D AARCH64_GOP_ENABLE=TRUE
echo "UEFI BUILD DONE rc=$? $(date)"
ls -l "$WORKSPACE/Build/LX2160aCex7/RELEASE_CLANG38/FV/LX2160ACEX7_EFI.fd"
