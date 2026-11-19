#!/usr/bin/env bash
#
# Stage 3b of the bootstrap chain: rebuild LLVM/Clang 3.9.0 with the clang
# built by ./refhost-llvm3.9.x-1.sh, in a bubblewrap sandbox that contains NO host
# C or C++ compiler at all.
#
# The compiler used for both C and C++ is <rootfs>/opt/llvm3.9/bin/clang(++),
# i.e. the LLVM/clang produced by stage 3a.  libc++ 3.9 (used as the C++
# standard library for LLVM 3.9 because 3.9's own <atomic> is clang-only) is
# rebuilt first with that compiler, and the second LLVM/clang is linked against
# the freshly built libc++ (falling back to the stage-1 libC for the __cxa/
# typeinfo entry points supplied by EDG's runtime, which are ABI compatible).
#
# The host is used only for:
#   * binutils' ld (the linker driver; as/ar/ranlib are host tools too),
#   * the build tools make/cmake/python3 and coreutils,
#   * the shared libraries those tools need to start.
# No host gcc, g++, cc1, libgcc, header or C++ library is visible.
#
# Inputs:
#     ${ROOTFS:-rootfs-hostgcc}/         rootfs with the stage-3a toolchain
#     <stage-3a>/src/llvm                LLVM 3.9.0 source
#     <stage-3a>/src/libcxx            libc++ 3.9 source used as the stdlib
#
# Output (all inside the rootfs):
#     <rootfs>/build/llvm3.9-bootstrap/libcxx/libc++.a
#     <rootfs>/build/llvm3.9-bootstrap/build/stage2/      LLVM build tree
#     <rootfs>/opt/llvm3.9-bootstrap/                     self-hosted clang + libc++
#     <rootfs>/build/llvm3.9-bootstrap/build-info.txt
#
# Directory selection (all paths are inside the rootfs; a leading "/" is
# optional, so "build/llvm3.9" and "/build/llvm3.9" mean the same thing):
#     ROOTFS          rootfs containing the whole chain   (default rootfs-hostgcc)
#     STAGE1_PREFIX   stage-3a install prefix             (default /opt/llvm3.9)
#     STAGE1_BUILD    stage-3a build tree                 (default build/llvm3.9)
#     SRC_DIR         LLVM 3.9.0 source tree              (default $STAGE1_BUILD/src)
#     BUILD_DIR       this stage's build tree             (default build/llvm3.9-bootstrap)
#     PREFIX          this stage's install prefix         (default /opt/llvm3.9-bootstrap)
#
# Usage:
#     ./refhost-llvm3.9.x-bootstrap.sh
#     JOBS=16 ./refhost-llvm3.9.x-bootstrap.sh
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
[ -d "$ROOTFS" ] || die "rootfs not found: $ROOTFS"
ROOTFS=$(cd "$ROOTFS" && pwd -P)
case "$ROOTFS" in
  "$ROOT"/*) ;;
  *) die "ROOTFS must be a directory inside $ROOT: $ROOTFS" ;;
esac

JOBS=${JOBS:-16}
[ "$JOBS" -ge 1 ] 2>/dev/null || JOBS=1

# Normalise a directory name to a path inside the rootfs.
in_rootfs() {
  local p=$1
  case "$p" in
    "$ROOTFS"|"$ROOTFS"/*) p=${p#"$ROOTFS"} ;;
  esac
  case "$p" in
    "") p=/ ;;
    /*) ;;
    *) p=/$p ;;
  esac
  case "$p" in
    /) ;;
    */) p=${p%/} ;;
  esac
  printf '%s' "$p"
}

STAGE1_PREFIX=$(in_rootfs "${STAGE1_PREFIX:-/opt/llvm3.9}")
PREFIX=$(in_rootfs "${PREFIX:-/opt/llvm3.9-bootstrap}")
STAGE1_BUILD=$(in_rootfs "${STAGE1_BUILD:-build/llvm3.9}")
SRC_IN=$(in_rootfs "${SRC_DIR:-$STAGE1_BUILD/src}")
BUILD_IN=$(in_rootfs "${BUILD_DIR:-build/llvm3.9-bootstrap}")
BUILD=$ROOTFS$BUILD_IN
SRC=$ROOTFS$SRC_IN
if [ "${STAGE3_HOST_LD:-0}" = 1 ]; then LINKER=/usr/bin/ld; LINKER_FUSE=; else LINKER=$STAGE1_PREFIX/bin/ld.lld; LINKER_FUSE=-fuse-ld=lld; fi
if [ "${USE_STAGE1_LIBCXX:-0}" = 1 ]; then LIBCXX_DIR=$STAGE1_PREFIX; else LIBCXX_DIR=$PREFIX; fi
LOG=$BUILD/log

command -v bwrap >/dev/null 2>&1 || die "bwrap (bubblewrap) not found"
BWRAP=$(command -v bwrap)

# ---------------------------------------------------------------- inputs ---

[ -x "$ROOTFS$STAGE1_PREFIX/bin/clang" ] || \
  die "stage-1 clang not found: $ROOTFS$STAGE1_PREFIX/bin/clang (run ./refhost-llvm3.9.x-1.sh first)"
[ -x "$ROOTFS$STAGE1_PREFIX/bin/clang++" ] || die "stage-1 clang++ not found"
[ -s "$ROOTFS$STAGE1_PREFIX/lib/libc++.a" ] || die "stage-1 libc++.a not found"
[ -d "$ROOTFS$STAGE1_PREFIX/include/c++/v1" ] || die "stage-1 libc++ headers not found"
[ -s "$ROOTFS$STAGE1_PREFIX/lib/libC.a" ] || die "stage-1 EDG libC.a not found"
[ -s "$ROOTFS$STAGE1_PREFIX/lib/dso_handle.o" ] || die "stage-1 dso_handle.o not found"
[ -d "$SRC/llvm" ] || die "LLVM source not found: $SRC (run ./refhost-llvm3.9.x-1.sh first)"
[ -d "$SRC/clang" ] || die "clang source not found: $SRC/clang"
[ -d "$SRC/libcxx/src" ] || die "libc++ 3.9 source not found: $SRC/libcxx/src"

# ---------------------------------------------------- 3.9 patches ---
# All 3.9 source patches live under edg-support/llvm-3.9; stage-1 applied
# them, and apply.sh is idempotent so this stage can safely re-check them.
[ -x "$ROOT/edg-support/llvm-3.9/apply.sh" ] || \
  die "missing $ROOT/edg-support/llvm-3.9/apply.sh"
"$ROOT/edg-support/llvm-3.9/apply.sh" "$SRC" >/dev/null || \
  die "applying 3.9 patches failed"

CLANG_VER=$("$ROOTFS$STAGE1_PREFIX/bin/clang" --version 2>/dev/null | head -n1 || true)
case "$CLANG_VER" in
  *"clang version 3.9"*) ;;
  *) die "unexpected stage-1 clang: $CLANG_VER" ;;
esac
CLANG_VER_NUM=$("$ROOTFS$STAGE1_PREFIX/bin/clang" --version 2>/dev/null | sed -n 's/.*clang version \([0-9][0-9.]*\).*/\1/p' | head -n1)
[ -n "$CLANG_VER_NUM" ] || CLANG_VER_NUM=3.9.0
LIBRT_DIR=$STAGE1_PREFIX/lib/clang/$CLANG_VER_NUM/lib/linux
[ -s "$ROOTFS$LIBRT_DIR/libclang_rt.builtins-x86_64.a" ] || \
  die "stage-1 compiler-rt builtins not found: $ROOTFS$LIBRT_DIR"
for t in lld ld.lld llvm-ar llvm-ranlib llvm-nm llvm-readobj; do
  [ -x "$ROOTFS$STAGE1_PREFIX/bin/$t" ] || \
    die "stage-1 tool $t not found (run ./refhost-llvm3.9.x-2.sh first)"
done

info "stage-1 clang : $CLANG_VER"
info "rootfs        : $ROOTFS"
info "stage-1 prefix: $ROOTFS$STAGE1_PREFIX"
info "stage-1 build : $ROOTFS$STAGE1_BUILD"
info "source tree   : $SRC"
info "libc++ source : $SRC/libcxx"
info "bootstrap to  : $ROOTFS$PREFIX"
info "build tree    : $BUILD"
info "jobs          : $JOBS"

START=$(date +%s)
START_UTC=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
mkdir -p "$BUILD/tools" "$BUILD/tmp" "$LOG"

# --------------------------------------------------- sandbox environment ---
#
# Everything here is seen from inside the rootfs mounted at /.

cat > "$BUILD/tools/toolchain.cmake" <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER $STAGE1_PREFIX/bin/clang)
set(CMAKE_CXX_COMPILER $STAGE1_PREFIX/bin/clang++)
set(CMAKE_ASM_COMPILER $STAGE1_PREFIX/bin/clang)
set(CMAKE_AR $STAGE1_PREFIX/bin/llvm-ar)
set(CMAKE_RANLIB $STAGE1_PREFIX/bin/llvm-ranlib)
set(CMAKE_NM $STAGE1_PREFIX/bin/llvm-nm)
set(CMAKE_LINKER $LINKER)
set(CMAKE_C_FLAGS_INIT "--sysroot=/ -static -O0 -fno-pie -rtlib=compiler-rt -B$STAGE1_PREFIX/bin -Ufopen64 -Ufreopen64 -Ufseeko64 -Uftello64 -Utmpfile64 -Ufgetpos64 -Ufsetpos64 -Ufstat64 -Ufstatvfs64 -Ulstat64 -Uopen64 -Ustat64 -Ustatvfs64 -D_GNU_SOURCE=1")
set(CMAKE_CXX_FLAGS_INIT "--sysroot=/ -static -O0 -fno-pie -rtlib=compiler-rt -nostdinc++ -isystem $PREFIX/include/c++/v1 -stdlib=libc++ -fno-exceptions -fuse-init-array -D_LIBCPP_NO_EXCEPTIONS=1 -D_LIBCPP_NO_RTTI=1 -D_LIBCPP_BUILD_STATIC=1 -D_LIBCPP_HAS_MUSL_LIBC=1 -Ufopen64 -Ufreopen64 -Ufseeko64 -Uftello64 -Utmpfile64 -Ufgetpos64 -Ufsetpos64 -Ufstat64 -Ufstatvfs64 -Ulstat64 -Uopen64 -Ustat64 -Ustatvfs64 -D_GNU_SOURCE=1")
set(CMAKE_EXE_LINKER_FLAGS_INIT "$LINKER_FUSE -nostartfiles /usr/lib/crt1.o /usr/lib/crti.o /usr/lib/crtn.o $STAGE1_PREFIX/lib/dso_handle.o -nodefaultlibs -Wl,--allow-multiple-definition")
set(CMAKE_C_STANDARD_LIBRARIES "-L/usr/lib -L$LIBRT_DIR -Wl,--start-group -lc -lm -lpthread -lclang_rt.builtins-x86_64 -Wl,--end-group")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "$LINKER_FUSE -L/usr/lib -Wl,--allow-multiple-definition")
set(CMAKE_CXX_STANDARD_LIBRARIES "-L$LIBCXX_DIR/lib -L$STAGE1_PREFIX/lib -L/usr/lib -L$LIBRT_DIR -Wl,--start-group -lc++ -lC -lc -lm -lpthread -lclang_rt.builtins-x86_64 -Wl,--end-group")
set(CMAKE_CROSSCOMPILING FALSE)
set(PYTHON_EXECUTABLE /usr/bin/python3)
EOF

# ------------------------------------------------------------- inner script ---

cat > "$BUILD/tools/inner-build.sh" <<'INNER_EOF'
#!/bin/bash
set -euo pipefail
info() { printf '==> %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

BUILD=@BUILD_IN@
SRC=@SRC_IN@
STAGE1_PREFIX=@STAGE1_PREFIX@
STAGE1_BUILD=@STAGE1_BUILD@
PREFIX=@PREFIX@
LIBCXX_DIR=@LIBCXX_DIR@
JOBS=@JOBS@
CLANG_VER=@CLANG_VER@
CLANG=$STAGE1_PREFIX/bin/clang
CLANGXX=$STAGE1_PREFIX/bin/clang++
LIBRT_DIR=$STAGE1_PREFIX/lib/clang/$CLANG_VER/lib/linux
LOG=$BUILD/log
export TMPDIR=/tmp
export PATH="$STAGE1_PREFIX/bin:/usr/bin:/bin"

# ------------------------------------------------------------- libc++ ---
#
# Rebuild libc++ 3.9 with clang itself.  Exceptions stay off, matching how
# LLVM 3.9 is built.  The headers are the source libc++ 3.9 headers.

info "rebuilding libc++ 3.9 with clang"
mkdir -p "$BUILD/libcxx/gen" "$BUILD/libcxx/obj" "$PREFIX/lib"
rm -f "$BUILD/libcxx/obj"/*.o "$BUILD/libcxx/libc++.a"
libcxx_fail=0
for src in "$SRC"/libcxx/src/*.cpp; do
  b=$(basename "$src" .cpp)
  if ! "$CLANGXX" -fuse-init-array --sysroot=/ -static -O1 -std=c++11 -stdlib=libc++ \
        -nostdinc++ -isystem "$SRC/libcxx/include" \
        -rtlib=compiler-rt -D_LIBCPP_NO_EXCEPTIONS=1 -D_LIBCPP_NO_RTTI=1 -D_LIBCPP_BUILD_STATIC=1 \
        -D_LIBCPP_HAS_MUSL_LIBC=1 -D_LIBCPP_BUILDING_LIBRARY=1 \
        -Ufopen64 -Ufreopen64 -Ufseeko64 -Uftello64 -Utmpfile64 -Ufgetpos64 -Ufsetpos64 -Ufstat64 -Ufstatvfs64 -Ulstat64 -Uopen64 -Ustat64 -Ustatvfs64 -D_GNU_SOURCE=1 \
        -fno-exceptions -I "$SRC/libcxx/src" \
        -c "$src" -o "$BUILD/libcxx/obj/$b.o" \
        > "$LOG/libcxx-$b.log" 2>&1; then
    printf 'FAIL compile %s (see %s)\n' "$b.cpp" "$LOG/libcxx-$b.log" >&2
    tail -n 4 "$LOG/libcxx-$b.log" >&2 || true
    libcxx_fail=$((libcxx_fail + 1))
  fi
done
[ "$libcxx_fail" -eq 0 ] || die "$libcxx_fail libc++ sources failed with clang"
"$STAGE1_PREFIX/bin/llvm-ar" rcs "$BUILD/libcxx/libc++.a" "$BUILD/libcxx/obj"/*.o
[ -s "$BUILD/libcxx/libc++.a" ] || die "stage-2 libc++.a was not produced"
cp "$BUILD/libcxx/libc++.a" "$PREFIX/lib/libc++.a"

# smoke test with the freshly built libc++
cat > "$BUILD/libcxx/smoke.cpp" <<'EOF'
#include <atomic>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>
#include <algorithm>
int main() {
  std::vector<int> v{3, 1, 2};
  std::sort(v.begin(), v.end());
  std::string s = "stage2 libc++";
  auto p = std::make_shared<int>(42);
  std::atomic<int> a(0);
  a.fetch_add(1);
  std::printf("%s %d %d %d\n", s.c_str(), v[0], *p, a.load());
  return (v[0] == 1 && *p == 42 && a.load() == 1) ? 0 : 1;
}
EOF
"$CLANGXX" -fuse-init-array -fuse-ld=lld --sysroot=/ -static -O1 -std=c++11 -stdlib=libc++ -rtlib=compiler-rt \
  -nostdinc++ -isystem "$SRC/libcxx/include" \
  -D_LIBCPP_NO_EXCEPTIONS=1 -D_LIBCPP_NO_RTTI=1 -D_LIBCPP_BUILD_STATIC=1 -D_LIBCPP_HAS_MUSL_LIBC=1 -Ufopen64 -Ufreopen64 -Ufseeko64 -Uftello64 -Utmpfile64 -Ufgetpos64 -Ufsetpos64 -Ufstat64 -Ufstatvfs64 -Ulstat64 -Uopen64 -Ustat64 -Ustatvfs64 -D_GNU_SOURCE=1 -fno-exceptions \
  -o "$BUILD/libcxx/smoke" "$BUILD/libcxx/smoke.cpp" \
  -nostartfiles /usr/lib/crt1.o /usr/lib/crti.o /usr/lib/crtn.o \
  "$STAGE1_PREFIX/lib/dso_handle.o" -nodefaultlibs \
  -L"$BUILD/libcxx" -L"$STAGE1_PREFIX/lib" -L/usr/lib -L"$LIBRT_DIR" \
  -Wl,--start-group -lc++ -lC -lc -lm -lpthread -lclang_rt.builtins-x86_64 \
  -Wl,--end-group -Wl,--allow-multiple-definition > "$LOG/libcxx-smoke.log" 2>&1 || {
    tail -n 20 "$LOG/libcxx-smoke.log" >&2
    die "linking the stage-2 libc++ smoke test failed"
  }
SMOKE_OUT=$("$BUILD/libcxx/smoke") || die "the stage-2 libc++ smoke test failed"
info "libc++ smoke test: $SMOKE_OUT"

# --------------------------------------------------------------- cmake ---

mkdir -p "$PREFIX/include/c++/v1"
cp -a "$SRC/libcxx/include/." "$PREFIX/include/c++/v1/"

info "configuring the self-hosted LLVM 3.9.0 + clang"
BD=$BUILD/build/stage2
if [ "${REUSE_BUILD:-0}" = 1 ] && [ -f "$BD/CMakeCache.txt" ]; then
  info "reusing existing build tree $BD"
else
  rm -rf "$BD"
fi
CMAKE_POLICY_VERSION_MINIMUM=3.5 cmake -G "Unix Makefiles" \
  -S "$SRC/llvm" -B "$BD" \
  -DCMAKE_TOOLCHAIN_FILE="$BUILD/tools/toolchain.cmake" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DLLVM_TABLEGEN="$STAGE1_BUILD/build/stage1/bin/llvm-tblgen" \
  -DCLANG_TABLEGEN="$STAGE1_BUILD/build/stage1/bin/clang-tblgen" \
  -DLLVM_TARGETS_TO_BUILD=X86 \
  -DLLVM_EXTERNAL_CLANG_SOURCE_DIR="$SRC/clang" \
  -DLLVM_EXTERNAL_CLANG_BUILD=ON \
  -DLLVM_EXTERNAL_LLD_SOURCE_DIR="$SRC/lld" \
  -DLLVM_EXTERNAL_LLD_BUILD=ON \
  -DLLVM_INCLUDE_TOOLS=ON -DLLVM_BUILD_TOOLS=OFF \
  -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_INCLUDE_DOCS=OFF -DLLVM_INCLUDE_UTILS=ON \
  -DLLVM_BUILD_TOOLS=OFF -DLLVM_BUILD_EXAMPLES=OFF \
  -DLLVM_BUILD_RUNTIME=OFF \
  -DCLANG_BUILD_TOOLS=OFF \
  -DCLANG_ENABLE_ARCMT=OFF -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
  -DCLANG_BUILD_EXAMPLES=OFF -DCLANG_INCLUDE_TESTS=OFF \
  -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_ZLIB=OFF \
  -DLLVM_ENABLE_LIBXML2=OFF \
  -DLLVM_ENABLE_FFI=OFF \
  -DLLVM_ENABLE_ASSERTIONS=OFF -DLLVM_APPEND_VC_REV=OFF \
  -DLLVM_BUILD_EXTERNAL_COMPILER_RT=OFF \
  -DHAVE_CXXABI_H=0 \
  -DCMAKE_BUILD_TYPE=Release \
  > "$LOG/cmake-configure.log" 2>&1 || {
    tail -n 40 "$LOG/cmake-configure.log" >&2
    die "cmake configure failed with the stage-1 clang (see $LOG/cmake-configure.log)"
  }

if [ "${REUSE_BUILD:-0}" = 1 ]; then rm -f "$BD/bin/clang" "$BD/bin/clang-3.9" "$BD/bin/lld"; fi
info "building the self-hosted clang + lld targets with $JOBS jobs"
if ! cmake --build "$BD" --target clang lld -- -j"$JOBS" > "$LOG/cmake-build.log" 2>&1; then
  grep -n -m8 -B2 -A8 'error:' "$LOG/cmake-build.log" >&2 || true
  tail -n 30 "$LOG/cmake-build.log" >&2
  die "self-hosted clang/lld build failed (see $LOG/cmake-build.log)"
fi

# ------------------------------------------------------------ install ---

info "installing the self-hosted clang into $PREFIX (manual)"
mkdir -p "$PREFIX/bin" "$PREFIX/lib/clang/$CLANG_VER/include" \
         "$PREFIX/include/c++/v1" "$PREFIX/lib"
cp "$BD/bin/clang" "$PREFIX/bin/clang"
ln -sf clang "$PREFIX/bin/clang++"
cp -a "$SRC/clang/lib/Headers/." "$PREFIX/lib/clang/$CLANG_VER/include/"
cp -a "$SRC/libcxx/include/." "$PREFIX/include/c++/v1/"
cp "$BUILD/libcxx/libc++.a" "$PREFIX/lib/libc++.a"
cp "$STAGE1_PREFIX/lib/libC.a" "$PREFIX/lib/libC.a"
cp "$STAGE1_PREFIX/lib/libc++abi.a" "$PREFIX/lib/libc++abi.a" 2>/dev/null || true
cp "$STAGE1_PREFIX/lib/dso_handle.o" "$PREFIX/lib/dso_handle.o"
mkdir -p "$PREFIX/lib/clang/$CLANG_VER/lib/linux"
cp "$STAGE1_PREFIX/lib/clang/$CLANG_VER/lib/linux/"*.a \
   "$PREFIX/lib/clang/$CLANG_VER/lib/linux/" 2>/dev/null || true
cp "$BD/bin/lld" "$PREFIX/bin/lld"
ln -sf lld "$PREFIX/bin/ld.lld"
ln -sf lld "$PREFIX/bin/lld-link"
for t in llvm-ar llvm-ranlib llvm-nm llvm-readobj; do
  if [ -e "$BD/bin/$t" ]; then cp -a "$BD/bin/$t" "$PREFIX/bin/$t"
  elif [ -e "$STAGE1_PREFIX/bin/$t" ]; then cp -a "$STAGE1_PREFIX/bin/$t" "$PREFIX/bin/$t"; fi
done
[ -x "$PREFIX/bin/clang" ] || die "the self-hosted clang was not installed"
[ -x "$PREFIX/bin/lld" ] || die "the self-hosted lld was not installed"

# ------------------------------------------------------------- checks ---

info "check: self-hosted clang runs"
"$PREFIX/bin/clang" --version > "$LOG/clang-version.txt" 2>&1 || \
  die "self-hosted clang --version failed"
grep -q 'clang version 3\.9' "$LOG/clang-version.txt" || \
  die "unexpected self-hosted clang: $(cat "$LOG/clang-version.txt")"

info "check: self-hosted clang compiles and links C and C++ by itself"
cat > "$BUILD/check.c" <<'EOF'
#include <stdio.h>
int main(void) { printf("stage2 C ok\n"); return 0; }
EOF
cat > "$BUILD/check.cpp" <<'EOF'
#include <cstdio>
#include <string>
#include <vector>
#include <algorithm>
int main() {
  std::vector<int> v{3, 1, 2};
  std::sort(v.begin(), v.end());
  std::string s = "stage2 C++ ok";
  std::printf("%s %d\n", s.c_str(), v[0]);
  return 0;
}
EOF
"$PREFIX/bin/clang" -fuse-ld=lld --sysroot=/ -static -O1 -fno-pie \
  -nostartfiles /usr/lib/crt1.o /usr/lib/crti.o /usr/lib/crtn.o \
  "$PREFIX/lib/dso_handle.o" -nodefaultlibs \
  -o "$BUILD/check-c" "$BUILD/check.c" \
  -L/usr/lib -L"$PREFIX/lib/clang/$CLANG_VER/lib/linux" \
  -Wl,--start-group -lc -lm -lpthread -lclang_rt.builtins-x86_64 -Wl,--end-group \
  -Wl,--allow-multiple-definition \
  > "$LOG/check-c.log" 2>&1 || die "self-hosted clang failed to build C"
"$PREFIX/bin/clang++" -fuse-init-array -fuse-ld=lld --sysroot=/ -static -O1 -fno-pie -std=c++11 -stdlib=libc++ \
  -nostdinc++ -isystem "$PREFIX/include/c++/v1" \
  -D_LIBCPP_NO_EXCEPTIONS=1 -D_LIBCPP_NO_RTTI=1 -D_LIBCPP_BUILD_STATIC=1 -D_LIBCPP_HAS_MUSL_LIBC=1 \
  -Ufopen64 -Ufreopen64 -Ufseeko64 -Uftello64 -Utmpfile64 -Ufgetpos64 -Ufsetpos64 -Ufstat64 -Ufstatvfs64 -Ulstat64 -Uopen64 -Ustat64 -Ustatvfs64 -D_GNU_SOURCE=1 -fno-exceptions \
  -nostartfiles /usr/lib/crt1.o /usr/lib/crti.o /usr/lib/crtn.o \
  "$PREFIX/lib/dso_handle.o" -nodefaultlibs \
  -o "$BUILD/check-cxx" "$BUILD/check.cpp" \
  -L"$LIBCXX_DIR/lib" -L/usr/lib -L"$PREFIX/lib/clang/$CLANG_VER/lib/linux" \
  -Wl,--start-group -lc++ -lC -lc -lm -lpthread -lclang_rt.builtins-x86_64 -Wl,--end-group \
  -Wl,--allow-multiple-definition \
  > "$LOG/check-cxx.log" 2>&1 || die "self-hosted clang++ failed to build C++"
[ "$("$BUILD/check-c")" = "stage2 C ok" ] || die "self-hosted C binary failed"
[ "$("$BUILD/check-cxx")" = "stage2 C++ ok 1" ] || die "self-hosted C++ binary failed"

info "check: self-hosted lld links a program"
"$PREFIX/bin/clang" -fuse-ld=lld --sysroot=/ -static -O1 -fno-pie \
  -nostartfiles /usr/lib/crt1.o /usr/lib/crti.o /usr/lib/crtn.o \
  "$PREFIX/lib/dso_handle.o" -nodefaultlibs \
  -o "$BUILD/check-lld" "$BUILD/check.c" \
  -L/usr/lib -L"$PREFIX/lib/clang/$CLANG_VER/lib/linux" \
  -Wl,--start-group -lc -lm -lpthread -lclang_rt.builtins-x86_64 -Wl,--end-group \
  -Wl,--allow-multiple-definition > "$LOG/check-lld.log" 2>&1 || die "self-hosted lld failed to link C"
[ "$("$BUILD/check-lld")" = "stage2 C ok" ] || die "self-hosted lld binary failed"
"$PREFIX/bin/ld.lld" --version > "$LOG/lld-version.txt" 2>&1 || die "self-hosted lld --version failed"

info "check: self-hosted binaries are static and glibc-free"
for exe in "$PREFIX/bin/clang" "$BUILD/check-c" "$BUILD/check-cxx"; do
  if "$STAGE1_PREFIX/bin/llvm-readobj" --program-headers "$exe" | grep -q "INTERP"; then die "$exe is dynamically linked"; fi
  if "$STAGE1_PREFIX/bin/llvm-nm" "$exe" | grep -q 'GLIBC_'; then die "$exe carries GLIBC symbols"; fi
done

# ------------------------------------------------------------- summary ---

{
  printf 'LLVM/Clang 3.9.1 rebuilt by the stage-1 LLVM/clang %s + musl/libc++ 3.9 + lld 3.9\n' "$CLANG_VER"
  printf 'date (UTC)      : %s\n' @START_UTC@
  printf 'stage-1 clang   : %s\n' "@CLANG_VER@"
  printf 'self-hosted     : %s\n' "$("$PREFIX/bin/clang" --version | head -n1)"
  printf 'libc++ (clang)  : %s bytes\n' "$(stat -c %s "$BUILD/libcxx/libc++.a")"
  printf 'host tools      : no host compiler and no host binutils in the sandbox\n'
  printf 'libc++ smoke    : %s\n' "$SMOKE_OUT"
  printf 'jobs            : %s\n' "$JOBS"
} > "$BUILD/build-info.txt"
INNER_EOF

sed -i \
  -e "s|@BUILD_IN@|$BUILD_IN|g" \
  -e "s|@SRC_IN@|$SRC_IN|g" \
  -e "s|@STAGE1_PREFIX@|$STAGE1_PREFIX|g" \
  -e "s|@STAGE1_BUILD@|$STAGE1_BUILD|g" \
  -e "s|@PREFIX@|$PREFIX|g" \
  -e "s|@LIBCXX_DIR@|$LIBCXX_DIR|g" \
  -e "s|@JOBS@|$JOBS|g" \
  -e "s|@CLANG_VER@|$CLANG_VER_NUM|g" \
  -e "s|@START_UTC@|$START_UTC|g" \
  "$BUILD/tools/inner-build.sh"
chmod +x "$BUILD/tools/inner-build.sh"

# ------------------------------------------------------------ sandbox ---
#
# Deliberately *no* /usr/bin/gcc, /usr/lib/gcc, /usr/libexec/gcc, cc1, libgcc
# or host headers.  The only host binaries are the ones listed below: the
# linker (ld) plus the build tools, and their shared-library runtime.

BWRAP_ARGS=(
  --die-with-parent
  --unshare-all
  --bind "$ROOTFS" /
  --proc /proc
  --dev /dev
  --bind "$BUILD/tmp" /tmp
  --ro-bind /usr/lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu
  --ro-bind /usr/lib64/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
  --ro-bind /etc/ld.so.cache /etc/ld.so.cache
)

for d in /usr/share/cmake-*; do
  [ -d "$d" ] && BWRAP_ARGS+=(--ro-bind "$d" "$d")
done
PY_STDLIB=$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["stdlib"])' 2>/dev/null || true)
if [ -n "$PY_STDLIB" ] && [ -d "$PY_STDLIB" ]; then
  BWRAP_ARGS+=(--ro-bind "$PY_STDLIB" "$PY_STDLIB")
fi

declare -A BOUND_TOOL=()
add_tool() {
  local p=$1 real
  [ -n "${BOUND_TOOL[$p]:-}" ] && return 0
  BOUND_TOOL[$p]=1
  [ -e "$p" ] || die "sandbox whitelist: $p does not exist"
  real=$(readlink -f "$p")
  BWRAP_ARGS+=(--ro-bind "$real" "$p")
}
add_tool_opt() { [ -e "$1" ] && add_tool "$1" || true; }

for t in \
  /usr/bin/make /usr/bin/cmake /usr/bin/python3 \
  /usr/bin/env /usr/bin/sh /usr/bin/bash /usr/bin/dash \
  /usr/bin/sed /usr/bin/grep /usr/bin/gawk /usr/bin/awk /usr/bin/find /usr/bin/xargs \
  /usr/bin/install /usr/bin/cp /usr/bin/mv /usr/bin/rm /usr/bin/mkdir \
  /usr/bin/chmod /usr/bin/ln /usr/bin/cat /usr/bin/head /usr/bin/tail \
  /usr/bin/wc /usr/bin/sort /usr/bin/uniq /usr/bin/date /usr/bin/stat \
  /usr/bin/readlink /usr/bin/dirname /usr/bin/basename /usr/bin/touch \
  /usr/bin/ls /usr/bin/uname /usr/bin/mktemp /usr/bin/cmp /usr/bin/tee \
  /usr/bin/tr /usr/bin/cut /usr/bin/true /usr/bin/false /usr/bin/sleep \
  /usr/bin/test /usr/bin/expr /usr/bin/printf /usr/bin/diff \
  /bin/sh /bin/bash
do
  add_tool "$t"
done

mkdir -p "$ROOTFS/usr/bin" "$ROOTFS/usr/lib/gcc" "$ROOTFS/usr/libexec/gcc"

# The sandbox must not be able to see any host compiler.
if [ "${STAGE3_HOST_LD:-0}" = 1 ]; then
  info "STAGE3_HOST_LD=1: diagnostic mode, host ld is allowed"
fi
LEAKS=$("$BWRAP" "${BWRAP_ARGS[@]}" --chdir / -- /bin/sh -c \
  'for p in /usr/bin/gcc /usr/bin/g++ /usr/bin/cc1 /usr/bin/clang /usr/bin/clang++ \
            /usr/bin/ld /usr/bin/ld.bfd /usr/bin/as /usr/bin/ar /usr/bin/ranlib \
            /usr/bin/nm /usr/bin/objcopy /usr/bin/strip /usr/bin/readelf; do
     if [ -x "$p" ] && [ -s "$p" ]; then printf "LEAK %s\n" "$p"; fi
   done
   for d in /usr/lib/gcc /usr/libexec/gcc; do
     if [ -d "$d" ] && find "$d" -type f -size +0c 2>/dev/null | grep -q .; then
       printf "LEAK %s\n" "$d"
     fi
   done') || die "sandbox sanity check failed"
if [ "${STAGE3_HOST_LD:-0}" != 1 ]; then
  [ -z "$LEAKS" ] || die "sandbox exposes host compiler paths: $LEAKS"
fi

info "starting bubblewrap sandbox (no host compiler)"
"$BWRAP" "${BWRAP_ARGS[@]}" --chdir "$BUILD_IN" -- \
  /bin/bash "$BUILD_IN/tools/inner-build.sh"

# bubblewrap creates empty mount-point files in the backing rootfs for every
# --ro-bind destination that did not exist; drop those stubs.
find "$ROOTFS/usr/bin" -maxdepth 1 -type f -size 0 -delete 2>/dev/null || true
find "$ROOTFS/usr/lib/gcc" "$ROOTFS/usr/libexec/gcc" -type f -size 0 -delete 2>/dev/null || true
rmdir "$ROOTFS/usr/lib/gcc" "$ROOTFS/usr/libexec/gcc" 2>/dev/null || true

END=$(date +%s)
ELAPSED=$((END - START))
info "done ($ELAPSED s)"
printf '\n'
printf 'self-hosted prefix : %s\n' "$ROOTFS$PREFIX"
printf 'clang              : %s\n' "$ROOTFS$PREFIX/bin/clang"
printf 'build info         : %s\n' "$BUILD/build-info.txt"
printf 'build logs         : %s\n' "$LOG"
printf 'elapsed            : %s s\n' "$ELAPSED"
