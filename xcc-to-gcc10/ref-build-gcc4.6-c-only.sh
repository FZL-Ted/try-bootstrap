#!/bin/bash
#
# ref-build-gcc4.6-c-only.sh -- build a **C-only** GCC 4.6.4 against musl.
#
# What this builds
#   Upstream gcc-4.6.4.1, configured with
#
#       --enable-languages=c
#       --disable-build-with-cxx
#
#   and installed as a reference toolchain in
#
#       ref-rootfs-gcc4.6-c-only/usr/gcc4.6
#
#   The resulting compiler ships a C front end (cc1) only: there is no
#   cc1plus, no libstdc++, and no g++/c++ driver.  "-x c++" fails because the
#   C++ front end is not installed.
#
#   Unlike GCC 10, GCC 4.6's own sources are C, so the build does not need a
#   host C++ compiler at all: --disable-build-with-cxx keeps the whole build
#   in C, and CXX is deliberately pointed at the host C compiler (a C++
#   compiler is only needed for the *target* libstdc++, which this build does
#   not produce).
#
#   The build is single stage (--disable-bootstrap), matching the project's
#   3-build-gcc46-stage2.sh.  The compiler is built by the installed GCC 4.6
#   from rootfs3/usr/gcc46.
#
# Inputs (read-only, taken from the existing rootfs3 build)
#   rootfs3/usr/gcc46/bin/gcc         host C compiler (GCC 4.6.4)
#   rootfs3/usr/musl-gcc              target musl 1.2.6 headers + static libs
#   rootfs3/usr/binutils/bin          self-built binutils 2.44 (as/ld/ar/...)
#   rootfs3/usr/include, usr/lib      musl headers + gmp/mpfr/mpc/zlib
#   rootfs3/src/gcc-4.6.4.1/gcc       prepared GCC 4.6 top-level source tree
#   ./gcc-4.6.4.1.tar.gz              only needed when the source must be
#                                     unpacked privately under the ref rootfs
#
# Output (everything new lives under ref-rootfs-gcc4.6-c-only/)
#   usr/gcc4.6                installed C-only GCC 4.6.4
#   usr/{include,lib,musl-gcc,binutils}
#                             a small self-contained target sysroot copied
#                             from rootfs3 (musl + the four support libs +
#                             the self-built binutils)
#   build/gcc4.6-c-only       build tree, configure/make/install logs
#   logs/ref-build-gcc4.6-c-only.log
#
#   The compiler is configured with --with-sysroot=<ref rootfs>, so at run
#   time it finds libc and as/ld inside the ref rootfs rather than rootfs3.
#   As elsewhere in this project the absolute build path is embedded; moving
#   the directory requires reconfiguring.
#
# GCC 4.6 build-tree fixes (needed because the host is modern and fixincludes
# is meaningless for musl):
#   A) STMP_FIXINC = stmp-fixinc -> empty   (--disable-fixincludes does not
#      remove this prerequisite by itself)
#   B) doc: $(BUILD_INFO) $(GENERATED_MANPAGES) -> doc: $(GENERATED_MANPAGES)
#      (the host makeinfo is too new for the 4.6 .texi files)
#   C) drop install-info from install's prerequisites
#   These are applied idempotently to the generated build-tree gcc/Makefile.
#
# Usage
#   ./ref-build-gcc4.6-c-only.sh                    # single-stage C-only build
#   CONF_ONLY=1 ./ref-build-gcc4.6-c-only.sh        # configure only
#   CLEAN=1 ./ref-build-gcc4.6-c-only.sh            # remove the build tree first
#   FORCE_SRC=1 ./ref-build-gcc4.6-c-only.sh        # private source copy under
#                                                   # ref-rootfs-gcc4.6-c-only/src
#   JOBS=8 GOAL=all-gcc ./ref-build-gcc4.6-c-only.sh
#
# Host tools: bash, make, sed, awk, grep, find, cmp, diff, perl, tar, gzip,
#   cp, mv, rm, mkdir, ln, chmod, stat, du, sha256sum, tee, readlink, install,
#   file, sort, head, tail, wc, tr, cut, uniq.
#   No host compiler, assembler, linker, libc or /usr headers are used: every
#   compile/link goes through rootfs3's GCC 4.6 + musl + self-built binutils.
#
# This script does not modify any existing 3-*.sh script or document, and it
# does not write into rootfs3/ (the source tree is reused read-only;
# generated-file fixes are applied to the build tree, never to the source).
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
ROOTFS="$ROOT/rootfs3"
REF="$ROOT/ref-rootfs-gcc4.6-c-only"
TARBALL="$ROOT/gcc-4.6.4.1.tar.gz"
BUILD="$REF/build/gcc4.6-c-only"
PREFIX="/usr/gcc4.6"
INSTALL_ROOT="$REF$PREFIX"
HOST_CC="$ROOTFS/usr/gcc46/bin/gcc"
MUSL_GCC="$ROOTFS/usr/musl-gcc"
REF_USR="$REF/usr"
DEPS="$REF_USR"                              # gmp/mpfr/mpc/zlib headers + libs
SYSROOT="$REF"                               # target sysroot = the ref rootfs
BINUTILS_BIN="$REF_USR/binutils/bin"
TRIPLE="x86_64-pc-linux-gnu"
TARGET="$TRIPLE"
CFLAGS_BUILD="${CFLAGS_BUILD:--O1}"
JOBS="${JOBS:-$(nproc)}"
GOAL="${GOAL:-all}"
CLEAN="${CLEAN:-0}"
FORCE_SRC="${FORCE_SRC:-0}"
CONF_ONLY="${CONF_ONLY:-0}"
LOGDIR="$REF/logs"
LOG="$LOGDIR/ref-build-gcc4.6-c-only.log"

AR_TOOL="$BINUTILS_BIN/ar"; RANLIB_TOOL="$BINUTILS_BIN/ranlib"; NM_TOOL="$BINUTILS_BIN/nm"
AS_BIN="$BINUTILS_BIN/as";  LD_BIN="$BINUTILS_BIN/ld"
READELF="$BINUTILS_BIN/readelf"

die()  { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }
note() { printf '\n==> %s\n' "$*"; }

mkdir -p "$LOGDIR"
exec > >(tee "$LOG") 2>&1

# ---------------------------------------------------------------- 0. Preconditions
note "[0/6] check inputs and host tools"
[ -d "$ROOTFS" ] || die "$ROOTFS not found"
case "$REF" in "$ROOT"/ref-rootfs-gcc4.6-c-only) ;; *) die "unexpected REF path: $REF" ;; esac
[ -x "$HOST_CC" ] || die "missing host compiler $HOST_CC (built by ./3-build-gcc46-stage2.sh)"
[ -f "$MUSL_GCC/lib/libc.a" ] || die "missing $MUSL_GCC/lib/libc.a (built by ./3-build-musl-gcc.sh)"
[ -f "$MUSL_GCC/include/stdio.h" ] || die "missing $MUSL_GCC/include/stdio.h"
for l in libgmp.a libmpfr.a libmpc.a libz.a; do
  [ -f "$ROOTFS/usr/lib/$l" ] || die "missing $ROOTFS/usr/lib/$l (run ./3-build-deps-gcc46.sh first)"
done
for h in gmp.h mpfr.h mpc.h zlib.h; do
  [ -f "$ROOTFS/usr/include/$h" ] || die "missing $ROOTFS/usr/include/$h"
done
for t in "$ROOTFS/usr/binutils/bin/as" "$ROOTFS/usr/binutils/bin/ld" \
         "$ROOTFS/usr/binutils/bin/ar" "$ROOTFS/usr/binutils/bin/ranlib" \
         "$ROOTFS/usr/binutils/bin/nm" "$ROOTFS/usr/binutils/bin/readelf"; do
  [ -x "$t" ] || die "missing self-built binutils: $t (run ./3-build-binutils.sh first)"
done
for t in bash make sed awk grep find cmp diff perl tar gzip cp mv rm mkdir ln chmod stat du sha256sum tee readlink install file sort head tail wc tr cut uniq; do
  command -v "$t" >/dev/null 2>&1 || die "missing host tool: $t"
done
# rootfs3's global sysroot must point at musl-gcc (otherwise musl-1 would leak in)
lc_sys="$(readlink -f "$ROOTFS/usr/lib/libc.a")"; lc_mg="$(readlink -f "$MUSL_GCC/lib/libc.a")"
[ "$lc_sys" = "$lc_mg" ] || die "rootfs3/usr/lib/libc.a does not point at musl-gcc (run ./3-adjust-rootfs-current.sh first)"

echo "    host gcc     : $("$HOST_CC" --version | head -1)  <- $HOST_CC"
echo "    target libc  : $MUSL_GCC (libc.a $(stat -Lc%s "$MUSL_GCC/lib/libc.a") bytes)"
echo "    languages    : c only (--enable-languages=c; no cc1plus, no libstdc++)"
echo "    build style  : single stage, C sources only (--disable-bootstrap --disable-build-with-cxx)"
echo "    ref rootfs   : $REF"
echo "    sysroot      : $SYSROOT (self-contained copy of the musl sysroot)"
echo "    install      : $PREFIX (DESTDIR=$REF -> $INSTALL_ROOT)"
echo "    make goal    : $GOAL    parallelism: $JOBS"

# ---------------------------------------------------------------- 1. Seed the ref rootfs
note "[1/6] seed the ref rootfs target sysroot from rootfs3"
mkdir -p "$REF_USR"
for d in musl-gcc include lib binutils; do
  [ -d "$ROOTFS/usr/$d" ] || die "missing $ROOTFS/usr/$d"
  rm -rf "${REF_USR:?}/$d"
  cp -a "$ROOTFS/usr/$d" "$REF_USR/"
  echo "    usr/$d <- rootfs3/usr/$d"
done
for f in "$REF_USR/include/stdio.h" "$REF_USR/include/stdint.h" \
         "$REF_USR/lib/libc.a" "$REF_USR/lib/libm.a" \
         "$REF_USR/musl-gcc/lib/libc.a" "$REF_USR/lib/libgmp.a" \
         "$REF_USR/lib/libpthread.a" \
         "$AS_BIN" "$LD_BIN" "$READELF"; do
  [ -e "$f" ] || die "seeded ref rootfs is incomplete: missing $f"
done
echo "    target libc : $(readlink -f "$REF_USR/lib/libc.a") ($(stat -Lc%s "$REF_USR/lib/libc.a") bytes)"
echo "    as/ld       : $AS_BIN / $LD_BIN"

# ---------------------------------------------------------------- 2. Source tree
note "[2/6] source tree"
SRC="$ROOTFS/src/gcc-4.6.4.1/gcc"
src_ok() {
  [ -f "$1/configure" ] &&
  [ -f "$1/gcc/Makefile.in" ] &&
  [ -f "$1/libgcc/config.host" ]
}
PRIVATE_SRC=0
if [ "$FORCE_SRC" = 1 ]; then
  PRIVATE_SRC=1
elif ! src_ok "$SRC"; then
  PRIVATE_SRC=1
fi
if [ "$PRIVATE_SRC" = 1 ]; then
  [ -f "$TARBALL" ] || die "$TARBALL not found (needed for a private source copy)"
  SRC="$REF/src/gcc"
  rm -rf "$SRC"
  mkdir -p "$REF/src"
  echo "    unpacking $TARBALL -> $REF/src (top-level directory: gcc/)"
  tar -xzf "$TARBALL" -C "$REF/src"
fi
src_ok "$SRC" || die "$SRC is not a complete GCC 4.6 top-level source tree"
if [ "$PRIVATE_SRC" = 0 ]; then
  echo "    reusing prepared source: $SRC (read-only)"
else
  echo "    private source: $SRC"
fi
[ -f "$SRC/gcc/Makefile.in" ] || die "$SRC/gcc/Makefile.in not found"

# ---------------------------------------------------------------- 3. configure
note "[3/6] configure (C only; CC=$HOST_CC, prefix=$PREFIX)"
if [ "$CLEAN" = 1 ] && [ -d "$BUILD" ]; then
  case "$BUILD" in "$REF"/build/*) rm -rf "$BUILD" ;; *) die "refusing to remove $BUILD" ;; esac
fi
mkdir -p "$BUILD"
cd "$BUILD"
# CXX is set to the host C compiler on purpose: GCC 4.6 is written in C and
# --disable-build-with-cxx keeps it that way.  Setting CXX explicitly also
# stops configure from silently borrowing a host g++ from PATH.
env -u CFLAGS -u CPPFLAGS -u LDFLAGS -u CXXFLAGS \
    CC="$HOST_CC" CXX="$HOST_CC" \
    CFLAGS="$CFLAGS_BUILD" CXXFLAGS="$CFLAGS_BUILD" \
    "$SRC/configure" \
      --prefix="$PREFIX" \
      --build="$TRIPLE" --host="$TRIPLE" --target="$TARGET" \
      --enable-languages=c \
      --disable-bootstrap \
      --disable-build-with-cxx \
      --disable-nls \
      --disable-shared \
      --enable-static \
      --disable-libssp \
      --disable-libgomp \
      --disable-libquadmath \
      --disable-libmudflap \
      --disable-libatomic \
      --disable-libvtv \
      --disable-libsanitizer \
      --disable-multilib \
      --disable-fixincludes \
      --disable-lto \
      --disable-plugin \
      --disable-decimal-float \
      --disable-fixed-point \
      --disable-dependency-tracking \
      --without-cloog \
      --without-ppl \
      --with-system-zlib \
      --with-sysroot="$SYSROOT" \
      --with-as="$AS_BIN" --with-ld="$LD_BIN" \
      --with-gmp-include="$DEPS/include"  --with-gmp-lib="$DEPS/lib" \
      --with-mpfr-include="$DEPS/include" --with-mpfr-lib="$DEPS/lib" \
      --with-mpc-include="$DEPS/include"  --with-mpc-lib="$DEPS/lib" \
      > configure.log 2>&1 || { tail -40 configure.log; die "configure failed (see $BUILD/configure.log)"; }
echo "    configure done"
grep -E 'checking for C compiler|checking whether the C compiler works|checking for the correct version of (gmp|mpfr|mpc)|checking for (as|ld) ' configure.log | tail -8 | sed 's/^/      /' || true
LANGS="$(grep -o -- '--enable-languages=[a-z,]*' config.status | head -1 || true)"
echo "    recorded option: ${LANGS:-(not found)}"
case "$LANGS" in --enable-languages=c) ;; *) die "configure did not record --enable-languages=c (got: $LANGS)" ;; esac
grep -q -- '--enable-languages=c,c++' config.status \
  && die "configure still passes a C++ language list to its subdirectories"
echo "    language list  : c only (config.status has no --enable-languages=c,c++)"

if [ "$CONF_ONLY" = 1 ]; then
  note "[4/6] CONF_ONLY=1: stopping after configure (build tree $BUILD)"
  exit 0
fi

# ---------------------------------------------------------------- 4. configure-gcc + build-tree fixes
note "[4/6] configure-gcc and the 4.6 build-tree Makefile fixes"
set +e
make -k -j"$JOBS" configure-gcc > make-configure-gcc.log 2>&1
cg_rc=$?
set -e
echo "    configure-gcc exit code: $cg_rc (log make-configure-gcc.log)"
[ -f "$BUILD/gcc/Makefile" ] || { tail -30 make-configure-gcc.log | sed 's/^/      /'; die "gcc/Makefile was not generated"; }

# A) --disable-fixincludes leaves stmp-fixinc as a prerequisite, but the
#    build-side fixincludes is not configured; drop the prerequisite.
if grep -q '^STMP_FIXINC = stmp-fixinc$' "$BUILD/gcc/Makefile"; then
  sed -i 's/^STMP_FIXINC = stmp-fixinc$/STMP_FIXINC =/' "$BUILD/gcc/Makefile"
  echo "    [A] removed the stmp-fixinc prerequisite"
elif grep -q '^STMP_FIXINC *= *$' "$BUILD/gcc/Makefile"; then
  echo "    [A] stmp-fixinc already empty (idempotent)"
else
  warn "'STMP_FIXINC = stmp-fixinc' not found in gcc/Makefile"
fi
# B) The host makeinfo is too new for the 4.6 .texi files; drop $(BUILD_INFO)
#    from the doc rule.
if grep -q '^doc: \$(BUILD_INFO) \$(GENERATED_MANPAGES)$' "$BUILD/gcc/Makefile"; then
  sed -i 's/^doc: \$(BUILD_INFO) \$(GENERATED_MANPAGES)$/doc: $(GENERATED_MANPAGES)/' "$BUILD/gcc/Makefile"
  echo "    [B] doc no longer depends on the info documents"
elif grep -q '^doc: \$(GENERATED_MANPAGES)$' "$BUILD/gcc/Makefile"; then
  echo "    [B] doc rule already fixed (idempotent)"
else
  warn "'doc: \$(BUILD_INFO) ...' not found in gcc/Makefile"
fi
# C) install-info would make `make install` exit nonzero after installing;
#    the info documents are not a product of this build.
if sed -n '/^install: install-common/,/install-driver install-lto-wrapper/p' "$BUILD/gcc/Makefile" | grep -q ' install-info '; then
  sed -i '/^install: install-common/,/install-driver install-lto-wrapper/s/ install-info / /' "$BUILD/gcc/Makefile"
  echo "    [C] dropped install-info from install's prerequisites"
elif sed -n '/^install: install-common/,/install-driver install-lto-wrapper/p' "$BUILD/gcc/Makefile" | grep -q 'install-cpp install-man  install-'; then
  echo "    [C] install-info already dropped (idempotent)"
else
  warn "install-info not found among install's prerequisites"
fi
CL="$(grep -m1 '^CONFIG_LANGUAGES' "$BUILD/gcc/Makefile" 2>/dev/null || true)"
case "$CL" in *c++*) die "C++ front end is still selected ($CL)" ;; esac
echo "    gcc/Makefile   : ${CL:-CONFIG_LANGUAGES not found} (no c++)"

# ---------------------------------------------------------------- 5. make
note "[5/6] make -j$JOBS $GOAL (single stage, C only)"
echo "    (AR/RANLIB/NM point at the ref rootfs's self-built binutils)"
t0=$(date +%s)
set +e
make -j"$JOBS" "$GOAL" \
     AR="$AR_TOOL" RANLIB="$RANLIB_TOOL" NM="$NM_TOOL" \
     > make-gcc4.6-c-only.log 2>&1
mk=$?
set -e
t1=$(date +%s)
echo "    make exit code: $mk    wall duration: $((t1-t0)) s"
if [ "$mk" != 0 ]; then
  echo "--- compile errors (warnings excluded) ---"
  grep -nE '^[^ ]+\.(c|cc|h):[0-9]+:[0-9]+: (error|fatal error)' make-gcc4.6-c-only.log | head -20 | sed 's/^/      /' || true
  echo "--- make error lines (first 25) ---"
  grep -nE 'Error [0-9]|error:|undefined reference' make-gcc4.6-c-only.log | head -25 | sed 's/^/      /' || true
  die "make failed (see $BUILD/make-gcc4.6-c-only.log)"
fi
for f in gcc/cc1 "$TARGET/libgcc/libgcc.a"; do
  [ -f "$BUILD/$f" ] && printf '    %-32s %s bytes\n' "$f" "$(stat -c%s "$BUILD/$f")"
done
[ -f "$BUILD/gcc/cc1" ] || die "cc1 was not built"
[ ! -e "$BUILD/gcc/cc1plus" ] || die "cc1plus was built even though --enable-languages=c was given"
CL="$(grep -m1 '^CONFIG_LANGUAGES' "$BUILD/gcc/Makefile" 2>/dev/null || true)"
case "$CL" in *c++*) die "the built compiler's language list is not C-only ($CL)" ;; esac
echo "    built languages: ${CL:-CONFIG_LANGUAGES not found}"

# ---------------------------------------------------------------- 6. install + acceptance
note "[6/6] make install DESTDIR=$REF -> $INSTALL_ROOT"
set +e
make install DESTDIR="$REF" AR="$AR_TOOL" RANLIB="$RANLIB_TOOL" NM="$NM_TOOL" \
     > install.log 2>&1
inst=$?
set -e
echo "    install exit code: $inst"
if [ "$inst" != 0 ]; then
  grep -nE 'Error [0-9]|error:|cannot|No such' install.log | head -20 | sed 's/^/      /' || true
  die "make install failed (see $BUILD/install.log)"
fi
find "$INSTALL_ROOT" -name '*.la' -delete 2>/dev/null || true
echo "    installed tree (first two levels):"
(cd "$INSTALL_ROOT" && find . -maxdepth 2 -type d | sort | head -12 | sed 's/^/      $PREFIX/')

note "acceptance: C compilation, self-contained sysroot, and no C++ front end"
GCC46="$INSTALL_ROOT/bin/gcc"
[ -x "$GCC46" ] || die "$PREFIX/bin/gcc was not installed"
echo "    version        : $("$GCC46" --version | head -1)"
echo "    machine        : $("$GCC46" -dumpmachine)  version=$("$GCC46" -dumpversion)"
echo "    -print-sysroot : $("$GCC46" -print-sysroot)"
echo "    libc.a         : $("$GCC46" -print-file-name=libc.a)"
echo "    as / ld        : $("$GCC46" -print-prog-name=as) / $("$GCC46" -print-prog-name=ld)"
[ "$("$GCC46" -print-sysroot)" = "$REF" ] || die "the installed compiler does not use $REF as its sysroot"
[ "$(readlink -f "$("$GCC46" -print-file-name=libc.a)")" = "$(readlink -f "$REF_USR/lib/libc.a")" ] \
  || die "the installed compiler does not find the ref rootfs's libc.a"

# (a) the installed tree must not contain any C++ front end or C++ library
CC1="$INSTALL_ROOT/libexec/gcc/$TARGET/4.6.4/cc1"
[ -f "$CC1" ] || die "cc1 was not installed"
for p in bin/g++ bin/c++ "bin/$TARGET-g++" "libexec/gcc/$TARGET/4.6.4/cc1plus" \
         include/c++ lib64/libstdc++.a lib/libstdc++.a lib64/libstdc++.so lib/libstdc++.so; do
  [ ! -e "$INSTALL_ROOT/$p" ] || die "unexpected C++ artifact in the install tree: $PREFIX/$p"
done
[ -z "$(find "$INSTALL_ROOT" \( -name 'cc1plus' -o -name 'libstdc++*' -o -name 'g++' \) -print -quit)" ] \
  || die "unexpected C++ artifact found in the install tree"
echo "    C-only check   : no cc1plus / libstdc++ / g++ in $PREFIX"
p="$("$GCC46" -print-file-name=libstdc++.a)"; [ "$p" = "libstdc++.a" ] \
  || die "-print-file-name=libstdc++.a resolved to $p (C++ runtime unexpectedly present)"
echo "    libstdc++      : absent (-print-file-name=libstdc++.a -> $p)"

# (b) C++ compilation must fail: the C++ front end is not installed
W="$BUILD/acc"; mkdir -p "$W"
cat > "$W/neg.cc" <<'CXX_EOF'
#include <cstdio>
int main() { std::printf("c++\n"); return 0; }
CXX_EOF
if "$GCC46" -x c++ -c "$W/neg.cc" -o "$W/neg.o" 2>"$W/neg.err"; then
  die "C++ compilation unexpectedly succeeded; the build is not C-only"
fi
grep -qE 'cc1plus|C\+\+ compiler not installed|language c\+\+ not recognized|not installed' "$W/neg.err" \
  || die "C++ compilation failed for an unexpected reason: $(head -1 "$W/neg.err")"
echo "    -x c++ rejection: \"$(head -1 "$W/neg.err")\""
if "$GCC46" -c "$W/neg.cc" -o "$W/neg.o" 2>"$W/neg-ext.err"; then
  die "a .cc file unexpectedly compiled; the build is not C-only"
fi
grep -qE 'cc1plus|C\+\+ compiler not installed|language c\+\+ not recognized|not installed' "$W/neg-ext.err" \
  || die ".cc compilation failed for an unexpected reason: $(head -1 "$W/neg-ext.err")"
echo "    .cc rejection  : \"$(head -1 "$W/neg-ext.err")\""

# (c) C89 and C99 compilation/execution against the copied musl sysroot
cat > "$W/hello89.c" <<'C_EOF'
#include <stdio.h>
int main(void) { printf("gcc4.6-c89 hello\n"); return 0; }
C_EOF
if "$GCC46" -std=c89 -O2 -Wall -Wextra -o "$W/hello89" "$W/hello89.c" 2>"$W/hello89.err"; then
  out="$("$W/hello89")"
  echo "    C89            : \"$out\""
  [ "$out" = "gcc4.6-c89 hello" ] || die "unexpected C89 output"
else
  sed -n '1,10p' "$W/hello89.err" | sed 's/^/      /'; die "C89 compilation failed"
fi

cat > "$W/c-only.c" <<'C_EOF'
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <complex.h>
#include <float.h>
#include <pthread.h>

static int cmp(const void *a, const void *b) {
  int x = *(const int *)a, y = *(const int *)b;
  return (x > y) - (x < y);
}
static void *add10(void *p) { *(long *)p += 10; return NULL; }

int main(void) {
  int a[5] = {5, 1, 4, 2, 3};
  double complex z;
  long total = 0;
  int n = 5;
  int vla[5];
  int i;
  pthread_t t;

  qsort(a, 5, sizeof a[0], cmp);
  z = csqrt(-4.0);
  for (i = 0; i < n; i++) vla[i] = i;
  if (pthread_create(&t, NULL, add10, &total) != 0) return 2;
  if (pthread_join(t, NULL) != 0) return 3;
  printf("c-only46 %d%d%d%d%d sqrt=%.1f complex=%.1f+%.1fi ld=%d thread=%ld vla=%d\n",
         a[0], a[1], a[2], a[3], a[4], sqrt(2.0),
         creal(z), cimag(z), (int)(LDBL_MANT_DIG), total,
         vla[0] + vla[1] + vla[2] + vla[3] + vla[4]);
  return 0;
}
C_EOF
EXPECT="c-only46 12345 sqrt=1.4 complex=0.0+2.0i ld=64 thread=10 vla=10"
if "$GCC46" -std=c99 -O2 -Wall -Wextra -o "$W/c-only" "$W/c-only.c" -lm -pthread 2>"$W/c-only.err"; then
  out="$("$W/c-only")"
  echo "    C99 compile/run: \"$out\""
  [ "$out" = "$EXPECT" ] || die "unexpected C program output (expected: $EXPECT)"
else
  sed -n '1,12p' "$W/c-only.err" | sed 's/^/      /'; die "C99 acceptance failed"
fi
interp="$("$READELF" -l "$W/c-only" 2>/dev/null | grep -c INTERP || true)"
echo "    static binary  : $interp PT_INTERP entries"
[ "$interp" = 0 ] || die "the produced C binary is dynamically linked (expected static musl)"

# (d) the same compile works in an empty environment
if env -i "$GCC46" -std=c99 -O2 -o "$W/c-only-env" "$W/c-only.c" -lm -pthread 2>"$W/env.err" \
   && [ "$(env -i "$W/c-only-env")" = "$EXPECT" ]; then
  echo "    env -i         : OK (compiles and runs with an empty environment)"
else
  sed -n '1,10p' "$W/env.err" 2>/dev/null | sed 's/^/      /'; die "env -i acceptance failed"
fi

# (e) record the result
INFO="$REF/ref-build-gcc4.6-c-only.info"
{
  echo "GCC_VERSION=4.6.4"
  echo "LANGUAGES=c"
  echo "BUILD_STYLE=single-stage, C sources only (--disable-bootstrap --disable-build-with-cxx)"
  echo "CONFIGURE_ARGS=$LANGS"
  echo "PREFIX=$PREFIX"
  echo "SYSROOT=$SYSROOT"
  echo "INSTALL_ROOT=$INSTALL_ROOT"
  echo "HOST_CC=$HOST_CC"
  echo "CC1=$CC1"
  echo "CC1_SIZE=$(stat -c%s "$CC1")"
  echo "LIBGCC_SIZE=$(stat -c%s "$INSTALL_ROOT/lib/gcc/$TARGET/4.6.4/libgcc.a" 2>/dev/null || echo 0)"
  echo "C89_ACCEPTANCE=gcc4.6-c89 hello"
  echo "C99_ACCEPTANCE=$EXPECT"
  echo "CXX_REJECTED=$([ ! -e "$INSTALL_ROOT/libexec/gcc/$TARGET/4.6.4/cc1plus" ] && echo yes || echo no)"
} > "$INFO"

note "done (log: $LOG)"
cat <<EOF
  installed to: $INSTALL_ROOT
  C compiler  : $INSTALL_ROOT/bin/gcc
  sysroot     : $SYSROOT
  C++ support : none (cc1plus / libstdc++ / g++ are absent by design)
EOF
