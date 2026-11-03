#!/usr/bin/env bash
#
# Build the EDG C/C++ front end release 5.1 -- the last release that can be
# built with a C-only compiler -- using the C-only GCC 4.6.4 + musl reference
# toolchain from:
#
#     compiler-test/ref-rootfs-gcc4.6-c-only
#
# Sources come from a release tarball, not from a git checkout.  Two input
# files must already exist next to this script:
#
#     edg-compiler-5.1.tar.gz    release tarball (GitHub archive of tag 5.1)
#     predefined_macros.txt      EDG predefined-macro table (from edg origin/main)
#
# This builds two products under ./build/edg5.1-gcc4.6c/:
#
#   * edgcpfe -- the C/C++ front end itself (63 plain-C sources);
#   * libC.a  -- the EDG C++ runtime support library (51 C++ sources from
#                lib_src/, translated to C by the just-built front end and
#                then compiled by GCC 4.6).
#
# The reference rootfs is treated as read-only input.  Everything the build
# produces (extracted tree, objects, executable, runtime library, generated
# files, smoke tests) goes under:
#
#     build/edg5.1-gcc4.6c/
#
# The front end sources of 5.1 are plain C (the switch to C++ happened for the
# 6.0 release), so a compiler that only supports C is sufficient for the front
# end.  The runtime library is C++, but it is compiled *with that front end*,
# so no external C++ compiler is needed either.
#
# Usage:
#     ./build-edg-5.1-by-gcc-4.6-c-only.sh
#
# Overridable environment variables:
#     REF       reference rootfs   (default: compiler-test/ref-rootfs-gcc4.6-c-only)
#     TARBALL   release tarball    (default: edg-compiler-5.1.tar.gz)
#     PREDEF    predefined macros  (default: predefined_macros.txt)
#
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
REF=${REF:-$ROOT/compiler-test/ref-rootfs-gcc4.6-c-only}
TARBALL=${TARBALL:-$ROOT/edg-compiler-5.1.tar.gz}
PREDEF=${PREDEF:-$ROOT/predefined_macros.txt}
BUILD=$ROOT/build/edg5.1-gcc4.6c
TREE=$BUILD/edg-5.1
LOG=$BUILD/build.log

CC=$REF/usr/gcc4.6/bin/gcc

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

# ---------------------------------------------------------------- sanity ---

[ -d "$REF" ]     || die "reference rootfs not found: $REF"
[ -x "$CC" ]      || die "C compiler not found: $CC"
[ -f "$TARBALL" ] || die "release tarball not found: $TARBALL"
[ -s "$TARBALL" ] || die "release tarball is empty: $TARBALL"
[ -f "$PREDEF" ]  || die "predefined macro table not found: $PREDEF"
[ -s "$PREDEF" ]  || die "predefined macro table is empty: $PREDEF"

# The build directory is removed and recreated, so keep it strictly at
# <root>/build/edg5.1-gcc4.6c and never let it be the root itself.
[ "$BUILD" = "$ROOT/build/edg5.1-gcc4.6c" ] || \
  die "unexpected build directory: $BUILD"

# The compiler is a statically linked binary configured with a hard-coded
# sysroot, so it runs directly on the host.  Verify that it really is the
# 4.6 toolchain and that its sysroot points at the reference rootfs.
GCC_VERSION=$("$CC" -dumpversion)
case "$GCC_VERSION" in
  4.6*) ;;
  *) die "expected GCC 4.6.x, got '$GCC_VERSION'" ;;
esac
GCC_SYSROOT=$("$CC" -print-sysroot)
[ "$GCC_SYSROOT" = "$(cd "$REF" && pwd -P)" ] || \
  die "unexpected sysroot '$GCC_SYSROOT' (expected $REF)"
GCC_INC=$("$CC" -print-file-name=include)
[ -d "$GCC_INC" ] || die "compiler include directory not found: $GCC_INC"
# Archive the runtime library with the binutils that belong to the same
# reference rootfs; fall back to the host ar if that is unavailable.
AR=$REF/usr/binutils/bin/ar
[ -x "$AR" ] || AR=ar

TARBALL_SIZE=$(stat -c %s "$TARBALL")
TARBALL_SHA=$(sha256sum "$TARBALL" | cut -d' ' -f1)
PREDEF_SIZE=$(stat -c %s "$PREDEF")
PREDEF_SHA=$(sha256sum "$PREDEF" | cut -d' ' -f1)

info "host build with $CC"
info "cc version: $GCC_VERSION   sysroot: $GCC_SYSROOT"
info "source tarball: $TARBALL ($TARBALL_SIZE bytes, sha256 $TARBALL_SHA)"
info "predefined macros: $PREDEF ($PREDEF_SIZE bytes)"

# ------------------------------------------------------------ extract src ---

rm -rf "$BUILD"
mkdir -p "$TREE"

# GitHub release archives have a single top-level directory (compiler-5.1/),
# which --strip-components=1 removes so that the tree starts at <build>/edg-5.1.
info "extracting $TARBALL to $TREE"
tar -xzf "$TARBALL" -C "$TREE" --strip-components=1 || \
  die "extracting $TARBALL failed"
[ -f "$TREE/src/cfe.c" ] || die "unexpected source tree: $TREE/src/cfe.c missing"
[ -d "$TREE/lib_src" ]  || die "unexpected source tree: $TREE/lib_src missing"

cd "$TREE"

# ------------------------------------------------------ runtime resources ---
#
# The front end reads lib/predefined_macros.txt at start-up (relative to the
# EDG base directory, which defaults to the current directory).  The 5.1
# tarball does not contain the release lib/ directory, so the table is supplied
# next to the build script.

mkdir -p lib
cp "$PREDEF" lib/predefined_macros.txt
[ -e include ] || ln -s include_c++ include   # release-style C++ include dir

# --------------------------------------------------- error message tables ---
#
# The front end needs err_codes.h and err_data.h, generated from the textual
# error tables by the mk_errinfo helper (itself plain C).

info "building mk_errinfo"
mkdir -p build
# -Wl,-z,noexecstack silences ld's "crtn.o: missing .note.GNU-stack" warning,
# see the note at the edgcpfe link step below.
"$CC" -O2 -w -Wl,-z,noexecstack -I src -o build/mk_errinfo util/mk_errinfo.c \
  >>"$LOG" 2>&1 || die "building mk_errinfo failed (see $LOG)"

info "generating src/err_codes.h and src/err_data.h"
./build/mk_errinfo src/error_msg.txt src/error_tag.txt \
                   src/err_codes.h src/err_data.h >>"$LOG" 2>&1 || \
  die "running mk_errinfo failed (see $LOG)"
[ -s src/err_codes.h ] && [ -s src/err_data.h ] || \
  die "error message tables were not generated"

# ------------------------------------------------------- build front end ---
#
# All 63 sources are C.  GCC 4.6 defaults to -std=gnu89 which is exactly what
# the 5.1 sources expect; no C++ compiler and no C++ front end are involved.

info "compiling $(ls src/*.c | wc -l | tr -d ' ') C sources with GCC $GCC_VERSION"
mkdir -p build/obj
(
  cd build/obj
  "$CC" -O2 -w -I ../../src -c ../../src/*.c
) >>"$LOG" 2>&1 || die "compiling the front end failed (see $LOG)"

info "linking edgcpfe"
# -Wl,-z,noexecstack also silences the "crtn.o: missing .note.GNU-stack"
# warning that the reference rootfs' musl crt objects trigger with ld 2.44.
"$CC" -O2 -w -o build/edgcpfe build/obj/*.o -Wl,-z,noexecstack \
  >>"$LOG" 2>&1 || die "linking edgcpfe failed (see $LOG)"
[ -x build/edgcpfe ] || die "edgcpfe was not produced"

# ------------------------------------------- build EDG runtime library ---
#
# lib_src/ is the C++ runtime support library (operator new/delete, RTTI,
# exception handling, static initialization, ...).  The release builds it with
# the front end itself: every C++ source is translated to C and that C is
# compiled by the native compiler.  --building_runtime passes the front end's
# ABI configuration to the runtime via predefined macros; the runtime requires
# at least C++14.  --g++ selects EDG's GNU C++ emulation, which the musl
# headers need (they use the GNU extension __builtin_va_list).

info "building EDG runtime library from lib_src"
mkdir -p build/rt/obj
RT_INCLUDES=(--sys_include="$TREE/include_c++" \
             --sys_include="$REF/usr/include" \
             --sys_include="$GCC_INC")
RT_COUNT=0
for src in lib_src/*.c; do
  [ -f "$src" ] || die "no runtime sources found in lib_src"
  base=$(basename "$src" .c)
  ./build/edgcpfe --c++14 --g++ --building_runtime "${RT_INCLUDES[@]}" \
    --gen_c_file_name="build/rt/$base.int.c" "$src" >>"$LOG" 2>&1 || \
    die "EDG 5.1 failed to translate $src (see $LOG)"
  "$CC" -O2 -w -c "build/rt/$base.int.c" -o "build/rt/obj/$base.o" \
    >>"$LOG" 2>&1 || die "GCC $GCC_VERSION failed to compile $base.int.c (see $LOG)"
  RT_COUNT=$((RT_COUNT + 1))
done
"$AR" rcs lib/libC.a build/rt/obj/*.o >>"$LOG" 2>&1 || \
  die "creating lib/libC.a failed (see $LOG)"
[ -s lib/libC.a ] || die "lib/libC.a was not produced"
RT_AR_COUNT=$("$AR" t lib/libC.a | wc -l | tr -d ' ')
info "libC.a: $RT_COUNT runtime sources -> $RT_AR_COUNT objects, $(stat -c %s lib/libC.a) bytes"

# --------------------------------------------------------------- checks ---

info "smoke test: version"
# The front end writes --version output to stderr.
VERSION_OUT=$(./build/edgcpfe --version 2>&1)
printf '%s\n' "$VERSION_OUT" | grep -q 'version 5\.1' || \
  die "unexpected version output: $VERSION_OUT"

# The front end in C mode: point it at the musl headers that ship with the
# same reference rootfs.  GNU emulation (--gcc) is required because musl's
# <bits/alltypes.h> uses the GNU extension __builtin_va_list, which EDG 5.1
# only accepts in GNU mode.  The generated C is then compiled by the very same
# GCC 4.6 + musl toolchain, so no host header or library is involved.
C_INCLUDES=(--gcc --sys_include="$REF/usr/include")

info "smoke test: translate and run a self-contained C program"
cat > build/test_basic.c <<'EOF'
int add(int a, int b) { return a + b; }
int main(void) { return add(20, 22) == 42 ? 0 : 1; }
EOF
./build/edgcpfe --c99 "${C_INCLUDES[@]}" \
  --gen_c_file_name=build/test_basic.int.c build/test_basic.c \
  >>"$LOG" 2>&1 || die "EDG 5.1 failed to translate build/test_basic.c"
"$CC" -O2 -w -Wl,-z,noexecstack \
  -o build/test_basic.out build/test_basic.int.c >>"$LOG" 2>&1 || \
  die "GCC $GCC_VERSION failed to compile build/test_basic.int.c"
./build/test_basic.out || die "generated test_basic.out failed at run time"

if [ -f "$ROOT/try/b.c" ]; then
  info "smoke test: translate $ROOT/try/b.c, compile, run"
  ./build/edgcpfe --c99 "${C_INCLUDES[@]}" \
    --gen_c_file_name=build/b.int.c "$ROOT/try/b.c" >>"$LOG" 2>&1 || \
    die "EDG 5.1 failed to translate try/b.c"
  "$CC" -O2 -w -Wl,-z,noexecstack \
    -o build/b.out build/b.int.c >>"$LOG" 2>&1 || \
    die "GCC $GCC_VERSION failed to compile the generated b.c"
  B_OUT=$(./build/b.out) || die "generated b.out failed at run time"
  [ "$B_OUT" = "Hello World" ] || die "unexpected try/b.c output: '$B_OUT'"
fi

# --------------------------------------- smoke tests for the C++ runtime ---
#
# With lib/libC.a in place, C++ programs can be translated to C, compiled by
# GCC 4.6 and linked against the EDG runtime.  -tused makes the front end
# instantiate the used templates in the generated C file (this build has no
# prelinker step).

info "smoke test: C++17 program + EDG runtime library"
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
  die "EDG 5.1 failed to translate build/test_cxx.cpp (see $LOG)"
"$CC" -O2 -w -Wl,-z,noexecstack -o build/test_cxx.out \
  build/test_cxx.int.c -Llib -lC >>"$LOG" 2>&1 || \
  die "linking build/test_cxx.out against libC.a failed (see $LOG)"
./build/test_cxx.out || die "generated test_cxx.out failed at run time"

info "smoke test: C++ exceptions through the EDG runtime"
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
  die "EDG 5.1 failed to translate build/test_eh.cpp (see $LOG)"
"$CC" -O2 -w -Wl,-z,noexecstack -o build/test_eh.out \
  build/test_eh.int.c -Llib -lC >>"$LOG" 2>&1 || \
  die "linking build/test_eh.out against libC.a failed (see $LOG)"
./build/test_eh.out || die "generated test_eh.out failed at run time"

# --------------------------------------------------------------- summary ---

{
  printf 'EDG front end 5.1 (tarball build)\n'
  printf 'source tarball: %s\n' "$TARBALL"
  printf 'tarball size  : %s bytes\n' "$TARBALL_SIZE"
  printf 'tarball sha256: %s\n' "$TARBALL_SHA"
  printf 'predefined    : %s (%s bytes, sha256 %s)\n' \
         "$PREDEF" "$PREDEF_SIZE" "$PREDEF_SHA"
  printf 'build compiler: %s %s\n' "$CC" "$GCC_VERSION"
  printf 'sysroot       : %s\n' "$GCC_SYSROOT"
  printf 'executable    : %s\n' "$TREE/build/edgcpfe"
  printf 'size          : %s bytes\n' "$(stat -c %s build/edgcpfe)"
  printf 'runtime lib   : %s\n' "$TREE/lib/libC.a"
  printf 'runtime objs  : %s (%s bytes)\n' \
         "$RT_AR_COUNT" "$(stat -c %s lib/libC.a)"
} > build/build-info.txt

info "done"
printf '%s\n' "$VERSION_OUT" | head -2
printf '\n'
printf 'executable  : %s\n' "$TREE/build/edgcpfe"
printf 'size        : %s bytes\n' "$(stat -c %s build/edgcpfe)"
printf 'runtime lib : %s\n' "$TREE/lib/libC.a"
printf 'size        : %s bytes (%s objects)\n' \
       "$(stat -c %s lib/libC.a)" "$RT_AR_COUNT"
printf 'build log   : %s\n' "$LOG"
printf 'build info  : %s\n' "$TREE/build/build-info.txt"
printf 'tests       : %s\n' "$(ls build/*.out 2>/dev/null | tr '\n' ' ')"
