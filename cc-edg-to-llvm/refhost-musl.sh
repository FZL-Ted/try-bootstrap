#!/usr/bin/env bash
#
# Stage 0 of the "reference host + musl" bootstrap chain.
#
# Build musl 1.2.6 from musl-v1.2.6.tar.gz with the *host* C compiler (gcc or
# clang), and install the result into a rootfs directory:
#
#     ${ROOTFS:-$ROOT/rootfs-hostgcc}/
#       usr/include/               musl C headers
#       usr/lib/                   libc.a, libm.a, crt1.o, crti.o, crtn.o, ...
#       bin/cc                     wrapper: host cc --sysroot=<rootfs> -static
#       src/musl-1.2.6/            musl source and its build tree
#       build/                     later stages (EDG 5.1, EDG 7.0) build here
#
# From this point on nothing in the rest of the chain is allowed to use the
# host glibc: every compiler invocation goes through bin/cc, which redirects
# both the C headers (via --sysroot) and the link (static musl libc.a) to this
# rootfs.
#
# The host compiler is treated as a C-only compiler throughout: musl is plain
# C, and the later stages only ever feed it C (the EDG front end emits C for
# every C++ translation unit).  g++/clang++/-x c++ are never used.
#
# This script deletes and recreates the rootfs, so it always prepares a clean
# rootfs; run it before the EDG stages.
#
# Usage:
#     ./refhost-musl.sh
#     HOSTCC=clang ROOTFS=rootfs-hostclang ./refhost-musl.sh
#
# Overridable environment variables:
#     HOSTCC     host C compiler            (default: gcc found in PATH)
#     ROOTFS     rootfs directory           (default: <script dir>/rootfs-hostgcc;
#                                            a relative path is resolved against
#                                            the current directory)
#     TARBALL    musl release tarball       (default: searched next to the
#                                            script, one level up, then in
#                                            the reference ../edgcpp-try tree)
#     JOBS       parallel make jobs         (default: nproc)
#
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

# ---------------------------------------------------------------- rootfs ---

ROOTFS=${ROOTFS:-$ROOT/rootfs-hostgcc}
case "$ROOTFS" in
  /*) ;;
  *) ROOTFS=$PWD/$ROOTFS ;;
esac
mkdir -p "$ROOTFS"
ROOTFS=$(cd "$ROOTFS" && pwd -P)
case "$ROOTFS" in
  "$ROOT"/*) ;;
  *) die "ROOTFS must be a directory inside $ROOT: $ROOTFS" ;;
esac

SRC=$ROOTFS/src
MUSL_SRC=$SRC/musl-1.2.6
BUILD=$ROOTFS/build
LOG=$BUILD/musl-build.log

find_input() {
  # $1 = file name; prints the first existing candidate
  local name=$1 dir
  for dir in "$ROOT" "$ROOT/.." "$ROOT/../../edgcpp-try"; do
    if [ -f "$dir/$name" ]; then
      printf '%s/%s\n' "$(cd "$dir" && pwd -P)" "$name"
      return 0
    fi
  done
  return 1
}

TARBALL=${TARBALL:-$(find_input musl-v1.2.6.tar.gz || true)}
[ -n "$TARBALL" ] && [ -f "$TARBALL" ] || \
  die "musl-v1.2.6.tar.gz not found (set TARBALL=...)"
HOSTCC=${HOSTCC:-gcc}
HOSTCC=$(command -v "$HOSTCC" || true)
[ -n "$HOSTCC" ] && [ -x "$HOSTCC" ] || die "host C compiler not found (HOSTCC=${HOSTCC:-gcc})"
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 1)}

HOSTCC_VERSION=$("$HOSTCC" --version | head -n 1)
HOSTCC_TARGET=$("$HOSTCC" -dumpmachine)
HOSTCC_DUMP=$("$HOSTCC" -dumpversion)
case "$HOSTCC_TARGET" in
  x86_64*-linux-gnu*) ;;
  *) die "this chain expects an x86_64-linux-gnu host compiler, got '$HOSTCC_TARGET'" ;;
esac

# gcc and clang need slightly different link-driver flags when --sysroot moves
# the C library away from the host's default location.  gcc finds its own
# crtbegin.o/libgcc through the driver; clang looks for them under the sysroot
# unless it is told where the gcc installation lives.
case "$HOSTCC_VERSION" in
  *clang*|*Clang*) HOSTCC_KIND=clang ;;
  *)               HOSTCC_KIND=gcc ;;
esac
WRAPPER_EXTRA=
GCC_PREFIX=
if [ "$HOSTCC_KIND" = clang ]; then
  CRT_GCC=$("$HOSTCC" -print-file-name=crtbegin.o)
  [ -f "$CRT_GCC" ] || die "clang: cannot locate crtbegin.o (is gcc's runtime installed?)"
  GCC_LIBDIR=$(dirname "$CRT_GCC")
  GCC_PREFIX=${GCC_LIBDIR%/lib/gcc/*}
  [ -n "$GCC_PREFIX" ] && [ "$GCC_PREFIX" != "$GCC_LIBDIR" ] || \
    die "clang: cannot derive the gcc installation prefix from $CRT_GCC"
  WRAPPER_EXTRA="--gcc-toolchain=$GCC_PREFIX"
fi

TARBALL_SIZE=$(stat -c %s "$TARBALL")
TARBALL_SHA=$(sha256sum "$TARBALL" | cut -d' ' -f1)

info "host compiler : $HOSTCC ($HOSTCC_KIND)"
info "                $HOSTCC_VERSION ($HOSTCC_DUMP, $HOSTCC_TARGET)"
[ -n "$GCC_PREFIX" ] && info "gcc prefix    : $GCC_PREFIX (for clang's crtbegin/libgcc)"
info "musl tarball  : $TARBALL ($TARBALL_SIZE bytes, sha256 $TARBALL_SHA)"
info "rootfs        : $ROOTFS"

# ------------------------------------------------------------ clean tree ---

rm -rf "$ROOTFS"
mkdir -p "$SRC" "$BUILD" "$ROOTFS/bin"
: > "$LOG"
: > "$BUILD/.start"
START_UTC=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
START=$(date +%s)

# --------------------------------------------------------------- extract ---

info "extracting musl to $MUSL_SRC"
mkdir -p "$MUSL_SRC"
tar -xzf "$TARBALL" -C "$MUSL_SRC" --strip-components=1 >>"$LOG" 2>&1 || \
  die "extracting $TARBALL failed"
[ -f "$MUSL_SRC/configure" ] || die "unexpected musl tree: configure missing"

# ------------------------------------------------------------- configure ---
#
# musl's build is C only and uses -nostdinc/-ffreestanding internally, so the
# host compiler compiles musl's own sources against musl's own headers.  Only
# the compiler binary, binutils and its compiler runtime (libgcc) come from
# the host; no glibc header or glibc library is consumed by the produced
# libc.a.  No --host is passed: this is a native build, so musl uses the
# unprefixed host binutils.
#
# A static-only musl keeps the rest of the chain free of a dynamic loader.

info "configuring musl (prefix=/usr, static only)"
(
  cd "$MUSL_SRC"
  ./configure --prefix=/usr --disable-shared CC="$HOSTCC"
) >>"$LOG" 2>&1 || die "musl configure failed (see $LOG)"

# musl writes its build objects next to its sources, inside the rootfs.
info "building musl with $JOBS jobs"
make -C "$MUSL_SRC" -j"$JOBS" >>"$LOG" 2>&1 || \
  die "musl build failed (see $LOG)"

info "installing musl into $ROOTFS"
make -C "$MUSL_SRC" DESTDIR="$ROOTFS" install >>"$LOG" 2>&1 || \
  die "musl install failed (see $LOG)"

# The generic musl-gcc wrapper shipped by 'make install' hard-codes /usr in
# its spec file, which is wrong for a chroot-less rootfs.  The chain uses the
# dedicated wrapper below instead.
rm -f "$ROOTFS/usr/bin/musl-gcc" "$ROOTFS/usr/lib/musl-gcc.specs"
rmdir "$ROOTFS/usr/bin" 2>/dev/null || true

[ -s "$ROOTFS/usr/lib/libc.a" ] || die "musl libc.a was not installed"
[ -s "$ROOTFS/usr/lib/libm.a" ] || die "musl libm.a was not installed"
[ -s "$ROOTFS/usr/lib/crt1.o" ] || die "musl crt1.o was not installed"
[ -s "$ROOTFS/usr/include/stdio.h" ] || \
  die "musl stdio.h was not installed (is this glibc?)"
# A glibc install would also provide libc.a/crt1.o; tell the two apart by a
# musl-only internal symbol (the header check is done with the wrapper below).
nm "$ROOTFS/usr/lib/libc.a" 2>/dev/null | grep -q ' T __syscall_cp' || \
  die "installed libc.a does not look like musl"

# ------------------------------------------------------ compiler wrapper ---
#
# All later stages call this wrapper instead of the host compiler.  --sysroot
# makes it look up the C headers and libraries in the rootfs only; -static
# picks musl's crt1.o/libc.a and rules out any runtime dependency on the host
# glibc.  For clang, --gcc-toolchain points at the gcc installation that
# provides crtbegin.o and libgcc.

HOSTCC_ABS=$HOSTCC
[ -x "$HOSTCC_ABS" ] || HOSTCC_ABS=$(command -v "$HOSTCC")
cat > "$ROOTFS/bin/cc" <<EOF
#!/bin/sh
# host C compiler restricted to the musl rootfs; C only, static output.
#
# The bootstrap assumes that the host compiler is a C-only compiler.  This
# wrapper enforces that assumption for every stage that runs after musl has
# been built: a C++ input (-x c++, *.cpp, *.cc, ...) is rejected before the
# compiler sees it.  EDG's front end emits C, so a C++ file must be
# translated to C first.
REAL_GCC='$HOSTCC_ABS'
SYSROOT='$ROOTFS'
expect_x=0
for arg do
  if [ "\$expect_x" -eq 1 ]; then
    case \$arg in
      c++|c++-header|objective-c++|objective-c++-header)
        echo "cc: this toolchain is C-only; refusing '-x \$arg'" >&2
        exit 1
        ;;
    esac
    expect_x=0
    continue
  fi
  case \$arg in
    -x) expect_x=1 ;;
    *.cpp|*.cc|*.cxx|*.c++|*.C|*.CPP|*.CC|*.CXX)
      echo "cc: this toolchain is C-only; refusing C++ source '\$arg'" >&2
      exit 1
      ;;
  esac
done
exec "\$REAL_GCC" $WRAPPER_EXTRA --sysroot="\$SYSROOT" -static "\$@"
EOF
chmod +x "$ROOTFS/bin/cc"
CC=$ROOTFS/bin/cc

# ---------------------------------------------------------------- checks ---

info "check: headers really are musl, not glibc"
if printf '#include <features.h>\n' | \
     "$CC" -dM -E -x c - 2>/dev/null | grep -q '__GLIBC__'; then
  die "the rootfs headers are glibc, not musl"
fi

info "check: wrapper uses musl headers and startup files only"
INCLUDE_LIST=$("$CC" -E -v -x c /dev/null -o /dev/null 2>&1 | \
  sed -n '/search starts here:/,/End of search list/p')
printf '%s\n' "$INCLUDE_LIST" >> "$LOG"
SHORT_INC=$(printf '%s\n' "$INCLUDE_LIST" | grep -v '^#' | sed 's/^ *//')
printf '%s\n' "$SHORT_INC" | grep -qx "$ROOTFS/usr/include" || \
  die "the wrapper does not use $ROOTFS/usr/include (got: $SHORT_INC)"
if printf '%s\n' "$SHORT_INC" | grep -qx '/usr/include'; then
  die "the wrapper still searches the host glibc /usr/include"
fi

info "check: the wrapper enforces C-only compilation"
mkdir -p "$BUILD/smoke"
printf 'int main(void) { return 0; }\n' > "$BUILD/smoke/refuse.cc"
if "$CC" -c "$BUILD/smoke/refuse.cc" -o "$BUILD/smoke/refuse.o" 2>/dev/null; then
  die "the wrapper accepted a C++ source file"
fi
if "$CC" -x c++ -c "$BUILD/smoke/refuse.cc" -o "$BUILD/smoke/refuse.o" 2>/dev/null; then
  die "the wrapper accepted '-x c++'"
fi
rm -f "$BUILD/smoke/refuse.cc" "$BUILD/smoke/refuse.o"

info "check: build and run a static C program against musl"
TMP=$BUILD/smoke
mkdir -p "$TMP"
cat > "$TMP/hello.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <math.h>

static void *worker(void *arg) {
  int *p = arg;
  *p += 1;
  return NULL;
}

int main(void) {
  pthread_t t;
  int v = 41;
  char *s = malloc(16);
  if (!s) return 1;
  strcpy(s, "musl");
  if (pthread_create(&t, NULL, worker, &v) != 0) return 1;
  if (pthread_join(t, NULL) != 0) return 1;
  if (sqrt(81.0) != 9.0) return 1;
  printf("%s %d\n", s, v);
  free(s);
  return v == 42 ? 0 : 1;
}
EOF
"$CC" -O2 -Wall -o "$TMP/hello" "$TMP/hello.c" -lm >>"$LOG" 2>&1 || \
  die "the musl wrapper failed to compile the smoke test (see $LOG)"
OUT=$("$TMP/hello") || die "the musl smoke test failed at run time"
[ "$OUT" = "musl 42" ] || die "unexpected smoke test output: '$OUT'"
if readelf -l "$TMP/hello" | grep -q 'INTERP'; then
  die "smoke test is dynamically linked (glibc loader present)"
fi
if readelf -sW "$TMP/hello" | grep -q 'GLIBC_'; then
  die "smoke test carries GLIBC versioned symbols"
fi
printf '%s\n' "$OUT" >> "$LOG"

# Record exactly which compiler and libc the rest of the chain will use.
cat > "$ROOTFS/build/musl-build-info.txt" <<EOF
musl 1.2.6 built with the host $HOSTCC_KIND
date (UTC)      : $START_UTC
rootfs          : $ROOTFS
musl tarball    : $TARBALL
tarball size    : $TARBALL_SIZE bytes
tarball sha256  : $TARBALL_SHA
host compiler   : $HOSTCC
host kind       : $HOSTCC_KIND
host version    : $HOSTCC_VERSION
host target     : $HOSTCC_TARGET
compiler include: $("$CC" -print-file-name=include)
configure       : --prefix=/usr --disable-shared CC=$HOSTCC
libc            : $ROOTFS/usr/lib/libc.a ($(stat -c %s "$ROOTFS/usr/lib/libc.a") bytes)
headers         : $ROOTFS/usr/include
wrapper         : $ROOTFS/bin/cc (host cc --sysroot=$ROOTFS -static${GCC_PREFIX:+ --gcc-toolchain=$GCC_PREFIX})
smoke test      : static C + pthread + libm, output "$OUT", passed
EOF

END=$(date +%s)
info "done ($((END - START)) s)"
printf '\n'
printf 'rootfs      : %s\n' "$ROOTFS"
printf 'host cc     : %s (%s)\n' "$HOSTCC" "$HOSTCC_KIND"
printf 'musl libc   : %s (%s bytes)\n' \
       "$ROOTFS/usr/lib/libc.a" "$(stat -c %s "$ROOTFS/usr/lib/libc.a")"
printf '  (libm.a, librt.a, libpthread.a, libdl.a, ... in the same directory)\n'
printf 'headers     : %s\n' "$ROOTFS/usr/include"
printf 'wrapper cc  : %s\n' "$ROOTFS/bin/cc"
printf 'build log   : %s\n' "$LOG"
printf 'build info  : %s\n' "$ROOTFS/build/musl-build-info.txt"
