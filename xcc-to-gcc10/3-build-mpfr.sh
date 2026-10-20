#!/bin/bash
#
# 3-build-mpfr.sh — build MPFR 4.1.0 with xcc + musl and install it into rootfs3/.
#
# This is the second of the three math libraries; the chain is GMP -> MPFR -> MPC
# (zlib is built separately). MPFR depends on GMP, so this script checks for
# rootfs3/usr/{include/gmp.h,lib/libgmp.a} and reuses the CC wrapper installed by
# ./3-build-xcc-musl.sh. It does not use xcc's bundled libc.
#
# Prerequisites (produced by earlier steps of this chain):
#   rootfs3/usr/xcc-musl/bin/{xcc,cc1,cpp,as,ld}   ← ./3-build-xcc-musl.sh
#   rootfs3/usr/xcc-musl/bin/xcc-musl-cc           ← ./3-build-xcc-musl.sh (the CC wrapper)
#   rootfs3/usr/{include,lib}/                     ← ./3-build-musl-xcc.sh (musl headers +
#                                                    libc.a + crt*.o, the global sysroot)
#   rootfs3/usr/include/gmp.h, lib/libgmp.a        ← ./3-build-gmp.sh
#
# Output:
#   rootfs3/usr/include/mpfr.h        public MPFR header
#   rootfs3/usr/include/mpf2mpfr.h    MPF -> MPFR compatibility header (installed with MPFR)
#   rootfs3/usr/lib/libmpfr.a         static library (the only library artifact needed)
#   rootfs3/src/mpfr-4.1.0/           unpacked source (needs no source patch)
#   rootfs3/build/mpfr-4.1.0/         build tree (configure.log/make.log/install.log)
#   rootfs3/tests/mpfr-smoke.c        smoke-test source
#   results/3-build-mpfr.log          full log
#
# Usage:
#   ./3-build-mpfr.sh                # full run: unpack -> configure -> make -> install -> smoke test
#   JOBS=8 ./3-build-mpfr.sh         # parallelism (default: nproc)
#   CLEAN=1 ./3-build-mpfr.sh        # delete the build tree first and start over
#   FORCE_SRC=1 ./3-build-mpfr.sh    # unpack again
#   NO_SMOKE=1 ./3-build-mpfr.sh     # skip the smoke test
#   CHECK=1 ./3-build-mpfr.sh        # additionally run make -k check (MPFR's own test suite, slow)
#
# ---------------------------------------------------------------------------
# Host tools used — full disclosure: apart from the xcc toolchain inside rootfs3,
# the only host binaries involved are those listed below; they are unpack/text/
# archive/driver tools, not compilers:
#
#   /usr/bin/bash       runs this script
#   /usr/bin/make       GNU make, drives MPFR's configure/Makefile
#   /usr/bin/tar + xz   unpacks mpfr-4.1.0.tar.xz
#   /usr/bin/sed        used by MPFR's libtool/configure and by the CHECK/smoke reporting
#   /usr/bin/awk(gawk)  used by MPFR's build (config.status etc.) and by the CHECK reporting
#   /usr/bin/grep       used by MPFR's build, by configure/make failure reporting and by
#                       the CHECK summary
#   /usr/bin/find cp mv rm mkdir ln cat head tail wc tr cut sort uniq cmp stat
#   /usr/bin/install    installs into rootfs3
#   /usr/bin/ar         archives the .o files xcc produced into libmpfr.a
#   /usr/bin/nm         libtool/configure look it up when probing symbols
#   /usr/bin/file readelf sha256sum   checked for; file/sha256sum inspect artifacts and hashes
#   /usr/bin/tee        mirrors the whole run into results/3-build-mpfr.log
#   /usr/bin/dirname mktemp env nproc   paths, scratch dirs, a clean configure environment,
#                       default parallelism
#
# MPFR's configure/make also spawn a host shell-tool set of their own (sed/awk/grep/ln/
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
MUSL_INC="$ROOTFS/usr/include"           # global sysroot (musl-1 plus the third-party libraries)
MUSL_LIB="$ROOTFS/usr/lib"
GMP_PREFIX="$ROOTFS/usr"
WRAP="${CC_WRAP:-$XCCDIR/bin/xcc-musl-cc}"   # CC wrapper (xcc-musl-cc by default)
                                             # CC_WRAP=… selects another, e.g. the stage-1
                                             # gcc46 + musl-gcc wrapper from ./3-build-deps-gcc46.sh

TARBALL="$ROOT/mpfr-4.1.0.tar.xz"
SRC="$ROOTFS/src/mpfr-4.1.0"
BUILD="$ROOTFS/build/mpfr-4.1.0"
TESTS="$ROOTFS/tests"
LOGDIR="$ROOT/results"
LOG="$LOGDIR/3-build-mpfr.log"

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
[ -f "$GMP_PREFIX/include/gmp.h" ] && [ -f "$GMP_PREFIX/lib/libgmp.a" ] \
  || die "missing GMP artifacts (run ./3-build-gmp.sh first; MPFR depends on GMP)"
[ -x "$WRAP" ] || die "missing CC wrapper $WRAP (run ./3-build-xcc-musl.sh first)"
for t in bash make tar xz sed awk grep find install ar nm file readelf \
         sha256sum tee cp mv rm mkdir ln cat head tail wc tr cut sort uniq cmp; do
  command -v "$t" >/dev/null 2>&1 || die "missing host tool: $t"
done

echo "    xcc    : $("$XCC" -v | tr '\n' ' ')  sha256=$(sha256sum "$XCC" | cut -c1-16)"
echo "    musl   : libc.a $(stat -c%s "$MUSL_LIB/libc.a") bytes sha256=$(sha256sum "$MUSL_LIB/libc.a" | cut -c1-16)"
echo "    gmp    : $(stat -c%s "$GMP_PREFIX/lib/libgmp.a") bytes sha256=$(sha256sum "$GMP_PREFIX/lib/libgmp.a" | cut -c1-16)"
echo "    CC     : $WRAP"

# ------------------------------------------------------------------ 1. Unpack the source
note "[1/7] unpacking $TARBALL -> $SRC"
if [ "$FORCE_SRC" = 1 ] || [ ! -d "$SRC" ]; then
  rm -rf "$SRC"
  mkdir -p "$ROOTFS/src"
  tar -xJf "$TARBALL" -C "$ROOTFS/src"
else
  echo "already present, skipping unpack (FORCE_SRC=1 forces a fresh unpack)"
fi
[ -f "$SRC/configure" ] || die "$SRC/configure does not exist"

# ------------------------------------------------------------------ 2. Source patches
note "[2/7] source patches"
# MPFR 4.1.0's configure has no package-specific K&R (pre-ANSI) self-test programs
# (checked: 0), so unlike GMP its configure needs no rewrite. What must be handled is
# autoconf's generic "option to accept ISO C89" probe, whose test program contains a
# K&R definition; the cache variable is preset to skip it:
#   ac_cv_prog_cc_c89=   (must be the empty string: on a cache hit autoconf runs
#                         CC="$CC $ac_cv_prog_cc_c89", and `yes` would make the
#                         compiler "xcc-musl-cc yes")
echo "    no source patch needed (configure has no package-specific K&R self-test; the autoconf probe is skipped via a cache variable)"

# ------------------------------------------------------------- 3. configure
note "[3/7] configure (CC=$WRAP, --with-gmp-*, TLS/float128/decimal-float disabled)"
if [ "$CLEAN" = 1 ]; then
  echo "    CLEAN=1: removing $BUILD"
  rm -rf "$BUILD"
fi
mkdir -p "$BUILD"
cd "$BUILD"

#  * --with-gmp-include/-lib: GMP is installed under the sysroot's /usr (product of
#    ./3-build-gmp.sh).
#  * --disable-thread-safe: thread safety needs TLS, which xcc does not support: it
#    rejects the __thread/_Thread_local storage class, and its own ld resolves only
#    R_X86_64_64 / PC32 / PLT32, not the TLS relocation types. Disabling it removes
#    TLS entirely.
#  * --disable-float128: needs compiler support for _Float128/__float128 (a GCC
#    extension), which xcc does not have.
#  * --disable-decimal-float: needs decimal-float types such as _Decimal64, which xcc
#    does not have.
#  * ac_cv_prog_cc_c89= (empty): see the source-patch step above.
env -u CFLAGS -u CPPFLAGS \
    ac_cv_prog_cc_c89= \
    CC="$WRAP" \
    CFLAGS="$CFLAGS_BUILD" \
    "$SRC/configure" \
      --prefix=/usr \
      --build="$TRIPLE" --host="$TRIPLE" \
      --disable-shared --enable-static \
      --disable-thread-safe \
      --disable-float128 \
      --disable-decimal-float \
      --with-gmp-include="$GMP_PREFIX/include" \
      --with-gmp-lib="$GMP_PREFIX/lib" \
      > configure.log 2>&1 || { tail -40 configure.log; die "configure failed (see $BUILD/configure.log)"; }
grep -E '^checking for gmp.h|^checking for GMP|^checking for __gmpz_|thread safe|GMP version|^CC=' configure.log | head -8 || true
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
[ -f src/.libs/libmpfr.a ] || [ -f src/libmpfr.a ] || die "make finished but produced no libmpfr.a"
echo "    libmpfr.a: $(find "$BUILD" -name libmpfr.a -printf '%p %s bytes\n' | head -1)"

# ---------------------------------------------------------------- 5. install
note "[5/7] make install DESTDIR=$ROOTFS (--prefix=/usr)"
make install DESTDIR="$ROOTFS" > install.log 2>&1 || { tail -30 install.log; die "install failed"; }
for f in "$ROOTFS/usr/include/mpfr.h" "$ROOTFS/usr/include/mpf2mpfr.h" "$ROOTFS/usr/lib/libmpfr.a"; do
  [ -f "$f" ] || die "missing $f"
done
echo "    mpfr.h      $(stat -c%s "$ROOTFS/usr/include/mpfr.h") bytes"
echo "    mpf2mpfr.h  $(stat -c%s "$ROOTFS/usr/include/mpf2mpfr.h") bytes"
echo "    libmpfr.a   $(stat -c%s "$ROOTFS/usr/lib/libmpfr.a") bytes sha256=$(sha256sum "$ROOTFS/usr/lib/libmpfr.a" | cut -c1-16)"
echo "    members     $(ar t "$ROOTFS/usr/lib/libmpfr.a" | wc -l)"
# Same as GMP: libtool's .la records the absolute libdir '/usr/lib', and for MPFR its
# dependency_libs also carries an absolute -L path into rootfs3/usr/lib. On the host
# those point outside the sysroot, and only the .a is used, so delete the .la.
rm -f "$ROOTFS/usr/lib/libmpfr.la"

if [ "$CHECK" = 1 ]; then
  note "[5b/7] make -k check (MPFR's own test suite, slow; -k keeps going after a failing directory)"
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
note "[6/7] smoke test (link the freshly installed libmpfr.a + libgmp.a with the CC wrapper)"
mkdir -p "$TESTS"
cat > "$TESTS/mpfr-smoke.c" <<'EOF'
/* Smoke test: libmpfr.a works and returns correct results. The only hard-coded
   expected value is the well-known first 20 decimals of pi; everything else is
   checked with identities, so no external reference library is needed. */
#include <stdio.h>
#include <string.h>
#include <gmp.h>
#include <mpfr.h>

static int failures = 0;
static void check(const char *what, int ok) {
  printf("  %-34s %s\n", what, ok ? "ok" : "FAIL");
  if (!ok) failures++;
}

int main(void) {
  mpfr_t pi, x, y;
  char buf[128];
  mpfr_exp_t exp;

  mpfr_init2(pi, 256);
  mpfr_init2(x, 256);
  mpfr_init2(y, 256);

  /* 1) Basic values and accessors: regression sentinels for xcc's decimal-literal
        handling. A mis-signed LONG_MIN makes MPFR_IS_SINGULAR always true, which
        skews every result below. */
  mpfr_set_ui(x, 5, MPFR_RNDN);
  check("mpfr_cmp_ui(x,5) == 0", mpfr_cmp_ui(x, 5) == 0);
  check("mpfr_cmp_ui(x,4) > 0",  mpfr_cmp_ui(x, 4) > 0);
  check("mpfr_get_si(x) == 5",   mpfr_get_si(x, MPFR_RNDN) == 5);
  check("mpfr_get_d(x) == 5.0",  mpfr_get_d(x, MPFR_RNDN) == 5.0);
  check("mpfr_integer_p(x)",     mpfr_integer_p(x) != 0);
  check("mpfr_fits_slong_p(x)",  mpfr_fits_slong_p(x, MPFR_RNDN) != 0);
  check("mpfr_fits_ulong_p(x)",  mpfr_fits_ulong_p(x, MPFR_RNDN) != 0);

  /* 2) Formatted output: the first 20 decimals of pi */
  mpfr_const_pi(pi, MPFR_RNDN);
  mpfr_snprintf(buf, sizeof buf, "%.20Rf", pi);
  printf("  pi = %s\n", buf);
  check("first 20 decimals of pi", strcmp(buf, "3.14159265358979323846") == 0);
  mpfr_snprintf(buf, sizeof buf, "%Rf", x);
  check("%Rf prints 5.000000", strcmp(buf, "5.000000") == 0);

  /* 3) Self-consistency: |4*atan(1) - const_pi| < 2^-250 (not bit-for-bit equality) */
  mpfr_set_ui(x, 1, MPFR_RNDN);
  mpfr_atan(x, x, MPFR_RNDN);
  mpfr_mul_ui(x, x, 4, MPFR_RNDN);
  mpfr_sub(y, x, pi, MPFR_RNDN);
  mpfr_abs(y, y, MPFR_RNDN);
  mpfr_set_ui(x, 1, MPFR_RNDN);
  mpfr_div_2exp(x, x, 250, MPFR_RNDN);
  check("|4*atan(1) - pi| < 2^-250", mpfr_cmp(y, x) < 0);

  /* 4) Round trip and transcendental functions (compared as double) */
  mpfr_set_ui(x, 2, MPFR_RNDN);
  mpfr_sqrt(y, x, MPFR_RNDN);
  mpfr_sqr(y, y, MPFR_RNDN);
  check("sqrt(2)^2 == 2 (double)", mpfr_get_d(y, MPFR_RNDN) == 2.0);
  mpfr_set_ui(x, 7, MPFR_RNDN);
  mpfr_log(y, x, MPFR_RNDN);
  mpfr_exp(y, y, MPFR_RNDN);
  check("exp(log(7)) == 7 (double)", mpfr_get_d(y, MPFR_RNDN) == 7.0);

  /* 5) get_str / strtofr round trip: get_str returns "digit string + exponent"
        (value = 0.digits x 10^exp), so parsing has to insert the decimal point and
        carry the exponent. */
  mpfr_set_ui(x, 5, MPFR_RNDN);
  {
    char *s = mpfr_get_str(NULL, &exp, 10, 0, x, MPFR_RNDN);
    check("get_str returns non-NULL", s != NULL);
    if (s != NULL) {
      char tmp[128];
      size_t L = strlen(s);
      if (L > 1) {
        memcpy(tmp, s, 1);
        tmp[1] = '.';
        memcpy(tmp + 2, s + 1, L - 1);
        sprintf(tmp + 1 + L, "e%ld", (long)exp - 1);
      } else {
        sprintf(tmp, "%se%ld", s, (long)exp - 1);
      }
      mpfr_set_str(y, tmp, 10, MPFR_RNDN);
      check("get_str/strtofr round trip == 5", mpfr_cmp_ui(y, 5) == 0);
      mpfr_free_str(s);
    }
  }

  printf("  mpfr %s / gmp %s / %d failed\n", mpfr_get_version(), gmp_version, failures);
  mpfr_clear(pi); mpfr_clear(x); mpfr_clear(y);
  return failures == 0 ? 0 : 1;
}
EOF
if [ "$NO_SMOKE" != 1 ]; then
  w=$(mktemp -d)
  "$WRAP" -o "$w/smoke" "$TESTS/mpfr-smoke.c" -L"$MUSL_LIB" -lmpfr -lgmp \
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
    $ROOTFS/usr/include/mpfr.h
    $ROOTFS/usr/include/mpf2mpfr.h
    $ROOTFS/usr/lib/libmpfr.a
  Build tree / source:
    $BUILD
    $SRC
  Log:
    $LOG

  The next step (MPC) reuses the same CC wrapper:
    CC=$WRAP
  and passes --with-gmp=$GMP_PREFIX --with-mpfr=$GMP_PREFIX to configure.
EOF
