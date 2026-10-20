#!/bin/bash
#
# 3-build-gcc46-stage2.sh — rebuild GCC 4.6.4.1 (stage2) with the **first-generation
#   gcc46 (stage1) + musl-gcc**. This pass also produces its **own** `libgcc` and a
#   static `libstdc++`, and installs the result under `rootfs3/usr/gcc46/`.
#
# Why this step exists (and how it splits work with ./3-build-gcc46-xcc.sh):
#   * The `all-gcc` + `libgcc` passes of ./3-build-gcc46-xcc.sh produce `cc1`/`cc1plus`
#     that were **compiled by xcc** and linked against the **xcc-built libc**
#     (musl-1). Every later product — gcc-10 in particular — inherits that lineage,
#     and xcc has already been caught generating broken code that still appeared to
#     run: it allocated `%rbp` as a general-purpose register, so the frame pointer
#     got clobbered (fixed by patches-3/xcc-regalloc-reserve-frame-pointer.patch).
#   * Here **gcc46 itself** compiles GCC 4.6: the resulting `cc1`/`cc1plus` are real
#     GCC output, and the target libc becomes **musl-gcc** (the musl rebuilt in full
#     by gcc46: 1349/1349 objects, including `_Complex` and a true 80-bit
#     `long double`).
#   * It is also the strongest acceptance test of "is gcc46 good enough?": one run
#     has to compile GCC's own thousands of C files + the C++ front end + the .cc
#     sources of `libstdc++`.
#
# Target libc / sysroot (two modes):
#   * **Default: `--with-sysroot=$ROOTFS`, i.e. the current rootfs itself** — the
#     compiler's target headers/libraries are `rootfs3/usr/{include,lib}`. That
#     requires them to already point at the **latest musl (musl-gcc) + the latest
#     four libraries** (`./3-adjust-rootfs-current.sh` repoints the musl links under
#     `usr/{include,lib}` from musl-1 to musl-gcc). The script **hard-checks** that
#     `usr/lib/libc.a` and `$MUSL_GCC/lib/libc.a` are the same file, and aborts with
#     two ways out (adjust the rootfs first / use the view mode). So "adjust the
#     rootfs" and "let GCC use the latest musl + libraries" are one and the same
#     action; no extra view or flag is needed.
#   * **View mode** (explicit opt-in):
#         SYSROOT=$ROOTFS/usr/musl-gcc-sysroot ./3-build-gcc46-stage2.sh
#     The view holds `usr -> ../musl-gcc` (a relative symlink) plus
#     `deps/{include,lib}` with only the four libraries (5 headers, 4 archives). Its
#     purpose is to **isolate** `rootfs3/usr/lib/libc.a`: in view mode `-L` would
#     pull that symlink into the link, and while the rootfs is unadjusted it is still
#     musl-1's libc.a, which does not mix with musl-gcc's crt1.o (`_DYNAMIC`,
#     explained in [1/7]).
#   Both modes place an empty `libpthread.a` under `<sysroot>/lib/` as a fallback
#   (musl folds pthread into libc).
#
# Who compiles what:
#   * **Host side** (GCC's own .c/.cc): CC = `$BUILD/gcc46-cc`, which execs
#     **stage1's xgcc** (`$S1/gcc/xgcc -B$S1/gcc --sysroot=$SYSROOT -isystem $DEPINC
#     -L$DEPLIB`), so host code is compiled by gcc46 and linked against musl-gcc;
#     `as`/`ld` go through `$S1/gcc/{as,collect-ld}` → the **self-built binutils**.
#   * **Target side** (stage2's libgcc / libstdc++): compiled by the top-level
#     Makefile's `CC_FOR_TARGET = $BUILD/gcc/xgcc -B$BUILD/gcc/` (**stage2's own**
#     cc1/cc1plus); assembling/linking also uses the self-built binutils (pinned at
#     configure time via `--with-as/--with-ld`).
#
# Prerequisites (all from the `3-` chain):
#   rootfs3/build/gcc-4.6.4.1/gcc/{cc1,cc1plus,xgcc,libgcc.a,crtbegin.o,crtend.o}
#                                                  ← ./3-build-gcc46-xcc.sh (all-gcc + libgcc)
#   rootfs3/usr/musl-gcc/{include,lib/libc.a,lib/crt1.o}   ← SELFTEST=1 ./3-build-musl-gcc.sh
#   rootfs3/usr/{include/gmp.h,mpfr.h,mpc.h,zlib.h}        ← ./3-build-{gmp,mpfr,mpc,zlib}.sh
#   rootfs3/usr/lib/{libgmp.a,libmpfr.a,libmpc.a,libz.a}   ← the same four scripts
#   rootfs3/usr/binutils/bin/{as,ld}                       ← ./3-build-binutils.sh (required)
#     ar/ranlib/nm are preferred from the same directory; only `ar` falls back to the host
#
# Output (on success):
#   rootfs3/build/gcc46-stage2/gcc/{cc1,cc1plus,xgcc,collect2}   stage2 compilers (in-tree)
#   rootfs3/build/gcc46-stage2/x86_64-pc-linux-gnu/libgcc/libgcc.a        stage2's libgcc
#   rootfs3/build/gcc46-stage2/x86_64-pc-linux-gnu/libstdc++-v3/…         stage2's libstdc++
#   rootfs3/usr/gcc46/{bin,lib,lib64,libexec,include/c++/4.6.4}           installed toolchain
#   results/3-build-gcc46-stage2.log                                       full log
#
# Usage:
#   ./3-build-gcc46-stage2.sh              # configure -> gcc/Makefile fixes -> make all -> install -> acceptance
#   CONF_ONLY=1 ./3-build-gcc46-stage2.sh  # stop after configure
#   CLEAN=1 ./3-build-gcc46-stage2.sh      # delete the build tree first
#   GOAL=all-gcc ./3-build-gcc46-stage2.sh # build only the stage2 compilers (no target libraries)
#   NO_INSTALL=1 ./3-build-gcc46-stage2.sh # skip install (acceptance inside the build tree only)
#   JOBS=n / CPU_LIMIT=seconds             # parallelism / CPU-time cap for make (ulimit -t)
#
# ---------------------------------------------------------------------------
# Host binaries used — full disclosure. Apart from the stage1 gcc46 and the
# self-built binutils inside rootfs3, this script only calls the host binaries listed
# below (all unpack/text/archive/driver tools, none of them a compiler):
#   /usr/bin/bash  runs this script;  /usr/bin/make  drives configure/Makefile;
#   sed / awk(gawk) / grep / find / sort / uniq / cat / head / tail / wc / tr / cut
#   cp / mv / rm / mkdir / ln / chmod / cmp / stat / sha256sum / readlink
#   file / readelf / tee        (tee mirrors the whole run into results/…)
#   nproc / date                (JOBS default; timestamp in timing.txt)
#   ar / nm / ranlib            (from the self-built binutils; only `ar` falls back to the host)
# tar/gzip are not needed: ./3-build-gcc46-xcc.sh already unpacked the sources, reused here.
# Never used: host gcc/cc/clang/g++/cpp, host /usr/include and /usr/lib.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
ROOTFS="$ROOT/rootfs3"
S1="$ROOTFS/build/gcc-4.6.4.1"                 # stage1 build tree (from ./3-build-gcc46-xcc.sh)
S1XGCC="$S1/gcc/xgcc"
MUSL_GCC="$ROOTFS/usr/musl-gcc"                # the musl that gcc46 rebuilt in full (1349/1349 objects)
DEPS="$ROOTFS/usr"                             # the four libraries are installed here too
SRCDIR_ROOT="$ROOTFS/src/gcc-4.6.4.1"          # the same unpacked source tree as ./3-build-gcc46-xcc.sh
SRC="$SRCDIR_ROOT/gcc"
BUILD="$ROOTFS/build/gcc46-stage2"
SYSROOT="${SYSROOT:-$ROOTFS}"                  # default = rootfs3 itself (the current rootfs's usr/{include,lib})
VIEW_MODE=0; [ "$SYSROOT" = "$ROOTFS" ] || VIEW_MODE=1
PREFIX="${PREFIX:-/usr/gcc46}"                 # install prefix (combined with DESTDIR=$ROOTFS)
INSTALL_ROOT="$ROOTFS$PREFIX"
WRAP="$BUILD/gcc46-cc"                         # host-side CC wrapper
LOGDIR="$ROOT/results"
LOG="$LOGDIR/3-build-gcc46-stage2.log"

JOBS="${JOBS:-$(nproc)}"
CLEAN="${CLEAN:-0}"
CONF_ONLY="${CONF_ONLY:-0}"
NO_INSTALL="${NO_INSTALL:-0}"
GOAL="${GOAL:-all}"                            # all = all-host + all-target (incl. libgcc/libstdc++)
CFLAGS_BUILD="${CFLAGS_BUILD:--O1}"
CPU_LIMIT="${CPU_LIMIT:-0}"
TRIPLE="x86_64-pc-linux-gnu"
TARGET="${TARGET:-x86_64-pc-linux-gnu}"

die()  { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }
note() { printf '\n==> %s\n' "$*"; }

# ---------------------------------------------------------------- as/ld/ar sources
BINUTILS_BIN="${BINUTILS_BIN:-$ROOTFS/usr/binutils/bin}"
if [ -x "$BINUTILS_BIN/as" ] && [ -x "$BINUTILS_BIN/ld" ]; then
  AS_BIN="$BINUTILS_BIN/as"; LD_BIN="$BINUTILS_BIN/ld"; ASLD_SRC="binutils(self-built)"
else
  die "self-built binutils not found: $BINUTILS_BIN/{as,ld} (run ./3-build-binutils.sh first)"
fi
AR_TOOL="$BINUTILS_BIN/ar"; RANLIB_TOOL="$BINUTILS_BIN/ranlib"; NM_TOOL="$BINUTILS_BIN/nm"
[ -x "$AR_TOOL" ] || AR_TOOL=ar

# Locations of the four libraries' (gmp/mpfr/mpc/zlib) headers and archives, which
# follow the sysroot mode:
#   * Default (SYSROOT=$ROOTFS): the global sysroot `$ROOTFS/usr/{include,lib}` (the
#     four libraries are installed there with --prefix=/usr). In that case
#     `-L$ROOTFS/usr/lib` and the compiler sysroot's libc.a are the **same file**
#     (both musl-gcc), so the "musl-1 libc.a mixed into the link ⇒ _DYNAMIC" pitfall
#     cannot happen.
#   * View mode (SYSROOT=<view>): the `$SYSROOT/deps/{include,lib}` mini-view that
#     holds **only the four libraries** (in view mode `-L$ROOTFS/usr/lib` would drag
#     musl-1's libc.a in, so it has to be isolated).
if [ "$VIEW_MODE" = 1 ]; then
  DEPINC="$SYSROOT/deps/include"; DEPLIB="$SYSROOT/deps/lib"
else
  DEPINC="$DEPS/include"; DEPLIB="$DEPS/lib"
fi

mkdir -p "$LOGDIR"
exec > >(tee "$LOG") 2>&1

# ---------------------------------------------------------------- 0. Preconditions
note "[0/7] checking inputs and host tools"
[ -f "$SRC/configure" ] || die "$SRC/configure not found (run the unpack step of ./3-build-gcc46-xcc.sh first)"
for f in cc1 cc1plus xgcc libgcc.a crtbegin.o crtend.o; do
  [ -e "$S1/gcc/$f" ] || die "missing stage1 product $S1/gcc/$f (run all-gcc + GOAL=all-target-libgcc of ./3-build-gcc46-xcc.sh first)"
done
[ -f "$MUSL_GCC/lib/libc.a" ] || die "missing $MUSL_GCC/lib/libc.a (run SELFTEST=1 ./3-build-musl-gcc.sh first)"
[ -f "$MUSL_GCC/lib/crt1.o" ] || die "missing $MUSL_GCC/lib/crt1.o (musl-gcc's startup file)"
[ -f "$MUSL_GCC/include/stdio.h" ] || die "missing $MUSL_GCC/include/stdio.h"
for h in gmp.h mpfr.h mpc.h zlib.h; do
  [ -f "$DEPS/include/$h" ] || die "missing $DEPS/include/$h (run ./3-build-{gmp,mpfr,mpc,zlib}.sh first)"
done
for l in libgmp.a libmpfr.a libmpc.a libz.a; do
  [ -f "$DEPS/lib/$l" ] || die "missing $DEPS/lib/$l (run ./3-build-{gmp,mpfr,mpc,zlib}.sh first)"
done
for t in bash make sed awk grep find cp mv rm mkdir ln chmod cmp stat sha256sum readlink \
         file readelf tee cat head tail wc tr cut sort uniq; do
  command -v "$t" >/dev/null 2>&1 || die "missing host tool: $t"
done

echo "    stage1 gcc46 : $("$S1XGCC" --version 2>/dev/null | head -1)  ($(sha256sum "$S1XGCC" | cut -c1-16))"
echo "    stage1 cc1   : $(stat -c%s "$S1/gcc/cc1") bytes   cc1plus: $(stat -c%s "$S1/gcc/cc1plus") bytes"
echo "    stage1 libgcc: $(stat -c%s "$S1/gcc/libgcc.a") bytes (this step produces stage2's own copy)"
echo "    musl-gcc     : libc.a $(stat -Lc%s "$MUSL_GCC/lib/libc.a") bytes  sha256=$(sha256sum "$MUSL_GCC/lib/libc.a" | cut -c1-16)"
echo "                     headers: $(find "$MUSL_GCC/include" -type f | wc -l)"
echo "    four libraries: gmp $(stat -c%s "$DEPS/lib/libgmp.a") / mpfr $(stat -c%s "$DEPS/lib/libmpfr.a") / mpc $(stat -c%s "$DEPS/lib/libmpc.a") / zlib $(stat -c%s "$DEPS/lib/libz.a") bytes"
echo "    as/ld        : $ASLD_SRC → as=$(sha256sum "$AS_BIN" | cut -c1-16)  ld=$(sha256sum "$LD_BIN" | cut -c1-16)"
echo "    target sysroot: $SYSROOT  ($([ "$VIEW_MODE" = 1 ] && echo 'view mode: usr -> ../musl-gcc' || echo 'global sysroot mode: usr/{include,lib} of rootfs3'))"
echo "    install      : ${PREFIX}  (DESTDIR=$ROOTFS → $INSTALL_ROOT)"
echo "    build/host/target : $TRIPLE / $TRIPLE / $TARGET     make goal: $GOAL"
# libtool archives record absolute paths, and nothing in this build reads them, so
# drop the four libraries' .la files first (zlib installs none). A stale .la could
# let a libtool-driven step resolve a host path instead of the sysroot one.
rm -f "$DEPS/lib"/libgmp.la "$DEPS/lib"/libmpfr.la "$DEPS/lib"/libmpc.la

# ------------------------------------- 1. Target sysroot (two modes) + libpthread.a fallback
if [ "$VIEW_MODE" = 0 ]; then
  note "[1/7] using the global sysroot $SYSROOT directly (the current rootfs's usr/{include,lib})"
  # Precondition: ./3-adjust-rootfs-current.sh has already repointed the musl links
  # under usr/{include,lib} from musl-1 to musl-gcc. Hard-check that it really is the
  # same musl — otherwise a toolchain would silently be built with musl-1 headers and
  # libraries and end up with a mismatched target libc.
  for p in usr/include/stdio.h usr/lib/libc.a usr/lib/crt1.o usr/lib/libm.a; do
    [ -e "$SYSROOT/$p" ] || die "cannot resolve $p in the global sysroot (run ./3-adjust-rootfs-current.sh first)"
  done
  lc_sys="$(readlink -f "$SYSROOT/usr/lib/libc.a")"
  lc_mg="$(readlink -f "$MUSL_GCC/lib/libc.a")"
  if [ "$lc_sys" != "$lc_mg" ]; then
    die "the global sysroot does not point at musl-gcc:
       $SYSROOT/usr/lib/libc.a -> $(readlink "$SYSROOT/usr/lib/libc.a")
       (expected to be the same file as $MUSL_GCC/lib/libc.a)
     run ./3-adjust-rootfs-current.sh first; or switch explicitly to "view mode":
       SYSROOT=$ROOTFS/usr/musl-gcc-sysroot ./3-build-gcc46-stage2.sh"
  fi
  echo "    ✅ global sysroot already points at musl-gcc: usr/lib/libc.a -> $(readlink "$SYSROOT/usr/lib/libc.a")"
  echo "       (so -L$SYSROOT/usr/lib and the compiler sysroot's libc.a are the same file ⇒ no mixed-link pitfall)"
  for l in libgmp.a libmpfr.a libmpc.a libz.a; do
    [ -f "$DEPLIB/$l" ] || die "the four libraries are missing from the global sysroot: $DEPLIB/$l (run ./3-build-deps-gcc46.sh or ./3-build-{gmp,mpfr,mpc,zlib}.sh first)"
  done
  for h in gmp.h mpfr.h mpc.h zlib.h; do
    [ -f "$DEPINC/$h" ] || die "the four libraries' header is missing from the global sysroot: $DEPINC/$h"
  done
  echo "    ✅ four libraries in place: $DEPLIB/{libgmp,libmpfr,libmpc,libz}.a + $DEPINC/{gmp,mpfr,mpc,zlib}.h"
else
  note "[1/7] creating the sysroot view $SYSROOT (pointing at musl-gcc) — view mode"
  mkdir -p "$SYSROOT"
  ln -sfn ../musl-gcc "$SYSROOT/usr"
  for p in usr/include/stdio.h usr/lib/libc.a usr/lib/crt1.o usr/lib/libm.a; do
    [ -e "$SYSROOT/$p" ] || die "cannot resolve $p in the sysroot view (is $SYSROOT/usr -> ../musl-gcc correct?)"
  done
  echo "    ✅ view usable: usr/include/stdio.h and usr/lib/{libc.a,crt1.o,libm.a} all resolve"
fi
# musl folds pthread into libc, but GCC's `*lib:` spec still contains
# `%{pthread:-lpthread}`, and libstdc++'s configure probes/test links may pass
# `-pthread` — so provide an **empty archive** as a fallback (the real symbols live
# in libc.a; this is the usual practice for musl cross toolchains and does not
# change musl-gcc itself).
mkdir -p "$SYSROOT/lib"
if [ ! -f "$SYSROOT/lib/libpthread.a" ]; then
  "$AR_TOOL" rcs "$SYSROOT/lib/libpthread.a"
  echo "    creating the fallback empty archive $SYSROOT/lib/libpthread.a (musl has no separate libpthread)"
fi

if [ "$VIEW_MODE" = 1 ]; then
# ★ View mode only: put the four libraries' headers and archives into a
#   subdirectory of the view. In view mode `-L$ROOTFS/usr/lib` would pull the
#   rootfs's `libc.a` symlink into the link — still **musl-1** when the rootfs has
#   not been adjusted — mixing it with musl-gcc's crt1.o ⇒ `undefined reference to
#   _DYNAMIC` (that symbol is **U** in musl-1 but **w** in musl-gcc: xcc compiled
#   musl's `extern weak hidden` declaration into a strong reference). Likewise
#   `-I$ROOTFS/usr/include` would bring in the 218 musl-1 headers. Hence the
#   isolated `deps/` view.
#   (The default "global sysroot" mode needs none of this: there usr/lib/libc.a is
#    musl-gcc's own copy, guaranteed by the hard check in [1/7].)
mkdir -p "$SYSROOT/deps/include" "$SYSROOT/deps/lib"
for h in gmp.h mpfr.h mpc.h zlib.h zconf.h; do
  [ -f "$DEPS/include/$h" ] || die "missing four-library header $DEPS/include/$h"
  ln -sfn "$DEPS/include/$h" "$SYSROOT/deps/include/$h"
done
for l in libgmp.a libmpfr.a libmpc.a libz.a; do
  [ -f "$DEPS/lib/$l" ] || die "missing four-library archive $DEPS/lib/$l"
  ln -sfn "$DEPS/lib/$l" "$SYSROOT/deps/lib/$l"
done
echo "    ✅ four-library view: $SYSROOT/deps/include/{gmp,mpfr,mpc,zlib,zconf}.h + deps/lib/{libgmp,libmpfr,libmpc,libz}.a"
fi

# ------------------------------------- 2. Source adaptation: make libstdc++ recognize musl (os/generic)
note "[2/7] libstdc++-v3/configure.host: \"os/gnu-linux\" -> \"os/generic\" (makes libstdc++ recognize musl)"
CH="$SRC/libstdc++-v3/configure.host"
if grep -q '"os/gnu-linux"' "$CH"; then
  sed -i 's|"os/gnu-linux"|"os/generic"|' "$CH"
  echo "    ✅ patched (GCC 4.6's libstdc++ only knows os/gnu-linux, musl is not glibc, so it has to take os/generic)"
else
  grep -q '"os/generic"' "$CH" || die "$CH contains neither \"os/gnu-linux\" nor \"os/generic\" (different source version?)"
  echo "    already os/generic (idempotent: patched by an earlier run)"
fi
grep -n 'os_include_dir="os/generic"' "$CH" | head -3 | sed 's/^/      /'
echo "    (configure also passes --enable-clocale=generic explicitly: musl's features.h does not define __GLIBC__,"
echo "       the gnu locale model needs glibc's xlocale/strxfrm_l, so generic is pinned here)"

# ---------------------------------------------------------------- 3. CC wrapper
note "[3/7] writing the host-side CC wrapper $WRAP"
# ★ CLEAN has to happen here (**before the wrapper is written**): the wrapper lives
#   in $BUILD, so "write the wrapper, then rm -rf $BUILD" would make configure fail
#   with "C compiler cannot create executables".
if [ "$CLEAN" = 1 ]; then
  echo "    CLEAN=1: removing $BUILD (including the previous run's wrapper/self-check artifacts)"
  rm -rf "$BUILD"
fi
mkdir -p "$BUILD"
# -B$S1/gcc supplies everything at once: cc1/cc1plus (stage1's), as/collect-ld (the
# scripts that forward to the self-built binutils), libgcc.a/crtbegin.o/crtend.o
# (stage1's, used for gcc46's own links); the GCC-internal headers
# (stddef.h/stdarg.h/unwind.h…) live in gcc/include there too, so no extra -isystem
# for them is needed.
# The explicit --sysroot wins over the rootfs3 path recorded in stage1's specs (we
# want musl-gcc here).
cat > "$WRAP" <<WRAP_EOF
#!/bin/sh
# Generated by 3-build-gcc46-stage2.sh: the host-side CC for the stage2 build
# (stage1 gcc46 + the target sysroot). Mode: $([ "$VIEW_MODE" = 1 ] && echo 'view mode (sysroot=<view>; -isystem/-L point at the <view>/deps four-library view)' || echo 'global sysroot mode (sysroot=rootfs3; -isystem/-L are rootfs3/usr, four libraries and musl side by side)').
# -B$S1/gcc supplies stage1's cc1/cc1plus, as/collect-ld (self-built binutils) and libgcc/crtbegin.
exec $S1XGCC -B$S1/gcc --sysroot=$SYSROOT -isystem $DEPINC -L$DEPLIB "\$@"
WRAP_EOF
chmod 755 "$WRAP"
echo "    $(cat "$WRAP" | tail -2 | head -1)"
echo "    self-check (compile and run a small program using malloc/snprintf):"
TMPD="$ROOTFS/tests"; mkdir -p "$TMPD"
cat > "$TMPD/3-stage2-wrapcheck.c" <<'C_EOF'
#include <stdio.h>
#include <stdlib.h>
int main(void) { char *p = malloc(4096); if (!p) return 1; snprintf(p, 4096, "gcc46+musl-gcc %d", 46); puts(p); free(p); return 0; }
C_EOF
if "$WRAP" -o "$BUILD/wrapcheck" "$TMPD/3-stage2-wrapcheck.c" 2>"$BUILD/wrapcheck.err"; then
  out="$("$BUILD/wrapcheck")"
  echo "      -> \"$out\"   $(file -b "$BUILD/wrapcheck" | cut -d, -f1-2)"
  [ "$out" = "gcc46+musl-gcc 46" ] || die "unexpected wrapper self-check output: $out"
else
  sed -n '1,15p' "$BUILD/wrapcheck.err" | sed 's/^/      /'; die "CC wrapper self-check failed"
fi
echo "    header/library search list:"
echo | "$WRAP" -E -v - 2>&1 | sed -n '/search starts here/,/End of search list/p' | sed 's/^/      /'

# ---------------------------------------------------------------- 4. configure
note "[4/7] configure (CC=$WRAP, --enable-languages=c,c++, target libraries include libgcc + libstdc++)"
mkdir -p "$BUILD"
cd "$BUILD"
find "$BUILD" -maxdepth 3 -name config.cache -delete 2>/dev/null || true

# Option notes (differences from ./3-build-gcc46-xcc.sh are spelled out):
#   --prefix=/usr/gcc46 + DESTDIR=$ROOTFS at install time ⇒ lands in
#     rootfs3/usr/gcc46/. The driver derives gcc_exec_prefix from argv[0] and cc1's
#     incpath.c has relocated_prefix logic, so "configured prefix ≠ actual location"
#     still finds cc1/libgcc/include/c++ (verified by the acceptance tests).
#   --enable-languages=c,c++ and **no** --disable-libstdcxx: this step wants libstdc++.
#   --enable-clocale=generic   musl is not glibc (see [2/7]).
#   --disable-libstdcxx-pch   no precompiled headers (simpler, avoids pch-only deps).
#   --disable-dependency-tracking   no .d dependency files (a one-shot build tree
#     does not need them).
#   --disable-shared / --enable-static  ⇒ only libstdc++.a/libsupc++.a, no .so.
#   The rest (--disable-{bootstrap,nls,multilib,fixincludes,lto,plugin,decimal-float,
#   fixed-point,libssp,libgomp,libquadmath,libmudflap,libatomic,libvtv,libsanitizer},
#   --without-{cloog,ppl}, --with-system-zlib, --with-sysroot, --with-as/--with-ld,
#   and the four-library --with-*) matches ./3-build-gcc46-xcc.sh.
# Thread model: **no** --disable-threads (defaults to posix) — musl folds pthread into
#   libc.a, and pthread.h/pthread_* are all present ([1/7]'s libpthread.a only covers
#   a `-lpthread` on the link line).
# CXX: must be set to our wrapper explicitly — otherwise configure takes the **host
#   g++** from PATH ("checking for g++... g++" ⇒ "using the GNU C++ compiler... yes",
#   i.e. it borrows the host compiler, which violates the project constraint). GCC
#   4.6's host-side sources are all C; C++ is only needed on the *target* side
#   (libstdc++), which uses CXX_FOR_TARGET (= stage2's own g++), so here CXX only has
#   to compile without touching the host; --disable-build-with-cxx additionally
#   states "do not compile GCC itself with C++".
env -u CFLAGS -u CPPFLAGS -u LDFLAGS \
    CC="$WRAP" CXX="$WRAP" CFLAGS="$CFLAGS_BUILD" CXXFLAGS="$CFLAGS_BUILD" \
    "$SRC/configure" \
      --prefix="$PREFIX" \
      --build="$TRIPLE" --host="$TRIPLE" --target="$TARGET" \
      --enable-languages=c,c++ \
      --enable-clocale=generic \
      --disable-bootstrap \
      --disable-build-with-cxx \
      --disable-nls \
      --disable-shared \
      --enable-static \
      --disable-libstdcxx-pch \
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
      --with-as="$AS_BIN" \
      --with-ld="$LD_BIN" \
      --with-gmp-include="$DEPINC" --with-gmp-lib="$DEPLIB" \
      --with-mpfr-include="$DEPINC" --with-mpfr-lib="$DEPLIB" \
      --with-mpc-include="$DEPINC" --with-mpc-lib="$DEPLIB" \
      > configure.log 2>&1 || { echo "--- configure tail ---"; tail -40 configure.log; die "configure failed (see $BUILD/configure.log)"; }
echo "    configure done"
grep -E '^checking for C compiler|host system type|target system type|^checking for gmp.h|^checking for mpfr.h|^checking for mpc.h|^checking whether the C compiler works' configure.log | head -8 | sed 's/^/      /'
echo "    target library directories (should include libgcc and libstdc++-v3):"
grep -E '^TARGET_CONFIGDIRS *=' Makefile 2>/dev/null | sed 's/^/      /' | cut -c1-220 || true
grep -qE '^TARGET_CONFIGDIRS *=.*libstdc\+\+' Makefile 2>/dev/null \
  || warn "TARGET_CONFIGDIRS has no libstdc++-v3 — libstdc++ will not be built (check --enable-languages and --disable-libstdcxx)"

if [ "$CONF_ONLY" = 1 ]; then
  note "[5/7] CONF_ONLY=1: configure only, stopping here"
  echo "    build tree: $BUILD"
  exit 0
fi

# --------------------------- 5. Pre-configure the gcc subdirectory + three required fixes
note "[5/7] pre-configuring the gcc subdirectory and stripping the prerequisites that make all-gcc / install fail"
# The same kind of fixes as ./3-build-gcc46-xcc.sh's [2b/5]; they must be redone here
# because stage2 is a fresh build tree:
#   A) `stmp-fixinc`: a prerequisite that --disable-fixincludes does not remove, while
#      the build-side fixincludes is not configured
#   B) `doc: $(BUILD_INFO) …`: the host makeinfo is too old, so doc/gccint.info fails
#   C) `install: … install-info …`: B only keeps `all` from generating info; install
#      still lists it as a prerequisite
# Without A/B, `all-gcc` exits 2, and `all-target-libgcc`/`all-target-libstdc++-v3`
# depend on it ⇒ the target libraries never even reach configure (a full make run
# then ends with nothing to show).
# All three are **idempotent**: a re-run reports "already patched" instead of a bogus
# "not found".
set +e
make -k -j"$JOBS" configure-gcc > make-configure-gcc.log 2>&1
cg_rc=$?
set -e
echo "    configure-gcc exit code $cg_rc (log $BUILD/make-configure-gcc.log)"
[ -f "$BUILD/gcc/Makefile" ] || { tail -30 make-configure-gcc.log | sed 's/^/      /'; die "gcc/Makefile was not generated"; }
if grep -q '^STMP_FIXINC = stmp-fixinc$' gcc/Makefile; then
  sed -i 's/^STMP_FIXINC = stmp-fixinc$/STMP_FIXINC =/' gcc/Makefile
  echo "    ✅ [A] removed the stmp-fixinc prerequisite (fixincludes is meaningless for musl and is not configured on the build side)"
elif grep -q '^STMP_FIXINC *= *$' gcc/Makefile; then
  echo "    [A] already empty (idempotent: patched by an earlier run)"
else
  warn "'STMP_FIXINC = stmp-fixinc' not found in gcc/Makefile (different GCC version?)"
fi
if grep -q '^doc: \$(BUILD_INFO) \$(GENERATED_MANPAGES)$' gcc/Makefile; then
  sed -i 's/^doc: \$(BUILD_INFO) \$(GENERATED_MANPAGES)$/doc: $(GENERATED_MANPAGES)/' gcc/Makefile
  echo "    ✅ [B] made doc stop depending on the info documents (the host makeinfo is too old)"
elif grep -q '^doc: \$(GENERATED_MANPAGES)$' gcc/Makefile; then
  echo "    [B] already doc: \$(GENERATED_MANPAGES) (idempotent)"
else
  warn "'doc: \$(BUILD_INFO) \$(GENERATED_MANPAGES)' not found in gcc/Makefile"
fi
# C) `install-info`: fix B only keeps `all` from generating info, but
#    `install: … install-info …` in gcc/Makefile still lists it as a prerequisite
#    ⇒ `make install` exits 2 (measured: everything is in fact installed and the
#    acceptance tests pass; only the exit code is wrong).
#    info docs are not our product ⇒ drop that one word from install's prerequisites;
#    the `install-info --dir-file=…` line inside the recipe stays as is.
if grep -q 'install-cpp install-man install-info' gcc/Makefile; then
  sed -i '/^install: install-common/,/install-driver install-lto-wrapper/s/ install-info / /' gcc/Makefile
  echo "    ✅ [C] removed install-info from install's prerequisites (we do not generate info documents)"
elif grep -q 'install-cpp install-man  install-' gcc/Makefile; then
  echo "    [C] install no longer has an install-info prerequisite (idempotent)"
else
  warn "install-info not found among gcc/Makefile's install prerequisites (different version?)"
fi

# ---------------------------------------------------------------- 6. make
note "[6/7] make -k $GOAL -j$JOBS (all-host + all-target: stage2 cc1/cc1plus + libgcc + libstdc++)"
TIMEFORMAT='    make time: %R real, %U user, %S sys'
# AR/RANLIB/NM point at the self-built binutils: the top-level Makefile spells out
# `'AR=$(AR)'` in EXTRA_HOST_FLAGS and `'AR=$$(AR_FOR_TARGET)'` (with
# AR_FOR_TARGET=$(AR)) in EXTRA_TARGET_FLAGS, so command-line overrides are forwarded
# to the sub-makes.
MAKE_ARGS=(
  "AR=$AR_TOOL" "RANLIB=$RANLIB_TOOL" "NM=$NM_TOOL"
)
set +e
if [ "$CPU_LIMIT" -gt 0 ] 2>/dev/null; then
  echo "    CPU time limit: $CPU_LIMIT s (ulimit -t)"
  time ( ulimit -t "$CPU_LIMIT"; make -k -j"$JOBS" "$GOAL" "${MAKE_ARGS[@]}" > make-stage2.log 2>&1 )
else
  time make -k -j"$JOBS" "$GOAL" "${MAKE_ARGS[@]}" > make-stage2.log 2>&1
fi
make_rc=$?
set -e
echo "    make exit code: $make_rc"
{ echo "goal=$GOAL"; echo "cpu_limit=$CPU_LIMIT"; echo "exit=$make_rc"; echo "date=$(date -Iseconds)"; } > timing.txt

# ---------------------------------------------------------------- 7. Summary / acceptance / install
note "[7/7] result summary and acceptance"
echo "    --- the stage2 compilers themselves ---"
for f in cc1 cc1plus xgcc collect2; do
  if [ -e "gcc/$f" ]; then printf '      ✅ %-10s %10s bytes\n' "$f" "$(stat -c%s "gcc/$f")"; else printf '      ❌ %-10s not produced\n' "$f"; fi
done
echo "    --- stage2's target libraries ---"
TL_LGCC="$BUILD/$TARGET/libgcc"
TL_CXX="$BUILD/$TARGET/libstdc++-v3"
libgcc_ok=0; libstdcxx_ok=0
if [ -f "$TL_LGCC/libgcc.a" ]; then
  libgcc_ok=1
  printf '      ✅ libgcc.a        %10s bytes / %s members / sha256 %s\n' \
    "$(stat -c%s "$TL_LGCC/libgcc.a")" "$("$AR_TOOL" t "$TL_LGCC/libgcc.a" | wc -l)" \
    "$(sha256sum "$TL_LGCC/libgcc.a" | cut -c1-16)"
else
  echo "      ❌ libgcc.a not produced"
fi
for f in crtbegin.o crtend.o; do
  [ -f "$TL_LGCC/$f" ] && printf '      ✅ %-14s %10s bytes\n' "$f" "$(stat -c%s "$TL_LGCC/$f")"
done
for f in src/.libs/libstdc++.a src/libstdc++.a libsupc++/.libs/libsupc++.a libsupc++/libsupc++.a; do
  [ -f "$TL_CXX/$f" ] || continue
  libstdcxx_ok=1
  printf '      ✅ %-30s %10s bytes\n' "$f" "$(stat -c%s "$TL_CXX/$f")"
done
[ "$libstdcxx_ok" = 1 ] || echo "      ❌ libstdc++.a/libsupc++.a not produced"

echo
echo "    --- compile errors (warnings excluded), deduplicated per source file ---"
grep -oE '^[^ ]+\.(c|cc|h)\([0-9]+\): .*' make-stage2.log 2>/dev/null \
  | grep -v 'warning:' | sed -E 's/\(([0-9]+)\): /\t/' \
  | awk -F'\t' '{f=$1; if (!(f in s)) {s[f]=1; print "      " f "\n        " $2}}' | head -40 || true
echo "    --- make's own errors (first 15 lines) ---"
grep -nE '\*\*\* |Error [0-9]' make-stage2.log 2>/dev/null | head -15 | sed 's/^/      /' || true
echo "    --- undefined symbols / link errors (first 10 lines) ---"
grep -nE 'Unresolved|undefined reference|cannot find' make-stage2.log 2>/dev/null | head -10 | sed 's/^/      /' || true

if [ "$libgcc_ok" != 1 ] || [ "$libstdcxx_ok" != 1 ]; then
  warn "target libraries are incomplete (libgcc=$libgcc_ok libstdc++=$libstdcxx_ok) — see the error list above"
fi

# ------------------------------------------------------------------ install
gcc46_ok=0
if [ "$NO_INSTALL" = 1 ]; then
  echo
  echo "    NO_INSTALL=1: skipping install (acceptance inside the build tree only)"
elif [ "$make_rc" = 0 ] || { [ "$libgcc_ok" = 1 ] && [ "$libstdcxx_ok" = 1 ]; }; then
  note "[7/7] make -k install DESTDIR=$ROOTFS  →  $INSTALL_ROOT"
  set +e
  make -k install DESTDIR="$ROOTFS" "${MAKE_ARGS[@]}" > install.log 2>&1
  inst_rc=$?
  set -e
  echo "    install exit code: $inst_rc (log $BUILD/install.log)"
  # libtool archives (.la) record absolute paths and nothing here consumes them;
  # drop them from the install tree.
  find "$INSTALL_ROOT" -name '*.la' -delete 2>/dev/null || true
  echo "    install tree (first two levels):"
  find "$INSTALL_ROOT" -maxdepth 2 -mindepth 1 \( -type d -o -type l \) | sort | sed "s|$INSTALL_ROOT|      \$PREFIX|" | head -20

  # ---------------- End-to-end acceptance: compile C and C++ with the installed gcc46/g++46 ----------------
  echo
  echo "    --- acceptance A: the installed gcc compiles a C program ---"
  T="$ROOTFS/tests"; mkdir -p "$T"
  cat > "$T/3-stage2-hello.c" <<'C_EOF'
#include <stdio.h>
int add(int a, int b) { return a + b; }
int main(void) { printf("stage2-c %d\n", add(20, 26)); return 0; }
C_EOF
  GC="$INSTALL_ROOT/bin/gcc"
  [ -x "$GC" ] || GC="$(ls "$INSTALL_ROOT"/bin/*gcc 2>/dev/null | head -1)"
  if [ -n "$GC" ] && [ -x "$GC" ]; then
    echo "      compiler: ${GC#$ROOTFS}"
    if "$GC" -o "$BUILD/hello-c" "$T/3-stage2-hello.c" 2>"$BUILD/hello-c.err"; then
      out="$("$BUILD/hello-c")"; rc=$?
      echo "      run: \"$out\" (exit code $rc)  $(file -b "$BUILD/hello-c" | cut -d, -f1-3)"
      [ "$out" = "stage2-c 46" ] && [ "$rc" = 0 ] || warn "C acceptance output mismatch (expected stage2-c 46/0)"
    else
      sed -n '1,15p' "$BUILD/hello-c.err" | sed 's/^/        /'; warn "the installed gcc failed to compile C"
    fi
  else
    warn "the installed gcc was not found ($INSTALL_ROOT/bin)"
  fi

  echo
  echo "    --- acceptance B: the installed g++ compiles a C++ program (templates + STL + cross-frame exception unwinding + RAII + virtual functions) ---"
  cat > "$T/3-stage2-hello.cc" <<'CXX_EOF'
#include <iostream>
#include <string>
#include <vector>
#include <algorithm>
#include <stdexcept>
template <typename T> T tsum(const std::vector<T>& v) { T s = T(); for (size_t i = 0; i < v.size(); ++i) s += v[i]; return s; }
struct Base { virtual ~Base() {} virtual const char* who() const { return "base"; } };
struct Derived : Base { const char* who() const { return "derived"; } };
struct Guard { std::string tag; Guard(const char* t) : tag(t) {} ~Guard() { std::cout << "~" << tag << " "; } };
static void thrower(int n) { Guard g("g"); if (n > 0) { thrower(n - 1); return; } throw std::runtime_error("deep-boom"); }
int main() {
  std::vector<int> v; v.push_back(3); v.push_back(1); v.push_back(2);
  std::sort(v.begin(), v.end());
  std::string s = "stage2";
  /* Thrown from 4 frames deep: this must really walk _Unwind_* frame by frame, and every frame's Guard must be destroyed. */
  try { thrower(3); }
  catch (const std::exception& e) { s += std::string("-caught-") + e.what(); }
  Base* b = new Derived();
  std::cout << s << " " << tsum(v) << " " << b->who() << " " << v[0] << v[1] << v[2] << std::endl;
  delete b;
  return 0;
}
CXX_EOF
  GXX=""
  for cand in g++ c++ "${TARGET}-g++"; do [ -x "$INSTALL_ROOT/bin/$cand" ] && { GXX="$INSTALL_ROOT/bin/$cand"; break; }; done
  if [ -n "$GXX" ]; then
    echo "      compiler: ${GXX#$ROOTFS}"
    if "$GXX" -o "$BUILD/hello-cxx" "$T/3-stage2-hello.cc" 2>"$BUILD/hello-cxx.err"; then
      out="$("$BUILD/hello-cxx")"; rc=$?
      echo "      run: \"$out\" (exit code $rc)  $(file -b "$BUILD/hello-cxx" | cut -d, -f1-3)"
      # Expected: four Guard destructors (n=3,2,1,0) before the final line.
      if [ "$out" = "~g ~g ~g ~g stage2-caught-deep-boom 6 derived 123" ] && [ "$rc" = 0 ]; then
        gcc46_ok=1
        echo "      ✅ C++ acceptance passed (iostream/STL/templates/virtual functions + **exception unwinding and RAII destruction across 4 frames**)"
      else
        warn "C++ acceptance output mismatch (expected '~g ~g ~g ~g stage2-caught-deep-boom 6 derived 123'/0)"
      fi
      if readelf -l "$BUILD/hello-cxx" 2>/dev/null | grep -q INTERP; then
        warn "the C++ binary has PT_INTERP (expected static)"
      else
        echo "      PT_INTERP: none (statically linked)"
      fi
    else
      sed -n '1,25p' "$BUILD/hello-cxx.err" | sed 's/^/        /'; warn "the installed g++ failed to compile C++"
    fi
  else
    warn "the installed g++ was not found ($INSTALL_ROOT/bin)"
  fi
  # Acceptance C links with -pthread, which relies on [1/7]'s empty libpthread.a and on musl's pthread living in libc.a.
  echo
  echo "    --- acceptance C: thread model (libstdc++ uses gthr-posix, musl's pthread lives in libc.a) ---"
  cat > "$T/3-stage2-thread.cc" <<'TH_EOF'
#include <pthread.h>
#include <string>
#include <iostream>
static std::string msg;
static void* worker(void*) { msg = "stage2-cxx-thread"; return 0; }
int main() { pthread_t t; if (pthread_create(&t, 0, worker, 0)) return 1; pthread_join(t, 0); std::cout << msg << std::endl; return 0; }
TH_EOF
  if [ -n "$GXX" ] && "$GXX" -pthread -o "$BUILD/hello-thread" "$T/3-stage2-thread.cc" 2>"$BUILD/hello-thread.err"; then
    out="$("$BUILD/hello-thread")"; rc=$?
    echo "      run: \"$out\" (exit code $rc)"
    if [ "$out" = "stage2-cxx-thread" ] && [ "$rc" = 0 ]; then
      echo "      ✅ thread acceptance passed (-pthread + the empty libpthread.a fallback + pthread from musl's libc.a)"
    else
      warn "thread acceptance output mismatch (expected stage2-cxx-thread/0)"
    fi
  else
    sed -n '1,15p' "$BUILD/hello-thread.err" 2>/dev/null | sed 's/^/        /'; warn "thread acceptance failed"
  fi

  echo
  echo "    --- installed contents quick check (actual locations) ---"
  # Locate installed files with find rather than guessing paths: on x86_64 the C++
  # library lands in lib64/ and cc1 in libexec/.
  for pat in cc1 cc1plus libgcc.a crtbegin.o libstdc++.a libsupc++.a iostream c++config.h; do
    p="$(find "$INSTALL_ROOT" -name "$pat" 2>/dev/null | head -1)"
    if [ -n "$p" ]; then printf '      ✅ %-14s %s\n' "$pat" "${p#$ROOTFS}"; else printf '      ⚠️  missing %-14s\n' "$pat"; fi
  done
else
  echo
  warn "make did not succeed and the target libraries are incomplete ⇒ skipping install"
fi

# ---------------------------------------------------------------- Record state
source "$ROOT/3-lib/common.sh" 2>/dev/null || true
if command -v record >/dev/null 2>&1; then
  record STAGE2_BUILD "$BUILD"
  record STAGE2_PREFIX "$PREFIX"
  record STAGE2_SYSROOT "$SYSROOT"
  record STAGE2_CC_WRAP "$WRAP"
  record STAGE2_MAKE_GOAL "$GOAL"
  record STAGE2_MAKE_EXIT "$make_rc"
  record STAGE2_CC1_SIZE "$(stat -c%s "$BUILD/gcc/cc1" 2>/dev/null || echo 0)"
  record STAGE2_CC1PLUS_SIZE "$(stat -c%s "$BUILD/gcc/cc1plus" 2>/dev/null || echo 0)"
  record STAGE2_LIBGCC_OK "$libgcc_ok"
  record STAGE2_LIBGCC_SIZE "$(stat -c%s "$TL_LGCC/libgcc.a" 2>/dev/null || echo 0)"
  record STAGE2_LIBGCC_MEMBERS "$("$AR_TOOL" t "$TL_LGCC/libgcc.a" 2>/dev/null | wc -l)"
  record STAGE2_LIBGCC_SHA256 "$(sha256sum "$TL_LGCC/libgcc.a" 2>/dev/null | cut -c1-16 || echo -)"
  record STAGE2_LIBSTDCXX_OK "$libstdcxx_ok"
  record STAGE2_INSTALL_ROOT "$INSTALL_ROOT"
  record STAGE2_CXX_OK "$gcc46_ok"
fi

note "done (log: $LOG)"
cat <<EOF
  build tree: $BUILD
  install tree: $INSTALL_ROOT
  key logs: $BUILD/{configure.log,make-configure-gcc.log,make-stage2.log,install.log}
EOF
if [ "$make_rc" != 0 ]; then
  echo "  note: make exit code $make_rc (see the error list above and the log)"
  exit "$make_rc"
fi
[ "$libgcc_ok" = 1 ] || die "stage2's libgcc.a was not produced"
[ "$libstdcxx_ok" = 1 ] || die "stage2's libstdc++.a/libsupc++.a was not produced"
if [ "$NO_INSTALL" != 1 ]; then
  [ "$gcc46_ok" = 1 ] || die "C++ acceptance with the installed g++ failed (see the output above)"
fi
