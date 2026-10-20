#!/bin/bash
#
# 3-build-zlib.sh — build zlib 1.3.2 with the xcc + musl toolchain and install it
# into rootfs3/.
#
# This is a prerequisite for GCC 4.6.4.1: it must run before ./3-build-gcc46-xcc.sh.
#
# Why this stage is needed:
#   GCC 4.6's `all-gcc` depends on `all-zlib`
#     Makefile.def:343  dependencies = { module=all-gcc; on=all-zlib; }
#   and cc1 always links `-lz`: `ZLIB = @zlibdir@ -lz` is part of $(BACKENDLIBS)
#   on the cc1 link line, whether or not LTO is enabled. The zlib bundled in the
#   GCC 4.6 tree (`gcc/zlib/`) is **zlib 1.2.3 (2005)**, and many of its sources
#   use **K&R function definitions**:
#       uLong ZEXPORT adler32(adler, buf, len)
#           uLong adler; const Bytef *buf; uInt len;
#   xcc only supports ANSI prototypes → `type expected`, so that source does not
#   compile. Upstream zlib removed K&R definitions only in 1.3 (2023-08-18,
#   "Remove K&R function definitions and zlib2ansi"), so this script installs a
#   **naturally ANSI** zlib 1.3.2 and points GCC at it with `--with-system-zlib`
#   (which also keeps the tree zlib out of the build, so the GCC source tree stays
#   pristine and no third-party source is patched).
#   GCC uses zlib only for LTO, and LTO is disabled here, so the version
#   difference does not change compiler functionality — the `-lz` at build time is
#   all that has to resolve.
#
# ⚠️ zlib only compiles once `patches-3/xcc-stdio-seek-macros.patch` is applied to
#   xcc: zconf.h defines SEEK_SET/SEEK_CUR/SEEK_END as macros (#ifndef SEEK_SET ->
#   #define SEEK_SET 0 ...), while xcc's stdio.h declares them as enum constants
#   unless that patch is in; with the macro defined first the enum body expands to
#   0,1,2 and the parser fails. ./3-build-xcc-musl.sh applies the patch idempotently.
#
# Prerequisites:
#   rootfs3/usr/xcc-musl/bin/{xcc,cc1,cpp,as,ld} ← ./3-build-xcc-musl.sh
#   rootfs3/usr/{include,lib}/                   ← ./3-build-musl-xcc.sh
#   rootfs3/usr/xcc-musl/bin/xcc-musl-cc         ← ./3-build-xcc-musl.sh (installs the wrapper)
#
# Output:
#   rootfs3/usr/include/zlib.h, zconf.h
#   rootfs3/usr/lib/libz.a                       what GCC's --with-system-zlib points at
#   rootfs3/src/zlib-1.3.2/                      unpacked source; it is also the build tree
#                                                (in-source build, so configure.log, make.log,
#                                                install.log, the objects and libz.a all land
#                                                in this directory)
#   rootfs3/tests/zlib-smoke.c                   smoke-test source
#   results/3-build-zlib.log                     full log
#
# Usage:
#   ./3-build-zlib.sh                # full run: unpack -> configure -> make -> install -> smoke test
#   JOBS=8 ./3-build-zlib.sh
#   CLEAN=1 ./3-build-zlib.sh        # re-unpack first (drops the in-source build tree)
#   FORCE_SRC=1 ./3-build-zlib.sh    # re-unpack
#   NO_SMOKE=1 ./3-build-zlib.sh     # skip the smoke test
#   CHECK=1 ./3-build-zlib.sh        # also run zlib's own make test (minigzip pipe + example)
#
# ---------------------------------------------------------------------------
# Host tools used — full disclosure: apart from the xcc toolchain inside rootfs3,
# this script only calls the host binaries listed below; they are all unpack/
# text/archive/driver tools, not compilers:
#
#   /usr/bin/bash       runs this script
#   /usr/bin/make       GNU make, drives zlib's configure/Makefile
#   /usr/bin/tar + gzip unpack zlib-1.3.2.tar.gz
#   /usr/bin/sed        called by zlib's configure itself; also used here
#   /usr/bin/awk(gawk)  called by zlib's configure itself
#   /usr/bin/grep       called by zlib's configure itself (libtool / Apple checks)
#   /usr/bin/find cp mv rm mkdir ln cat head tail wc tr cut sort uniq cmp stat
#   /usr/bin/install    installs into rootfs3
#   /usr/bin/ar ranlib  archive the .o files xcc produced into libz.a
#   /usr/bin/nm         zlib's configure probes symbols with it
#   /usr/bin/file readelf sha256sum   checked for; file/sha256sum inspect artifacts and hashes
#   /usr/bin/tee        mirrors the whole run into results/3-build-zlib.log
#
# zlib's configure/make also spawn a host shell-tool set of their own (sed/awk/
# grep/ln/cmp/mv/rm/sort/test/expr/...); those are non-compiler tools as well and
# are declared here.
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
MUSL_INC="$ROOTFS/usr/include"
MUSL_LIB="$ROOTFS/usr/lib"
DEPS="$ROOTFS/usr"
WRAP="${CC_WRAP:-$XCCDIR/bin/xcc-musl-cc}"   # CC wrapper (xcc-musl-cc by default; CC_WRAP=… picks another, e.g. the gcc46+musl-gcc wrapper from ./3-build-deps-gcc46.sh)

TARBALL="$ROOT/zlib-1.3.2.tar.gz"
SRC="$ROOTFS/src/zlib-1.3.2"
# zlib is built **in place** (configure/make run inside the source directory),
# unlike the GCC builds:
#   zlib 1.3.2's configure adds `-include zconf.h` to CFLAGS for an **out-of-tree**
#   build (so the zconf.h in the build directory wins), and xcc does not accept
#   `-include` (`Warning: unknown option` → zconf.h is taken as a source file →
#   `Unknown source type`). Built in place, configure adds no such flag, and the
#   "zconf.h is generated in this directory" path holds anyway.
#   GCC's own build passes no compile-time `-include` (it only appears as make's
#   `-include mddeps.mk` directive, in etags and in newlib strings), so xcc needs
#   no `-include` support for it.
BUILD="$SRC"
TESTS="$ROOTFS/tests"
LOGDIR="$ROOT/results"
LOG="$LOGDIR/3-build-zlib.log"

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
[ -x "$WRAP" ] || die "missing CC wrapper $WRAP (run ./3-build-xcc-musl.sh first)"
for t in bash make tar gzip sed awk grep find install ar ranlib nm file readelf \
         sha256sum tee cp mv rm mkdir ln cat head tail wc tr cut sort uniq cmp stat; do
  command -v "$t" >/dev/null 2>&1 || die "missing host tool: $t"
done

echo "    xcc    : $("$XCC" -v | tr '\n' ' ')  sha256=$(sha256sum "$XCC" | cut -c1-16)"
echo "    musl   : libc.a $(stat -c%s "$MUSL_LIB/libc.a") bytes"
echo "    CC     : $WRAP"

# ------------------------------------------------------------------ 1. Unpack the source
note "[1/7] unpacking $TARBALL -> $SRC"
# In-source build → CLEAN and FORCE_SRC both mean "unpack again", which is the most
# deterministic and idempotent choice.
if [ "$FORCE_SRC" = 1 ] || [ "$CLEAN" = 1 ] || [ ! -d "$SRC" ]; then
  rm -rf "$SRC"
  mkdir -p "$ROOTFS/src"
  tar -xzf "$TARBALL" -C "$ROOTFS/src"
else
  echo "already present, skipping unpack (CLEAN=1 / FORCE_SRC=1 forces a fresh unpack)"
fi
[ -f "$SRC/configure" ] || die "$SRC/configure does not exist"
echo "    version: $(sed -n 's/^#define ZLIB_VERSION "\(.*\)"/\1/p' "$SRC/zlib.h" | head -1)"

# ------------------------------------------------------------------ 2. Source patches
note "[2/7] source patches"
# Since zlib 1.3 (first ChangeLog entry: "Remove K&R function definitions and
# zlib2ansi") the sources are pure ANSI C, so xcc needs no K&R support; configure
# runs no package-specific K&R probe either.
echo "    no source patch needed (1.3.2 has no K&R function definitions; configure has no package-specific K&R self-test)"

# ------------------------------------------------------------- 3. configure
note "[3/7] configure (in-source build, CC=$WRAP, --static --prefix=/usr)"
mkdir -p "$BUILD"
cd "$BUILD"
# ⚠️ Must call the **relative path** `./configure`, never "$SRC/configure":
#   zlib's configure uses `SRCDIR=`dirname $0`` to detect an out-of-tree build; as
#   soon as $0 contains a path (even an absolute path back to the same directory)
#   it takes the else branch and adds `-include zconf.h` to CFLAGS. xcc does not
#   accept `-include` (`Warning: unknown option` → zconf.h is treated as a source
#   file → `Unknown source type`). With "./configure" the dirname is ".", ZINC
#   stays empty and the problem disappears.
# ★ `-std=gnu99` (or c99 and newer) is required: zlib 1.3.2's `gzguts.h` has
#     #elif !defined(__STDC_VERSION__) || __STDC_VERSION__-0 < 199901L
#       → #define NO_snprintf / NO_vsnprintf
#   and **GCC 4.6 defaults to gnu89** (no `__STDC_VERSION__`), so zlib turns the
#   snprintf family off and the `gzprintf()` path hits the `#if defined(NO_vsnprintf)`
#   **stub**, which just returns Z_STREAM_ERROR (-2). Observed symptom: the self-test
#   in `examples/example.c` fails at `gzprintf(file, ", %s!", "hello") != 8`
#   (`make test` reports `*** zlib test FAILED ***`), returns -2 with an empty
#   `gzerror()` string — easily misread as a broken compiler. xcc avoids this
#   because it declares `__STDC_VERSION__=199901L`.
ZLIB_STD="${ZLIB_STD:--std=gnu99}"
env -u CFLAGS -u CPPFLAGS \
    CC="$WRAP" \
    CFLAGS="$CFLAGS_BUILD $ZLIB_STD" \
    ./configure --static --prefix=/usr \
      > configure.log 2>&1 || { tail -30 configure.log; die "configure failed (see $BUILD/configure.log)"; }
grep -E 'Checking for|Version|Building' configure.log | tail -6 | sed 's/^/      /' || true
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
[ -f libz.a ] || die "make finished but produced no libz.a"
echo "    libz.a: $(stat -c%s libz.a) bytes; $(ar t libz.a | wc -l) members"

# ---------------------------------------------------------------- 5. install
note "[5/7] make install DESTDIR=$ROOTFS (--prefix=/usr)"
make install DESTDIR="$ROOTFS" > install.log 2>&1 || { tail -30 install.log; die "install failed"; }
for f in "$DEPS/include/zlib.h" "$DEPS/include/zconf.h" "$DEPS/lib/libz.a"; do
  [ -f "$f" ] || die "missing $f"
done
echo "    zlib.h    $(stat -c%s "$DEPS/include/zlib.h") bytes"
echo "    zconf.h   $(stat -c%s "$DEPS/include/zconf.h") bytes"
echo "    libz.a    $(stat -c%s "$DEPS/lib/libz.a") bytes sha256=$(sha256sum "$DEPS/lib/libz.a" | cut -c1-16)"
echo "    members   $(ar t "$DEPS/lib/libz.a" | wc -l)"
# A static build should not produce a shared library; flag it if one shows up
# (GCC's --with-system-zlib needs only the .a + .h).
if ls "$DEPS/lib"/libz.so* >/dev/null 2>&1; then
  echo "    note: libz.so* appeared (this build is expected to produce only the static library)"
fi

if [ "$CHECK" = 1 ]; then
  note "[5b/7] zlib's own make test (minigzip pipe + example)"
  if make test > check.log 2>&1; then
    grep -E '\*\*\*|OK|error' check.log | tail -6 | sed 's/^/      /'
    echo "    self-test OK"
  else
    echo "    self-test FAIL"
    tail -20 check.log | sed 's/^/      /'
  fi
fi

# ---------------------------------------------------------------- 6. Smoke test
note "[6/7] smoke test (link the freshly installed libz.a with the CC wrapper)"
mkdir -p "$TESTS"
cat > "$TESTS/zlib-smoke.c" <<'EOF'
/* Smoke test: zlib compiles, compresses and decompresses, and the known
   checksums match. — Uses only the standard zlib C API; no external reference
   library is needed. */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <zlib.h>

static int failures = 0;
static void check(const char *what, int ok) {
  printf("  %-40s %s\n", what, ok ? "ok" : "FAIL");
  if (!ok) failures++;
}

int main(void) {
  const char *msg = "123456789";
  unsigned char src[4096], comp[8192], back[4096];
  uLong clen, blen;
  int i;

  printf("  zlib %s\n", zlibVersion());
  check("zlibVersion starts with 1.3", strncmp(zlibVersion(), "1.3", 3) == 0);

  /* Known checksums (standard CRC-32 and Adler-32 test vectors) */
  check("crc32(\"123456789\") == 0xCBF43926",
        crc32(0L, (const Bytef *)msg, 9) == 0xCBF43926UL);
  check("adler32(1L,\"123456789\") == 0x091E01DE",
        adler32(1L, (const Bytef *)msg, 9) == 0x091E01DEUL);
  check("adler32(0L,\"123456789\") == 0x091501DD",
        adler32(0L, (const Bytef *)msg, 9) == 0x091501DDUL);

  /* compress2 / uncompress round trip in one shot */
  for (i = 0; i < (int)sizeof src; i++)
    src[i] = (unsigned char)((i % 64) ? 'A' + (i % 26) : 'Z');   /* has repeats, so it compresses */
  clen = sizeof comp;
  check("compress2 succeeded", compress2(comp, &clen, src, sizeof src, 6) == Z_OK);
  printf("  %d bytes -> %lu bytes\n", (int)sizeof src, (unsigned long)clen);
  check("output really is compressed", clen < sizeof src);
  blen = sizeof back;
  check("uncompress succeeded", uncompress(back, &blen, comp, clen) == Z_OK);
  check("decompressed length matches", blen == sizeof src);
  check("decompressed content matches", memcmp(back, src, sizeof src) == 0);

  /* deflate / inflate streaming round trip */
  {
    z_stream zs;
    Bytef out[8192];
    uLong produced;
    memset(&zs, 0, sizeof zs);
    check("deflateInit succeeded", deflateInit(&zs, 6) == Z_OK);
    zs.next_in = src; zs.avail_in = sizeof src;
    zs.next_out = out; zs.avail_out = sizeof out;
    check("deflate(Z_FINISH) succeeded", deflate(&zs, Z_FINISH) == Z_STREAM_END);
    produced = sizeof out - zs.avail_out;
    check("deflateEnd succeeded", deflateEnd(&zs) == Z_OK);

    memset(&zs, 0, sizeof zs);
    check("inflateInit succeeded", inflateInit(&zs) == Z_OK);
    zs.next_in = out; zs.avail_in = (uInt)produced;
    zs.next_out = back; zs.avail_out = sizeof back;
    check("inflate(Z_FINISH) succeeded", inflate(&zs, Z_FINISH) == Z_STREAM_END);
    check("streaming round trip preserves content",
          sizeof back - zs.avail_out == sizeof src && memcmp(back, src, sizeof src) == 0);
    check("inflateEnd succeeded", inflateEnd(&zs) == Z_OK);
  }

  /* gz* file API round trip */
  {
    gzFile g;
    char gzpath[] = "/tmp/zlib-smoke.gz";
    g = gzopen(gzpath, "wb");
    check("gzopen(wb) succeeded", g != NULL);
    if (g != NULL) {
      check("gzwrite wrote everything", gzwrite(g, src, sizeof src) == (int)sizeof src);
      check("gzclose(wb) succeeded", gzclose(g) == Z_OK);
    }
    memset(back, 0, sizeof back);
    g = gzopen(gzpath, "rb");
    check("gzopen(rb) succeeded", g != NULL);
    if (g != NULL) {
      int n = gzread(g, back, sizeof back);
      check("gzread read back the same length", n == (int)sizeof src);
      check("gzread content matches", memcmp(back, src, sizeof src) == 0);
      check("gzclose(rb) succeeded", gzclose(g) == Z_OK);
    }
    remove(gzpath);
  }

  /* The gz file really is a gzip stream: read the raw bytes with plain stdio and
     look at the magic number. (Do not use gzopen/gzread — they decompress and
     would hand back the original data instead of the file header.) */
  {
    unsigned char hdr[2] = {0, 0};
    gzFile g = gzopen("/tmp/zlib-smoke2.gz", "wb");
    if (g) { gzwrite(g, src, sizeof src); gzclose(g); }
    {
      FILE *f = fopen("/tmp/zlib-smoke2.gz", "rb");
      if (f) { size_t got = fread(hdr, 1, 2, f); (void)got; fclose(f); }
    }
    check("gz file starts with 1f 8b", hdr[0] == 0x1f && hdr[1] == 0x8b);
    remove("/tmp/zlib-smoke2.gz");
  }

  printf("  %d failed\n", failures);
  return failures == 0 ? 0 : 1;
}
EOF
if [ "$NO_SMOKE" != 1 ]; then
  w=$(mktemp -d)
  "$WRAP" -o "$w/smoke" "$TESTS/zlib-smoke.c" -L"$MUSL_LIB" -lz || die "smoke compile/link failed"
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
    $DEPS/include/zlib.h
    $DEPS/include/zconf.h
    $DEPS/lib/libz.a
  Build tree / source:
    $BUILD
    $SRC
  Log:
    $LOG

  Next step: ./3-build-gcc46-xcc.sh passes --with-system-zlib to GCC, so it does not
  build the K&R gcc/zlib bundled in the GCC source tree and uses this libz.a instead.
EOF
