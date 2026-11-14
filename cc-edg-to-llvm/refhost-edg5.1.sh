#!/usr/bin/env bash
#
# Stage 1 of the "reference host + musl" bootstrap chain.
#
# Build EDG C/C++ front end release 5.1 -- the last release whose front end is
# plain C -- with the host C compiler (gcc or clang) restricted to the musl
# rootfs created by ./refhost-musl.sh.
#
# The compiler is treated as a C-only compiler everywhere:
#
#   * the 5.1 front end itself is 63 C sources;
#   * the 5.1 C++ runtime library (lib_src/) is first translated to C by the
#     freshly built front end and only then compiled with the C-only compiler;
#   * no g++, no gcc -x c++, no C++ compiler of any kind is invoked.
#
# Inputs (read-only):
#     edgcpp-compiler-5.1.tar.gz
#     edg-support/predefined/edg5.1/predefined_macros.txt
#     ${ROOTFS:-rootfs-hostgcc}/   (musl headers + libraries + bin/cc wrapper)
#
# Output (all inside the rootfs):
#     <rootfs>/build/edg5.1/edg-5.1/build/edgcpfe   the 5.1 front end
#     <rootfs>/build/edg5.1/edg-5.1/lib/libC.a      the 5.1 runtime
#     <rootfs>/build/edg5.1/build.log
#     <rootfs>/build/edg5.1/build-info.txt
#
# Usage:
#     ./refhost-edg5.1.sh
#     HOSTCC=clang ROOTFS=rootfs-hostclang ./refhost-edg5.1.sh
#
# Overridable environment variables:
#     ROOTFS    rootfs directory (default: <script dir>/rootfs-hostgcc)
#     HOSTCC    host C compiler; must match the one used by refhost-musl.sh
#     AR        host ar (default: the ar found in PATH)
#     TARBALL   EDG 5.1 tarball
#     PREDEF    predefined macro table
#     OPT       compiler optimization flag (default: -O2)
#
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

ROOTFS=${ROOTFS:-$ROOT/rootfs-hostgcc}
case "$ROOTFS" in
  /*) ;;
  *) ROOTFS=$PWD/$ROOTFS ;;
esac
[ -d "$ROOTFS" ] || die "rootfs not found: $ROOTFS (run ./refhost-musl.sh first)"
ROOTFS=$(cd "$ROOTFS" && pwd -P)
case "$ROOTFS" in
  "$ROOT"/*) ;;
  *) die "ROOTFS must be a directory inside $ROOT: $ROOTFS" ;;
esac

BUILD=$ROOTFS/build/edg5.1
TREE=$BUILD/edg-5.1
LOG=$BUILD/build.log
CC=$ROOTFS/bin/cc

find_input() {
  local name=$1 dir
  for dir in "$ROOT" "$ROOT/.." "$ROOT/../../edgcpp-try"; do
    if [ -f "$dir/$name" ]; then
      printf '%s/%s\n' "$(cd "$dir" && pwd -P)" "$name"
      return 0
    fi
  done
  return 1
}

TARBALL=${TARBALL:-$(find_input edgcpp-compiler-5.1.tar.gz || true)}
[ -n "$TARBALL" ] && [ -f "$TARBALL" ] || \
  die "edgcpp-compiler-5.1.tar.gz not found (set TARBALL=...)"
PREDEF=${PREDEF:-$ROOT/edg-support/predefined/edg5.1/predefined_macros.txt}
OPT=${OPT:--O2}

# ---------------------------------------------------------------- sanity ---

[ -x "$CC" ] || die "musl compiler wrapper not found: $CC (run ./refhost-musl.sh first)"
[ -s "$ROOTFS/usr/lib/libc.a" ] || die "no musl libc.a in the rootfs"
[ -s "$TARBALL" ] || die "release tarball not found: $TARBALL"
[ -s "$PREDEF" ] || die "predefined macro table not found: $PREDEF"

# Everything below is produced inside <rootfs>/build/edg5.1.
[ "$BUILD" = "$ROOTFS/build/edg5.1" ] || die "unexpected build directory: $BUILD"

# The wrapper must be the musl one, not the host glibc gcc.
printf '#include <features.h>\n' | "$CC" -dM -E -x c - 2>/dev/null | \
  grep -q '__GLIBC__' && die "$CC still uses glibc headers"

GCC_REAL=$(sed -n "s/^REAL_GCC='\([^']*\)'.*/\1/p" "$CC" | head -n 1)
[ -x "$GCC_REAL" ] || die "cannot determine the host compiler behind $CC"
GCC_VERSION=$("$GCC_REAL" -dumpversion)
GCC_BANNER=$("$GCC_REAL" --version | head -n 1)
CC_NAME=$(basename "$GCC_REAL")
case "$GCC_BANNER" in
  *clang*|*Clang*) CC_KIND=clang ;;
  *)               CC_KIND=gcc ;;
esac
# The include directory must come from the wrapper, so gcc gets gcc's
# compiler headers and clang gets clang's resource headers.
GCC_INC=$("$CC" -print-file-name=include)
[ -d "$GCC_INC" ] || die "compiler include directory not found: $GCC_INC"
# If HOSTCC was given, it must be the compiler the rootfs was built with.
if [ -n "${HOSTCC:-}" ]; then
  HOSTCC_BIN=$(command -v "$HOSTCC" || true)
  [ -n "$HOSTCC_BIN" ] || die "HOSTCC not found: $HOSTCC"
  if [ "$(readlink -f "$HOSTCC_BIN")" != "$(readlink -f "$GCC_REAL")" ]; then
    die "rootfs was built with $GCC_REAL, but HOSTCC=$HOSTCC; rerun ./refhost-musl.sh with the same HOSTCC/ROOTFS"
  fi
fi
AR=${AR:-$(command -v ar || true)}
[ -n "$AR" ] || die "host ar not found"

TARBALL_SIZE=$(stat -c %s "$TARBALL")
TARBALL_SHA=$(sha256sum "$TARBALL" | cut -d' ' -f1)

info "host compiler : $GCC_REAL ($GCC_BANNER)"
info "musl rootfs   : $ROOTFS"
info "source tarball: $TARBALL ($TARBALL_SIZE bytes, sha256 $TARBALL_SHA)"
info "predefined    : $PREDEF"

# ------------------------------------------------------------ extract src ---

rm -rf "$BUILD"
mkdir -p "$TREE" "$TREE/build"
: > "$LOG"

info "extracting $TARBALL to $TREE"
tar -xzf "$TARBALL" -C "$TREE" --strip-components=1 >>"$LOG" 2>&1 || \
  die "extracting $TARBALL failed"
[ -f "$TREE/src/cfe.c" ] || die "unexpected source tree: $TREE/src/cfe.c missing"
[ -d "$TREE/lib_src" ] || die "unexpected source tree: $TREE/lib_src missing"

cd "$TREE"

# The front end reads lib/predefined_macros.txt from the EDG base directory
# (the current directory by default).  The release tarball does not contain
# the release lib/ directory, so the table is supplied by edg-support/.
mkdir -p lib
cp "$PREDEF" lib/predefined_macros.txt
[ -e include ] || ln -s include_c++ include   # release-style C++ include dir

# --------------------------------------------------- error message tables ---

info "building mk_errinfo"
"$CC" "$OPT" -w -std=gnu89 -fcommon -I src -o build/mk_errinfo util/mk_errinfo.c \
  >>"$LOG" 2>&1 || die "building mk_errinfo failed (see $LOG)"

info "generating src/err_codes.h and src/err_data.h"
./build/mk_errinfo src/error_msg.txt src/error_tag.txt \
                   src/err_codes.h src/err_data.h >>"$LOG" 2>&1 || \
  die "running mk_errinfo failed (see $LOG)"
[ -s src/err_codes.h ] && [ -s src/err_data.h ] || \
  die "error message tables were not generated"

# ------------------------------------------------------- build front end ---
#
# All 63 sources are C.  -std=gnu89 is what the 5.1 sources expect; -fcommon
# restores the tentative-definition merging they rely on, which modern gcc no
# longer does by default.  No C++ compiler and no C++ front end are involved.

FE_SOURCES=$(ls src/*.c)
FE_COUNT=$(printf '%s\n' "$FE_SOURCES" | wc -l | tr -d ' ')
info "compiling $FE_COUNT C sources"
mkdir -p build/obj
(
  cd build/obj
  "$CC" "$OPT" -w -std=gnu89 -fcommon -I ../../src -c ../../src/*.c
) >>"$LOG" 2>&1 || die "compiling the front end failed (see $LOG)"

info "linking edgcpfe 5.1"
"$CC" "$OPT" -w -o build/edgcpfe build/obj/*.o -lm \
  -Wl,-z,noexecstack >>"$LOG" 2>&1 || \
  die "linking edgcpfe failed (see $LOG)"
[ -x build/edgcpfe ] || die "edgcpfe was not produced"

# ------------------------------------------- build EDG runtime library ---
#
# lib_src/ holds the C++ runtime support library.  The release builds it with
# the front end itself: each C++ source is translated to C and that C is
# compiled by the C-only gcc.  --building_runtime passes the front end's ABI
# configuration to the runtime; the runtime requires at least C++14.  --g++
# selects EDG's GNU C++ emulation, needed because the musl headers use the GNU
# extension __builtin_va_list.

info "building the EDG 5.1 runtime library from lib_src"
RT_INCLUDES=(--sys_include="$TREE/include_c++" \
             --sys_include="$ROOTFS/usr/include" \
             --sys_include="$GCC_INC")
mkdir -p build/rt/obj
RT_COUNT=0
for src in lib_src/*.c; do
  [ -f "$src" ] || die "no runtime sources found in lib_src"
  base=$(basename "$src" .c)
  ./build/edgcpfe --c++14 --g++ --building_runtime "${RT_INCLUDES[@]}" \
    --gen_c_file_name="build/rt/$base.int.c" "$src" >>"$LOG" 2>&1 || \
    die "EDG 5.1 failed to translate $src (see $LOG)"
  "$CC" "$OPT" -w -std=gnu99 -fcommon -c "build/rt/$base.int.c" \
    -o "build/rt/obj/$base.o" >>"$LOG" 2>&1 || \
    die "$CC_NAME $GCC_VERSION failed to compile $base.int.c (see $LOG)"
  RT_COUNT=$((RT_COUNT + 1))
done
"$AR" rcs lib/libC.a build/rt/obj/*.o >>"$LOG" 2>&1 || \
  die "creating lib/libC.a failed (see $LOG)"
[ -s lib/libC.a ] || die "lib/libC.a was not produced"
RT_AR_COUNT=$("$AR" t lib/libC.a | wc -l | tr -d ' ')
info "libC.a: $RT_COUNT sources -> $RT_AR_COUNT objects, $(stat -c %s lib/libC.a) bytes"

# --------------------------------------------------------------- checks ---

info "check: version"
VERSION_OUT=$(./build/edgcpfe --version 2>&1)
printf '%s\n' "$VERSION_OUT" | grep -q 'version 5\.1' || \
  die "unexpected version output: $VERSION_OUT"

# The front end writes its output to a generated C file; that C file is
# compiled by the same C-only gcc that built the front end.  GNU emulation
# (--gcc) is required because musl's <bits/alltypes.h> uses the GNU extension
# __builtin_va_list, which EDG 5.1 only accepts in GNU mode.
C_INCLUDES=(--gcc --sys_include="$ROOTFS/usr/include")

info "check: translate, compile and run a C program"
cat > build/test_basic.c <<'EOF'
#include <stdio.h>
#include <string.h>
int add(int a, int b) { return a + b; }
int main(void) {
  char buf[16];
  strcpy(buf, "edg5.1");
  if (add(20, 22) != 42) return 1;
  printf("%s %d\n", buf, add(1, 2));
  return 0;
}
EOF
./build/edgcpfe --c99 "${C_INCLUDES[@]}" \
  --gen_c_file_name=build/test_basic.int.c build/test_basic.c \
  >>"$LOG" 2>&1 || die "EDG 5.1 failed to translate build/test_basic.c"
"$CC" "$OPT" -w -std=gnu99 -fcommon -Wl,-z,noexecstack \
  -o build/test_basic.out build/test_basic.int.c >>"$LOG" 2>&1 || \
  die "$CC_NAME $GCC_VERSION failed to compile build/test_basic.int.c"
[ "$(./build/test_basic.out)" = "edg5.1 3" ] || \
  die "generated test_basic.out failed at run time"

info "check: C++17 program + EDG runtime library"
cat > build/test_cxx.cpp <<'EOF'
struct Base { virtual int f() const { return 1; } };
struct Derived : Base { int f() const override { return 2; } };
template <class T> T twice(T v) { return v + v; }
int main() {
  Derived d; Base *p = &d;
  int a[3] = {1, 2, 3}; int s = 0;
  for (int v : a) s += v;
  auto l = [](int x) { return x * 3; };
  if constexpr (sizeof(int) >= 4) s += 0;
  return (p->f() == 2 && twice(21) == 42 && s == 6 && l(2) == 6) ? 0 : 1;
}
EOF
./build/edgcpfe --c++17 -tused --gen_c_file_name=build/test_cxx.int.c \
  build/test_cxx.cpp >>"$LOG" 2>&1 || \
  die "EDG 5.1 failed to translate build/test_cxx.cpp"
"$CC" "$OPT" -w -std=gnu99 -fcommon -Wl,-z,noexecstack -o build/test_cxx.out \
  build/test_cxx.int.c -Llib -lC -lm >>"$LOG" 2>&1 || \
  die "linking build/test_cxx.out against libC.a failed (see $LOG)"
./build/test_cxx.out || die "generated test_cxx.out failed at run time"

info "check: C++ exceptions through the EDG runtime"
cat > build/test_eh.cpp <<'EOF'
int main() {
  int r = 0;
  try { throw 42; }
  catch (int v) { r = v; }
  catch (...) { r = -1; }
  return r == 42 ? 0 : 1;
}
EOF
./build/edgcpfe --c++17 -tused --gen_c_file_name=build/test_eh.int.c \
  build/test_eh.cpp >>"$LOG" 2>&1 || \
  die "EDG 5.1 failed to translate build/test_eh.cpp"
"$CC" "$OPT" -w -std=gnu99 -fcommon -Wl,-z,noexecstack -o build/test_eh.out \
  build/test_eh.int.c -Llib -lC -lm >>"$LOG" 2>&1 || \
  die "linking build/test_eh.out against libC.a failed (see $LOG)"
./build/test_eh.out || die "generated test_eh.out failed at run time"

info "check: everything is static and glibc-free"
for exe in build/edgcpfe build/test_basic.out build/test_cxx.out build/test_eh.out; do
  if readelf -l "$exe" | grep -q INTERP; then
    die "$exe is dynamically linked"
  fi
  if readelf -sW "$exe" | grep -q 'GLIBC_'; then
    die "$exe carries GLIBC symbols"
  fi
done

# ------------------------------------------------------------ read-only ---

TARBALL_SHA_AFTER=$(sha256sum "$TARBALL" | cut -d' ' -f1)
[ "$TARBALL_SHA_AFTER" = "$TARBALL_SHA" ] || \
  die "the release tarball was modified during the build"

# ------------------------------------------------------------- summary ---

{
  printf 'EDG front end 5.1 built by the host C compiler + musl rootfs\n'
  printf 'date (UTC)      : %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  printf 'source tarball  : %s\n' "$TARBALL"
  printf 'tarball size    : %s bytes\n' "$TARBALL_SIZE"
  printf 'tarball sha256  : %s\n' "$TARBALL_SHA"
  printf 'predefined      : %s\n' "$PREDEF"
  printf 'host compiler   : %s (%s)\n' "$GCC_REAL" "$GCC_BANNER"
  printf 'compiler kind   : %s\n' "$CC_KIND"
  printf 'gcc include dir : %s\n' "$GCC_INC"
  printf 'sysroot / libc  : %s, musl %s\n' \
         "$ROOTFS" "$(stat -c %s "$ROOTFS/usr/lib/libc.a") bytes"
  printf 'front end       : %s (%s bytes)\n' "$TREE/build/edgcpfe" \
         "$(stat -c %s build/edgcpfe)"
  printf 'runtime library : %s (%s bytes, %s objects)\n' \
         "$TREE/lib/libC.a" "$(stat -c %s lib/libC.a)" "$RT_AR_COUNT"
  printf 'C sources       : %s\n' "$FE_COUNT"
  printf 'runtime sources : %s\n' "$RT_COUNT"
  printf 'smoke tests     : C, C++17+runtime, C++ exceptions (passed)\n'
  printf 'compiler rule   : the host C compiler is used as a C-only compiler;\n'
  printf '                  the C++ runtime library is translated to C by\n'
  printf '                  edgcpfe before the compiler sees it.\n'
} > "$BUILD/build-info.txt"

info "done"
printf '\n'
printf 'front end   : %s (%s bytes)\n' "$TREE/build/edgcpfe" \
       "$(stat -c %s build/edgcpfe)"
printf 'runtime lib : %s (%s bytes, %s objects)\n' \
       "$TREE/lib/libC.a" "$(stat -c %s lib/libC.a)" "$RT_AR_COUNT"
printf 'build info  : %s\n' "$BUILD/build-info.txt"
