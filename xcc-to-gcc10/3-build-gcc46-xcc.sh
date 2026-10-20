#!/bin/bash
#
# 3-build-gcc46-xcc.sh — build GCC 4.6.4.1 with xcc + musl.
#
# Default milestone: configure + `make all-gcc`, i.e. use xcc to compile GCC's own
# C and C++ front ends (the `gcc/xgcc` driver plus `cc1` and `cc1plus`). That builds
# no target-side runtime library and installs nothing, and the run first answers one
# concrete question: **can xcc compile GCC's own sources** (357 gcc/*.c, 113
# libiberty/*.c, plus libcpp, libdecnumber and intl)?
#
# GOAL=all-target-libgcc extends the same run to the target-side libgcc (libgcc.a,
# crtbegin/crtend/crtprec*/crtfastmath, libgcov.a). Before that, linking anything
# needs `-nostdlib` plus hand-picked crt files; afterwards ordinary linking works:
# crt1/crti/crtn and libc come from the musl sysroot, crtbegin/crtend and libgcc
# from the freshly built libgcc. libstdc++ and the other target runtimes stay out
# of scope.
#
# Source tarball: gcc-4.6.4.1.tar.gz (the ekaitz-zarraga RISC-V fork, which adds
#   gcc/config/riscv/). Its top-level directory is `gcc/`, so it is unpacked into
#   $SRCDIR_ROOT and $SRCDIR_ROOT/gcc becomes srcdir. The tarball does **not**
#   bundle gmp/mpfr/mpc, so the libraries installed in rootfs3 are required.
#
# Prerequisites (each one built by another script in this directory):
#   rootfs3/usr/xcc-musl/bin/{xcc,cc1,cpp,as,ld}   <- ./3-build-xcc-musl.sh
#   rootfs3/usr/xcc-musl/bin/xcc-musl-cc           <- ./3-build-xcc-musl.sh (CC wrapper)
#   rootfs3/usr/{include,lib}/                     <- ./3-build-musl-xcc.sh (musl sysroot;
#                                                     ./3-adjust-rootfs-current.sh
#                                                     repoints the links)
#   rootfs3/usr/{include/gmp.h,lib/libgmp.a}       <- ./3-build-gmp.sh
#   rootfs3/usr/{include/mpfr.h,lib/libmpfr.a}     <- ./3-build-mpfr.sh
#   rootfs3/usr/{include/mpc.h,lib/libmpc.a}       <- ./3-build-mpc.sh
#   rootfs3/usr/{include/zlib.h,lib/libz.a}        <- ./3-build-zlib.sh (**before** GCC!)
#   rootfs3/usr/binutils/bin/{as,ld,ar,ranlib,nm}  <- ./3-build-binutils.sh (the default
#                                                     as/ld; xcc's own are the fallback)
#
# Why the zlib stage is required: GCC 4.6's Makefile.def gives `all-gcc` a
#   dependency on `all-zlib` (not a hard dependency), and cc1 always links -lz.
#   The zlib bundled in the tree (gcc/zlib/) is zlib 1.2.3 written in K&R style,
#   which xcc cannot compile, so --with-system-zlib points GCC at the zlib 1.3.2
#   installed by ./3-build-zlib.sh.
#
# Products (on success):
#   rootfs3/build/gcc-4.6.4.1/gcc/xgcc       compiler driver
#   rootfs3/build/gcc-4.6.4.1/gcc/cc1        C front end
#   rootfs3/build/gcc-4.6.4.1/gcc/cc1plus    C++ front end
#   rootfs3/build/gcc-4.6.4.1/$TARGET/libgcc/{libgcc.a,libgcov.a,crt*.o}
#                                            with GOAL=all-target-libgcc
#   rootfs3/build/gcc-4.6.4.1/{configure.log,make-gcc.log,timing.txt}
#   results/3-build-gcc46-xcc.log                  full run log (tee)
#
# Usage:
#   ./3-build-gcc46-xcc.sh                 # unpack -> configure -> make -k all-gcc -> summary
#   JOBS=8 ./3-build-gcc46-xcc.sh          # parallelism (default: nproc)
#   CLEAN=1 ./3-build-gcc46-xcc.sh         # delete the build tree first
#   FORCE_SRC=1 ./3-build-gcc46-xcc.sh     # unpack the source again
#   GOAL=all-gcc ./3-build-gcc46-xcc.sh    # make goal (default: all-gcc)
#   GOAL=all-target-libgcc ./3-build-gcc46-xcc.sh
#                                    # target libgcc (libgcc.a + crtbegin/crtend/
#                                    # crtprec* + libgcov.a); see above for what that
#                                    # changes for ordinary links
#   CONF_ONLY=1 ./3-build-gcc46-xcc.sh     # run configure only (fastest way to probe)
#   CPU_LIMIT=1800 ./3-build-gcc46-xcc.sh  # CPU-time limit for make (seconds, ulimit -t)
#                                    # ⚠️ wall-clock alone cannot tell "stuck": a
#                                    # suspended machine inflates real time. This
#                                    # script always reports user/sys as well.
#
# ---------------------------------------------------------------------------
# Host tools — full disclosure: apart from the rootfs3 toolchain, this script only
# calls the host binaries listed below; they are unpack/text/archive/driver tools,
# not compilers:
#
#   /usr/bin/bash       runs this script
#   /usr/bin/make       GNU make, drives GCC's configure/Makefile
#   /usr/bin/tar + gzip unpack gcc-4.6.4.1.tar.gz
#   /usr/bin/sed        called by GCC's configure/Makefile itself
#   /usr/bin/awk(gawk)  used by the build itself (config.status, gen* shell parts)
#   /usr/bin/grep       used by the build; also for the preconditions and the
#                       failure summary
#   /usr/bin/find cp mv rm mkdir ln cat head tail wc tr cut sort uniq cmp stat
#                       coreutils (the precondition check lists all of them)
#   /usr/bin/ar nm      archive and symbol tools; the build prefers the self-built
#                       binutils (ar/ranlib/nm) when they are present
#   /usr/bin/file readelf sha256sum   inspect artifacts and record hashes
#   /usr/bin/readlink   resolves the sysroot path
#   /usr/bin/tee        mirrors the whole run into results/3-build-gcc46-xcc.log
#   flex/bison are **not needed**: the release tarball ships the generated
#                       insn-*.c / parse.c files
#
# GCC's configure/make also spawn a host shell-tool set of its own (sed/awk/grep/
# ln/cmp/mv/rm/sort/sleep/test/expr/...); those are non-compilers as well and are
# declared here.
#
# Never used: host gcc/cc/clang/g++/ld/as/cpp, host /usr/include and /usr/lib.
# Compiling/assembling/linking is done entirely by
# rootfs3/usr/xcc-musl/bin/{xcc,cc1,cpp,as,ld} + musl.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
ROOTFS="$ROOT/rootfs3"
XCCDIR="$ROOTFS/usr/xcc-musl"            # the xcc toolchain that links against musl
XCC="$XCCDIR/bin/xcc"
MUSL_INC="$ROOTFS/usr/include"           # global sysroot: musl headers
MUSL_LIB="$ROOTFS/usr/lib"
DEPS="$ROOTFS/usr"                       # the third-party libraries live here too
WRAP="$XCCDIR/bin/xcc-musl-cc"           # the CC wrapper shipped with the toolchain

TARBALL="$ROOT/gcc-4.6.4.1.tar.gz"
SRCDIR_ROOT="$ROOTFS/src/gcc-4.6.4.1"     # unpack root (contains gcc/)
SRC="$SRCDIR_ROOT/gcc"                    # the real srcdir
BUILD="$ROOTFS/build/gcc-4.6.4.1"
LOGDIR="$ROOT/results"
LOG="$LOGDIR/3-build-gcc46-xcc.log"

JOBS="${JOBS:-$(nproc)}"
CLEAN="${CLEAN:-0}"
FORCE_SRC="${FORCE_SRC:-0}"
GOAL="${GOAL:-all-gcc}"
CONF_ONLY="${CONF_ONLY:-0}"
CFLAGS_BUILD="${CFLAGS_BUILD:--O1}"
TRIPLE="x86_64-pc-linux-gnu"
TARGET="${TARGET:-x86_64-pc-linux-gnu}"   # x86_64 only for now; riscv64 would come later
# ★ Target sysroot (required for the libgcc stage):
#   rootfs3 already uses the layout GCC expects — <sysroot>/usr/include,
#   <sysroot>/usr/lib. Without it the effect was measured: the build-tree xgcc
#   falls back to the host /usr/include, /lib/x86_64-linux-gnu and /usr/lib (that
#   is what `xgcc -E -v` lists, and LIBRARY_PATH even contains /lib/../lib64), so
#   the target-side libgcc is built against the host's glibc headers — gcc/Makefile
#   has inhibit_libc = false, and libgcc2.c's __eprintf (guarded by
#   `#ifndef inhibit_libc`) includes <stdio.h> in that hosted compile.
SYSROOT="${SYSROOT:-$ROOTFS}"

die()  { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }
note() { printf '\n==> %s\n' "$*"; }

# ---------------------------------------------------------------- as/ld source
# ★ The default is the **self-built binutils** (rootfs3/usr/binutils/bin, built by
#   ./3-build-binutils.sh with xcc-musl). Why it must be passed explicitly: GCC's
#   configure searches **PATH** for as/ld and bakes the result into gcc/Makefile as
#   `ORIGINAL_AS_FOR_TARGET = /usr/bin/as` (observed), so gcc/as and gcc/collect-ld
#   become forwarding scripts to the **host** binutils: that breaks the "no host
#   binutils" rule and hides the real tools. `--with-as/--with-ld` pin them to the
#   self-built tools, so the driver never borrows someone else's as/ld via -B.
BINUTILS_BIN="${BINUTILS_BIN:-$ROOTFS/usr/binutils/bin}"
if [ -x "$BINUTILS_BIN/as" ] && [ -x "$BINUTILS_BIN/ld" ]; then
  AS_BIN="$BINUTILS_BIN/as"
  LD_BIN="$BINUTILS_BIN/ld"
  ASLD_SRC="binutils (self-built)"
else
  AS_BIN="$XCCDIR/bin/as"
  LD_BIN="$XCCDIR/bin/ld"
  ASLD_SRC="xcc bundled (no $BINUTILS_BIN/{as,ld} found)"
  warn "self-built binutils not found at $BINUTILS_BIN/{as,ld} -- falling back to xcc's bundled as/ld; run ./3-build-binutils.sh first"
fi

mkdir -p "$LOGDIR"
exec > >(tee "$LOG") 2>&1

# ---------------------------------------------------------------- 0. Precondition checks
note "[0/5] check inputs and host tools"
[ -f "$TARBALL" ] || die "$TARBALL not found"
for f in xcc cc1 cpp as ld; do
  [ -x "$XCCDIR/bin/$f" ] || die "missing $XCCDIR/bin/$f (run ./3-build-xcc-musl.sh first)"
done
[ -f "$MUSL_LIB/libc.a" ] || die "missing $MUSL_LIB/libc.a (run ./3-build-musl-xcc.sh first)"
for h in gmp.h mpfr.h mpc.h; do
  [ -f "$DEPS/include/$h" ] || die "missing $DEPS/include/$h (run ./3-build-{gmp,mpfr,mpc}.sh first)"
done
for l in libgmp.a libmpfr.a libmpc.a libz.a; do
  [ -f "$DEPS/lib/$l" ] || die "missing $DEPS/lib/$l (run ./3-build-{gmp,mpfr,mpc,zlib}.sh first)"
done
[ -f "$DEPS/include/zlib.h" ] || die "missing $DEPS/include/zlib.h (run ./3-build-zlib.sh first)"
[ -x "$WRAP" ] || die "missing CC wrapper $WRAP (generated by ./3-build-xcc-musl.sh; run it first)"
for t in bash make tar gzip sed awk grep find ar nm file readelf readlink \
         sha256sum tee cp mv rm mkdir ln cat head tail wc tr cut sort uniq cmp stat; do
  command -v "$t" >/dev/null 2>&1 || die "missing host tool: $t"
done

echo "    xcc    : $("$XCC" -v | tr '\n' ' ')  sha256=$(sha256sum "$XCC" | cut -c1-16)"
echo "    musl   : libc.a $(stat -Lc%s "$MUSL_LIB/libc.a") bytes (-L: follows the relative link inside usr/lib)"
echo "    gmp    : $(stat -c%s "$DEPS/lib/libgmp.a") bytes"
echo "    mpfr   : $(stat -c%s "$DEPS/lib/libmpfr.a") bytes"
echo "    mpc    : $(stat -c%s "$DEPS/lib/libmpc.a") bytes"
echo "    zlib   : $(stat -c%s "$DEPS/lib/libz.a") bytes"
echo "    CC     : $WRAP"
echo "    as/ld  : $ASLD_SRC  →  as=$AS_BIN  ld=$LD_BIN"
echo "             (as sha256=$(sha256sum "$AS_BIN" | cut -c1-16)  ld sha256=$(sha256sum "$LD_BIN" | cut -c1-16))"
echo "    build/host/target : $TRIPLE / $TRIPLE / $TARGET"
echo "    sysroot : $SYSROOT  (target headers/libs = $SYSROOT/usr/{include,lib})"
echo "    make goal : $GOAL"
# The libtool archives record absolute paths, so on the host libtool would read
# the host /usr/lib/*.la files; drop them.
rm -f "$DEPS/lib"/libgmp.la "$DEPS/lib"/libmpfr.la "$DEPS/lib"/libmpc.la

# ------------------------------------------------------------------ 1. Unpack the sources
note "[1/5] unpack $TARBALL -> $SRCDIR_ROOT"
if [ "$FORCE_SRC" = 1 ] || [ ! -d "$SRC" ]; then
  rm -rf "$SRCDIR_ROOT"
  mkdir -p "$SRCDIR_ROOT"
  echo "    (84 MB archive, about 590 MB unpacked, please wait)"
  tar -xzf "$TARBALL" -C "$SRCDIR_ROOT"
else
  echo "already present, skipping the unpack (FORCE_SRC=1 forces it)"
fi
[ -f "$SRC/configure" ] || die "$SRC/configure does not exist (the archive's top-level directory should be gcc/)"
echo "    version: $(cat "$SRC/gcc/BASE-VER" 2>/dev/null) $(cat "$SRC/gcc/DEV-PHASE" 2>/dev/null)"
echo "    gcc/*.c: $(find "$SRC/gcc" -maxdepth 1 -name '*.c' | wc -l) files"
echo "    riscv backend: $(find "$SRC/gcc/config/riscv" -type f 2>/dev/null | wc -l) files"

# ------------------------------------------------------------- 2. configure
note "[2/5] configure (CC=$WRAP, minimal set: C front end only, no target libraries)"
if [ "$CLEAN" = 1 ]; then
  echo "    CLEAN=1: removing $BUILD"
  rm -rf "$BUILD"
fi
mkdir -p "$BUILD"
cd "$BUILD"

# ★ Remove autoconf's config.cache first: the **first** configure caches probe
#   results (vfork among them), and afterwards the sub-directory configures keep
#   reading those old values even when an ac_cv_* is changed (for example forcing
#   the vfork fallback with ac_cv_func_vfork_works=no) — the change then looks
#   ineffective (observed: libiberty/config.h stayed `/* #undef vfork */`, still
#   dated the first configure).
find "$BUILD" -maxdepth 2 -name config.cache -delete 2>/dev/null || true

# Option notes:
#   --enable-languages=c,c++  ★ C and C++ front ends (cc1/xgcc + **cc1plus**).
#      GCC 4.6's C++ front end is plain **C source** (gcc/cp/*.c, 31 files; 4.8
#      moved it to .cc), so xcc can compile it.
#      On the first attempt cc1plus built but segfaulted on every non-empty input
#      (gdb: strcmp(0x0,"<built-in>") <- splay_tree_* <- get_fileinfo). Both root
#      causes are fixed now, and they are the same two behind the wide cc1 ICE wave:
#        (a) **xcc allocated %rbp as a general-purpose register** -> patch
#            xcc-regalloc-reserve-frame-pointer;
#        (b) the driver and the build must use the **self-built binutils** as/ld
#            (see --with-as/--with-ld below).
#      With both fixed, cc1plus (19 792 408 B) compiles C++98: templates, virtual
#      functions and new/delete pass at -O0 and -O1 and emit normal assembly. The
#      only thing still missing is the C++ standard library headers (libstdc++ is
#      not built, so `#include <cstdio>` reports `fatal error: cstdio: No such file
#      or directory`) — expected, not a crash.
#      One fix from that attempt is kept: xcc-extern-with-initializer.patch folds
#      the false "duplicate declaration" error for `extern T x[];` after a
#      definition (the shape of gengtype's gt-*.h; without it cp/cp-lang.o does not
#      compile).
#   --disable-bootstrap    no 3-stage bootstrap (xcc compiles GCC here; GCC is not
#                          bootstrapping itself)
#   --disable-nls          no internationalization (drops the gettext dependency)
#   --disable-shared       static libraries only
#   --disable-threads      no thread support (avoids pthread/TLS probes)
#   --disable-libssp / --disable-libgomp / --disable-libquadmath /
#   --disable-libmudflap / --disable-lto / --disable-plugin
#                          target-side runtimes, plugins and LTO: none of them is
#                          built at this stage
#   --disable-libatomic / --disable-libvtv / --disable-libsanitizer /
#   --disable-libstdcxx    also target-side runtimes, all switched off
#   --disable-multilib     no 32-bit multilib
#   --disable-fixincludes  ★ saves time: no fixincludes run (otherwise fixincl is
#                          built and the system headers are rewritten)
#   --disable-decimal-float / --disable-fixed-point
#                          they need _Decimal64 / _Fract types, which xcc lacks
#   --without-cloog / --without-ppl    optional dependencies, not needed
#   --with-system-zlib     use the zlib 1.3.2 from ./3-build-zlib.sh instead of the
#                          K&R zlib 1.2.3 bundled in the tree
#   --with-sysroot=$ROOTFS ★ target sysroot: makes the **newly built** xgcc look
#                          for target headers/libraries in $ROOTFS/usr/{include,lib}
#                          (= musl + the third-party libraries) instead of the host
#                          /usr/include and /lib/x86_64-linux-gnu, which is what it
#                          falls back to without the flag (see the SYSROOT note at
#                          the top). The target libgcc only sees musl headers
#                          through this. (The host-side compile of GCC itself still
#                          goes through xcc-musl-cc and is unaffected.)
#   --with-as / --with-ld  ★ pin the driver's assembler/linker to the **self-built
#                          binutils** (rootfs3/usr/binutils/bin/{as,ld}, built by
#                          ./3-build-binutils.sh with xcc-musl). Without them
#                          configure picks the **host** /usr/bin/as from PATH
#                          (observed `ORIGINAL_AS_FOR_TARGET = /usr/bin/as`), and
#                          gcc/as and gcc/collect-ld become forwarding scripts to
#                          host tools. Override with `BINUTILS_BIN=...`; if not
#                          found, the xcc-bundled as/ld are used.
#   --with-gmp/mpfr/mpc-*  use the third-party libraries installed in rootfs3
#                          (GCC's host side needs all three)
#   ac_cv_prog_cc_c89=     autoconf's C89 probe program is K&R code, which xcc
#                          always fails to compile, so the probe is skipped
#   ac_cv_func_vfork_works=no
#                          ★ xcc cannot compile a working vfork: `vfork() + child
#                          _exit()` segfaults at -O0 and -O1, while the same program
#                          with fork() works. GCC 4.6's libiberty/pex-unix.c starts
#                          cc1/as with `vfork + execvp`, so `xgcc -c hello.c` then
#                          segfaults outright (`xgcc -###` only printing the command,
#                          or cc1 used on its own, works). The setting is meant to
#                          make autoconf's "vfork works" answer no, so that its
#                          not-working branch applies the standard fallback
#                          (`#define vfork fork`).
#                          ⚠️ It does **not** reach libiberty/config.h here: the
#                          generated libiberty/configure runs
#                          `ac_cv_func_vfork_works=$ac_cv_func_vfork` before its
#                          cache check, so the value is overwritten with "yes" (the
#                          log shows "checking for working vfork... (cached) yes")
#                          and HAVE_WORKING_VFORK ends up defined. What actually
#                          moves pex to fork() is the `-Dvfork=fork` on the make
#                          command line in [2b/5]; the config.h rewrite there is
#                          only a best-effort extra.
env -u CFLAGS -u CPPFLAGS -u LDFLAGS \
    ac_cv_prog_cc_c89= \
    ac_cv_func_vfork_works=no \
    CC="$WRAP" \
    CFLAGS="$CFLAGS_BUILD" \
    "$SRC/configure" \
      --prefix=/usr \
      --build="$TRIPLE" --host="$TRIPLE" --target="$TARGET" \
      --enable-languages=c,c++ \
      --disable-bootstrap \
      --disable-nls \
      --disable-shared \
      --disable-threads \
      --disable-libssp \
      --disable-libgomp \
      --disable-libquadmath \
      --disable-libmudflap \
      --disable-libatomic \
      --disable-libvtv \
      --disable-libsanitizer \
      --disable-libstdcxx \
      --disable-multilib \
      --disable-fixincludes \
      --disable-lto \
      --disable-plugin \
      --disable-decimal-float \
      --disable-fixed-point \
      --without-cloog \
      --without-ppl \
      --with-system-zlib \
      --with-sysroot="$SYSROOT" \
      --with-as="$AS_BIN" \
      --with-ld="$LD_BIN" \
      --with-gmp-include="$DEPS/include" --with-gmp-lib="$DEPS/lib" \
      --with-mpfr-include="$DEPS/include" --with-mpfr-lib="$DEPS/lib" \
      --with-mpc-include="$DEPS/include" --with-mpc-lib="$DEPS/lib" \
      > configure.log 2>&1 || { echo "--- tail of configure ---"; tail -40 configure.log; die "configure failed (see $BUILD/configure.log)"; }
echo "    configure done"

grep -E '^checking for gmp.h|^checking for the correct gmp.h|^checking for mpfr.h|^checking for mpc.h|^checking for C compiler|host system type|target system type' configure.log | head -8 | sed 's/^/      /'

if [ "$CONF_ONLY" = 1 ]; then
  note "[3/5] CONF_ONLY=1: configure only, stopping here"
  echo "    build tree: $BUILD"
  exit 0
fi

# ============================ 2b. Configure the gcc subdirectory + three required patches
note "[2b/5] configure the gcc subdirectory in advance and patch its generated files (without the patches the **target libraries** can never be built)"
# Why this is a separate step:
#   * `$BUILD/gcc/Makefile` is **not** a product of the top-level configure — the
#     top-level make target `configure-gcc` creates it. The patches below edit that
#     file, so the step has to run, and be patched, before the real make goal. On an
#     already configured tree it is a no-op (a few seconds).
#   * It also makes the subdirectory config.h files (e.g. `$BUILD/gcc/config.h`)
#     appear first, so the vfork patch below lands on a file even in a fresh
#     (CLEAN) build.

# Common make arguments (used by both the [2b/5] and [3/5] makes):
#   * `CFLAGS` carries `-Dvfork=fork`: xcc cannot compile a usable vfork (see the
#     ac_cv_func_vfork_works note above). A command-line macro is immune to config.h
#     regeneration, which makes it the second line of defence; the top-level
#     Makefile's HOST_EXPORTS (which contains `CFLAGS="$(CFLAGS)"`) passes it on to
#     the sub-makes.
#   * `AR/RANLIB/NM` are switched to the self-built binutils: the top-level
#     Makefile's EXTRA_HOST_FLAGS contains `'AR=$(AR)'` etc., so command-line
#     overrides travel into the gcc sub-make.
#   ⚠️ **Other variables do not get through**: the top-level Makefile ends with
#      `# Don't pass command-line variables to submakes.` + `.NOEXPORT:` +
#      `MAKEOVERRIDES=`, so only the variables listed explicitly in EXTRA_*_FLAGS
#      or HOST_EXPORTS (AR/AS/CC/CFLAGS/NM/RANLIB...) take effect. That is why
#      patches A/B below have to edit the generated Makefile instead of using
#      `make VAR=`.
MAKE_ARGS=(
  "CFLAGS=$CFLAGS_BUILD -Dvfork=fork"
  "CFLAGS_FOR_BUILD=$CFLAGS_BUILD -Dvfork=fork"
)
if [ "$ASLD_SRC" = "binutils (self-built)" ] && [ -x "$BINUTILS_BIN/ar" ] && [ -x "$BINUTILS_BIN/ranlib" ]; then
  MAKE_ARGS+=("AR=$BINUTILS_BIN/ar" "RANLIB=$BINUTILS_BIN/ranlib" "NM=$BINUTILS_BIN/nm")
  echo "    archivers: self-built binutils ar/ranlib/nm (the host ones would work too; this just keeps the tools self-built)"
fi

set +e
make -k -j"$JOBS" configure-gcc "${MAKE_ARGS[@]}" > make-configure-gcc.log 2>&1
cg_rc=$?
set -e
echo "    configure-gcc exit code $cg_rc (log $BUILD/make-configure-gcc.log)"
[ -f "$BUILD/gcc/Makefile" ] || { tail -30 make-configure-gcc.log | sed 's/^/      /'; die "gcc/Makefile still not generated (see $BUILD/make-configure-gcc.log)"; }

# ★★ Patches A / B (required by the target-library stage): **remove two
#   prerequisites that make `all-gcc` fail for ever**.
#   Symptom: `all-target-libgcc` (and every other target library, e.g.
#   `all-target-libstdc++-v3`) depends on `all-gcc` in the top-level Makefile
#   (`configure-target-libgcc: maybe-all-gcc`), while in this environment `all-gcc`
#   always ends with exit code 2, so the target library configure never even runs
#   (observed: 94 s wasted, `$TARGET/libgcc/` does not exist at all):
#     A) `stmp-fixinc`: `--disable-fixincludes` does not remove this prerequisite
#        from gcc/Makefile (gcc/configure.ac:1802 sets STMP_FIXINC=stmp-fixinc
#        unconditionally), and the top-level **build-side** fixincludes module is
#        not configured (`$BUILD/build-$build/` contains only libiberty)
#        => always `No rule to make target '.../build-x86_64-pc-linux-gnu/
#        fixincludes/fixinc.sh'`. Its only purpose is producing `gcc/include-fixed/`
#        (running fixincludes to "fix" the system headers) — exactly what is
#        unwanted for musl, so emptying it just completes the intent of
#        `--disable-fixincludes`. Note that `stmp-int-hdrs: $(STMP_FIXINC) ...`
#        merely loses one prerequisite; GCC's own internal headers
#        (stddef.h/unwind.h...) are still installed into `gcc/include/`.
#     B) `doc/gccint.info`: the host makeinfo is texinfo 7.3, too new for the old
#        .texi sources, so building the info documentation always fails; and
#        `doc: $(BUILD_INFO) $(GENERATED_MANPAGES)` pulls `info`
#        (-> `$(INFOFILES)` -> `doc/gccint.info`) in as a prerequisite of doc when
#        BUILD_INFO=info, while doc itself is a prerequisite of all.internal. The
#        info documentation is not needed here, so `$(BUILD_INFO)` is dropped from
#        doc's prerequisites.
#     `-k` cannot rescue the former: it is a failed prerequisite, not a parallel
#     branch.
if grep -q '^STMP_FIXINC = stmp-fixinc$' gcc/Makefile; then
  sed -i 's/^STMP_FIXINC = stmp-fixinc$/STMP_FIXINC =/' gcc/Makefile
  echo "    ✅ [A] dropped the stmp-fixinc prerequisite (fixincludes is pointless for musl and the build-side module is not configured)"
else
  warn "'STMP_FIXINC = stmp-fixinc' not found in gcc/Makefile (different GCC version?) -- if stmp-fixinc still fails, see the log"
fi
if grep -q '^doc: \$(BUILD_INFO) \$(GENERATED_MANPAGES)$' gcc/Makefile; then
  sed -i 's/^doc: \$(BUILD_INFO) \$(GENERATED_MANPAGES)$/doc: $(GENERATED_MANPAGES)/' gcc/Makefile
  echo "    ✅ [B] doc no longer depends on the info manuals (host makeinfo is too old; info is not a product here)"
else
  warn "'doc: \$(BUILD_INFO) \$(GENERATED_MANPAGES)' not found in gcc/Makefile -- if doc/gccint.info still fails, see the log"
fi

# ★ Patch C: force the vfork -> fork fallback in the generated config.h files.
# Background: GCC 4.6's libiberty/pex-unix.c starts cc1/as with `vfork + execvp`,
# and **xcc miscompiles vfork** in some shapes (minimal reproducer: `vfork();
# if (!p) _exit(7); waitpid(...); printf(...)` segfaults at -O0 and -O1, while the
# same program with fork() works). The result is that `xgcc -c hello.c` segfaults
# outright (while `xgcc -###` and cc1 on its own are fine). AC_FUNC_VFORK's runtime
# probe cannot catch this shape, and in this tree it does not even run: as noted
# above, the generated configure pre-fills the cache variable, so config.h declares
# vfork as working and pex takes the vfork branch. The fallback that autoconf's own
# not-working branch would apply (`AC_DEFINE(vfork, fork)`) is therefore written
# straight into the generated config.h here, so that pex would use fork().
vfork_fixed=0
while IFS= read -r h; do
  sed -i 's|^/\* #undef vfork \*/$|#define vfork fork|' "$h"
  vfork_fixed=$((vfork_fixed+1))
done < <(grep -rl '^/\* #undef vfork \*/$' --include='config.h' "$BUILD" 2>/dev/null)
# Note: editing config.h alone is not enough — the Makefile rule
# `config.h: stamp-h1` regenerates config.h whenever config.status is newer than
# the stamp file, wiping the change (observed). So the relevant stamp files are
# touched as well, and `-Dvfork=fork` on the make command line (see MAKE_ARGS
# above) backs it up: a command-line macro survives regeneration.
find "$BUILD" -maxdepth 2 \( -name 'stamp-h1' -o -name 'stamp-h' \) -exec touch {} + 2>/dev/null || true
echo "    vfork->fork fallback applied to $vfork_fixed config.h file(s) (stamp files touched; -Dvfork=fork on the make line still backs it up)"
[ "$vfork_fixed" -gt 0 ] || warn "no config.h needed the vfork fallback (if xgcc still segfaults, see the log above)"

# ---------------------------------------------------------------- 3. make
note "[3/5] make -k $GOAL -j$JOBS (-k keeps going so as many failures as possible surface)"
# Timing always uses **CPU time** (user+sys): a suspended machine inflates real
# time badly, so judging "stuck/too slow" by real time leads to wrong conclusions.
CPU_LIMIT="${CPU_LIMIT:-0}"
TIMEFORMAT='    make time: %R real, %U user, %S sys'
# MAKE_ARGS (CFLAGS/-Dvfork=fork + self-built ar/ranlib/nm) was defined in [2b/5]
# and is shared by both makes; `STMP_FIXINC`/`BUILD_INFO` cannot be solved with
# command-line variables — see patches A/B in [2b/5].
set +e
if [ "$CPU_LIMIT" -gt 0 ] 2>/dev/null; then
  echo "    CPU time limit: $CPU_LIMIT s (ulimit -t; on timeout it stops in place, the logs are kept)"
  time ( ulimit -t "$CPU_LIMIT"; make -k -j"$JOBS" "$GOAL" \
           "${MAKE_ARGS[@]}" > make-gcc.log 2>&1 )
else
  time make -k -j"$JOBS" "$GOAL" \
         "${MAKE_ARGS[@]}" > make-gcc.log 2>&1
fi
make_rc=$?
set -e
echo "    make exit code: $make_rc"
# Record the run in the build tree, next to the logs.
{ echo "goal=$GOAL"; echo "cpu_limit=$CPU_LIMIT"; echo "exit=$make_rc";
  echo "date=$(date -Iseconds)"; } > timing.txt

# ------------------------------------------------------------------ 4. Summary
note "[4/5] result summary"
if [ -f gcc/cc1 ]; then
  echo "    ✅ gcc/cc1 built: $(stat -c%s gcc/cc1) bytes"
  echo "       $(file -b gcc/cc1 2>/dev/null | cut -d, -f1-2)"
else
  echo "    ❌ gcc/cc1 not built"
fi
if [ -f gcc/xgcc ]; then
  echo "    ✅ gcc/xgcc built: $(stat -c%s gcc/xgcc) bytes (shell wrapper)"
fi

# Count the .o files produced so far to see how far the build got
obj_total=$(find . -name '*.o' | wc -l)
echo "    .o files produced so far: $obj_total"

# ---- Interpreting make's exit code: separate real failures from **harmless**
# ---- errors that GCC itself reports ----
# Without patches A/B (see [2b/5]) the top level still builds `stmp-fixinc`
# (missing `../build-.../fixincludes/fixinc.sh`) -> `*** No rule to make target`,
# and the host makeinfo (texinfo 7.3) is too new, so `doc/gccint.info` and
# `doc/gfdl.7` fail. Neither class has anything to do with the `cc1`/`xgcc` we
# want. Criterion: if **all** errors match the whitelist and cc1/xgcc were
# produced, treat the stage as successful (the raw exit code is still printed,
# not hidden).
BENIGN_ERR_RE='fixinc|stmp-fixinc|doc/[^ ]*\.(info|7)|\(ignored\)|make: \*\*\*|all-gcc\] Error'
if [ "$make_rc" != 0 ]; then
  all_errs="$(grep -aE 'make(\[[0-9]+\])?: \*\*\* |Error [0-9]+' make-gcc.log 2>/dev/null || true)"
  real_errs="$(printf '%s\n' "$all_errs" | grep -vE "$BENIGN_ERR_RE" | grep -v '^$' || true)"
  if [ -f gcc/cc1 ] && [ -f gcc/xgcc ] && [ -z "$real_errs" ]; then
    echo "    ℹ️  make exited with $make_rc, but every error is on the harmless whitelist (stmp-fixinc, doc/gccint.info),"
    echo "         and both cc1 and xgcc were produced => this stage counts as successful (raw exit code recorded in timing.txt)"
    make_rc=0
  else
    echo "    ❌ make errors outside the whitelist:"
    printf '%s\n' "$real_errs" | head -10 | sed 's/^/      /'
  fi
fi

# ---- Silent-failure detection: 384-byte empty ELF shells ----
# xcc's driver is a `cpp | cc1 | as` pipeline. When an upstream stage (cpp/cc1) is
# killed by `ulimit -t` or by an external signal, the downstream `as` still exits
# normally and writes a **384-byte object file with no symbols** — and **make
# considers that step successful**, so the broken product is taken as up to date
# and skipped by the next make, surfacing only at cc1 link time as "undefined
# symbol" (observed: when a build job received SIGTERM, `insn-recog.o` was exactly
# such a 384-byte empty shell).
#
# Criterion: .o files of exactly 384 bytes. But **not every 384-byte object is a
# failure**: with certain configurations some translation units are legitimately
# empty in GCC (no peepholes, --without-cloog/ppl, AIX/XCOFF specifics). The
# whitelist below was measured on this GCC version (8 file names); anything else is
# treated as a failure and **deleted**, so a rerun of make compiles it again.
EMPTY_OK="collect2-aix.o graphite-cloog-util.o graphite-ppl.o insn-peep.o loop-doloop.o target-globals.o vmsdbgout.o xcoffout.o"
empty_bad=0
echo
echo "    --- 384-byte empty object scan (xcc pipeline fake success) ---"
while IFS= read -r o; do
  [ -n "$o" ] || continue
  base="$(basename "$o")"
  if printf ' %s ' "$EMPTY_OK" | grep -q " $base "; then
    continue                       # legitimate empty object (on the whitelist)
  fi
  empty_bad=$((empty_bad+1))
  printf '      ❌ %s (empty shell, deleted; the next make run recompiles it)\n' "${o#./}"
  rm -f "$o"
done < <(find . -name '*.o' -size 384c | sort)
[ "$empty_bad" = 0 ] && echo "      ✅ no empty shells (legitimate empty objects are skipped by the whitelist)"
echo "    empty-shell count: $empty_bad"
echo "empty_shells=$empty_bad" >> timing.txt

# ---- End-to-end acceptance: compile hello.c with the freshly built xgcc
# ---- (assembling/linking = self-built binutils) ----
# This answers two things at once:
#   1) "is the GCC milestone still alive" (cc1 + driver + target as/ld chain up);
#   2) "whose as/ld does the driver actually use" — `-print-prog-name=as|ld` asks
#      the driver directly, which is more reliable than looking at PATH (a `gcc/as`
#      forwarding script can exec the host as behind your back).
hello_ok=0
if [ "$make_rc" = 0 ] && [ -x gcc/xgcc ] && [ -x gcc/cc1 ]; then
  echo
  echo "    --- end-to-end acceptance: xgcc compiles hello.c (as/ld = $ASLD_SRC) ---"
  echo "      driver as  : $(gcc/xgcc -print-prog-name=as 2>/dev/null || echo '(unavailable)')"
  echo "      driver ld  : $(gcc/xgcc -print-prog-name=ld 2>/dev/null || echo '(unavailable)')"
  echo "      expected as: $AS_BIN"
  echo "      expected ld: $LD_BIN"
  T="$ROOTFS/tests"; mkdir -p "$T"
  cat > "$T/3-gcc-hello.c" <<'H_EOF'
#include <stdio.h>
int add(int a, int b) { return a + b; }
int main(void) { printf("hello %d\n", add(2, 3)); return 0; }
H_EOF
  H="$BUILD/smoke"; rm -rf "$H"; mkdir -p "$H"
  if gcc/xgcc -B"$PWD/gcc" -B"$BINUTILS_BIN" -I"$MUSL_INC" -nostdlib \
        -o "$H/hello" \
        "$MUSL_LIB/crt1.o" "$MUSL_LIB/crti.o" "$T/3-gcc-hello.c" "$MUSL_LIB/crtn.o" \
        -L"$MUSL_LIB" -lc; then
    out="$("$H/hello" 2>&1)"; rc=$?
    echo "      run        : \"$out\" (exit code $rc)  product $(stat -c%s "$H/hello") bytes"
    if [ "$out" = "hello 5" ] && [ "$rc" = 0 ]; then
      hello_ok=1
      echo "      ✅ gcc46 milestone verified (assembling/linking all go through the self-built binutils)"
    else
      warn "unexpected hello output: expected 'hello 5'/0, got '$out'/$rc"
    fi
  else
    warn "xgcc failed to compile/link hello.c"
  fi
  echo "gcc_hello_ok=$hello_ok" >> timing.txt
fi

# ---- Target-side libgcc (GOAL=all-target-libgcc / GOAL=all) ----
# Products land in $BUILD/$TARGET/libgcc/ — the "pre-install" location of libgcc in
# a GCC build tree (copying it into $prefix/lib/gcc/$target/$ver/ is `make
# install`'s job, and this script runs no install, so that rootfs3/usr/bin keeps
# xcc's entry links: an install with --prefix=/usr would drop GCC's own entries,
# e.g. cpp, into that directory).
# libgcc's compiling/assembling/archiving is done entirely by the **freshly built
# cc1 + the self-built binutils** (as/ld pinned with --with-as/--with-ld,
# AR/RANLIB/NM on the make line), with headers from the sysroot.
TARGET_LIBGCC="$BUILD/$TARGET/libgcc"
AR_TOOL="$BINUTILS_BIN/ar"; [ -x "$AR_TOOL" ] || AR_TOOL=ar
libgcc_ok=0; libgcc_size=0; libgcc_members=0; libgcc_sha=-
if [ -f "$TARGET_LIBGCC/libgcc.a" ]; then
  libgcc_ok=1
  libgcc_size=$(stat -c%s "$TARGET_LIBGCC/libgcc.a")
  libgcc_members=$("$AR_TOOL" t "$TARGET_LIBGCC/libgcc.a" 2>/dev/null | wc -l)
  libgcc_sha=$(sha256sum "$TARGET_LIBGCC/libgcc.a" | cut -c1-16)
fi
if [ -d "$TARGET_LIBGCC" ]; then
  echo
  echo "    --- target-side libgcc ($TARGET_LIBGCC) ---"
  if [ "$libgcc_ok" = 1 ]; then
    echo "      ✅ libgcc.a: $libgcc_size bytes / $libgcc_members members / sha256 $libgcc_sha"
  else
    echo "      ❌ libgcc.a not built"
  fi
  for f in libgcov.a crtbegin.o crtend.o crtbeginS.o crtendS.o crtbeginT.o \
           crtprec32.o crtprec64.o crtprec80.o crtfastmath.o; do
    [ -f "$TARGET_LIBGCC/$f" ] || continue
    printf '      %-16s %8s bytes\n' "$f" "$(stat -c%s "$TARGET_LIBGCC/$f")"
  done
fi

# ---- End-to-end acceptance (libgcc version): **no** -nostdlib, the driver picks
# ---- crt1 + libc + libgcc by itself ----
# This is the "gcc46 finally links like an ordinary compiler" criterion:
# crt1.o/crti.o/crtn.o come from musl in the sysroot, crtbegin.o/crtend.o +
# libgcc.a from the freshly built libgcc (pointed at with -B), and -lc resolves
# through the sysroot to musl's libc.a (there is no libc.so, so the product is
# static).
libgcc_link_ok=0
if [ "$libgcc_ok" = 1 ] && [ -x gcc/xgcc ] && [ -x gcc/cc1 ]; then
  T="$ROOTFS/tests"; mkdir -p "$T"
  H="$BUILD/smoke"; mkdir -p "$H"
  [ -f "$T/3-gcc-hello.c" ] || cat > "$T/3-gcc-hello.c" <<'H_EOF'
#include <stdio.h>
int add(int a, int b) { return a + b; }
int main(void) { printf("hello %d\n", add(2, 3)); return 0; }
H_EOF
  echo
  echo "    --- acceptance: gcc46 ordinary link (sysroot + libgcc, no more -nostdlib) ---"
  echo "      driver sysroot   : $(gcc/xgcc -B"$PWD/gcc" -print-sysroot 2>/dev/null || echo '(unavailable)')"
  echo "      expected sysroot : $SYSROOT"
  # libgcc's build copies `libgcc.a`/`crtbegin.o`/`crtend.o` **into the gcc
  # directory** (standard GCC behaviour), so the command below deliberately passes
  # **only -B$PWD/gcc** (not the libgcc directory): the driver must assemble
  # crt1+crti+crtbegin+libc+libgcc+crtend+crtn by itself, which says more than
  # pointing it at every piece by hand.
  for f in libgcc.a crtbegin.o crtend.o; do
    [ -f "gcc/$f" ] || warn "gcc/$f is not in the gcc directory (the libgcc build should copy it there)"
  done
  if gcc/xgcc -B"$PWD/gcc" -o "$H/hello-normal" "$T/3-gcc-hello.c" 2> "$H/hello-normal.err"; then
    out="$("$H/hello-normal" 2>&1)"; rc=$?
    echo "      run : \"$out\" (exit code $rc)  product $(stat -c%s "$H/hello-normal") bytes"
    echo "      type: $(file -b "$H/hello-normal" 2>/dev/null | cut -d, -f1-3)"
    if readelf -l "$H/hello-normal" 2>/dev/null | grep -q INTERP; then
      warn "product has PT_INTERP (expected static: musl here only ships libc.a, no libc.so)"
    fi
    if [ "$out" = "hello 5" ] && [ "$rc" = 0 ]; then
      libgcc_link_ok=1
      echo "      ✅ libgcc acceptance passed (crtbegin/crtend/libgcc.a + musl's crt/libc fully automatic; static)"
    else
      warn "the ordinarily linked product ran wrong: expected 'hello 5'/0, got '$out'/$rc"
    fi
  else
    warn "ordinary link failed (without -nostdlib):"
    sed -n '1,20p' "$H/hello-normal.err" | sed 's/^/        /'
  fi
  { echo "libgcc_ok=$libgcc_ok"; echo "libgcc_link_ok=$libgcc_link_ok"; } >> timing.txt
fi

# Failure summary: xcc diagnostics look like "path(line): message"
echo
echo "    --- compile errors (warnings excluded), deduplicated per source file ---"
grep -oE '^[^ ]+\.(c|cc|h)\([0-9]+\): .*' make-gcc.log 2>/dev/null \
  | grep -v 'warning:' \
  | sed -E 's/\(([0-9]+)\): /\t/' \
  | awk -F'\t' '{file=$1; msg=$2; if (!(file in seen)) {seen[file]=1; print "      " file "\n        " msg}}' \
  | head -60 || true
echo
echo "    --- make's own errors (first 15 lines) ---"
grep -nE '\*\*\* |Error [0-9]' make-gcc.log 2>/dev/null | head -15 | sed 's/^/      /' || true
echo
echo "    --- undefined symbols / link errors (first 10 lines) ---"
grep -nE 'Unresolved|undefined reference|cannot open' make-gcc.log 2>/dev/null | head -10 | sed 's/^/      /' || true

note "[5/5] done (stage log: $LOG)"
cat <<EOF
  build tree / sources:
    $BUILD
    $SRC
  key logs:
    $BUILD/configure.log
    $BUILD/make-gcc.log
EOF
if [ "$make_rc" != 0 ]; then
  echo "  note: make did not succeed (exit code $make_rc). On a first attempt this is expected;"
  echo "        work through the error list above and the build log, then decide whether to add a compat layer,"
  echo "        change xcc, or patch GCC's sources."
  exit "$make_rc"
fi

# ---- State record (3-lib/common.sh's record writes results/3-STATE.env) ----
source "$ROOT/3-lib/common.sh" 2>/dev/null || true
if command -v record >/dev/null 2>&1; then
  record GCC_ASLD_SRC "$ASLD_SRC"
  record GCC_AS "$AS_BIN"
  record GCC_AS_SHA256 "$(sha256sum "$AS_BIN" | cut -c1-16)"
  record GCC_LD "$LD_BIN"
  record GCC_LD_SHA256 "$(sha256sum "$LD_BIN" | cut -c1-16)"
  record GCC_CC1_SIZE "$(stat -c%s "$BUILD/gcc/cc1" 2>/dev/null || echo 0)"
  record GCC_HELLO_OK "$hello_ok"
  record GCC_SYSROOT "$SYSROOT"
  record GCC_LIBGCC_OK "$libgcc_ok"
  record GCC_LIBGCC_SIZE "${libgcc_size:-0}"
  record GCC_LIBGCC_MEMBERS "${libgcc_members:-0}"
  record GCC_LIBGCC_SHA256 "${libgcc_sha:--}"
  record GCC_LIBGCC_LINK_OK "${libgcc_link_ok:-0}"
fi
[ "$hello_ok" = 1 ] || die "GCC milestone acceptance failed (hello did not pass; see the output above)"
# When GOAL mentions libgcc the target-side acceptance must pass too (otherwise
# the next stage would assume libgcc is ready).
case "$GOAL" in
  *libgcc*)
    [ "$libgcc_ok" = 1 ] || die "GOAL=$GOAL but libgcc.a was not built (see the make log above)"
    [ "$libgcc_link_ok" = 1 ] || die "GOAL=$GOAL but the gcc46 ordinary link (sysroot+libgcc) acceptance failed"
    ;;
esac
