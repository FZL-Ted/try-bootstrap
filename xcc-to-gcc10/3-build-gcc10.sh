#!/bin/bash
#
# 3-build-gcc10.sh — build **GCC 10.4.0** with the gcc-4.6 installed in the rootfs.
#
# Inputs:
#   * Host compiler = `rootfs3/usr/gcc46/bin/{gcc,g++}` (installed by
#     ./3-build-gcc46-stage2.sh): the newest usable gcc-4.6. It **must** be the
#     installed copy that ships libstdc++, not a build-tree xgcc — GCC 10 itself is
#     written in C++, so the host needs a working C++ compiler plus a static
#     libstdc++ (checked below: usr/gcc46/lib64/libstdc++.a).
#   * Target libc = `rootfs3/usr/musl-gcc` (./3-build-musl-gcc.sh) plus the four
#     libraries built with gcc46 by ./3-build-deps-gcc46.sh
#     (gmp 6.2.1 / mpfr 4.1.0 / mpc 1.2.1 / zlib 1.3.2). gmp 6.2.1 is the last
#     release that gcc 4.6 can still compile.
#   * Assembler/linker = the self-built binutils 2.44 (./3-build-binutils.sh),
#     through `--with-as/--with-ld` and `AR/RANLIB/NM` on the make command line.
#
# ★ The key difference from the gcc46 build: **three-stage bootstrap is on**
#   (`--enable-bootstrap`, no `--disable-bootstrap`). Not a hack — upstream gcc-10's
#   `configure` explicitly supports a C++98 host:
#       # When bootstrapping with GCC, build stage 1 in C++98 mode to ensure that a
#       # C++98 compiler can still start the bootstrap.
#       if test "$enable_bootstrap:$GXX" = "yes:yes"; then CXX="$CXX -std=gnu++98"; fi
#   and in a native build `--enable-bootstrap` already defaults to yes. After a
#   successful bootstrap, `make` runs `make compare` in stage 3, comparing the
#   stage2/stage3 host objects **byte for byte**; a mismatch fails the build — so
#   "make succeeded" is itself the evidence that the bootstrap holds. The script
#   additionally checks the make log for `Comparison successful` and reports the
#   recorded stage directories.
#
# Usage:
#   ./3-build-gcc10.sh                     # default: three-stage bootstrap (most
#                                          # expensive, roughly 3x a single stage)
#   NO_BOOTSTRAP=1 ./3-build-gcc10.sh      # single stage (--disable-bootstrap)
#   CONF_ONLY=1 ./3-build-gcc10.sh         # configure only (quick check of the
#                                          # switches and the toolchain)
#   CLEAN=1 ./3-build-gcc10.sh             # remove the build tree first
#   FORCE_SRC=1 ./3-build-gcc10.sh         # unpack the source archive again
#   GOAL=all-gcc JOBS=20 ...               # override the make goal / parallelism
#
# Products: `rootfs3/usr/gcc10/` (`--prefix=/usr/gcc10` + `DESTDIR=$ROOTFS`; it
#        coexists with `usr/gcc46/`, neither overwrites the other; to make it the
#        "current generation" run `./3-adjust-rootfs-current.sh` afterwards)
# Log:   `results/3-build-gcc10.log`; build tree `rootfs3/build/gcc10/`
#
# Host tools: bash/make/sed/awk/grep/find/cmp/diff/perl/tar/xz/gzip/bzip2/cp/mv/rm/
#   mkdir/ln/chmod/stat/du/sha256sum/tee/readlink (all checked below), plus plain
#   coreutils (date/head/tail/sort/wc); readelf comes from the self-built binutils.
#   The script unpacks `gcc-10.4.0.tar.gz` into `rootfs3/src/` when needed.
#   **No** host gcc/cc/g++/clang, and no host /usr/include or /usr/lib.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
ROOTFS="$ROOT/rootfs3"
TARBALL="$ROOT/gcc-10.4.0.tar.gz"
SRC="$ROOTFS/src/gcc-10.4.0"
BUILD="$ROOTFS/build/gcc10"
PREFIX="/usr/gcc10"
INSTALL_ROOT="$ROOTFS$PREFIX"
HOST_GCC="$ROOTFS/usr/gcc46/bin/gcc"
HOST_GXX="$ROOTFS/usr/gcc46/bin/g++"
MUSL_GCC="$ROOTFS/usr/musl-gcc"
SYSROOT="$ROOTFS"                              # target sysroot = the current rootfs (already pointed at musl-gcc)
DEPS="$ROOTFS/usr"
BINUTILS_BIN="$ROOTFS/usr/binutils/bin"
TRIPLE="x86_64-pc-linux-gnu"
TARGET="$TRIPLE"
CFLAGS_BUILD="${CFLAGS_BUILD:--O1}"            # host-side optimization level
JOBS="${JOBS:-$(nproc)}"
GOAL="${GOAL:-all}"
CLEAN="${CLEAN:-0}"
FORCE_SRC="${FORCE_SRC:-0}"
CONF_ONLY="${CONF_ONLY:-0}"
NO_BOOTSTRAP="${NO_BOOTSTRAP:-0}"

AR_TOOL="$BINUTILS_BIN/ar"; RANLIB_TOOL="$BINUTILS_BIN/ranlib"; NM_TOOL="$BINUTILS_BIN/nm"
AS_BIN="$BINUTILS_BIN/as";  LD_BIN="$BINUTILS_BIN/ld"

LOGDIR="$ROOT/results"; LOG="$LOGDIR/3-build-gcc10.log"

die()  { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }
note() { printf '\n==> %s\n' "$*"; }

if [ "$NO_BOOTSTRAP" = 1 ]; then
  BOOT_DESC="single stage (NO_BOOTSTRAP=1, explicit --disable-bootstrap)"
else
  BOOT_DESC="**three-stage bootstrap** (--enable-bootstrap; stage1 built by a C++98 host, byte-for-byte compare on success)"
fi

mkdir -p "$LOGDIR"
exec > >(tee "$LOG") 2>&1

# ---------------------------------------------------------------- 0. Precondition checks
note "[0/7] check inputs and host tools"
[ -f "$TARBALL" ] || die "$TARBALL not found (the gcc-10.4.0 source archive belongs in the repository root)"
if [ "$FORCE_SRC" = 1 ] || [ ! -f "$SRC/configure" ]; then
  rm -rf "$SRC"
  mkdir -p "$ROOTFS/src"
  echo "    unpacking $TARBALL -> $ROOTFS/src"
  tar -xzf "$TARBALL" -C "$ROOTFS/src"
fi
[ -f "$SRC/configure" ] || die "$SRC/configure not found (did the unpack fail?)"
[ -f "$SRC/MD5SUMS" ] || warn "no MD5SUMS in the source tree (source integrity cannot be checked)"
for f in gcc/Makefile.in gcc/Makefile.in libstdc++-v3/configure.host libgcc/config.host; do
  [ -e "$SRC/$f" ] || die "missing $SRC/$f in the source tree (incomplete unpack?)"
done
# Evidence that upstream supports bootstrapping with a C++98 host (missing -> wrong source version)
grep -q 'build stage 1 in C++98 mode' "$SRC/configure" \
  || warn "'build stage 1 in C++98 mode' comment not found in $SRC/configure (different version? the bootstrap may be unsupported)"
for t in "$HOST_GCC" "$HOST_GXX"; do [ -x "$t" ] || die "missing host compiler $t (built by ./3-build-gcc46-stage2.sh)"; done
[ -f "$ROOTFS/usr/gcc46/lib64/libstdc++.a" ] || die "missing host libstdc++.a ($ROOTFS/usr/gcc46/lib64/) -- GCC 10 itself is written in C++, so the host needs a C++ runtime"
[ -f "$MUSL_GCC/lib/libc.a" ] || die "missing $MUSL_GCC/lib/libc.a (built by ./3-build-musl-gcc.sh)"
[ -f "$MUSL_GCC/include/stdio.h" ] || die "missing $MUSL_GCC/include/stdio.h"
for l in libgmp.a libmpfr.a libmpc.a libz.a; do
  [ -f "$DEPS/lib/$l" ] || die "missing one of the four libraries: $DEPS/lib/$l (run ./3-build-deps-gcc46.sh or the four 3-build-*.sh first)"
done
for h in gmp.h mpfr.h mpc.h zlib.h; do
  [ -f "$DEPS/include/$h" ] || die "missing one of the four library headers: $DEPS/include/$h"
done
for t in "$AS_BIN" "$LD_BIN" "$AR_TOOL" "$RANLIB_TOOL" "$NM_TOOL"; do
  [ -x "$t" ] || die "missing self-built binutils: $t (run ./3-build-binutils.sh first)"
done
for t in bash make sed awk grep find cmp diff perl tar xz gzip bzip2 cp mv rm mkdir ln chmod stat du sha256sum tee readlink; do
  command -v "$t" >/dev/null 2>&1 || die "missing host tool: $t"
done
# The global sysroot must already point at musl-gcc (otherwise musl-1's headers/libraries would be mixed in)
lc_sys="$(readlink -f "$SYSROOT/usr/lib/libc.a")"; lc_mg="$(readlink -f "$MUSL_GCC/lib/libc.a")"
[ "$lc_sys" = "$lc_mg" ] || die "the global sysroot does not point at musl-gcc ($SYSROOT/usr/lib/libc.a -> $(readlink "$SYSROOT/usr/lib/libc.a")):
      run ./3-adjust-rootfs-current.sh first"

echo "    sources      : $SRC (gcc 10.4.0; $(du -sh "$SRC" 2>/dev/null | cut -f1))"
echo "    host gcc     : $("$HOST_GCC" --version | head -1)  <- $HOST_GCC"
echo "    host g++     : $("$HOST_GXX" --version | head -1)"
echo "    target libc  : $MUSL_GCC (libc.a $(stat -Lc%s "$MUSL_GCC/lib/libc.a") bytes)"
echo "    four libs    : gmp $(stat -c%s "$DEPS/lib/libgmp.a") / mpfr $(stat -c%s "$DEPS/lib/libmpfr.a") / mpc $(stat -c%s "$DEPS/lib/libmpc.a") / zlib $(stat -c%s "$DEPS/lib/libz.a") bytes"
echo "    as/ld        : $AS_BIN / $LD_BIN (self-built binutils)"
echo "    target sysroot: $SYSROOT (the current rootfs, already pointed at musl-gcc)"
echo "    bootstrap    : $BOOT_DESC"
echo "    install      : $PREFIX (DESTDIR=$ROOTFS -> $INSTALL_ROOT)"
echo "    make goal    : $GOAL    parallelism: $JOBS"

# Host C++ self-check: GCC 10 is written in C++, so the host g++ must compile **and run** templates/exceptions/STL
TMPD="$ROOTFS/tests"; mkdir -p "$TMPD"
cat > "$TMPD/3-gcc10-hostcc.cc" <<'CXX_EOF'
#include <iostream>
#include <vector>
#include <string>
#include <stdexcept>
struct G { const char *n; G(const char *s):n(s){} ~G(){ std::cout << "~" << n << " "; } };
template <class T> T twice(T v) { return v + v; }
int main() {
  std::vector<std::string> v; v.push_back("host-cxx");
  try { G g("g"); throw std::runtime_error("boom"); }
  catch (const std::exception &e) { std::cout << v[0] << " " << e.what() << " " << twice(21) << std::endl; }
  return 0;
}
CXX_EOF
hostout="$("$HOST_GXX" -O1 -o "$BUILD-hostcc" "$TMPD/3-gcc10-hostcc.cc" 2>/dev/null && "$BUILD-hostcc")" \
  || die "host g++ self-check failed (neither compiling nor running it works)"
[ "$hostout" = "~g host-cxx boom 42" ] || die "unexpected host g++ self-check output: $hostout"
cat > "$TMPD/3-gcc10-hostgmp.c" <<'C_EOF'
#include <stdio.h>
#include <gmp.h>
int main(void){ mpz_t z; mpz_init_set_ui(z, 10); mpz_mul_ui(z, z, 21);
  printf("host-c-gmp %ld\n", mpz_get_ui(z)); mpz_clear(z); return 0; }
C_EOF
gmpout="$("$HOST_GCC" -o "$BUILD-hostgmp" "$TMPD/3-gcc10-hostgmp.c" -lgmp 2>/dev/null && "$BUILD-hostgmp")" \
  || die "host gcc -lgmp self-check failed"
[ "$gmpout" = "host-c-gmp 210" ] || die "unexpected host gcc/-lgmp self-check output: $gmpout"
echo "    host self-check: \"$hostout\" and \"$gmpout\" (C++ templates/exceptions/STL + linking the four libraries) ✅"

# ---------------------------------------------------------------- 1. Build tree + source adaptations
note "[1/7] prepare the build tree and the source adaptations (idempotent)"
if [ "$CLEAN" = 1 ] && [ -d "$BUILD" ]; then
  echo "    CLEAN=1: removing $BUILD"
  rm -rf "$BUILD"
fi
mkdir -p "$BUILD"

# (a) Let libstdc++ recognise musl: gcc-10's configure.host has a `linux-musl*)` ->
#     os/generic branch, but our target triple is x86_64-pc-linux-gnu (not -musl),
#     so it falls into `gnu*|linux*` -> os/gnu-linux. Point that branch at os/generic
#     as well (idempotent).
CH="$SRC/libstdc++-v3/configure.host"
if grep -q '"os/gnu-linux"' "$CH"; then
  sed -i 's|"os/gnu-linux"|"os/generic"|' "$CH"
  echo "    ✅ libstdc++-v3/configure.host: \"os/gnu-linux\" -> \"os/generic\" (musl is not glibc)"
else
  grep -q '"os/generic"' "$CH" || die "$CH contains neither \"os/gnu-linux\" nor \"os/generic\""
  echo "    already os/generic (idempotent)"
fi
grep -n 'os_include_dir="os/generic"' "$CH" | head -2 | sed 's/^/      /'

# (b) Drop two "documentation/install-info" prerequisites that always fail on this
#     machine (same approach for both, idempotent):
#     * `doc: $(BUILD_INFO) $(GENERATED_MANPAGES)` — doc is part of all.internal,
#       and the host makeinfo is texinfo 7.3, which cannot handle the old .texi
#       files of gcc-10;
#     * `install-info` in the `install:` prerequisites — the info documentation is
#       not needed.
#     ★ The edit goes into the **source Makefile.in** (not the Makefile that
#       configure generates), because each bootstrap stage configures again and
#       only Makefile.in covers every stage.
MI="$SRC/gcc/Makefile.in"
mi_before="$(sha256sum "$MI" | cut -c1-16)"
if grep -q '^doc: \$(BUILD_INFO) \$(GENERATED_MANPAGES)$' "$MI"; then
  sed -i 's|^doc: \$(BUILD_INFO) \$(GENERATED_MANPAGES)$|doc: $(GENERATED_MANPAGES)|' "$MI"
  echo "    ✅ gcc/Makefile.in: doc no longer depends on \$(BUILD_INFO) (no info output, avoiding the texinfo 7.3 vs. old .texi conflict)"
else
  echo "    gcc/Makefile.in: doc rule is not in the expected shape, skipping (idempotent)"
fi
if sed -i '/^install: install-common/,/install-driver install-lto-wrapper/s/ install-info / /' "$MI" \
   && ! grep -qE '^    install-cpp install-man install-info ' "$MI"; then
  echo "    ✅ gcc/Makefile.in: dropped install-info from install's prerequisites"
else
  echo "    gcc/Makefile.in: install-info prerequisite already dropped (idempotent)"
fi
echo "    gcc/Makefile.in sha256: $mi_before → $(sha256sum "$MI" | cut -c1-16)"
echo "    (the source tree is therefore no longer byte-identical to the archive: libstdc++-v3/configure.host"
echo "     and gcc/Makefile.in were edited; MD5SUMS reports those two as mismatches, which is expected.)"

if [ "$CONF_ONLY" = 1 ] && [ ! -f "$BUILD/Makefile" ]; then
  : # fall through: CONF_ONLY still needs at least one configure run
fi

# ---------------------------------------------------------------- 2. configure
note "[2/7] configure (CC=$HOST_GCC, CXX=$HOST_GXX, prefix=$PREFIX)"
cd "$BUILD"
BOOT_FLAG="--enable-bootstrap"; [ "$NO_BOOTSTRAP" = 1 ] && BOOT_FLAG="--disable-bootstrap"
env -u CFLAGS -u CPPFLAGS -u LDFLAGS -u CXXFLAGS \
    CC="$HOST_GCC" CXX="$HOST_GXX" \
    CFLAGS="$CFLAGS_BUILD" CXXFLAGS="$CFLAGS_BUILD" \
    "$SRC/configure" \
      --prefix="$PREFIX" \
      --build="$TRIPLE" --host="$TRIPLE" --target="$TARGET" \
      --enable-languages=c,c++ \
      --enable-clocale=generic \
      "$BOOT_FLAG" \
      --enable-checking=release \
      --disable-dependency-tracking \
      --disable-nls \
      --disable-shared \
      --disable-libstdcxx-pch \
      --disable-libssp \
      --disable-libgomp \
      --disable-libquadmath \
      --disable-libitm \
      --disable-libvtv \
      --disable-libatomic \
      --disable-libsanitizer \
      --disable-libstdcxx-filesystem-ts \
      --disable-multilib \
      --disable-lto \
      --disable-plugin \
      --without-isl \
      --with-system-zlib \
      --with-sysroot="$SYSROOT" \
      --with-as="$AS_BIN" --with-ld="$LD_BIN" \
      --with-gmp-include="$DEPS/include"    --with-gmp-lib="$DEPS/lib" \
      --with-mpfr-include="$DEPS/include"   --with-mpfr-lib="$DEPS/lib" \
      --with-mpc-include="$DEPS/include"    --with-mpc-lib="$DEPS/lib" \
      > configure.log 2>&1 || { tail -40 configure.log; die "configure failed (see $BUILD/configure.log)"; }
echo "    configure done"
grep -E 'checking for (C compiler|C\+\+ compiler)|checking whether the C compiler works|checking for the correct version of (gmp|mpfr|mpc)|checking for (gmp|mpfr|mpc) (header|lib)|checking for (as|ld) ' configure.log | tail -8 | sed 's/^/      /' || true
echo "    target library directories (should contain libgcc and libstdc++-v3):"
grep -m1 '^TARGET_CONFIGDIRS' Makefile 2>/dev/null | sed 's/^/      /' || true
echo "    configure's bootstrap verdict (config.log):"
grep -m1 -nE 'enable_bootstrap|bootstrap' configure.log 2>/dev/null | head -2 | sed 's/^/      /' || true
if [ "$NO_BOOTSTRAP" != 1 ]; then
  grep -q 'std=gnu++98' Makefile config.status 2>/dev/null \
    && echo "    ✅ configure pinned CXX to \".../g++ -std=gnu++98\" (upstream's guarantee for bootstrapping with a C++98 host; see CXX= in the Makefile)" \
    || warn "-std=gnu++98 not found in Makefile/config.status -- stage1 may not be in C++98 mode; watch the bootstrap"
fi

if [ "$CONF_ONLY" = 1 ]; then
  note "[3/7] CONF_ONLY=1: configure only, stopping here (build tree $BUILD)"
  exit 0
fi

# ---------------------------------------------------------------- 3. make (bootstrap)
note "[3/7] make -j$JOBS $GOAL ($BOOT_DESC) -- this is the most expensive step, possibly 1-2 hours"
echo "    (host CFLAGS=$CFLAGS_BUILD; AR/RANLIB/NM all point at the self-built binutils)"
t0=$(date +%s)
set +e
make -j"$JOBS" "$GOAL" \
     AR="$AR_TOOL" RANLIB="$RANLIB_TOOL" NM="$NM_TOOL" \
     > make-gcc10.log 2>&1
mk=$?
set -e
t1=$(date +%s)
echo "    make exit code: $mk    duration: $((t1-t0)) s"
if [ "$mk" != 0 ]; then
  echo "--- compile errors (warnings excluded) ---"
  grep -nE '^[^ ]+\.(c|cc|h):[0-9]+:[0-9]+: (error|fatal error)' make-gcc10.log | head -20 | sed 's/^/      /' || true
  echo "--- make error lines (first 25) ---"
  grep -nE 'Error [0-9]|error:|undefined reference' make-gcc10.log | head -25 | sed 's/^/      /' || true
  echo "--- bootstrap comparison failure? ---"
  grep -nE 'Bootstrap comparison failure|comparison failure|make\[[0-9]+\]: \*\*\* .*compare' make-gcc10.log | head -10 | sed 's/^/      /' || true
  die "make failed (see $BUILD/make-gcc10.log)"
fi

# ---------------------------------------------------------------- 4. Bootstrap verdict checks
note "[4/7] check the bootstrap verdict (stage_final / stage directories / compare record)"
echo "    stage_final        : $(cat "$BUILD/stage_final" 2>/dev/null || echo '(none)')"
for d in stage1-gcc prev-gcc gcc; do
  if [ -d "$BUILD/$d" ]; then
    printf '    %-12s present (cc1 %s bytes)\n' "$d" "$(stat -c%s "$BUILD/$d/cc1" 2>/dev/null || echo '?')"
  else
    printf '    %-12s absent\n' "$d"
  fi
done
if [ "$NO_BOOTSTRAP" = 1 ]; then
  echo "    (NO_BOOTSTRAP=1: no bootstrap comparison was done this run)"
else
  # GCC's bootstrap moves stage2-* to prev-gcc and the final compiler to gcc, so
  # those are the directories to report; stage2-gcc/stage3-gcc are not kept.
  if grep -q 'Comparison successful' "$BUILD/make-gcc10.log" 2>/dev/null; then
    echo "      ✅ make compare: Comparison successful"
  elif grep -qE 'Bootstrap comparison failure|\.bad_compare' "$BUILD/make-gcc10.log" 2>/dev/null; then
    die "bootstrap comparison failed (see $BUILD/make-gcc10.log)"
  else
    warn "make exited 0 but the log has no 'Comparison successful'; verify the bootstrap by hand"
  fi
  grep -E 'Comparing stages|Comparison successful' "$BUILD/make-gcc10.log" 2>/dev/null | tail -4 | sed 's/^/      /' || true
fi
echo "    --- target libraries ---"
for f in "gcc/cc1" "gcc/cc1plus"; do
  [ -f "$BUILD/$f" ] && printf '      %-28s %s bytes\n' "$f" "$(stat -c%s "$BUILD/$f")"
done
for f in "$BUILD/x86_64-pc-linux-gnu/libgcc/libgcc.a" \
         "$BUILD/x86_64-pc-linux-gnu/libstdc++-v3/src/.libs/libstdc++.a"; do
  [ -f "$f" ] && printf '      %-46s %s bytes\n' "${f#$BUILD/}" "$(stat -c%s "$f")"
done

# ---------------------------------------------------------------- 5. install
note "[5/7] make install DESTDIR=$ROOTFS → $INSTALL_ROOT"
set +e
make install DESTDIR="$ROOTFS" AR="$AR_TOOL" RANLIB="$RANLIB_TOOL" NM="$NM_TOOL" \
     > install.log 2>&1
inst=$?
set -e
echo "    install exit code: $inst"
if [ "$inst" != 0 ]; then
  echo "--- install error lines (first 20) ---"
  grep -nE 'Error [0-9]|error:|cannot|No such' install.log | head -20 | sed 's/^/      /' || true
  die "make install failed (see $BUILD/install.log)"
fi
find "$INSTALL_ROOT" -name '*.la' -delete 2>/dev/null || true
echo "    install tree (first two levels):"
(cd "$INSTALL_ROOT" && find . -maxdepth 2 -type d | sort | head -12 | sed 's/^/      $PREFIX/')

# ---------------------------------------------------------------- 6. Acceptance
note "[6/7] acceptance (compile C / C++ / threads / the four libraries with the freshly installed gcc-10)"
GCC10="$INSTALL_ROOT/bin/gcc"; GXX10="$INSTALL_ROOT/bin/g++"
[ -x "$GCC10" ] || die "$PREFIX/bin/gcc was not installed"
echo "    version: $("$GCC10" --version | head -1)   (machine=$("$GCC10" -dumpmachine) version=$("$GCC10" -dumpversion))"
echo "    -print-sysroot : $("$GCC10" -print-sysroot)"
echo "    -print-file-name=libc.a  : $("$GCC10" -print-file-name=libc.a)"
echo "    -print-file-name=libgmp.a: $("$GCC10" -print-file-name=libgmp.a)"

W="$BUILD/acc"; mkdir -p "$W"
cat > "$TMPD/3-gcc10-c.c" <<'C_EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <gmp.h>
int main(void) {
  char buf[64]; snprintf(buf, sizeof buf, "stage10-c %d", 10);
  mpz_t z; mpz_init_set_ui(z, 6); mpz_mul_ui(z, z, 7);
  printf("%s gmp=%ld\n", buf, mpz_get_ui(z));
  mpz_clear(z); return 0;
}
C_EOF
if "$GCC10" -O2 -o "$W/c" "$TMPD/3-gcc10-c.c" -lgmp 2>"$W/c.err"; then
  out="$("$W/c")"; echo "    C   : \"$out\" ($("$ROOTFS/usr/binutils/bin/readelf" -l "$W/c" 2>/dev/null | grep -c INTERP) PT_INTERP entries)"
  [ "$out" = "stage10-c 10 gmp=42" ] || warn "unexpected C output (expected stage10-c 10 gmp=42)"
else
  sed -n '1,10p' "$W/c.err" | sed 's/^/      /'; warn "C acceptance failed"
fi

cat > "$TMPD/3-gcc10-cxx.cc" <<'CXX_EOF'
#include <iostream>
#include <vector>
#include <string>
#include <memory>
#include <numeric>
#include <stdexcept>
#include <algorithm>
struct G { const char *n; G(const char *s):n(s){} ~G(){ std::cout << "~" << n << " "; } };
struct Base { virtual ~Base(){} virtual const char *who() const { return "base"; } };
struct Derived : Base { const char *who() const override { return "derived"; } };
template <class... T> auto sum_all(T... v) { return (v + ... + 0); }   // C++17 fold expression
int main() {
  std::vector<std::string> v{"gcc10", "cxx"};
  auto up = std::make_unique<Derived>();
  auto lam = [](int a, int b) { return a * b; };
  try { G g("g"); throw std::runtime_error("boom"); }
  catch (const std::exception &e) {
    std::cout << v[0] << "-" << v[1] << " " << e.what() << " " << up->who() << " "
              << lam(6, 7) << " " << sum_all(1, 2, 3) << " "
              << std::accumulate(v.begin(), v.end(), std::string(""))
              << std::endl;
  }
  return 0;
}
CXX_EOF
if "$GXX10" -O2 -std=c++17 -o "$W/cc" "$TMPD/3-gcc10-cxx.cc" 2>"$W/cc.err"; then
  out="$("$W/cc")"; echo "    C++ : \"$out\""
  [ "$out" = "~g gcc10-cxx boom derived 42 6 gcc10cxx" ] || warn "unexpected C++ output (expected ~g gcc10-cxx boom derived 42 6 gcc10cxx)"
else
  sed -n '1,10p' "$W/cc.err" | sed 's/^/      /'; warn "C++ acceptance failed"
fi

cat > "$TMPD/3-gcc10-thread.cc" <<'CXX_EOF'
#include <iostream>
#include <thread>
#include <mutex>
#include <vector>
#include <numeric>
int main() {
  std::mutex m; long total = 0; std::vector<std::thread> ts;
  for (int i = 1; i <= 4; ++i) ts.emplace_back([&, i]{ std::lock_guard<std::mutex> lk(m); total += i * 10; });
  for (auto &t : ts) t.join();
  std::cout << "stage10-cxx-thread " << total << std::endl;   // 10+20+30+40 — the four threads add 10, 20, 30 and 40
  return 0;
}
CXX_EOF
if "$GXX10" -O2 -pthread -o "$W/th" "$TMPD/3-gcc10-thread.cc" 2>"$W/th.err"; then
  out="$("$W/th")"; echo "    threads: \"$out\""
  [ "$out" = "stage10-cxx-thread 100" ] || warn "unexpected thread output (expected stage10-cxx-thread 100)"
else
  sed -n '1,10p' "$W/th.err" | sed 's/^/      /'; warn "thread acceptance failed"
fi

# Run it again under env -i (absolute paths only, empty environment)
if env -i "$GXX10" -O2 -std=c++17 -o "$W/ccenv" "$TMPD/3-gcc10-cxx.cc" 2>/dev/null && \
   [ "$("$W/ccenv")" = "~g gcc10-cxx boom derived 42 6 gcc10cxx" ]; then
  echo "    env -i: ✅ (the same C++ program compiles and runs identically in an empty environment)"
else
  warn "env -i acceptance failed"
fi

# Scan the public headers: take the **installed tree**'s top-level public headers.
# The gcc-10 install flattens libstdc++'s source headers into the top level of
# include/c++/10.4.0/, so there is no std/ or c/ subdirectory to look into there.
HDRS="$INSTALL_ROOT/include/c++/10.4.0"
if [ -d "$HDRS" ]; then
  ok=0; bad=0; extra=""
  for h in $(find "$HDRS" -maxdepth 1 -type f -printf '%f\n' | grep -vE '\.(h|tcc|py)$' | sort); do
    printf '#include <%s>\nint main(){return 0;}\n' "$h" > "$W/h.cc"
    if "$GXX10" -std=c++17 -fsyntax-only "$W/h.cc" 2>/dev/null; then
      ok=$((ok+1))
    else
      bad=$((bad+1)); extra="$extra $h"
    fi
  done
  echo "    public headers: ${ok} pass / ${bad} need extra flags (of $((ok+bad)) top-level public headers in $HDRS)"
  [ -n "$extra" ] && echo "      need extra flags:$extra (e.g. <coroutine> needs -std=c++20 -fcoroutines; not a defect)"
  if [ -f "$HDRS/coroutine" ]; then
    printf '#include <coroutine>\nint main(){return 0;}\n' > "$W/h.cc"
    "$GXX10" -std=c++20 -fcoroutines -fsyntax-only "$W/h.cc" 2>/dev/null \
      && echo "      <coroutine>: available with C++20 + -fcoroutines ✅"
  fi
else
  warn "gcc-10's C++ header directory $HDRS not found"
fi

# C++17's std::filesystem leans heavily on libc (dirent/stat/readlink) — a good health check for musl
cat > "$TMPD/3-gcc10-fs.cc" <<'FS_EOF'
#include <filesystem>
#include <iostream>
int main() {
  namespace fs = std::filesystem;
  std::error_code ec; fs::path p("/tmp/gcc10fs");
  fs::create_directories(p, ec); fs::remove_all(p, ec);
  std::cout << "stage10-fs " << fs::path("/a/b").filename().string() << " " << ec.value() << std::endl;
  return 0;
}
FS_EOF
if "$GXX10" -O2 -std=c++17 -o "$W/fs" "$TMPD/3-gcc10-fs.cc" 2>"$W/fs.err"; then
  out="$("$W/fs")"; echo "    filesystem: \"$out\""
  [ "$out" = "stage10-fs b 0" ] || warn "unexpected filesystem output"
else
  sed -n '1,8p' "$W/fs.err" | sed 's/^/      /'; warn "std::filesystem acceptance failed"
fi

# LTO is **intentionally** off (--disable-lto); this only records the fact
printf 'int f(int x){return x*3;}\nint main(){return f(2)==6?0:1;}\n' > "$W/lto.c"
if "$GCC10" -O2 -flto -o "$W/lto" "$W/lto.c" 2>/dev/null; then
  echo "    -flto    : ✅ available"
else
  echo "    -flto    : ⛔ unavailable (--disable-lto is passed deliberately; drop that switch and rebuild if LTO is needed)"
fi

# ---------------------------------------------------------------- 7. Record
note "[7/7] record and wrap up"
source "$ROOT/3-lib/common.sh" 2>/dev/null || true
if command -v record >/dev/null 2>&1; then
  record GCC10_VERSION "10.4.0"
  record GCC10_BUILD "$BUILD"
  record GCC10_PREFIX "$PREFIX"
  record GCC10_SYSROOT "$SYSROOT"
  record GCC10_HOST_CC "$HOST_GCC"
  record GCC10_HOST_CXX "$HOST_GXX"
  record GCC10_BOOTSTRAP "$([ "$NO_BOOTSTRAP" = 1 ] && echo disabled || echo enabled)"
  record GCC10_MAKE_GOAL "$GOAL"
  record GCC10_MAKE_EXIT "$mk"
  record GCC10_INSTALL_EXIT "$inst"
  record GCC10_CC1_SIZE "$(stat -c%s "$INSTALL_ROOT/libexec/gcc/$TARGET/10.4.0/cc1" 2>/dev/null || echo 0)"
  record GCC10_CC1PLUS_SIZE "$(stat -c%s "$INSTALL_ROOT/libexec/gcc/$TARGET/10.4.0/cc1plus" 2>/dev/null || echo 0)"
  record GCC10_LIBGCC_SIZE "$(stat -c%s "$INSTALL_ROOT/lib/gcc/$TARGET/10.4.0/libgcc.a" 2>/dev/null || echo 0)"
  record GCC10_LIBGCC_MEMBERS "$("$AR_TOOL" t "$INSTALL_ROOT/lib/gcc/$TARGET/10.4.0/libgcc.a" 2>/dev/null | wc -l)"
  record GCC10_LIBSTDCXX_SIZE "$(stat -c%s "$INSTALL_ROOT/lib64/libstdc++.a" 2>/dev/null || stat -c%s "$INSTALL_ROOT/lib/libstdc++.a" 2>/dev/null || echo 0)"
  record GCC10_STAGE_FINAL "$(cat "$BUILD/stage_final" 2>/dev/null || echo -)"
  record GCC10_INSTALL_ROOT "$INSTALL_ROOT"
fi
echo "    key product locations:"
for f in "libexec/gcc/$TARGET/10.4.0/cc1" "libexec/gcc/$TARGET/10.4.0/cc1plus" \
         "lib/gcc/$TARGET/10.4.0/libgcc.a" "lib64/libstdc++.a" "include/c++/10.4.0/iostream"; do
  [ -e "$INSTALL_ROOT/$f" ] && printf '      ✅ %-44s %s\n' "$PREFIX/$f" "$(stat -c%s "$INSTALL_ROOT/$f" 2>/dev/null || echo -)"
done

note "done (log: $LOG)"
cat <<EOF
  installed to: $INSTALL_ROOT
  next step (optional: switch the rootfs's "current generation" to gcc-10):
      ./3-adjust-rootfs-current.sh          # first point its GCC_PREFIX at /usr/gcc10
EOF
