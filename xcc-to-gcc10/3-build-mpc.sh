#!/bin/bash
#
# 3-build-mpc.sh — build MPC 1.2.1 with xcc + musl and install it into rootfs3/.
#
# This is the last of the three math libraries; the chain is GMP -> MPFR -> MPC
# (zlib is built separately). MPC depends on both GMP and MPFR, so this script checks
# rootfs3/usr/{include/gmp.h,include/mpfr.h} and lib/{libgmp.a,libmpfr.a} and reuses
# the CC wrapper installed by ./3-build-xcc-musl.sh. It does not use xcc's bundled libc.
#
# Prerequisites (produced by earlier steps of this chain):
#   rootfs3/usr/xcc-musl/bin/{xcc,cc1,cpp,as,ld}   ← ./3-build-xcc-musl.sh
#   rootfs3/usr/xcc-musl/bin/xcc-musl-cc           ← ./3-build-xcc-musl.sh (the CC wrapper)
#   rootfs3/usr/{include,lib}/                     ← ./3-build-musl-xcc.sh (musl headers +
#                                                    libc.a + crt*.o, the global sysroot)
#   rootfs3/usr/include/gmp.h, lib/libgmp.a        ← ./3-build-gmp.sh
#   rootfs3/usr/include/mpfr.h, lib/libmpfr.a      ← ./3-build-mpfr.sh
#
# Output:
#   rootfs3/usr/include/mpc.h         public MPC header
#   rootfs3/usr/lib/libmpc.a          static library (the only library artifact needed)
#   rootfs3/src/mpc-1.2.1/            unpacked source (needs no source patch)
#   rootfs3/build/mpc-1.2.1/          build tree (configure.log/make.log/install.log)
#   rootfs3/tests/mpc-smoke.c         smoke-test source
#   results/3-build-mpc.log           full log
#
# Usage:
#   ./3-build-mpc.sh                # full run: unpack -> configure -> make -> install -> smoke test
#   JOBS=8 ./3-build-mpc.sh         # parallelism (default: nproc)
#   CLEAN=1 ./3-build-mpc.sh        # delete the build tree first and start over
#   FORCE_SRC=1 ./3-build-mpc.sh    # unpack again
#   NO_SMOKE=1 ./3-build-mpc.sh     # skip the smoke test
#   CHECK=1 ./3-build-mpc.sh        # additionally run make -k check (MPC's own test suite)
#
# ---------------------------------------------------------------------------
# Host tools used — full disclosure: apart from the xcc toolchain inside rootfs3,
# the only host binaries involved are those listed below; they are unpack/text/
# archive/driver tools, not compilers:
#
#   /usr/bin/bash       runs this script
#   /usr/bin/make       GNU make, drives MPC's configure/Makefile
#   /usr/bin/tar + gzip unpacks mpc-1.2.1.tar.gz
#   /usr/bin/sed        used by MPC's libtool/configure and by the CHECK/smoke reporting
#   /usr/bin/awk(gawk)  used by MPC's build (config.status etc.) and by the CHECK reporting
#   /usr/bin/grep       used by MPC's build, by configure/make failure reporting and by
#                       the CHECK summary
#   /usr/bin/find cp mv rm mkdir ln cat head tail wc tr cut sort uniq cmp stat
#   /usr/bin/install    installs into rootfs3
#   /usr/bin/ar         archives the .o files xcc produced into libmpc.a
#   /usr/bin/nm         libtool/configure look it up when probing symbols
#   /usr/bin/file readelf sha256sum   checked for; file/sha256sum inspect artifacts and hashes
#   /usr/bin/tee        mirrors the whole run into results/3-build-mpc.log
#   /usr/bin/dirname mktemp env nproc   paths, scratch dirs, a clean configure environment,
#                       default parallelism
#
# MPC's configure/make also spawn a host shell-tool set of their own (sed/awk/grep/ln/
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
MUSL_INC="$ROOTFS/usr/include"
MUSL_LIB="$ROOTFS/usr/lib"
DEPS="$ROOTFS/usr"                          # GMP and MPFR are both installed here
WRAP="${CC_WRAP:-$XCCDIR/bin/xcc-musl-cc}"   # CC wrapper (xcc-musl-cc by default)
                                             # CC_WRAP=… selects another, e.g. the stage-1
                                             # gcc46 + musl-gcc wrapper from ./3-build-deps-gcc46.sh

TARBALL="$ROOT/mpc-1.2.1.tar.gz"
SRC="$ROOTFS/src/mpc-1.2.1"
BUILD="$ROOTFS/build/mpc-1.2.1"
TESTS="$ROOTFS/tests"
LOGDIR="$ROOT/results"
LOG="$LOGDIR/3-build-mpc.log"

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
note "[0/7] checking inputs and host tools"
[ -f "$TARBALL" ] || die "cannot find $TARBALL"
for f in xcc cc1 cpp as ld; do
  [ -x "$XCCDIR/bin/$f" ] || die "missing $XCCDIR/bin/$f (run ./3-build-xcc-musl.sh first)"
done
[ -f "$MUSL_LIB/libc.a" ] || die "missing $MUSL_LIB/libc.a (run ./3-build-musl-xcc.sh first)"
for h in gmp.h mpfr.h; do
  [ -f "$DEPS/include/$h" ] || die "missing $DEPS/include/$h (run ./3-build-gmp.sh / ./3-build-mpfr.sh first)"
done
for l in libgmp.a libmpfr.a; do
  [ -f "$DEPS/lib/$l" ] || die "missing $DEPS/lib/$l (run ./3-build-gmp.sh / ./3-build-mpfr.sh first)"
done
[ -x "$WRAP" ] || die "missing CC wrapper $WRAP (run ./3-build-xcc-musl.sh first)"
for t in bash make tar gzip sed awk grep find install ar nm file readelf \
         sha256sum tee cp mv rm mkdir ln cat head tail wc tr cut sort uniq cmp; do
  command -v "$t" >/dev/null 2>&1 || die "missing host tool: $t"
done

echo "    xcc    : $("$XCC" -v | tr '\n' ' ')  sha256=$(sha256sum "$XCC" | cut -c1-16)"
echo "    musl   : libc.a $(stat -c%s "$MUSL_LIB/libc.a") bytes sha256=$(sha256sum "$MUSL_LIB/libc.a" | cut -c1-16)"
echo "    gmp    : $(stat -c%s "$DEPS/lib/libgmp.a") bytes sha256=$(sha256sum "$DEPS/lib/libgmp.a" | cut -c1-16)"
echo "    mpfr   : $(stat -c%s "$DEPS/lib/libmpfr.a") bytes sha256=$(sha256sum "$DEPS/lib/libmpfr.a" | cut -c1-16)"
echo "    CC     : $WRAP"
# Defensive cleanup: GMP's and MPFR's libtool .la archives record the absolute
# libdir '/usr/lib', and MPFR's dependency_libs also carries an absolute -L path into
# rootfs3/usr/lib. On the host, where rootfs3/usr is not /, those point at the host's
# /usr/lib instead of the sysroot. Only the .a is used, and the two library steps
# already delete their .la files; this is a safety net.
rm -f "$DEPS/lib"/libgmp.la "$DEPS/lib"/libmpfr.la

# ------------------------------------------------------------------ 1. Unpack the source
note "[1/7] unpacking $TARBALL -> $SRC"
if [ "$FORCE_SRC" = 1 ] || [ ! -d "$SRC" ]; then
  rm -rf "$SRC"
  mkdir -p "$ROOTFS/src"
  tar -xzf "$TARBALL" -C "$ROOTFS/src"
else
  echo "already present, skipping unpack (FORCE_SRC=1 forces a fresh unpack)"
fi
[ -f "$SRC/configure" ] || die "$SRC/configure does not exist"

# ------------------------------------------------------------------ 2. Source patches
note "[2/7] source patches"
# MPC 1.2.1's configure has no package-specific K&R (pre-ANSI) self-test programs
# (checked: 0), and its sources need no changes. What must be handled is autoconf's
# generic "option to accept ISO C89" probe, whose test program contains a K&R
# definition; the cache variable is preset to skip it:
#   ac_cv_prog_cc_c89=   (must be the empty string: on a cache hit autoconf runs
#                         CC="$CC $ac_cv_prog_cc_c89", and `yes` would make the
#                         compiler "xcc-musl-cc yes")
echo "    no source patch needed (configure has no package-specific K&R self-test; the autoconf probe is skipped via a cache variable)"

# ------------------------------------------------------------- 3. configure
note "[3/7] configure (CC=$WRAP, --with-gmp*/--with-mpfr*, --disable-shared)"
if [ "$CLEAN" = 1 ]; then
  echo "    CLEAN=1: removing $BUILD"
  rm -rf "$BUILD"
fi
mkdir -p "$BUILD"
cd "$BUILD"

#  * --with-gmp-include/-lib and --with-mpfr-include/-lib: both dependencies live
#    under the sysroot's /usr.
#  * MPC 1.2.1's configure requires MPFR >= 4.1.0; the 4.1.0 built by
#    ./3-build-mpfr.sh satisfies that.
#  * ac_cv_prog_cc_c89= (empty): see the source-patch step above.
env -u CFLAGS -u CPPFLAGS \
    ac_cv_prog_cc_c89= \
    CC="$WRAP" \
    CFLAGS="$CFLAGS_BUILD" \
    "$SRC/configure" \
      --prefix=/usr \
      --build="$TRIPLE" --host="$TRIPLE" \
      --disable-shared --enable-static \
      --with-gmp-include="$DEPS/include" \
      --with-gmp-lib="$DEPS/lib" \
      --with-mpfr-include="$DEPS/include" \
      --with-mpfr-lib="$DEPS/lib" \
      > configure.log 2>&1 || { tail -40 configure.log; die "configure failed (see $BUILD/configure.log)"; }
grep -E '^checking for gmp.h|^checking for mpfr.h|^checking for MPFR|^checking for mpc_|^CC=' configure.log | head -8 || true
echo "    configure done"

# ------------------------------------------------------------------- 4. make
note "[4/7] make -j$JOBS"
make -j"$JOBS" > make.log 2>&1 || {
  echo "--- failure summary (diagnostic lines, warnings excluded) ---"
  grep -nE '^[^ ]+\.[ch]\([0-9]+\):' make.log | grep -v 'warning:' | head -20 || true
  echo "--- make error lines ---"
  grep -nE 'Error [0-9]|error:' make.log | head -10 || true
  die "make failed (see $BUILD/make.log)"
}
[ -f src/.libs/libmpc.a ] || [ -f src/libmpc.a ] || die "make finished but produced no libmpc.a"
echo "    libmpc.a: $(find "$BUILD" -name libmpc.a -printf '%p %s bytes\n' | head -1)"

# ---------------------------------------------------------------- 5. install
note "[5/7] make install DESTDIR=$ROOTFS (--prefix=/usr)"
make install DESTDIR="$ROOTFS" > install.log 2>&1 || { tail -30 install.log; die "install failed"; }
for f in "$ROOTFS/usr/include/mpc.h" "$ROOTFS/usr/lib/libmpc.a"; do
  [ -f "$f" ] || die "missing $f"
done
echo "    mpc.h     $(stat -c%s "$ROOTFS/usr/include/mpc.h") bytes"
echo "    libmpc.a  $(stat -c%s "$ROOTFS/usr/lib/libmpc.a") bytes sha256=$(sha256sum "$ROOTFS/usr/lib/libmpc.a" | cut -c1-16)"
echo "    members   $(ar t "$ROOTFS/usr/lib/libmpc.a" | wc -l)"
# Same as GMP/MPFR: libtool's .la records absolute paths, which are wrong on the
# host; only the .a is used, so delete the .la right after install.
rm -f "$ROOTFS/usr/lib/libmpc.la"

if [ "$CHECK" = 1 ]; then
  note "[5b/7] make -k check (MPC's own test suite, slow; -k keeps going after a failing directory)"
  make -k check > check.log 2>&1 || true
  pass=$(grep -c '^PASS:' check.log || true)
  fail=$(grep -c '^FAIL:' check.log || true)
  err=$(grep -c '^ERROR:' check.log || true)
  echo "    test totals: PASS=$pass FAIL=$fail ERROR=$err"
  if [ "$fail" != 0 ] || [ "$err" != 0 ]; then
    for t in $(grep -E '^(FAIL|ERROR):' check.log | awk '{print $2}' | sort -u); do
      for l in $(find "$BUILD/tests" -name "$t.log" 2>/dev/null | sort); do
        echo "    --- $t  [$(dirname "${l#$BUILD/}")]"
        head -6 "$l" | sed 's/^/        /'
      done
    done
  fi
  echo "    test-program compile diagnostics: $(grep -E '^[^ ]+\.[ch]\([0-9]+\):' check.log | grep -vc 'warning:' || true) error-class lines"
fi

# ---------------------------------------------------------------- 6. Smoke test
note "[6/7] smoke test (link the freshly installed libmpc.a + libmpfr.a + libgmp.a with the CC wrapper)"
mkdir -p "$TESTS"
cat > "$TESTS/mpc-smoke.c" <<'EOF'
/* Smoke test: MPC (complex arithmetic) computes and returns correct results. All
   expected values are exact or have a closed form, plus a few self-consistency
   identities, so no external reference library is needed:
     (1+2i)*(3+4i) = -5+10i     exact
     (a*b)/b       = a          division inverts the multiplication
     |3+4i|        = 5          exact
     sqrt(-1)      = i          exact
     exp(i*pi)     = -1         within tolerance
     (a+bi)(a-bi)  = a^2+b^2    (== the square of mpc_abs) */
#include <stdio.h>
#include <string.h>
#include <gmp.h>
#include <mpfr.h>
#include <mpc.h>

static int failures = 0;
static void check(const char *what, int ok) {
  printf("  %-40s %s\n", what, ok ? "ok" : "FAIL");
  if (!ok) failures++;
}

int main(void) {
  mpc_t a, b, c;
  mpfr_t r, s;

  mpc_init2(a, 256);
  mpc_init2(b, 256);
  mpc_init2(c, 256);
  mpfr_init2(r, 256);
  mpfr_init2(s, 256);

  printf("  mpc %s / mpfr %s / gmp %s\n",
         mpc_get_version(), mpfr_get_version(), gmp_version);
  check("mpc_get_version starts with 1.2.1", strncmp(mpc_get_version(), "1.2.1", 5) == 0);

  /* (1+2i) * (3+4i) = -5+10i */
  mpc_set_ui_ui(a, 1, 2, MPC_RNDNN);
  mpc_set_ui_ui(b, 3, 4, MPC_RNDNN);
  mpc_mul(c, a, b, MPC_RNDNN);
  check("(1+2i)*(3+4i) real part == -5", mpfr_cmp_si(mpc_realref(c), -5) == 0);
  check("(1+2i)*(3+4i) imaginary part == 10", mpfr_cmp_ui(mpc_imagref(c), 10) == 0);

  /* Division inverts multiplication: (a*b)/b == a */
  mpc_div(c, c, b, MPC_RNDNN);
  check("(a*b)/b real part == 1", mpfr_cmp_ui(mpc_realref(c), 1) == 0);
  check("(a*b)/b imaginary part == 2", mpfr_cmp_ui(mpc_imagref(c), 2) == 0);

  /* |3+4i| == 5; the product with the conjugate == |a|^2 */
  mpc_set_ui_ui(a, 3, 4, MPC_RNDNN);
  mpc_abs(r, a, MPFR_RNDN);
  check("|3+4i| == 5", mpfr_cmp_ui(r, 5) == 0);
  mpc_conj(c, a, MPC_RNDNN);
  mpc_mul(c, a, c, MPC_RNDNN);
  mpfr_sqr(s, r, MPFR_RNDN);
  check("a*conj(a) real part == |a|^2", mpfr_cmp(mpc_realref(c), s) == 0);
  check("a*conj(a) imaginary part == 0", mpfr_zero_p(mpc_imagref(c)) != 0);

  /* sqrt(-1) == i */
  mpc_set_si(a, -1, MPC_RNDNN);
  mpc_sqrt(c, a, MPC_RNDNN);
  check("sqrt(-1) real part == 0", mpfr_zero_p(mpc_realref(c)) != 0);
  check("sqrt(-1) imaginary part == 1", mpfr_cmp_ui(mpc_imagref(c), 1) == 0);

  /* exp(i*pi) == -1 (tolerance 2^-100) */
  mpfr_const_pi(r, MPFR_RNDN);
  mpc_set_ui_ui(a, 0, 1, MPC_RNDNN);
  mpc_mul_fr(a, a, r, MPC_RNDNN);
  mpc_exp(c, a, MPC_RNDNN);
  mpfr_set_ui(s, 1, MPFR_RNDN);
  mpfr_div_2exp(s, s, 100, MPFR_RNDN);
  mpfr_add_ui(r, mpc_realref(c), 1, MPFR_RNDN);   /* r = Re + 1 */
  mpfr_abs(r, r, MPFR_RNDN);
  check("|Re(exp(i*pi)) + 1| < 2^-100", mpfr_cmp(r, s) < 0);
  mpfr_abs(r, mpc_imagref(c), MPFR_RNDN);
  check("|Im(exp(i*pi))| < 2^-100", mpfr_cmp(r, s) < 0);

  /* exp(log(z)) == z, for z = 1+2i */
  mpc_set_ui_ui(a, 1, 2, MPC_RNDNN);
  mpc_log(c, a, MPC_RNDNN);
  mpc_exp(c, c, MPC_RNDNN);
  mpfr_set_ui(s, 1, MPFR_RNDN);
  mpfr_div_2exp(s, s, 200, MPFR_RNDN);
  mpc_sub(c, c, a, MPC_RNDNN);
  mpc_abs(r, c, MPFR_RNDN);
  check("|exp(log(1+2i)) - (1+2i)| < 2^-200", mpfr_cmp(r, s) < 0);

  printf("  %d failed\n", failures);
  mpc_clear(a); mpc_clear(b); mpc_clear(c);
  mpfr_clear(r); mpfr_clear(s);
  return failures == 0 ? 0 : 1;
}
EOF
if [ "$NO_SMOKE" != 1 ]; then
  w=$(mktemp -d)
  "$WRAP" -o "$w/smoke" "$TESTS/mpc-smoke.c" -L"$MUSL_LIB" -lmpc -lmpfr -lgmp \
    || die "smoke compile/link failed"
  out=$("$w/smoke") || { echo "$out" | sed 's/^/    /'; die "smoke run failed"; }
  echo "$out" | sed 's/^/  /'
  echo "$out" | grep -q ' 0 failed' || die "smoke test reported failures"
  echo "    $(file -b "$w/smoke" | cut -d, -f1-2)"
  rm -rf "$w"
  echo "    smoke test passed"
fi

# ------------------------------------------------------------------- Summary
note "[7/7] done"
cat <<EOF
  Installed:
    $ROOTFS/usr/include/mpc.h
    $ROOTFS/usr/lib/libmpc.a
  Build tree / source:
    $BUILD
    $SRC
  Log:
    $LOG

  All three prerequisite libraries (GMP/MPFR/MPC) are now installed under $ROOTFS/usr,
  and can be used directly as the --with-gmp/--with-mpfr/--with-mpc prefixes for the
  later GCC build.
EOF
