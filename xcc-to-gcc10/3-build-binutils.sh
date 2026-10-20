#!/bin/bash
#
# 3-build-binutils.sh — build GNU binutils 2.44 with **xcc-musl** (the third-generation
#   xcc C front end) + musl 1.2.6, C-only parts: as/ld/ar/objdump/nm/...
#
# Why this stage is needed:
#   GCC's own `gcc/as` and `gcc/collect-ld` are only forwarding shell scripts; the
#   real work is done by the `as`/`ld` that GCC's configure recorded. Without
#   --with-as/--with-ld that is the host /usr/bin/{as,ld} picked from PATH, so those
#   scripts forward to host tools. ./3-build-gcc46-xcc.sh therefore pins its driver to the
#   tools built here (rootfs3/usr/binutils/bin/{as,ld}), falling back to the as/ld
#   bundled with xcc only if this stage has not run.
#   xcc's as cannot replace GNU as: it does not understand GNU options such as
#   `--64` (which GCC's x86-64 ASM_SPEC passes) and lacks x87/SSE instructions, so
#   it cannot assemble GCC's output. This stage must therefore run before the GCC
#   stage for the self-hosted path to be self-consistent.
#
# Why 2.44: binutils-2.44.tar.gz is the source package available locally (already
#   fetched, so the build needs no network). In 2.44 the `gold` directory is gone and
#   gprofng still needs C++; with the C++ components disabled, the remaining
#   as/ld/ar/objdump/nm/... are all C.
#
# C++ components (disabled: the xcc/musl toolchain has no C++ front end):
#   * `--disable-gold`    — gold is C++ (upstream removed the directory in 2.44; the
#                           flag is explicit and doubles as a safety net);
#   * `--disable-gprofng` — gprofng is C++ (gprofng/src is built from .cc sources);
#   * `--disable-gdb`, `--disable-sim` — this source package contains **no** gdb/sim
#                           directories at all (they are released separately as
#                           gdb-*.tar.gz); the flags are only explicit "not wanted"
#                           markers. binutils' top-level configure sets
#                           `enable_option_checking=no`, so it accepts them silently:
#                           no "unrecognized options" warning is printed, which is
#                           expected and does not affect the build.
#   * GCC-only switches such as `--disable-libquadmath` do not exist here and are
#                           not passed.
#   The remaining `gprof` (C) is only built by `make all`, not by this stage's
#   default goal.
#
# Install location (rootfs3 is managed as a sysroot, but existing tools must not be
# overwritten):
#   `--prefix=/usr/binutils` + `make install DESTDIR=$ROOTFS`
#     → rootfs3/usr/binutils/{bin,lib,include,share}
#   Why not `--prefix=/usr`: that `make install` would overwrite
#     rootfs3/usr/bin/{as,ld,...}, the entry links the rest of the chain uses.
#     Repointing those links at the new tools is a separate step, done by
#     3-adjust-rootfs-current.sh (this script does not touch them).
#   This script hashes rootfs3/usr/bin/{as,ld} and
#   rootfs3/usr/xcc-musl/bin/{xcc,cc1,cpp,as,ld} before and after install and aborts
#   if any of them changed.
#
# Prerequisites:
#   rootfs3/usr/xcc-musl/bin/{xcc,cc1,cpp,as,ld}   ← ./3-build-xcc-musl.sh
#   rootfs3/usr/xcc-musl/bin/xcc-musl-cc           ← ./3-build-xcc-musl.sh (CC wrapper)
#   rootfs3/usr/{include,lib}/                     ← ./3-build-musl-xcc.sh (musl headers/libs)
#   rootfs3/usr/{include/zlib.h,lib/libz.a}        ← ./3-build-zlib.sh (--with-system-zlib)
#   binutils-2.44.tar.gz                           ← repository root (already present)
#
# Products (on success):
#   rootfs3/usr/binutils/bin/{as,ld,ar,ranlib,nm,objdump,readelf,strip,objcopy,strings,size,...}
#   rootfs3/usr/binutils/lib/lib{bfd,opcodes,ctf,sframe}.a + libctf-nobfd.a
#   rootfs3/usr/binutils/include/*.h               bfd.h, bfdlink.h, dis-asm.h, ...
#                                                  (libiberty is built as a dependency
#                                                   but not installed here; gprof is not
#                                                   in the default goal)
#   rootfs3/src/binutils-2.44/                     unpacked source (not modified)
#   rootfs3/build/binutils-2.44/                   build tree + configure.log /
#                                                  make-binutils.log / install.log
#   rootfs3/tests/binutils-smoke.c                 smoke-test source
#   results/3-build-binutils.log                   full run log (tee)
#   results/3-STATE.env                            BINUTILS_* keys appended
#
# Usage:
#   ./3-build-binutils.sh                 # unpack -> configure -> make -> empty-object check -> install -> smoke
#   CONF_ONLY=1 ./3-build-binutils.sh     # configure only (quick probe)
#   MAKE_ONLY=1 ./3-build-binutils.sh     # skip configure, reuse the existing build tree and only run make
#                                         # (for source edits; changing configure options needs a fresh configure)
#   GOAL=all ./3-build-binutils.sh        # also build gprof/libctf/libsframe
#                                         # (default goal: all-gas all-ld all-binutils)
#   CLEAN=1 ./3-build-binutils.sh         # delete the build tree first
#   FORCE_SRC=1 ./3-build-binutils.sh     # unpack the source again
#   NO_INSTALL=1 ./3-build-binutils.sh    # do not install (inspect the artifacts in the build tree)
#   NO_SMOKE=1 ./3-build-binutils.sh      # skip the smoke test
#   CPU_LIMIT=1800 ./3-build-binutils.sh  # CPU-time limit for make (seconds, ulimit -t)
#   JOBS=8 ./3-build-binutils.sh          # parallelism
#
# ⚠️ Troubleshooting discipline (the same as in 3-build-gcc46-xcc.sh):
#   1) judge speed by **CPU time** (user+sys) only: this machine suspends, so
#      wall-clock time is meaningless;
#   2) do not treat "file exists / exit code 0" as success: the xcc driver is a
#      cpp|cc1|as pipeline, and when an upstream stage is killed the downstream as
#      still writes a **384-byte empty-shell .o** and exits 0 — hence the
#      empty-object check at the end;
#   3) `make` does not rebuild existing .o files when the compiler changes: after
#      switching toolchains use CLEAN=1 or delete the targets explicitly.
#
# ---------------------------------------------------------------------------
# Host tools used — full disclosure: apart from the xcc toolchain in rootfs3, the host
# binaries used here are listed below; they are all unpack / text-processing /
# archive / driver tools, not compilers:
#
#   /usr/bin/bash       runs this script
#   /usr/bin/make       GNU make, drives binutils' configure/Makefile
#   /usr/bin/tar + gzip unpack binutils-2.44.tar.gz
#   /usr/bin/sed        called by binutils' configure/Makefile itself
#   /usr/bin/awk(gawk)  used by the build itself (config.status, gen* shell parts)
#   /usr/bin/grep       used by the build; also for the preconditions and failure summaries here
#   /usr/bin/find cp mv rm mkdir ln cat head tail wc tr cut sort uniq cmp stat
#   /usr/bin/install    installs into rootfs3/usr/binutils
#   /usr/bin/ar ranlib  archive libiberty/libbfd/... during the build (**not** the product's ar)
#   /usr/bin/nm         symbol probes
#   /usr/bin/file readelf sha256sum   inspect artifacts and record hashes
#   /usr/bin/tee        mirrors the whole run into results/3-build-binutils.log
#
#   flex/bison/makeinfo are **not** needed: the release tarball ships the generated
#   lexer/parser sources (binutils/arparse.c, arlex.c, gas/itbl-parse.c, ...) and the
#   pre-built .info documents, and maintainer mode is off by default. make is also
#   invoked with MAKEINFO=true.
#
# No build product is compiled or linked with host gcc/cc/clang/g++/ld/as/cpp, nor
# with host /usr/include or /usr/lib: compiling/assembling/linking is done entirely
# by the xcc toolchain in rootfs3/usr/xcc-musl/bin + musl. (binutils' configure still
# runs its usual compiler probes, including a C++ one, but nothing is built from
# their result.) The acceptance test for the new binutils also uses only binutils
# itself + musl.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
ROOTFS="$ROOT/rootfs3"
XCCDIR="$ROOTFS/usr/xcc-musl"              # third-generation toolchain (linked against musl)
XCC="$XCCDIR/bin/xcc"
WRAP="$XCCDIR/bin/xcc-musl-cc"             # CC wrapper (reused by the libraries and the GCC stage)
SYSINC="$ROOTFS/usr/include"               # global sysroot (musl-1 headers/libs)
SYSLIB="$ROOTFS/usr/lib"

TARBALL="$ROOT/binutils-2.44.tar.gz"
SRCDIR_ROOT="$ROOTFS/src/binutils-2.44"    # unpack root; its contents are used directly as srcdir
SRC="$SRCDIR_ROOT"                         # the srcdir (configure lives here)
BUILD="$ROOTFS/build/binutils-2.44"
TESTS="$ROOTFS/tests"
LOGDIR="$ROOT/results"
STATE="$LOGDIR/3-STATE.env"
LOG="$LOGDIR/3-build-binutils.log"

PREFIX="/usr/binutils"                     # ★ dedicated prefix: never lands in /usr/bin
PREFIX_DIR="$ROOTFS$PREFIX"

TRIPLE="x86_64-pc-linux-gnu"
TARGET="${TARGET:-x86_64-pc-linux-gnu}"    # amd64 only in this stage
JOBS="${JOBS:-$(nproc)}"
CLEAN="${CLEAN:-0}"
FORCE_SRC="${FORCE_SRC:-0}"
CONF_ONLY="${CONF_ONLY:-0}"
MAKE_ONLY="${MAKE_ONLY:-0}"
NO_INSTALL="${NO_INSTALL:-0}"
NO_SMOKE="${NO_SMOKE:-0}"
CPU_LIMIT="${CPU_LIMIT:-0}"
CFLAGS_BUILD="${CFLAGS_BUILD:--O1}"
# Minimal goal: as + ld + binutils (ar/nm/objdump/...). `make all` also builds
# gprof/libctf/libsframe.
GOAL="${GOAL:-all-gas all-ld all-binutils}"

die()  { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }
note() { printf '\n==> %s\n' "$*"; }

record() { # record <key> <value> (same format as 3-lib/common.sh; keys carry the BINUTILS_ prefix)
  mkdir -p "$LOGDIR"; touch "$STATE"
  grep -v "^$1=" "$STATE" > "$STATE.tmp" 2>/dev/null || true
  mv "$STATE.tmp" "$STATE"
  echo "$1=$2" >> "$STATE"
}

mkdir -p "$LOGDIR"
exec > >(tee "$LOG") 2>&1
echo "### log: $LOG"
echo "### time: $(date -Is)"
echo "### host: $(uname -srm)"
echo "### command: $0 $*"

# ---------------------------------------------------------------- 0. Precondition checks
note "[0/6] checking inputs and host tools"
[ -f "$TARBALL" ] || die "$TARBALL not found (the binutils 2.44 source tarball belongs in the repository root)"
for f in xcc cc1 cpp as ld; do
  [ -x "$XCCDIR/bin/$f" ] || die "missing $XCCDIR/bin/$f (run ./3-build-xcc-musl.sh first)"
done
[ -x "$WRAP" ] || die "missing CC wrapper $WRAP (generated by ./3-build-xcc-musl.sh)"
[ -f "$SYSLIB/libc.a" ] || die "missing $SYSLIB/libc.a (run ./3-build-musl-xcc.sh first)"
[ -f "$SYSINC/stdio.h" ] || die "missing $SYSINC/stdio.h (run ./3-build-musl-xcc.sh first)"
# ★ Safety check: xcc's as/ld must be real ELF binaries. If an option-filtering as/ld
#   wrapper is installed here, it execs itself → **infinite self-exec and every
#   assembly hangs forever** (xcc -c never returns and the whole build stalls).
#   Reject that state here and print the recovery command.
for f in as ld; do
  file -b "$XCCDIR/bin/$f" | grep -q 'ELF' || \
    die "$XCCDIR/bin/$f is not ELF (it may have been overwritten by an as/ld filtering wrapper, which self-execs in an endless loop).
      recovery: install -m755 xcc/gen3as $XCCDIR/bin/as
                install -m755 xcc/gen3ld $XCCDIR/bin/ld"
done
for t in bash make tar gzip sed awk grep find ar nm file readelf readlink \
         sha256sum tee cp mv rm mkdir ln cat head tail wc tr cut sort uniq cmp stat install; do
  command -v "$t" >/dev/null 2>&1 || die "missing host tool: $t"
done

echo "    xcc    : $("$XCC" -v | tr '\n' ' ')  sha256=$(sha256sum "$XCC" | cut -c1-16)"
echo "    cc1    : $(stat -c%s "$XCCDIR/bin/cc1") bytes  as: $(stat -c%s "$XCCDIR/bin/as") bytes  ld: $(stat -c%s "$XCCDIR/bin/ld") bytes"
echo "    musl   : libc.a $(stat -c%s "$SYSLIB/libc.a") bytes"
echo "    zlib   : $(stat -c%s "$SYSLIB/libz.a" 2>/dev/null || echo missing) bytes (used by --with-system-zlib)"
echo "    CC     : $WRAP"
echo "    build/host/target : $TRIPLE / $TRIPLE / $TARGET"
echo "    make goal: $GOAL"
echo "    install prefix: $PREFIX  (DESTDIR=$ROOTFS → $PREFIX_DIR)"

# Record the existing tools that must not change (re-checked after install; see the
# header). The list is normally 7 entries: rootfs3/usr/bin/{as,ld} plus
# xcc-musl/bin/{xcc,cc1,cpp,as,ld}; entries resolving into this stage's install
# prefix are skipped because they are this stage's own products.
GUARD="$BUILD/guard-hashes.txt"
mkdir -p "$BUILD"
{
  for p in "$ROOTFS/usr/bin/as" "$ROOTFS/usr/bin/ld" \
           "$XCCDIR/bin/xcc" "$XCCDIR/bin/cc1" "$XCCDIR/bin/cpp" "$XCCDIR/bin/as" "$XCCDIR/bin/ld"; do
    if [ -e "$p" ]; then
      real="$(readlink -f "$p")"
      # usr/bin/{as,ld} may already point into this stage's install prefix after
      # ./3-adjust-rootfs-current.sh; those are our own products, so a rebuild is
      # allowed to replace them. Only guard foreign tools (e.g. xcc-musl).
      case "$real" in "$PREFIX_DIR"/*) continue ;; esac
      printf '%s  %s\n' "$(sha256sum "$real" | cut -d' ' -f1)" "$p"
    fi
  done
} > "$GUARD"
echo "    recorded sha256 of $(wc -l < "$GUARD") existing tools (re-checked after install) → $GUARD"

# ------------------------------------------------------------------ 1. Unpack the source
note "[1/6] unpacking $TARBALL -> $SRCDIR_ROOT"
if [ "$FORCE_SRC" = 1 ] || [ ! -f "$SRC/configure" ]; then
  rm -rf "$SRCDIR_ROOT"
  mkdir -p "$SRCDIR_ROOT"
  echo "    (51 MB tarball, about 400 MB unpacked, this takes a while)"
  # The tarball has a top-level binutils-2.44/ directory; strip it so that
  # $SRC/configure is the srcdir used below.
  tar -xzf "$TARBALL" -C "$SRCDIR_ROOT" --strip-components=1
else
  echo "already present, skipping unpack (FORCE_SRC=1 forces a re-unpack)"
fi
[ -f "$SRC/configure" ] || die "$SRC/configure does not exist"
BFD_VER_DATE="$(sed -n 's/^#define BFD_VERSION_DATE //p' "$SRC/bfd/version.h" 2>/dev/null)"
echo "    BFD_VERSION_DATE = $BFD_VER_DATE (the 2.44 date stamp is 20250202)"
echo "    top-level directories: $(ls "$SRC" | grep -v '^zlib$' | tr '\n' ' ' | head -c 200)"
echo "    gold directory present: $( [ -d "$SRC/gold" ] && echo yes || echo 'no (removed upstream as of 2.44)' )"
echo "    gprofng directory present: $( [ -d "$SRC/gprofng" ] && echo 'yes (C++, --disable-gprofng will be used)' || echo no )"
echo "    gdb/sim directories present: $( [ -d "$SRC/gdb" ] && echo yes || echo 'no (released separately; not in this tarball)' )"

# ------------------------------------------------------------- 2. configure
note "[2/6] configure (CC=$WRAP, C++ components off, Werror/NLS/shared off)"
# ★★ Key engineering point: binutils has a **GCC-style top-level configure** — the
#    top-level configure only configures a few directories; the configure scripts of
#    `bfd`/`opcodes`/`gas`/`ld`... are run **by make during the build** (the
#    `configure-bfd:` rules in the Makefile). So autoconf cache overrides of the
#    `ac_cv_*` kind, which are **environment variables**, cannot be passed to the
#    top-level configure only: they must be exported so that make and every
#    sub-configure inherit them (otherwise the sub-configures probe again and the
#    override "does not seem to work" — bfd/config.h stays `#undef TLS`).
#    All three below are exported:
#      ac_cv_prog_cc_c89        xcc only supports ANSI prototypes; autoconf's C89 probe
#                               program contains a K&R definition
#      ac_cv_func_vfork_works   xcc's vfork misbehaves; the answer is seeded as "no" so
#                               libiberty would use the fork fallback (see the caveat in
#                               the option list below)
#      ac_cv_tls                xcc has no TLS keyword at all, so seed it with the
#                               **empty string** to get `#define TLS ` (details below)
export ac_cv_prog_cc_c89=
export ac_cv_func_vfork_works=no
export ac_cv_tls=
if [ "$CLEAN" = 1 ]; then
  echo "    CLEAN=1: removing $BUILD"
  rm -rf "$BUILD"
fi
mkdir -p "$BUILD"
cd "$BUILD"
# autoconf's config.cache remembers the results of the first configure run (e.g. the
# vfork probe), after which changing ac_cv_* "does not seem to work". Delete it first.
find "$BUILD" -maxdepth 2 -name config.cache -delete 2>/dev/null || true

if [ "$MAKE_ONLY" = 1 ]; then
  [ -f Makefile ] || die "MAKE_ONLY=1 but $BUILD/Makefile does not exist (run configure once first)"
  echo "    MAKE_ONLY=1: reusing the existing configure result"
else
  # Options:
  #   --prefix=/usr/binutils        ★ dedicated prefix, never overwrites rootfs3/usr/bin/{as,ld}
  #   --build/--host/--target       native build: build==host==target==x86_64-pc-linux-gnu
  #   --disable-gold                gold is C++ (removed in 2.44; explicit as a safety net)
  #   --disable-gprofng             gprofng is C++ (.cc sources)
  #   --disable-gdb --disable-sim   this package has no such directories; explicit
  #                                 "not wanted" markers, silently accepted (this configure
  #                                 has option checking disabled — no warning, as expected)
  #   --disable-nls                 no internationalization (skips the po/ catalogs and
  #                                 the gettext dependency)
  #   --disable-werror              do not turn warnings into errors (xcc emits many
  #                                 unrelated warnings; binutils itself warns as well)
  #   --disable-shared --enable-static  static libraries only (libbfd/libopcodes/libctf/libsframe)
  #   --disable-silent-rules        print full command lines (needed for troubleshooting)
  #   --with-system-zlib            use the zlib 1.3.2 already installed in the sysroot
  #                                 (libz.a) instead of the zlib bundled in the tree
  #   --without-zstd                no zstd-compressed debug sections (there is no zstd library)
  #   --without-mmap                ★ stop bfd from mmap()ing input sections (bfd's
  #                                 `--with-mmap` is on by default). Reason: the bfd built
  #                                 by xcc fails on the mmap path — `ld` crashes while
  #                                 resolving relocations (`bfd_getl32` ← read_reloc ←
  #                                 _bfd_final_link_relocate, with a different crash site
  #                                 each time, i.e. memory/state corruption), and
  #                                 `strip`/`objcopy` report "mapped section … has
  #                                 non-NULL buffer". With mmap off, bfd falls back to the
  #                                 read() path. This is an **engineering workaround**, not
  #                                 a fix for xcc; the exact xcc defect is still unlocated.
  #   ac_cv_prog_cc_c89=            autoconf's C89 probe program is K&R code, and xcc only
  #                                 supports ANSI prototypes (same as in the GCC and library
  #                                 stages; an empty value means "pretend it passed")
  #   ac_cv_func_vfork_works=no     ★ xcc miscompiles the vfork shape used by libiberty's
  #                                 pex (`vfork()` then `execvp()`/`_exit()` in the child;
  #                                 the child shares the parent's stack and the parent's
  #                                 saved `environ` is corrupted). The setting is meant to
  #                                 make autoconf's "vfork works" answer no, so libiberty
  #                                 takes the fork() fallback. ⚠️ It does not reach
  #                                 libiberty's config.h: the generated configure runs
  #                                 `ac_cv_func_vfork_works=$ac_cv_func_vfork` before its
  #                                 cache check, so the value is overwritten with "yes"
  #                                 (libiberty/config.h ends up with HAVE_WORKING_VFORK).
  #                                 The export is therefore a no-op for this build.
  #   ac_cv_tls=                    ★★ **xcc has no TLS storage class at all** (none of
  #                                 `thread_local` / `_Thread_local` / `__thread` /
  #                                 `__declspec(thread)` is accepted). When bfd's ax_tls.m4
  #                                 probe fails it goes down the `ac_cv_tls=none` branch and
  #                                 **defines nothing**, so
  #                                     static TLS bfd_error_type bfd_error;
  #                                 in bfd.c is still the literal `TLS` after preprocessing →
  #                                 xcc reports "`;' or `,' expected" (observed on the
  #                                 declarations of bfd_error, _bfd_error_buf and
  #                                 error_handler_messages in bfd/bfd.c).
  #                                 Here the cache value is preset to the **empty string**
  #                                 (not `none`): `test "$ac_cv_tls" != "none"` succeeds →
  #                                 `#define TLS ` is generated (empty expansion) → those
  #                                 declarations become ordinary static variables. Semantic
  #                                 effect: bfd's error state changes from "one per thread"
  #                                 to "one global", which does not matter for single-threaded
  #                                 tools such as as/ld/ar (ax_tls.m4 has this none path for
  #                                 "compiler without TLS"; bfd.c just lacks the
  #                                 `#ifndef TLS` fallback).
  env -u CFLAGS -u CPPFLAGS -u LDFLAGS \
      ac_cv_prog_cc_c89= \
      ac_cv_func_vfork_works=no \
      ac_cv_tls= \
      CC="$WRAP" \
      CFLAGS="$CFLAGS_BUILD" \
      "$SRC/configure" \
        --prefix="$PREFIX" \
        --build="$TRIPLE" --host="$TRIPLE" --target="$TARGET" \
        --disable-gold \
        --disable-gprofng \
        --disable-gdb \
        --disable-sim \
        --disable-nls \
        --disable-werror \
        --disable-shared \
        --enable-static \
        --disable-silent-rules \
        --with-system-zlib \
        --without-zstd \
        --without-mmap \
        > configure.log 2>&1 || {
          echo "--- configure tail ---"; tail -40 configure.log
          die "configure failed (see $BUILD/configure.log)"; }
  echo "    configure done (log: $BUILD/configure.log)"
fi
echo "    --- key configure results ---"
grep -E '^checking for C compiler|^checking whether .* works|^checking for .*zlib|host system type|target system type|^configure: WARNING: unrecognized' \
  configure.log 2>/dev/null | sort -u | head -12 | sed 's/^/      /' || true
# install-<module> targets available at the top level (used by the install step;
# names can differ between versions)
INSTALL_TARGETS="$( { grep -oE '^install-(binutils|gas|ld|bfd|opcodes|libctf|libsframe|libiberty|gprof):' Makefile 2>/dev/null || true; } | tr -d ':' | sort -u | tr '\n' ' ')"
echo "    install-* targets: ${INSTALL_TARGETS:-(none)}"

if [ "$CONF_ONLY" = 1 ]; then
  note "[3/6] CONF_ONLY=1: configure only, stopping here"
  echo "    build tree: $BUILD"
  exit 0
fi

# ---------------------------------------------------------------- 3. make
note "[3/6] make -k $GOAL -j$JOBS (-k keeps going so that as many failures as possible surface)"
# Always read **CPU time** (user+sys): this machine suspends, which makes real time
# far too high.
TIMEFORMAT='    make time: %R real, %U user, %S sys'
set +e
if [ "$CPU_LIMIT" -gt 0 ] 2>/dev/null; then
  echo "    CPU time limit: $CPU_LIMIT s (ulimit -t; on timeout it stops where it is and the log is kept)"
  time ( ulimit -t "$CPU_LIMIT"; make -k -j"$JOBS" $GOAL \
           CFLAGS="$CFLAGS_BUILD" CFLAGS_FOR_BUILD="$CFLAGS_BUILD" \
           MAKEINFO=true > make-binutils.log 2>&1 )
else
  time make -k -j"$JOBS" $GOAL \
         CFLAGS="$CFLAGS_BUILD" CFLAGS_FOR_BUILD="$CFLAGS_BUILD" \
         MAKEINFO=true > make-binutils.log 2>&1
fi
make_rc=$?
set -e
echo "    make exit code: $make_rc"
{ echo "goal=$GOAL"; echo "cpu_limit=$CPU_LIMIT"; echo "exit=$make_rc";
  echo "date=$(date -Iseconds)"; } > timing.txt

# ------------------------------------------------------------------ 4. Artifacts and failure summary
note "[4/6] artifact check / empty-shell detection / failure summary"
# In the build tree several programs carry a `-new` suffix (gas/as-new, ld/ld-new,
# binutils/nm-new, binutils/strip-new), while others (binutils/ar, objdump, readelf,
# ranlib, objcopy) keep their final names. `make install` installs all of them under
# their real names (as/ld/nm/...).
for p in gas/as-new ld/ld-new binutils/ar binutils/objdump binutils/nm-new \
         binutils/readelf binutils/strip-new binutils/objcopy binutils/ranlib; do
  if [ -f "$p" ]; then
    printf '    ✅ %-20s %9s bytes  %s\n' "$p" "$(stat -c%s "$p")" "$(file -b "$p" | cut -d, -f1-2)"
  else
    printf '    ❌ %-20s not produced\n' "$p"
  fi
done
obj_total=$(find . -name '*.o' | wc -l)
echo "    .o files produced: $obj_total"

# Silent-failure detection: 384-byte empty ELF shells (when a stage of the xcc
# cpp|cc1|as pipeline is killed, as still exits 0).
# Some .o files in binutils are legitimately empty (configuration-dependent), so this
# only **reports** them and deletes nothing; the real criteria are the later "did the
# link succeed" and "does the smoke test pass".
# Known-legitimate empty object:
#   gas/literal.o — all of its code is inside `#ifdef NEED_LITERAL_POOL`, and x86
#                   does not use a literal pool (only alpha/ia64 define the macro), so
#                   the object has no symbols; the link and the smoke test pass with it.
EMPTY_OK="literal.o"
echo
echo "    --- 384-byte empty-object suspects (fake success from the xcc pipeline) ---"
empty_bad=0
while IFS= read -r o; do
  [ -n "$o" ] || continue
  base="$(basename "$o")"
  if printf ' %s ' "$EMPTY_OK" | grep -q " $base "; then
    printf '      ✅ %s (legitimately empty object, skipped per the allowlist)\n' "${o#./}"
    continue
  fi
  empty_bad=$((empty_bad+1))
  printf '      ⚠️  %s\n' "${o#./}"
done < <(find . -name '*.o' -size 384c | sort)
[ "$empty_bad" = 0 ] && echo "      ✅ no 384-byte empty shells (outside the allowlist)" || echo "      total: $empty_bad (if the final link is missing symbols, suspect these first)"

# Failure summary: xcc diagnostics look like "path(line): message"
echo
echo "    --- compile errors (warnings excluded), deduplicated per source file (first 40) ---"
grep -oE '^[^ ]+\.(c|h)\([0-9]+\): .*' make-binutils.log 2>/dev/null \
  | grep -v 'warning:' \
  | sed -E 's/\(([0-9]+)\): /\t/' \
  | awk -F'\t' '{file=$1; msg=$2; if (!(file in seen)) {seen[file]=1; print "      " file "\n        " msg}}' \
  | head -80 || true
echo
echo "    --- make's own errors (first 15 lines) ---"
grep -nE '\*\*\* |Error [0-9]' make-binutils.log 2>/dev/null | head -15 | sed 's/^/      /' || true
echo
echo "    --- undefined symbols / link errors (first 10 lines) ---"
grep -nE 'Unresolved|undefined reference|cannot open|No such file' make-binutils.log 2>/dev/null | head -10 | sed 's/^/      /' || true

# ---------------------------------------------------------------- 5. Install
note "[5/6] installing to $PREFIX_DIR (--prefix=$PREFIX, DESTDIR=$ROOTFS)"
build_ok=1
for p in gas/as-new ld/ld-new binutils/ar; do
  [ -f "$p" ] || build_ok=0
done
if [ "$build_ok" != 1 ]; then
  warn "as/ld/ar were not all produced (make exit code $make_rc) — still installing the components that did get built, for inspection"
fi
if [ "$NO_INSTALL" = 1 ]; then
  echo "    NO_INSTALL=1: skipping install"
else
  # Install only the modules this stage owns; skip any module whose install target is
  # missing. gprof (not built by the default goal) and libiberty (built as a
  # dependency, not needed at run time) are deliberately left out.
  want=""
  for t in binutils gas ld bfd opcodes libctf libsframe; do
    case " $INSTALL_TARGETS " in *" install-$t "*) want="$want install-$t" ;; esac
  done
  [ -n "$want" ] || die "no usable install-* target in the top-level Makefile (did configure fail?)"
  echo "    make$want"
  set +e
  make $want DESTDIR="$ROOTFS" MAKEINFO=true > install.log 2>&1
  inst_rc=$?
  set -e
  echo "    install exit code: $inst_rc"
  [ "$inst_rc" = 0 ] || { echo "--- install tail ---"; tail -25 install.log | sed 's/^/      /'; }
fi

# ★ Re-check: none of the existing tools may change by a single byte. Their sha256 is
# recorded before install; a changed or missing file aborts the run.
if [ -s "$GUARD" ]; then
  echo
  echo "    --- integrity re-check of existing tools (sha256 before/after install) ---"
  guard_bad=0
  while IFS= read -r line; do
    h="${line%% *}"; p="${line##* }"
    if [ ! -e "$p" ]; then printf '      ⚠️  disappeared: %s\n' "$p"; guard_bad=1; continue; fi
    h2="$(sha256sum "$(readlink -f "$p")" | cut -d' ' -f1)"
    if [ "$h" != "$h2" ]; then printf '      ❌ modified: %s\n' "$p"; guard_bad=1; fi
  done < "$GUARD"
  if [ "$guard_bad" = 0 ]; then
    echo "      ✅ all $(wc -l < "$GUARD") guarded existing tools are unchanged (entries pointing into this stage's install prefix were skipped)"
  else
    die "existing xcc tools were modified — this violates the rule that existing tools must not be overwritten"
  fi
fi

# ---------------------------------------------------------------- 6. Smoke acceptance
note "[6/6] smoke acceptance: assemble -> link -> run with the **newly built** as/ld/ar/nm/objdump"
if [ "$NO_SMOKE" = 1 ]; then
  echo "    NO_SMOKE=1: skipping"
else
  mkdir -p "$TESTS"
  cat > "$TESTS/binutils-smoke.c" <<'EOF'
/* binutils-smoke.c — acceptance program for 3-build-binutils.sh.
 * Covers: a function call, sprintf/strlen (musl's libc.a) and a return-value check. */
#include <stdio.h>
#include <string.h>
static int add(int a, int b) { return a + b; }
int main(void) {
  char buf[32];
  int n = add(20, 22);
  sprintf(buf, "%d", n);
  printf("binutils-smoke %s %zu\n", buf, strlen(buf));
  return n == 42 ? 0 : 1;
}
EOF
  B="$BUILD"
  P="$PREFIX_DIR/bin"
  BOOT_AS=""
  for c in "$P/as" "$B/gas/as-new"; do [ -x "$c" ] && BOOT_AS="$c" && break; done
  BOOT_LD=""
  for c in "$P/ld" "$B/ld/ld-new"; do [ -x "$c" ] && BOOT_LD="$c" && break; done
  BOOT_AR=""
  for c in "$P/ar" "$B/binutils/ar"; do [ -x "$c" ] && BOOT_AR="$c" && break; done
  echo "    tools used: as=$BOOT_AS"
  echo "                ld=$BOOT_LD"
  echo "                ar=$BOOT_AR"
  [ -n "$BOOT_AS" ] && [ -n "$BOOT_LD" ] && [ -n "$BOOT_AR" ] || die "as/ld/ar are incomplete, cannot run the smoke test"

  W="$B/smoke"; rm -rf "$W"; mkdir -p "$W"
  cp "$TESTS/binutils-smoke.c" "$W/smoke.c"

  # (1) Produce assembly with xcc (C->S only, no assembly/linking)
  "$WRAP" -O1 -S -o "$W/smoke.s" "$W/smoke.c"
  echo "    (1) xcc -S            -> smoke.s $(stat -c%s "$W/smoke.s") bytes"

  # (2) Assemble with the **new as**
  "$BOOT_AS" -o "$W/smoke.o" "$W/smoke.s"
  echo "    (2) binutils as       -> smoke.o $(stat -c%s "$W/smoke.o") bytes"
  "$BOOT_AS" --version | head -1 | sed 's/^/        /'

  # (3) Archive with the **new ar** and list the archive with it
  ( cd "$W" && "$BOOT_AR" cr libsmoke.a smoke.o && "$BOOT_AR" t libsmoke.a | sed 's/^/        ar t: /' )
  echo "    (3) binutils ar       -> libsmoke.a $(stat -c%s "$W/libsmoke.a") bytes"

  # (4) Link a static executable with the **new ld** (crt + musl libc.a).
  #     A non-zero exit is reported and tolerated: ld is the newest piece here, and
  #     the as/ar/objdump/... results are still worth keeping. (bfd's mmap path, which
  #     is disabled above with --without-mmap, is where linker crashes have been seen.)
  ld_ok=1
  set +e
  "$BOOT_LD" -static -o "$W/smoke" \
      "$SYSLIB/crt1.o" "$SYSLIB/crti.o" "$W/smoke.o" "$SYSLIB/crtn.o" \
      -L"$SYSLIB" -lc
  ld_rc=$?
  set -e
  echo "    (4) binutils ld       -> exit code $ld_rc"
  "$BOOT_LD" --version | head -1 | sed 's/^/        /'
  if [ "$ld_rc" != 0 ]; then
    ld_ok=0
    rm -f "$W/smoke"   # a crashed ld leaves a truncated file; do not let the checks below use it
    warn "the newly built ld failed to link (exit code $ld_rc) — known issue, see the log; as/ar and the rest remain usable"
  else
    file -b "$W/smoke" | sed 's/^/        /'
  fi

  # (5) Run it (only meaningful if ld succeeded)
  if [ "$ld_ok" = 1 ]; then
    out="$("$W/smoke")"; rc=$?
    echo "    (5) run               -> \"$out\" (exit code $rc)"
    [ "$out" = "binutils-smoke 42 2" ] && [ "$rc" = 0 ] || die "smoke test failed: expected 'binutils-smoke 42 2'/0, got '$out'/$rc"
    echo "        ✅ assemble->link->run: the whole chain went through the **new binutils**"
  else
    out="(ld failed, not run)"
    echo "    (5) run               -> skipped (ld produced no usable executable)"
  fi

  # (6) Spot-check the other basic tools (when present); the build tree uses *-new
  #     names, the installed ones use the final names.
  #     When ld failed there is no executable, so probe the object produced by as
  #     instead (nm/objdump/readelf work on both).
  probe_file="$W/smoke.o"
  [ -f "$W/smoke" ] && probe_file="$W/smoke"
  for t in nm objdump readelf strip objcopy ranlib; do
    c="$P/$t"
    [ -x "$c" ] || c="$B/binutils/$t-new"
    [ -x "$c" ] || c="$B/binutils/$t"
    [ -x "$c" ] || { echo "    (6) $t missing (skipped)"; continue; }
    case "$t" in
      nm)      "$c" "$probe_file" | grep -q ' T main\| t main\|main' && echo "    (6) nm      : found main ✅" || warn "nm did not find main" ;;
      objdump) "$c" -d "$probe_file" | grep -q 'main' && echo "    (6) objdump : disassembly contains main ✅" || warn "objdump output looks wrong" ;;
      readelf) "$c" -h "$probe_file" | grep -qE 'Type: +(REL|EXEC|DYN)' && echo "    (6) readelf : header parsed ✅" || warn "readelf output looks wrong" ;;
      strip)   cp "$probe_file" "$W/probe.stripped"; "$c" --strip-all "$W/probe.stripped" && \
                 [ -s "$W/probe.stripped" ] && echo "    (6) strip   : --strip-all ✅" || warn "strip failed" ;;
      objcopy) "$c" "$probe_file" "$W/probe.copy" && [ -s "$W/probe.copy" ] && \
                 echo "    (6) objcopy : copy ✅" || warn "objcopy failed" ;;
      ranlib)  "$c" "$W/libsmoke.a" && echo "    (6) ranlib  : index rebuilt ✅" || warn "ranlib failed" ;;
    esac
  done
  echo "$out" > "$W/SMOKE.txt"
  record BINUTILS_LD_OK "$ld_ok"
fi

note "done (log: $LOG)"
if [ -d "$PREFIX_DIR" ]; then
  echo "  install prefix contents:"
  find "$PREFIX_DIR" -maxdepth 2 \( -type f -o -type l \) -printf '    %-56p %9s\n' 2>/dev/null | sort -k1 | head -40
fi
cat <<EOF
  build tree / sources:
    $BUILD
    $SRC
  key logs:
    $BUILD/configure.log
    $BUILD/make-binutils.log
    $BUILD/install.log
    $LOG
EOF
record BINUTILS_GOAL "$GOAL"
record BINUTILS_MAKE_EXIT "$make_rc"
record BINUTILS_PREFIX "$PREFIX_DIR"
if [ -x "$PREFIX_DIR/bin/as" ] && [ -x "$PREFIX_DIR/bin/ld" ] && [ -x "$PREFIX_DIR/bin/ar" ]; then
  record BINUTILS_OK 1
  record BINUTILS_FINGERPRINT "as=$(sha256sum "$PREFIX_DIR/bin/as" | cut -c1-16) ld=$(sha256sum "$PREFIX_DIR/bin/ld" | cut -c1-16) ar=$(sha256sum "$PREFIX_DIR/bin/ar" | cut -c1-16)"
  echo "  ✅ as/ld/ar installed into $PREFIX_DIR/bin/"
else
  record BINUTILS_OK 0
  echo "  ❌ as/ld/ar incomplete (make exit code $make_rc)"
fi
if [ "$make_rc" != 0 ]; then
  echo "  note: make did not fully succeed (exit code $make_rc). The compile errors and make errors are listed above;"
  echo "        record them in the log, then decide between an xcc patch / different configure options / a source adaptation patch."
  exit "$make_rc"
fi
