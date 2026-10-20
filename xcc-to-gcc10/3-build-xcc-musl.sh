#!/bin/bash
#
# 3-build-xcc-musl.sh — builds the third-generation compiler, **xcc-musl**, from
#   **xcc-xcclib (second generation, linked against xcc's bundled libc) + musl-1**.
#
# Generations of the 3- chain:
#   1) ./3-build-xcc-boot.sh    host gcc -> xcc-boot -> (self-hosted, bundled libc) xcc-xcclib
#   2) ./3-build-musl-xcc.sh      xcc-xcclib + bundled libc -> musl-1 (also lands the global sysroot)
#   3) ./3-build-xcc-musl.sh    xcc-xcclib + musl-1 -> xcc-musl          <- this script
#   4) ./3-build-{gmp,mpfr,mpc,zlib}.sh, ./3-build-gcc46-xcc.sh, ...
#
# Approach: reuse xcc's own Makefile self-hosting target and replace only the
# compiler with the musl-targeting wrapper:
#
#   make CC=./xcc-musl-cc HOST=gen2 TARGET=gen3 self-hosting
#
#   * `HOST=gen2` makes the Makefile treat `gen2xcc/gen2cc1/gen2cpp/gen2as/gen2ld`
#     as parent dependencies (the script links **xcc-xcclib**'s binaries under
#     those names into the build tree);
#   * `CC=./xcc-musl-cc` overrides the Makefile's `./$(HOST)xcc`: the build goes
#     through the wrapper, whose **target libc is musl-1** (it injects -nostdlib,
#     musl's crt1.o/crti.o/crtn.o, -L<sysroot>/lib and -lc; see the wrapper's
#     header);
#   * `TARGET=gen3` -> product names `gen3xcc/gen3cc1/gen3cpp/gen3as/gen3ld`.
#
# Why not just run `make gen3`: that target depends on `gen2`, which depends on
# `all` (a host-gcc build). The parent compiler here is the already-installed
# xcc-xcclib, so it should not be rebuilt with the host gcc.
#
# Output:
#   rootfs3/usr/xcc-musl/bin/{xcc,cc1,cpp,as,ld}    third generation (static, linked
#                                                  against musl-1; no glibc and no
#                                                  longer xcc's bundled libc)
#   rootfs3/usr/xcc-musl/bin/xcc-musl-cc            CC wrapper (used by the four libs / GCC)
#   rootfs3/usr/xcc-musl/shim/stdarg.h              stdarg shim (xcc's stdarg.h plus the
#                                                   __isoc_va_list alias)
#   rootfs3/usr/xcc-musl/shim/bits/alltypes.h       va_list bridge, written by
#                                                   ./3-build-musl-xcc.sh [5.5.0]
#   rootfs3/usr/xcc-musl/asm/                       hand-written longjmp.s/sigsetjmp.s
#                                                   (written by ./3-build-musl-xcc.sh;
#                                                   this script only ensures the
#                                                   directory exists)
#   rootfs3/usr/xcc-musl/{include,lib}              symlinks for xcc's dirname(argv[0])
#                                                   lookup (targets derived from SYSROOT)
#   results/3-build-xcc-musl.log                    full run log
#
# Usage:
#   ./3-build-xcc-musl.sh              # build + install + verify + smoke test
#   CLEAN=1 ./3-build-xcc-musl.sh      # clear obj/gen3* first (recommended after changing the patch set)
#   NO_SMOKE=1 ./3-build-xcc-musl.sh   # skip the smoke tests
#   JOBS=8 ./3-build-xcc-musl.sh       # parallelism
#
# Host tools allowed for this step (the series allowlist):
#   bash make git sed gawk grep sort file readelf install cp mv rm mkdir ln cat head
#   tail wc tr cut xargs stat sha256sum tee timeout bwrap (optional).
# No host gcc/glibc: compiling is done by the xcc toolchain in rootfs3 and the
# libc linked is musl-1.
#
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=3-lib/common.sh
source "$HERE/3-lib/common.sh"

CLEAN="${CLEAN:-0}"
NO_SMOKE="${NO_SMOKE:-0}"
# The **sysroot** the include/lib symlinks below are derived from. It must name a
# snapshot directory under rootfs3/usr (for example $MUSL1): the links are built as
# ../$(basename "$SYSROOT")/{include,lib}. The default is musl-1, the target libc of
# this xcc generation. The compiler used for compiling and linking gets its sysroot
# from the CC wrapper, not from this variable.
SYSROOT="${SYSROOT:-$MUSL1}"

log_start "3-build-xcc-musl.log"

info "[0/6] Preflight checks"
[ -d "$SRC/.git" ] || die "3- source tree not found: $SRC"
for f in xcc cc1 cpp as ld; do
  [ -x "$XCCLIBDIR/bin/$f" ] || die "missing $XCCLIBDIR/bin/$f (run ./3-build-xcc-boot.sh first)"
done
[ -f "$MUSL1/lib/libc.a" ] || die "missing $MUSL1/lib/libc.a (run ./3-build-musl-xcc.sh first)"
echo "    compiler (parent) : $XCCLIBDIR/bin/xcc  ($(sha256sum "$XCCLIBDIR/bin/xcc" | cut -c1-16))"
echo "    target libc       : musl-1  $MUSL1/lib/libc.a  ($(sha256sum "$MUSL1/lib/libc.a" | cut -c1-16))"
echo "    host gcc          : not used"
echo "    jobs              : $JOBS"

# ---- 1. Apply patches (the same patches-3/*.patch set as ./3-build-xcc-boot.sh, idempotent) ----
info "[1/6] Confirming the patches are applied"
apply_patches_3

# The CC wrapper is needed for the build below: it is the compiler that turns the
# xcc sources into the third generation. Install it first; while $MUSLDIR/bin/xcc
# does not exist yet, the wrapper falls back to xcc-xcclib.
mkdir -p "$MUSLDIR/bin"
install -m 755 "$ROOT/3-build-xcc-musl-cc.sh" "$MUSLDIR/bin/xcc-musl-cc"

# Keep the wrapper's SHIM pointing at shim/ (the directory this script populates):
# if the installed copy still names $DIR/include, rewrite it.
if grep -q 'SHIM="\$DIR/include"' "$MUSLDIR/bin/xcc-musl-cc" 2>/dev/null; then
  sed -i 's|SHIM="\$DIR/include"|SHIM="$DIR/shim"|' "$MUSLDIR/bin/xcc-musl-cc"
fi

# ---- 2. Prepare the build tree: parent binaries + wrapper link ----
info "[2/6] Preparing the build tree (gen2* = xcc-xcclib, the xcc-musl-cc wrapper)"
for f in xcc cc1 cpp as ld; do
  ln -sfn "$XCCLIBDIR/bin/$f" "$SRC/gen2$f"
done
ln -sfn "$MUSLDIR/bin/xcc-musl-cc" "$SRC/xcc-musl-cc"
[ -x "$SRC/xcc-musl-cc" ] || die "wrapper symlink failed: $SRC/xcc-musl-cc"
# The stdarg shim the wrapper injects with -I<shim> must already exist for the
# first compile. Create it early if missing; it is refreshed again after the
# install step below.
if [ ! -f "$MUSLDIR/shim/stdarg.h" ]; then
  mkdir -p "$MUSLDIR/shim"
  cp -f "$SRC/include/stdarg.h" "$MUSLDIR/shim/stdarg.h"
  cat >> "$MUSLDIR/shim/stdarg.h" <<'EOF'

/* appended by 3-build-xcc-musl.sh: in musl, __isoc_va_list is a synonym for va_list */
typedef __builtin_va_list __isoc_va_list;
EOF
fi
mkdir -p "$MUSLDIR/asm"
echo "    gen2* -> $XCCLIBDIR/bin/{xcc,cc1,cpp,as,ld}"
echo "    xcc-musl-cc -> $MUSLDIR/bin/xcc-musl-cc"

if [ "$CLEAN" = 1 ]; then
  info "[2b/6] Cleaning obj/gen3*"
  rm -rf "$SRC/obj/gen3" "$SRC"/gen3xcc "$SRC"/gen3cc1 "$SRC"/gen3cpp "$SRC"/gen3as "$SRC"/gen3ld
fi

# ---- 3. Self-host: build the third generation with the wrapper (xcc-xcclib + musl-1) ----
info "[3/6] make CC=./xcc-musl-cc HOST=gen2 TARGET=gen3 self-hosting"
t0=$(date +%s)
make -C "$SRC" -j"$JOBS" CC=./xcc-musl-cc HOST=gen2 TARGET=gen3 self-hosting \
  || die "xcc-musl build failed (make ... self-hosting)"
t1=$(date +%s)
echo "    took $((t1-t0)) s"
for f in gen3xcc gen3cc1 gen3cpp gen3as gen3ld; do
  [ -s "$SRC/$f" ] || die "missing/empty build output: $SRC/$f"
done
# xcc's driver is a cpp | cc1 | as pipeline: if an upstream stage is killed, as
# still writes a 384-byte empty ELF and exits 0, so "the file exists" is not a
# success criterion — check the size.
for f in gen3xcc gen3cc1 gen3cpp gen3as gen3ld; do
  sz=$(stat -c%s "$SRC/$f")
  [ "$sz" -gt 20000 ] || die "$f is only $sz bytes, probably an empty ELF (an upstream pipeline stage failed)"
done

# 4.0 The CC wrapper was installed before the build (step 1); it is used by the
#     four libraries and GCC. Its default sysroot is the global sysroot
#     ($ROOTFS/usr, landed by ./3-build-musl-xcc.sh [5.5]; ./3-adjust-rootfs-current.sh
#     later repoints it at musl-gcc). Point it elsewhere with XCC_SYSINC /
#     XCC_SYSLIB.
# ---- 4. Install ----
info "[4/6] Installing into $MUSLDIR"
mkdir -p "$MUSLDIR/bin"
for f in xcc cc1 cpp as ld; do
  install -m 755 "$SRC/gen3$f" "$MUSLDIR/bin/$f"
done
# Entry links: point at the third generation (the "current generation" used by the
# four libs / GCC)
clean_entry
for f in xcc cc1 cpp as ld; do
  ln -sfn "../xcc-musl/bin/$f" "$ENTRYDIR/$f"
done
ln -sfn "../$(basename "$SYSROOT")/include" "$ENTRYDIR/include"
ln -sfn "../$(basename "$SYSROOT")/lib" "$ENTRYDIR/lib"
ln -sfn ../xcc-musl/bin/xcc-musl-cc "$ENTRYDIR/xcc-musl-cc"
# The toolchain's own include/lib entries: the xcc driver looks for `<dir>/include`
# and `<dir>/lib` based on dirname(argv[0]) (src/xcc/main.c: `-idirafter
# <root>/include` and, when linking, `-L<root>/lib`), so these are symlinks whose
# targets are derived from SYSROOT.
# Layout notes (learned the hard way; do not change casually):
#   * the xcc driver adds -idirafter <dirname(argv[0])>/include, so $MUSLDIR/include
#     must be the include directory of the sysroot to use by default;
#   * the wrapper injects `-I$DIR/shim` first, because musl's bits/alltypes.h needs
#     `#include <stdarg.h>` to pick up xcc's va_list implementation. The shim holds
#     stdarg.h and the va_list-bridge bits/alltypes.h; the musl headers themselves
#     come from the sysroot (-idirafter) or, when building musl, from its source
#     tree.
#     ⚠️ Never mirror the whole musl header set in the shim: it would be searched
#     before musl's own `src/include`, hide the `hidden` macro used for kernel
#     headers, and in practice made 871 musl files fail to compile.
rm -rf "$MUSLDIR/include" "$MUSLDIR/lib"
ln -sfn "../$(basename "$SYSROOT")/include" "$MUSLDIR/include"
rm -f "$MUSLDIR/lib"
ln -sfn "../$(basename "$SYSROOT")/lib" "$MUSLDIR/lib"

# stdarg shim: copy it from the work tree (which already has the stdarg hygiene
# patch) into $MUSLDIR/shim/.
# ⚠️ Refresh stdarg.h only; **do not rm -rf the whole shim directory**: the
#    shim/bits/alltypes.h va_list bridge is written by ./3-build-musl-xcc.sh [5.5.0]
#    and is part of the xcc overlay layer. Wiping the shim and then rerunning this
#    step after musl-1 removes the bridge, and the smoke test immediately fails
#    with `bits/alltypes.h(326): typedef __builtin_va_list va_list;`.
mkdir -p "$MUSLDIR/shim"
cp -f "$SRC/include/stdarg.h" "$MUSLDIR/shim/stdarg.h"
cat >> "$MUSLDIR/shim/stdarg.h" <<'EOF'

/* appended by 3-build-xcc-musl.sh: in musl, __isoc_va_list is a synonym for va_list */
typedef __builtin_va_list __isoc_va_list;
EOF

# ---- 5. Verify: static, no PT_INTERP, and **not** linked against xcc's bundled libc ----
info "[5/6] Verification"
check_static "$MUSLDIR/bin"
echo "    all 5 executables are statically linked, no PT_INTERP ✅"
# Key criterion: the third generation is a musl-linked build and must not use
# symbols from xcc's bundled libc. Many symbol names overlap between musl and the
# bundled libc, so use __libc_start_main (the entry that musl's crt1.o calls) as
# the sentinel: it must be present, otherwise the binary was probably not linked
# against musl (warn only, because the build itself already succeeded).
if nm "$MUSLDIR/bin/xcc" 2>/dev/null | grep -q '__libc_start_main'; then
  echo "    contains __libc_start_main (the entry path musl's crt1.o uses) ✅"
else
  warn "__libc_start_main not found in xcc -- the binary may not be linked against musl"
fi
for f in xcc cc1 cpp as ld; do
  printf '    %-4s %8s bytes  sha256=%s\n' "$f" "$(stat -c%s "$MUSLDIR/bin/$f")" \
    "$(sha256sum "$MUSLDIR/bin/$f" | cut -c1-16)"
done

# ---- 6. Smoke tests ----
if [ "${NO_SMOKE:-0}" != 1 ]; then
  info "[6/6] Smoke tests"
  scratch="$(mktemp -d)"
  cleanup() { rm -rf "$scratch"; rmdir "$ROOTFS/dev" "$ROOTFS/proc" 2>/dev/null || true; }
  trap cleanup EXIT

  # 6.1 Build and run an ordinary program with xcc-musl, through the wrapper
  #     (target = musl in the current global sysroot).
  #     ⚠️ After ./3-adjust-rootfs-current.sh repoints the sysroot at musl-gcc,
  #     rerunning this step requires pointing the target back at musl-1:
  #     XCC_SYSINC=$ROOTFS/usr/musl-1/include XCC_SYSLIB=$ROOTFS/usr/musl-1/lib .
  #     Going through the **CC wrapper** is required: musl's <stdio.h> declares
  #     __isoc_va_list (gated by __NEED___isoc_va_list in bits/alltypes.h) as
  #     __builtin_va_list, a type xcc only knows from its own stdarg.h, which the
  #     shim provides together with the __isoc_va_list alias. Calling xcc directly
  #     without -I<shim> leaves the type undefined and yields
  #     `stdio.h(116): ';' or ',' expected` (observed in practice). The wrapper
  #     also injects musl's crt*.o and -lc.
  cat > "$scratch/t.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(void) {
  char *p = malloc(80000);
  if (!p) return 1;
  strcpy(p, "xcc-musl");
  printf("%s %zu %.3f %d\n", p, strlen(p), 1.0/3.0, (int)sizeof(void*));
  free(p);
  return 0;
}
EOF
  "$MUSLDIR/bin/xcc-musl-cc" "$scratch/t.c" -o "$scratch/t" || die "xcc-musl compile/link failed"
  out="$("$scratch/t")" || die "xcc-musl smoke run failed"
  echo "    xcc-musl (via xcc-musl-cc, sysroot=$SYSROOT) -> $out"
  [ "$out" = "xcc-musl 8 0.333 8" ] || die "unexpected smoke output: $out"
  file -b "$scratch/t" | sed 's/^/      /'

  # 6.1b Fix verification: the patches that must keep working on musl-1
  #      (xcc-declit-signed, xcc-cmp-const-fold, xcc-strtod-correct-rounding,
  #      xcc-mov-const-flonum-cast, xcc-ternary-qualified-struct)
  cat > "$scratch/accept.c" <<'EOF'
#include <stdio.h>
#include <limits.h>
#include <float.h>
typedef struct { int a; } S;
static S pick(const S *p, const S *q) { return *(1 ? p : q); }   /* ternary-qualified-struct */
static double dbl;                                                /* mov-const-flonum-cast */
int main(void) {
  volatile long y = 0;
  printf("declit: (y <= LONG_MIN+3) = %d (expect 0)\n", (y <= LONG_MIN + 3));
  printf("cmpfold: (4294967296LL < 1) = %d (expect 0)\n", (4294967296LL < 1));
  printf("strtod: DBL_MIN=%.20e\n", DBL_MIN);
  printf("strtod: TRUE_MIN=%.20e\n", DBL_TRUE_MIN);
  { long long n; double s; n = s = 0; dbl = s + 1.5; printf("flonum-cast: %.1f %d\n", dbl, (int)n); }
  return 0;
}
EOF
  "$MUSLDIR/bin/xcc-musl-cc" "$scratch/accept.c" -o "$scratch/accept" || die "acceptance program compile failed"
  acc="$("$scratch/accept")" || die "acceptance program run failed"
  echo "$acc" | sed 's/^/      /'
  echo "$acc" | grep -q '^declit: (y <= LONG_MIN+3) = 0' || die "declit-signed fix is not working"
  echo "$acc" | grep -q '^cmpfold: (4294967296LL < 1) = 0' || die "cmp-const-fold fix is not working"
  echo "$acc" | grep -q '^strtod: DBL_MIN=2.22507385850720138309e-308' || die "strtod fix is not working"
  echo "$acc" | grep -q '^strtod: TRUE_MIN=4.94065645841246544177e-324' || die "strtod subnormal fix is not working"
  echo "$acc" | grep -q '^flonum-cast: 1.5 0' || die "mov-const-flonum-cast fix is not working"

  # 6.2 Bare-root smoke test (no host /usr or /lib under the root; the paths below
  #     assume rootfs3 is mounted as /, i.e. the default global sysroot).
  #     Note: **do not** call xcc-musl-cc in the bare root — it is a bash script
  #     and rootfs3 has no /bin/bash (`execvp ... No such file or directory`,
  #     observed). Call xcc directly and spell out what the wrapper injects
  #     (-I shim, musl crt*.o, -L, -lc, -nostdlib). This also shows that all flags
  #     the wrapper injects are ordinary compiler flags.
  if command -v bwrap >/dev/null 2>&1; then
    echo "    bare-root smoke (bwrap mounts rootfs3 as /, calling /usr/xcc-musl/bin/xcc directly)"
    mkdir -p "$ROOTFS/dev" "$ROOTFS/proc"
    bwrap --bind "$ROOTFS" / --bind "$scratch" /tmp --dev /dev --proc /proc --chdir / \
          /usr/xcc-musl/bin/xcc -I/usr/xcc-musl/shim -idirafter /usr/include \
          -nostdlib -o /tmp/t-bwrap /tmp/t.c \
          /usr/lib/crt1.o /usr/lib/crti.o /usr/lib/crtn.o -L/usr/lib -lc \
      || die "bare-root compile failed"
    out=$(bwrap --bind "$ROOTFS" / --bind "$scratch" /tmp --dev /dev --proc /proc --chdir / \
                /tmp/t-bwrap) || die "bare-root run failed"
    [ "$out" = "xcc-musl 8 0.333 8" ] || die "unexpected bare-root smoke output: $out"
    echo "      /usr/xcc-musl/bin/xcc -> $out"
    rmdir "$ROOTFS/dev" "$ROOTFS/proc" 2>/dev/null || true
  fi
fi

# ---- Record state ----
record XCC_MUSL "$MUSLDIR"
record XCC_MUSL_VERSION "$("$MUSLDIR/bin/xcc" -v 2>/dev/null | head -1)"
record XCC_MUSL_SHA256 "$(sha256sum "$MUSLDIR/bin/xcc" | cut -c1-16)"
record XCC_MUSL_LIBC "musl-1"

echo
echo "== Outputs =="
tree_report "$MUSLDIR" "  "
echo
echo "  next: ./3-build-gmp.sh       # build the four libraries with xcc-musl + the global sysroot"
