# FreeBSD-native build environment for lx2160a_uefi (clang compiler + GNU ld).
#
# Usage:
#   export ROOTDIR=/path/to/lx2160a_uefi   # the checkout root (this repo)
#   . freebsd/scripts/env-freebsd.sh
#
: "${ROOTDIR:?set ROOTDIR to the lx2160a_uefi checkout root first}"

export WORKSPACE="$ROOTDIR/build/tianocore"
export PACKAGES_PATH="$WORKSPACE/edk2:$WORKSPACE/edk2-platforms:$WORKSPACE/edk2-non-osi"
export PYTHON_COMMAND=python3

# EDK2 CLANG38 toolchain knobs: native base clang, llvm-objcopy for the RC step.
export CLANG38_BIN=/usr/bin/
export CLANG38_AARCH64_PREFIX=llvm-

# Prepend the gcc/g++/make/python -> clang/gmake/python3 shims (see bin/).
export PATH="$ROOTDIR/freebsd/scripts/bin:$PATH"
