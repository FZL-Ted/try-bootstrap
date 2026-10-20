#!/bin/bash
#
# 3-build-all.sh — run the complete bootstrap chain from the host compiler to
# GCC 10.4.0.
#
# The sequence is the same one documented in README.md. GNU make 4.4 is not
# built by this driver; run ./3-build-make.sh separately if you need it.
#
# Usage:
#   ./3-build-all.sh                 # full chain, JOBS defaults to nproc
#   JOBS=8 ./3-build-all.sh          # parallel make jobs
#   CPU_LIMIT=1800 ./3-build-all.sh  # per-make CPU-time limit (where supported)
#   RESET=0 ./3-build-all.sh         # do not reset the xcc tree before patching
#
# Every step is idempotent and logs under results/.
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

ROOTFS="$HERE/rootfs3"
LOGDIR="$HERE/results"
LOG="$LOGDIR/3-build-all.log"
mkdir -p "$LOGDIR"
exec > >(tee "$LOG") 2>&1

export JOBS="${JOBS:-$(nproc)}"
if [ -n "${CPU_LIMIT:-}" ]; then export CPU_LIMIT; fi
RESET="${RESET:-1}"

step() {
  printf '\n=======================================================================\n'
  printf '== %s\n' "$*"
  printf '=======================================================================\n'
}

trap 'echo "FAILED at: $CURRENT (see above and results/)" >&2' ERR
CURRENT="starting"

step "Step 1/17: seed xcc-boot and xcc-xcclib with the host compiler"
CURRENT="3-build-xcc-boot.sh"
if [ "$RESET" = 1 ]; then RESET=1 ./3-build-xcc-boot.sh; else ./3-build-xcc-boot.sh; fi

step "Step 2/17: build musl with xcc-xcclib (musl-1)"
CURRENT="3-build-musl-xcc.sh"
./3-build-musl-xcc.sh

step "Step 3/17: build xcc-musl"
CURRENT="3-build-xcc-musl.sh"
./3-build-xcc-musl.sh

step "Step 4/17: build GMP"
CURRENT="3-build-gmp.sh"
./3-build-gmp.sh

step "Step 5/17: build MPFR"
CURRENT="3-build-mpfr.sh"
./3-build-mpfr.sh

step "Step 6/17: build MPC"
CURRENT="3-build-mpc.sh"
./3-build-mpc.sh

step "Step 7/17: build zlib"
CURRENT="3-build-zlib.sh"
./3-build-zlib.sh

step "Step 8/17: build GNU binutils"
CURRENT="3-build-binutils.sh"
./3-build-binutils.sh

step "Step 9/17: build GCC 4.6 stage 1 with xcc-musl (all-gcc)"
CURRENT="3-build-gcc46-xcc.sh"
./3-build-gcc46-xcc.sh

step "Step 10/17: build musl-gcc with GCC 4.6 stage 1"
CURRENT="3-build-musl-gcc.sh"
./3-build-musl-gcc.sh

step "Step 11/17: build target libgcc with GCC 4.6 stage 1"
CURRENT="3-build-gcc46-xcc.sh (GOAL=all-target-libgcc)"
GOAL=all-target-libgcc ./3-build-gcc46-xcc.sh

step "Step 12/17: first GCC 4.6 stage-2 build (sysroot view)"
CURRENT="3-build-gcc46-stage2.sh (view mode)"
SYSROOT="$ROOTFS/usr/musl-gcc-sysroot" ./3-build-gcc46-stage2.sh

step "Step 13/17: switch the current rootfs to GCC 4.6 + musl-gcc"
CURRENT="3-adjust-rootfs-current.sh"
./3-adjust-rootfs-current.sh

step "Step 14/17: rebuild the four libraries with GCC 4.6 stage 1"
CURRENT="3-build-deps-gcc46.sh"
./3-build-deps-gcc46.sh

step "Step 15/17: final GCC 4.6 stage-2 build"
CURRENT="3-build-gcc46-stage2.sh (final)"
CLEAN=1 ./3-build-gcc46-stage2.sh

step "Step 16/17: build GCC 10.4.0"
CURRENT="3-build-gcc10.sh"
./3-build-gcc10.sh

step "Step 17/17: switch the current rootfs to GCC 10"
CURRENT="3-adjust-rootfs-current.sh (GCC_PREFIX=/usr/gcc10)"
GCC_PREFIX=/usr/gcc10 ./3-adjust-rootfs-current.sh

step "Final check"
CURRENT="final gcc-10 smoke test"
GCC10="$ROOTFS/usr/gcc10/bin/gcc"
[ -x "$GCC10" ] || { echo "missing $GCC10" >&2; exit 1; }
"$GCC10" --version | head -1
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/hello.c" <<'EOF'
#include <stdio.h>
int main(void) { puts("gcc-10 clean-build smoke OK"); return 0; }
EOF
"$ROOTFS/usr/bin/gcc" "$TMP/hello.c" -o "$TMP/hello"
"$TMP/hello"

echo
echo "=== build-all completed: GCC 10.4.0 is installed at $ROOTFS/usr/gcc10 ==="
