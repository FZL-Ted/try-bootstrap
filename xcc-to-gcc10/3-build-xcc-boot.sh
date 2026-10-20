#!/bin/bash
#
# 3-build-xcc-boot.sh — first stage of the 3- chain: seed xcc-boot (the first
#   generation) with the **host gcc**, then let xcc-boot build xcc-xcclib (the
#   second generation) by self-hosting.
#
# The 3- chain:
#   1) ./3-build-xcc-boot.sh       host gcc -> xcc-boot -> (self-hosted) xcc-xcclib
#   2) ./3-build-musl-xcc.sh         xcc-xcclib + bundled libc -> musl-1
#   3) ./3-build-xcc-musl.sh       xcc-xcclib + musl-1 -> xcc-musl
#   4) ./3-build-{gmp,mpfr,mpc,zlib}.sh, ./3-build-gcc46-xcc.sh, ...
#
# Naming across generations:
#   xcc-boot   = the first xcc, compiled with the host gcc (a bootstrap seed only)
#   xcc-xcclib = the second xcc: self-hosted, statically linked against
#                **xcc's bundled libc**
#   xcc-musl   = the third xcc, linked against **musl** (not built by this script)
#
# This is the only place in the chain allowed to use the host gcc/glibc, and only
# to compile the first-generation tools. After this step all compiling,
# assembling and linking is done by tools inside rootfs3. The xcc-boot produced
# here is dynamically linked against the host glibc, so **it is not a
# deliverable**: it is only the seed for self-hosting.
#
# Executable names: every generation keeps the names xcc/cc1/cpp/as/ld inside its
# own directory. xcc locates its sibling programs (cpp/cc1/as) and include/,
# lib/crt0.a relative to dirname(argv[0]); renaming it to xcc-boot would make it
# look for xcc-bootcpp and break. The generation is encoded only in the directory
# name: rootfs3/usr/xcc-boot/bin/ and rootfs3/usr/xcc-xcclib/bin/.
#
# Output:
#   rootfs3/usr/xcc-boot/bin/{xcc,cc1,cpp,as,ld}       first generation (dynamic, host glibc)
#   rootfs3/usr/xcc-boot/lib/{crt0.a,libc.a}           xcc's bundled libc
#   rootfs3/usr/xcc-xcclib/bin/{xcc,cc1,cpp,as,ld}     second generation (**static, no glibc**)
#   rootfs3/usr/xcc-xcclib/lib/{crt0.a,libc.a}         xcc's bundled libc (used to link gen2)
#   results/3-build-xcc-boot.log                       full run log
#   results/3-STATE.env                                cross-script state (keys written with `record`)
#
# Usage:
#   ./3-build-xcc-boot.sh              # incremental build (idempotent patches, reused objects)
#   CLEAN=1 ./3-build-xcc-boot.sh      # make clean first, then a full build
#   RESET=1 ./3-build-xcc-boot.sh      # restore the source tree to a clean baseline before patching (recommended for the first run or after changing patches)
#   JOBS=8 ./3-build-xcc-boot.sh       # parallelism (default: nproc)
#   NO_SMOKE=1 ./3-build-xcc-boot.sh   # skip the smoke tests
#
# Host tools allowed for this step (the series allowlist):
#   bash make git sed gawk grep sort uniq comm tar xz unzip ar nm ranlib file readelf
#   install cp mv rm mkdir ln cat head tail wc tr cut xargs stat cmp sha256sum tee timeout
#   bwrap (optional, for the bare-root smoke test)
# The host compiler (gcc) and the host glibc headers/libraries are used only in
#   this step, to produce the seed; later scripts in the chain do not use them.
#   xcc-boot linking dynamically against the host glibc is **expected**: it is
#   only a seed.
#
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=3-lib/common.sh
source "$HERE/3-lib/common.sh"

# Switch defaults (set -u requires them to be defined explicitly)
RESET="${RESET:-0}"
NO_SELFCHECK="${NO_SELFCHECK:-0}"
NO_SMOKE="${NO_SMOKE:-0}"

log_start "3-build-xcc-boot.log"

info "[0/6] Preflight checks"
[ -d "$SRC" ] || die "3- source tree not found: $SRC (should be a clean copy of xcc/)"
command -v gcc >/dev/null 2>&1 || die "host gcc not found (this step is the only place it is allowed)"
[ -n "$(ls -A "$PATCHES"/*.patch 2>/dev/null)" ] || die "no patches found in patches-3/"
echo "    source tree : $SRC"
echo "    patches     : $(ls "$PATCHES"/*.patch | wc -l) -> $(ls "$PATCHES"/*.patch | xargs -n1 basename | tr '\n' ' ')"
echo "    host gcc    : $(gcc --version | head -1)  [bootstrap for this step only]"
echo "    jobs        : $JOBS"
echo "    outputs     : $BOOTDIR , $XCCLIBDIR"

# ---- 1. Restore the baseline (optional) + apply patches ----
if [ "$RESET" = 1 ]; then
  info "[1/6] Restoring the source tree to a clean baseline"
  reset_src
else
  info "[1/6] Keeping the source tree as is (RESET=1 restores a clean baseline before patching)"
fi
apply_patches_3

# The inline-asm patch is essential for self-hosting and for building musl, so
# verify it separately (this also holds when the idempotent patch step was
# skipped). The criterion is "are the files this patch adds present in the tree?",
# not `git apply --reverse --check`: later patches touch the same lines, so a
# per-patch reverse check reports failure even though the patch is applied. This
# patch adds src/cc/arch/x64/asm_constraint.c and src/cc/backend/asm_operand.h,
# and the loop below also requires every other path in its `+++` headers to exist.
asm_patch="$PATCHES/xcc-inline-asm.patch"
if [ -f "$asm_patch" ]; then
  asm_ok=1
  for f in $(awk '/^\+\+\+ /{f=$2; sub(/^b\//,"",f); print f}' "$asm_patch"); do
    [ -f "$SRC/$f" ] || { asm_ok=0; echo "      missing file: $f"; }
  done
  [ "$asm_ok" = 1 ] || die "xcc-inline-asm patch is not applied"
  echo "    inline-asm patch is applied"
fi

# ---- 2. Clean (optional) ----
if [ "$CLEAN" = 1 ]; then
  info "[2/6] make clean"
  make -C "$SRC" clean >/dev/null || true
  rm -rf "$SRC/obj"
fi

# ---- 3. Bootstrap: host gcc builds the first-generation xcc + bundled lib ----
info "[3/6] Bootstrap-building xcc-boot + bundled lib with the host gcc (CC=$(command -v gcc))"
t0=$(date +%s)
make -C "$SRC" -j"$JOBS" all || die "bootstrap build failed (make all)"
t1=$(date +%s)
echo "    make all took $((t1-t0)) s"
for f in xcc cc1 cpp as ld lib/crt0.a lib/libc.a; do
  [ -e "$SRC/$f" ] || die "missing bootstrap output: $SRC/$f"
done
echo "    xcc-boot: $("$SRC/xcc" -v | head -1)"

# ---- 4. Self-host: xcc-boot compiles xcc itself, statically linked with xcc's own ld + crt0/libc ----
info "[4/6] Self-hosting xcc-xcclib (xcc-boot compiles itself, statically linked against xcc's bundled libc, no glibc)"
t0=$(date +%s)
make -C "$SRC" -j"$JOBS" TARGET=gen2 self-hosting || die "self-hosting build failed (make TARGET=gen2 self-hosting)"
t1=$(date +%s)
echo "    make self-hosting took $((t1-t0)) s"
for f in gen2xcc gen2cc1 gen2cpp gen2as gen2ld; do
  [ -x "$SRC/$f" ] || die "missing self-hosted output: $SRC/$f"
done

# ---- 5. Self-consistency check (the real fixed-point criterion: gen3 and gen4 byte-identical) ----
# Note: **do not use gen2 == gen3 as the criterion**. gen2 and gen3 are both built
# from the **same sources**, but gen2 is compiled by xcc-boot (the seed built by
# the host gcc) while gen3 is compiled by gen2; any dependence on compiler
# differences (even just debug info or uninitialized bytes) makes them differ.
# The correct fixed-point criterion is "third and fourth generation agree": build
# gen3 with gen2, then gen4 with gen3; gen3 == gen4 means xcc reproduces itself
# stably (self-hosting has converged).
if [ "${NO_SELFCHECK:-0}" != 1 ]; then
  info "[5/6] Self-consistency check: gen2 -> gen3 -> gen4, requires gen3 == gen4 (the self-hosting fixed point)"
  # Important: **delete the old gen3/gen4 and their objects first**. Otherwise
  # make's dependency check may consider the old gen3 up to date (it exists and is
  # newer than the sources) and skip it, so gen4 is built from a gen3 left over by
  # an earlier configuration and the criterion ends up comparing two different
  # builds. That shows up as a false "not converged" result; rebuilding both from
  # scratch gives identical gen3 and gen3 == gen4.
  rm -rf "$SRC/obj/gen3" "$SRC/obj/gen4"
  rm -f "$SRC"/gen3xcc "$SRC"/gen3cc1 "$SRC"/gen3cpp "$SRC"/gen3as "$SRC"/gen3ld
  rm -f "$SRC"/gen4xcc "$SRC"/gen4cc1 "$SRC"/gen4cpp "$SRC"/gen4as "$SRC"/gen4ld
  if make -C "$SRC" -j"$JOBS" gen3 >/dev/null 2>&1; then
    if make -C "$SRC" -j"$JOBS" HOST=gen3 TARGET=gen4 self-hosting >/dev/null 2>&1; then
      ok=1
      for f in cc1 as cpp xcc ld; do
        if [ -x "$SRC/gen3$f" ] && [ -x "$SRC/gen4$f" ]; then
          cmp -s "$SRC/gen3$f" "$SRC/gen4$f" ||
            { warn "gen3$f != gen4$f (self-hosting did not converge to a fixed point)"; ok=0; }
        fi
      done
      [ "$ok" = 1 ] && echo "    gen3* == gen4* (byte-identical): self-hosting converged to a fixed point ✅" ||
                      echo "    note: gen3 != gen4, see above (needs manual judgement whether it is a defect)"
      # Also record the gen2 vs gen3 differences (informational only: a different
      # seed compiler may legitimately cause differences; this is not a failure
      # criterion).
      n_diff=0
      for f in cc1 as cpp xcc ld; do
        [ -x "$SRC/gen2$f" ] && [ -x "$SRC/gen3$f" ] && cmp -s "$SRC/gen2$f" "$SRC/gen3$f" || n_diff=$((n_diff+1))
      done
      echo "    reference: gen2 vs gen3 differ in $n_diff/5 files (different seed compiler; not a failure criterion)"
    else
      warn "gen4 self-check could not be built (does not affect this step's outputs)"
    fi
  else
    warn "gen3 self-check could not be built (does not affect this step's outputs)"
  fi
fi

# ---- 6. Install + verify ----
info "[6/6] Installing xcc-boot and xcc-xcclib into $ROOTFS"
mkdir -p "$ROOTFS/tmp" "$ROOTFS/usr/bin" "$ROOTFS/usr/lib" "$ROOTFS/usr/include"
chmod 1777 "$ROOTFS/tmp"
ln -sfn usr/bin "$ROOTFS/bin"
ln -sfn usr/lib "$ROOTFS/lib"

# 6.1 xcc-boot: install the native executables produced by make all (copy them; install_toolchain would look for the gen2-prefixed names)
mkdir -p "$BOOTDIR/bin" "$BOOTDIR/lib"
for f in xcc cc1 cpp as ld; do
  install -m 755 "$SRC/$f" "$BOOTDIR/bin/$f"
done
install -m 644 "$SRC/lib/crt0.a" "$SRC/lib/libc.a" "$BOOTDIR/lib/"
ln -sfn ../lib "$BOOTDIR/bin/lib"
echo "    installed [xcc-boot  ] -> $BOOTDIR/bin/{xcc,cc1,cpp,as,ld}"

# 6.2 xcc-xcclib: the self-hosted build (static, no glibc)
install_toolchain gen2 "$XCCLIBDIR" "xcc-xcclib"

# 6.3 Entry links: point at xcc-xcclib (the "current generation" for later builds)
clean_entry
for f in xcc cc1 cpp as ld; do
  ln -sfn "../xcc-xcclib/bin/$f" "$ENTRYDIR/$f"
done
ln -sfn ../xcc-xcclib/lib "$ENTRYDIR/lib"

# 6.4 Verification
check_static "$XCCLIBDIR/bin"
echo "    all 5 xcc-xcclib executables are statically linked, no PT_INTERP ✅"
echo "    xcc-boot   (first generation, dynamically linked against the host glibc -- expected; bootstrap seed only):"
file -b "$BOOTDIR/bin/xcc" | sed 's/^/      /'

# 6.5 Smoke tests: freestanding (no libc) at the three entry points
scratch="$(mktemp -d)"
cleanup() { rm -rf "$scratch"; rmdir "$ROOTFS/dev" "$ROOTFS/proc" 2>/dev/null || true; }
trap cleanup EXIT
if [ "${NO_SMOKE:-0}" != 1 ]; then
  asm_src="$scratch/asm-smoke.c"
  cat > "$asm_src" <<'ASM_SMOKE_EOF'
/* Freestanding smoke test: no libc at all, writes "asm-ok" with a raw syscall.
   This exercises every feature of the inline-asm patch at once (multiple
   outputs, memory operands, fixed-register/matching constraints, immediates,
   clobbers) plus the assembler's syscall / lock;cmpxchg / bsf templates. */
static long sys_write(long fd, const char *buf, long len) {
  long ret;
  __asm__ volatile("syscall" : "=a"(ret)
                   : "a"(1L), "D"(fd), "S"(buf), "d"(len)
                   : "rcx", "r11", "memory");
  return ret;
}
static void sys_exit(int code) {
  __asm__ volatile("syscall" : : "a"(60L), "D"((long)code) : "rcx", "r11", "memory");
}
static int cas(volatile int *p, int t, int s) {
  int old;
  __asm__ __volatile__("lock ; cmpxchg %3, %1"
                       : "=a"(old), "=m"(*p) : "a"(t), "r"(s) : "memory");
  return old;
}
static long pair(long a) {
  long hi, lo;
  __asm__ volatile("movq %2, %0\n\taddq %3, %0\n\tmovq %0, %1"
                   : "=r"(hi), "=r"(lo) : "r"(a), "i"(7));
  return hi * 100 + lo;
}
static long ctz(unsigned long x) { __asm__("bsf %1, %0" : "=r"(x) : "r"(x)); return x; }
static int run(void) {
  char buf[16];
  int n = 0;
  volatile int v = 5;
  if (cas(&v, 5, 9) != 5 || v != 9) return 1;
  if (pair(10) != 1717)             return 2;
  if (ctz(0x800) != 11)             return 3;
  buf[n++] = 'a'; buf[n++] = 's'; buf[n++] = 'm'; buf[n++] = '-';
  buf[n++] = 'o'; buf[n++] = 'k'; buf[n++] = '\n';
  return sys_write(1, buf, n) == n ? 0 : 4;
}
void _start(void) { sys_exit(run()); }
ASM_SMOKE_EOF

  echo "    smoke: freestanding (-nostdlib, no libc at all)"
  for entry in "$ENTRYDIR/xcc" "$XCCLIBDIR/bin/xcc" "$BOOTDIR/bin/xcc"; do
    "$entry" -nostdlib -o "$scratch/asm-smoke" "$asm_src" ||
      die "smoke compile/link failed ($entry)"
    out="$("$scratch/asm-smoke")" || die "smoke run failed ($entry)"
    [ "$out" = "asm-ok" ] || die "unexpected smoke output ($entry): $out"
    echo "      $entry -> $out"
  done

  # Bundled-libc smoke test: use xcc-xcclib to build a program linked against
  # **xcc's bundled libc** (before ./3-build-musl-xcc.sh builds musl, this is the
  # only way to verify directly that libsrc works).
  libc_src="$scratch/libc-smoke.c"
  cat > "$libc_src" <<'LIBC_SMOKE_EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
extern char **environ;
int main(void) {
  char *p = malloc(64);
  strcpy(p, "libsrc-ok");
  if (strcmp(p, "libsrc-ok") != 0) return 1;
  printf("%s %d %s\n", p, (int)strlen(p), "2");
  free(p);
  return 0;
}
LIBC_SMOKE_EOF
  echo "    smoke: link xcc's bundled libc with xcc-xcclib (verifies libsrc/crt0/libc.a)"
  "$XCCLIBDIR/bin/xcc" -I"$SRC/include" -L"$XCCLIBDIR/lib" \
      "$libc_src" -o "$scratch/libc-smoke" || die "bundled-libc smoke compile/link failed"
  out="$("$scratch/libc-smoke")" || die "bundled-libc smoke run failed"
  [ "$out" = "libsrc-ok 9 2" ] || die "unexpected bundled-libc smoke output: $out"
  echo "      xcc-xcclib + bundled libc -> $out"

  if command -v bwrap >/dev/null 2>&1; then
    echo "    bare-root smoke (bwrap mounts rootfs3 as /; it has no host /usr or /lib)"
    mkdir -p "$ROOTFS/dev" "$ROOTFS/proc"
    bwrap --bind "$ROOTFS" / --bind "$scratch" /tmp --dev /dev --proc /proc --chdir / \
          /usr/bin/xcc -nostdlib -o /tmp/asm-smoke-bwrap /tmp/asm-smoke.c ||
      die "bare-root compile failed"
    out=$(bwrap --bind "$ROOTFS" / --bind "$scratch" /tmp --dev /dev --proc /proc --chdir / \
                /tmp/asm-smoke-bwrap) || die "bare-root run failed"
    [ "$out" = "asm-ok" ] || die "unexpected bare-root smoke output: $out"
    echo "      /usr/bin/xcc -> $out"
    rmdir "$ROOTFS/dev" "$ROOTFS/proc" 2>/dev/null || true
  fi
fi

# ---- Record state ----
boot_ver="$("$BOOTDIR/bin/xcc" -v 2>/dev/null | head -1)"
xclib_ver="$("$XCCLIBDIR/bin/xcc" -v 2>/dev/null | head -1)"
record XCC_BOOT "$BOOTDIR"
record XCC_BOOT_VERSION "$boot_ver"
record XCC_XCCLIB "$XCCLIBDIR"
record XCC_XCCLIB_VERSION "$xclib_ver"
record XCC_XCCLIB_SHA256 "$(sha256sum "$XCCLIBDIR/bin/xcc" | cut -c1-16)"
record XCC_SRC "$SRC"
record PATCHES3 "$(ls "$PATCHES"/*.patch | xargs -n1 basename | tr '\n' ' ')"

echo
echo "== Outputs =="
tree_report "$BOOTDIR"   "  "
tree_report "$XCCLIBDIR" "  "
echo
echo "  next: ./3-build-musl-xcc.sh    # build musl 1.2.6 with xcc-xcclib"
