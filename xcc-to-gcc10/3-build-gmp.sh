#!/bin/bash
#
# 3-build-gmp.sh — build GMP 6.2.1 with xcc + musl and install it into rootfs3/.
#
# This is the first of the three math libraries, built in the order GMP -> MPFR ->
# MPC (zlib is built separately). GMP has no library prerequisites: only the
# xcc-musl toolchain and the musl-1 global sysroot listed below.
#
# The compiler is rootfs3/usr/xcc-musl/bin/xcc-musl-cc, the CC wrapper installed by
# ./3-build-xcc-musl.sh. It drives the xcc-musl toolchain in rootfs3/usr/xcc-musl,
# takes headers from the musl global sysroot rootfs3/usr/include (with the va_list
# shim first) and links musl's crt1.o + libc.a. It does not use xcc's bundled libc.
#
# Prerequisites (produced by earlier steps of this chain):
#   rootfs3/usr/xcc-musl/bin/{xcc,cc1,cpp,as,ld}   ← ./3-build-xcc-musl.sh
#   rootfs3/usr/xcc-musl/bin/xcc-musl-cc           ← ./3-build-xcc-musl.sh (the CC wrapper)
#   rootfs3/usr/xcc-musl/shim/stdarg.h             ← ./3-build-musl-xcc.sh (va_list shim,
#                                                    refreshed by ./3-build-xcc-musl.sh)
#   rootfs3/usr/{include,lib}/                     ← ./3-build-musl-xcc.sh (musl headers +
#                                                    libc.a + crt*.o, the global sysroot)
#
# Output:
#   rootfs3/usr/include/gmp.h       public GMP header
#   rootfs3/usr/lib/libgmp.a        static library (the only library artifact needed)
#   rootfs3/src/gmp-6.2.1/          unpacked source (configure patched from K&R to ANSI)
#   rootfs3/build/gmp-6.2.1/        build tree (configure/make work dir; holds
#                                   configure.log/make.log)
#   rootfs3/usr/xcc-musl/bin/xcc-musl-cc   the CC configure/make see
#   rootfs3/tests/gmp-smoke.c       smoke-test source
#   results/3-build-gmp.log         full log
#
# Usage:
#   ./3-build-gmp.sh                # full run: checks -> unpack -> patch -> configure -> make -> install -> smoke test
#   JOBS=8 ./3-build-gmp.sh         # parallelism (default: nproc)
#   CLEAN=1 ./3-build-gmp.sh        # delete the build tree first and start over
#   FORCE_SRC=1 ./3-build-gmp.sh    # unpack again (drops the patch, which is then reapplied)
#   NO_SMOKE=1 ./3-build-gmp.sh     # skip the smoke test
#   CHECK=1 ./3-build-gmp.sh        # additionally run make -k check (GMP's own test suite, slow)
#
# ---------------------------------------------------------------------------
# Host tools used — full disclosure: apart from the xcc toolchain inside rootfs3,
# the only host binaries involved are those listed below; they are unpack/text/
# archive/driver tools, not compilers:
#
#   /usr/bin/bash       runs this script
#   /usr/bin/make       GNU make, drives the Makefile configure generates (required to
#                       build GMP)
#   /usr/bin/m4         GMP's configure/make run it over config.m4 (required even with
#                       --disable-assembly)
#   /usr/bin/tar + xz   unpacks gmp-6.2.1.tar.xz
#   /usr/bin/sed        used by GMP's configure/libtool and by the CHECK/smoke reporting
#   /usr/bin/awk(gawk)  used by GMP's build (config.status, conftest.awk) and by the
#                       source patch here
#   /usr/bin/grep       used by GMP's build, by the failure reporting and by the patch's
#                       idempotence check
#   /usr/bin/find cp mv rm mkdir ln cat head tail wc tr cut sort uniq cmp stat
#   /usr/bin/install    installs into rootfs3
#   /usr/bin/ar         archives the .o files xcc produced into libgmp.a (GNU binutils ar)
#   /usr/bin/nm         libtool/GMP probe symbols with it
#   /usr/bin/file readelf sha256sum   checked for; file/sha256sum inspect artifacts and hashes
#   /usr/bin/tee        mirrors the whole run into results/3-build-gmp.log
#   /usr/bin/dirname mktemp chmod env nproc   paths, scratch dirs, permissions, a clean
#                       configure environment, default parallelism
#
# GMP's configure/make also spawn a host shell-tool set of their own (sed/awk/grep/ln/
# cmp/mv/rm/sort/sleep/test/...); those are non-compiler tools as well and are declared
# here.
#
# Never used: host gcc/cc/clang/g++/ld/as/cpp, host /usr/include and /usr/lib.
# Compiling/assembling/linking is done entirely by
# rootfs3/usr/xcc-musl/bin/{xcc,cc1,cpp,as,ld} + musl.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
ROOTFS="$ROOT/rootfs3"
XCCDIR="$ROOTFS/usr/xcc-musl"            # the xcc toolchain that targets musl
XCC="$XCCDIR/bin/xcc"
MUSL_INC="$ROOTFS/usr/include"           # global sysroot (installed by ./3-build-musl-xcc.sh)
MUSL_LIB="$ROOTFS/usr/lib"
SHIM_INC="$ROOTFS/usr/xcc-musl/shim"     # va_list shim (stdarg.h + a bridged bits/alltypes.h)
WRAP="${CC_WRAP:-$XCCDIR/bin/xcc-musl-cc}"   # CC wrapper (xcc-musl-cc by default)
                                             # CC_WRAP=… selects another, e.g. the stage-1
                                             # gcc46 + musl-gcc wrapper from ./3-build-deps-gcc46.sh

TARBALL="$ROOT/gmp-6.2.1.tar.xz"
SRC="$ROOTFS/src/gmp-6.2.1"
BUILD="$ROOTFS/build/gmp-6.2.1"
TESTS="$ROOTFS/tests"
LOGDIR="$ROOT/results"
LOG="$LOGDIR/3-build-gmp.log"

JOBS="${JOBS:-$(nproc)}"
CLEAN="${CLEAN:-0}"
FORCE_SRC="${FORCE_SRC:-0}"
NO_SMOKE="${NO_SMOKE:-0}"
CHECK="${CHECK:-0}"
CFLAGS_BUILD="${CFLAGS_BUILD:--O1}"
TRIPLE="x86_64-pc-linux-gnu"

die()  { echo "error: $*" >&2; exit 1; }
note() { printf '\n==> %s\n' "$*"; }

mkdir -p "$LOGDIR"
exec > >(tee "$LOG") 2>&1

# ---------------------------------------------------------------- 0. Precondition checks
note "[0/8] checking inputs and host tools"
[ -f "$TARBALL" ] || die "cannot find $TARBALL"
for f in xcc cc1 cpp as ld; do
  [ -x "$XCCDIR/bin/$f" ] || die "missing $XCCDIR/bin/$f (run ./3-build-xcc-musl.sh first)"
done
[ -x "$WRAP" ] || die "missing $WRAP (run ./3-build-xcc-musl.sh first)"
[ -f "$MUSL_LIB/libc.a" ] || die "missing $MUSL_LIB/libc.a (run ./3-build-musl-xcc.sh first)"
for f in crt1.o crti.o crtn.o; do
  [ -f "$MUSL_LIB/$f" ] || die "missing $MUSL_LIB/$f (run ./3-build-musl-xcc.sh first)"
done
[ -f "$SHIM_INC/stdarg.h" ] || die "missing $SHIM_INC/stdarg.h (run ./3-build-musl-xcc.sh first)"
for t in bash make tar xz sed awk grep find install ar nm file readelf \
         sha256sum tee cp mv rm mkdir ln cat head tail wc tr cut sort uniq cmp; do
  command -v "$t" >/dev/null 2>&1 || die "missing host tool: $t"
done

echo "    xcc    : $("$XCC" -v | tr '\n' ' ')  sha256=$(sha256sum "$XCC" | cut -c1-16)"
echo "    musl   : libc.a $(stat -c%s "$MUSL_LIB/libc.a") bytes sha256=$(sha256sum "$MUSL_LIB/libc.a" | cut -c1-16)"
echo "    headers: $MUSL_INC ($(find "$MUSL_INC" -name '*.h' | wc -l) files) + shim $SHIM_INC"
echo "    archive: ar=$(command -v ar)"

# ------------------------------------------- 1. CC wrapper (the cc configure/make see)
# No wrapper is generated here: the toolchain ships
#   $XCCDIR/bin/xcc-musl-cc (installed by ./3-build-xcc-musl.sh)
# and it is already a complete "xcc-musl + global sysroot" wrapper (it drops GCC
# flags, injects -I for the shim, adds the sysroot headers with -idirafter, and at
# link time adds crt + -lc + -nostdlib). This step only checks it and runs a
# self-test, so there is no second implementation to keep in sync.
note "[1/8] reusing the toolchain's bundled CC wrapper $WRAP"
[ -x "$WRAP" ] || die "missing $WRAP (run ./3-build-xcc-musl.sh first)"
tmpd=$(mktemp -d)
trap 'rm -rf "$tmpd"' EXIT
cat > "$tmpd/t.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(void) {
  char *p = malloc(64);
  if (!p) return 1;
  strcpy(p, "wrap-ok");
  printf("%s %d\n", p, (int)strlen(p));
  free(p);
  return 0;
}
EOF
out=$("$WRAP" -o "$tmpd/t" "$tmpd/t.c" && "$tmpd/t") || die "CC wrapper self-test failed"
[ "$out" = "wrap-ok 7" ] || die "CC wrapper self-test produced unexpected output: $out"
echo "    self-test: $out  ($(file -b "$tmpd/t" | cut -d, -f1-2))"

# ------------------------------------------------------------------ 2. Unpack the source
note "[2/8] unpacking $TARBALL -> $SRC"
if [ "$FORCE_SRC" = 1 ] || [ ! -d "$SRC" ]; then
  rm -rf "$SRC"
  mkdir -p "$ROOTFS/src"
  tar -xJf "$TARBALL" -C "$ROOTFS/src"
else
  echo "already present, skipping unpack (FORCE_SRC=1 forces a fresh unpack)"
fi
[ -f "$SRC/configure" ] || die "$SRC/configure does not exist"

# ------------------------------------------------------------------ 3. Source patch
note "[3/8] applying the source adaptation patch (idempotent)"
# GMP's configure self-test programs use K&R (pre-ANSI) function definitions:
#     lshift_com (rp, up, n, cnt) / unsigned long *rp; / ... / {
# These are configure's "compiler works" probes (4 occurrences); xcc only accepts
# ANSI definitions, so configure would conclude that no usable compiler exists.
# GMP's real sources are ANSI; only the test programs are rewritten.
n=$(grep -c '^lshift_com (rp, up, n, cnt)$' "$SRC/configure" || true)
if [ "$n" != 0 ]; then
  awk '
    /^lshift_com \(rp, up, n, cnt\)$/ {
      print "lshift_com (unsigned long *rp, unsigned long *up, long n, unsigned cnt)"
      skip = 4                       # drop the 4 K&R parameter declarations
      next
    }
    skip > 0 { skip--; next }
    { print }
  ' "$SRC/configure" > "$SRC/configure.tmp"
  mv "$SRC/configure.tmp" "$SRC/configure"
  chmod +x "$SRC/configure"
  echo "    patched $n K&R self-test programs in configure -> ANSI"
else
  echo "    already patched (no K&R self-test programs)"
fi

# ------------------------------------------------------------- 4. configure
note "[4/8] configure (CC=$WRAP, MPN_PATH=generic, --disable-assembly)"
if [ "$CLEAN" = 1 ]; then
  echo "    CLEAN=1: removing $BUILD"
  rm -rf "$BUILD"
fi
mkdir -p "$BUILD"
cd "$BUILD"

#  * MPN_PATH=generic + --disable-assembly: GMP's default x86_64 build picks the
#    m4-generated .asm/.S assembly kernels, which need a general assembler; the host
#    assembler is off-limits and xcc's as only understands the dialect cc1 emits.
#    Forcing the pure-C mpn/generic implementation removes the assembly kernels, so
#    no general assembler is needed (the kernels are just slower); GMP still uses
#    host m4 for the config.m4 machinery of its configure/make.
#  * ac_cv_prog_cc_c89= (empty string): autoconf's "option to accept ISO C89" probe
#    contains a K&R function definition and always fails under xcc, so it must be
#    preset. The value must be the empty string, not `yes`: on a cache hit autoconf
#    runs CC="$CC $ac_cv_prog_cc_c89", and `yes` would make the compiler
#    "xcc-musl-cc yes".
env -u CFLAGS -u CPPFLAGS \
    MPN_PATH=generic \
    ac_cv_prog_cc_c89= \
    CC="$WRAP" \
    CFLAGS="$CFLAGS_BUILD" \
    "$SRC/configure" \
      --prefix=/usr \
      --build="$TRIPLE" --host="$TRIPLE" \
      --disable-shared --enable-static \
      --disable-assembly \
      --enable-cxx=no \
      > configure.log 2>&1 || { tail -40 configure.log; die "configure failed (see $BUILD/configure.log)"; }
grep -E '^ABI=|^path=|^checking compiler' configure.log | head -5 || true
echo "    configure done"

# ------------------------------------------------------------------- 5. make
note "[5/8] make -j$JOBS"
make -j"$JOBS" > make.log 2>&1 || {
  echo "--- failure summary (diagnostic lines, warnings excluded) ---"
  grep -nE '^[^ ]+\.[ch]\([0-9]+\):' make.log | grep -v 'warning:' | head -20 || true
  echo "--- make error lines ---"
  grep -nE 'Error [0-9]|error:' make.log | head -10 || true
  die "make failed (see $BUILD/make.log)"
}
[ -f .libs/libgmp.a ] || [ -f libgmp.a ] || die "make finished but produced no libgmp.a"
echo "    libgmp.a: $(find "$BUILD" -name libgmp.a -printf '%p %s bytes\n' | head -1)"

# ---------------------------------------------------------------- 6. install
note "[6/8] make install DESTDIR=$ROOTFS (--prefix=/usr)"
make install DESTDIR="$ROOTFS" > install.log 2>&1 || { tail -30 install.log; die "install failed"; }
[ -f "$ROOTFS/usr/include/gmp.h" ] || die "missing $ROOTFS/usr/include/gmp.h"
[ -f "$ROOTFS/usr/lib/libgmp.a" ]  || die "missing $ROOTFS/usr/lib/libgmp.a"
echo "    gmp.h     $(stat -c%s "$ROOTFS/usr/include/gmp.h") bytes"
echo "    libgmp.a  $(stat -c%s "$ROOTFS/usr/lib/libgmp.a") bytes sha256=$(sha256sum "$ROOTFS/usr/lib/libgmp.a" | cut -c1-16)"
echo "    members   $(ar t "$ROOTFS/usr/lib/libgmp.a" | wc -l)"
# libtool's .la records libdir as the absolute path '/usr/lib'. That is right inside
# the chroot but wrong on the host, where rootfs3/usr is not /, so libtool could pick
# up the host's /usr/lib. Only the .a is needed, so drop the .la right after install.
rm -f "$ROOTFS/usr/lib/libgmp.la"

if [ "$CHECK" = 1 ]; then
  note "[6b/8] make -k check (GMP's own test suite, slow; -k keeps going after a failing directory)"
  make -k check > check.log 2>&1 || true
  pass=$(grep -c '^PASS:' check.log || true)
  fail=$(grep -c '^FAIL:' check.log || true)
  xfail=$(grep -c '^XFAIL:' check.log || true)
  skip=$(grep -c '^SKIP:' check.log || true)
  err=$(grep -c '^ERROR:' check.log || true)
  echo "    test totals: PASS=$pass FAIL=$fail XFAIL=$xfail SKIP=$skip ERROR=$err"
  if [ "$fail" != 0 ] || [ "$err" != 0 ]; then
    for t in $(grep -E '^(FAIL|ERROR):' check.log | awk '{print $2}' | sort -u); do
      for l in $(find "$BUILD/tests" -name "$t.log" 2>/dev/null | sort); do
        echo "    --- $t  [$(dirname "${l#$BUILD/}")]"
        head -6 "$l" | sed 's/^/        /'
      done
    done
  fi
fi

# ---------------------------------------------------------------- 7. Smoke test
note "[7/8] smoke test (link the freshly installed libgmp.a with xcc + musl)"
mkdir -p "$TESTS"
cat > "$TESTS/gmp-smoke.c" <<'EOF'
/* Smoke test: the libgmp.a built by xcc + musl does big-integer arithmetic correctly. */
#include <stdio.h>
#include <gmp.h>

int main(void) {
  mpz_t a, c;
  char *s;
  unsigned long i;

  mpz_init_set_ui(a, 2);
  mpz_init(c);
  mpz_pow_ui(c, a, 100);
  s = mpz_get_str(NULL, 10, c);
  printf("2^100 = %s\n", s);

  mpz_set_ui(c, 1);
  for (i = 2; i <= 20; i++) mpz_mul_ui(c, c, i);
  s = mpz_get_str(NULL, 10, c);
  printf("20!   = %s\n", s);

  printf("gmp %s\n", gmp_version);
  return 0;
}
EOF
if [ "$NO_SMOKE" != 1 ]; then
  w=$(mktemp -d)
  "$WRAP" -o "$w/smoke" "$TESTS/gmp-smoke.c" -L"$MUSL_LIB" -lgmp || die "smoke compile/link failed"
  out=$("$w/smoke") || die "smoke run failed (exit code $?)"
  echo "$out" | sed 's/^/    /'
  echo "$out" | grep -q '^2^100 = 1267650600228229401496703205376$' || die "wrong 2^100 result"
  echo "$out" | grep -q '^20!   = 2432902008176640000$'               || die "wrong 20! result"
  echo "    $(file -b "$w/smoke" | cut -d, -f1-2)"
  rm -rf "$w"
  echo "    smoke test passed"
fi

# ------------------------------------------------------------------- Summary
note "[8/8] done"
cat <<EOF
  Installed:
    $ROOTFS/usr/include/gmp.h
    $ROOTFS/usr/lib/libgmp.a
  Build tree / source:
    $BUILD
    $SRC
  Log:
    $LOG

  Later steps (MPFR/MPC) reuse the same CC wrapper:
    CC=$WRAP
  and pass --with-gmp=$ROOTFS/usr to configure (or -I$MUSL_INC -L$MUSL_LIB).
EOF
