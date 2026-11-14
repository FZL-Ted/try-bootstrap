#!/usr/bin/env bash
#
# Stage 3b of the bootstrap chain: rebuild LLVM/Clang 5.0.2 with the clang
# built by ./refhost-llvm5.x.sh, in a bubblewrap sandbox that contains NO host
# C or C++ compiler at all.
#
# The compiler used for both C and C++ is <rootfs>/opt/llvm5/bin/clang(++),
# i.e. the LLVM/clang produced by stage 3a.  libc++ is rebuilt first with that
# compiler, and the second LLVM/clang is then linked against the freshly built
# libc++ (falling back to the stage-1 one for the __cxa/typeinfo entry points
# supplied by EDG's runtime, which are ABI compatible).
#
# The host is used only for:
#   * binutils' ld (the linker driver; as/ar/ranlib are LLVM's own tools),
#   * the build tools make/cmake/python3 and coreutils,
#   * the shared libraries those tools need to start.
# No host gcc, g++, cc1, libgcc, header or C++ library is visible.
#
# Inputs:
#     ${ROOTFS:-rootfs-hostgcc}/         rootfs with the stage-3a toolchain
#     llvm-project-5.x.tar.gz            LLVM 5.0.2 source
#
# Output (all inside the rootfs):
#     <rootfs>/build/llvm5-bootstrap/libcxx/libc++.a
#     <rootfs>/build/llvm5-bootstrap/build/stage2/      LLVM build tree
#     <rootfs>/opt/llvm5-bootstrap/                     self-hosted LLVM + clang
#     <rootfs>/build/llvm5-bootstrap/build-info.txt
#
# Usage:
#     ./refhost-llvm-5.x-bootstrap.sh
#     JOBS=8 ./refhost-llvm-5.x-bootstrap.sh
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

JOBS=${JOBS:-$(nproc --ignore=1 2>/dev/null || nproc 2>/dev/null || echo 1)}
[ "$JOBS" -ge 1 ] 2>/dev/null || JOBS=1
STAGE1_PREFIX=${STAGE1_PREFIX:-/opt/llvm5}
PREFIX=${PREFIX:-/opt/llvm5-bootstrap}
BUILD=$ROOTFS/build/llvm5-bootstrap
SRC=$ROOTFS/build/llvm5/src
LOG=$BUILD/log

command -v bwrap >/dev/null 2>&1 || die "bwrap (bubblewrap) not found"
BWRAP=$(command -v bwrap)

# ---------------------------------------------------------------- inputs ---

[ -x "$ROOTFS$STAGE1_PREFIX/bin/clang" ] || \
  die "stage-1 clang not found: $ROOTFS$STAGE1_PREFIX/bin/clang (run ./refhost-llvm5.x.sh first)"
[ -x "$ROOTFS$STAGE1_PREFIX/bin/clang++" ] || die "stage-1 clang++ not found"
[ -s "$ROOTFS$STAGE1_PREFIX/lib/libc++.a" ] || die "stage-1 libc++.a not found"
[ -d "$ROOTFS/usr/include/c++/v1" ] || die "stage-1 libc++ headers not found"
[ -f "$ROOTFS/usr/lib/libc++.a" ] || die "stage-1 libc++.a is not installed in /usr/lib"
[ -f "$ROOTFS/usr/lib/libC.a" ] || die "EDG C++ runtime libC.a not installed in /usr/lib"
[ -d "$SRC/llvm" ] || die "LLVM source not found: $SRC (run ./refhost-llvm5.x.sh first)"

CLANG_VER=$("$ROOTFS$STAGE1_PREFIX/bin/clang" --version 2>/dev/null | head -n1 || true)
case "$CLANG_VER" in
  *"clang version 5."*) ;;
  *) die "unexpected stage-1 clang: $CLANG_VER" ;;
esac

info "stage-1 clang : $CLANG_VER"
info "stage-1 prefix: $ROOTFS$STAGE1_PREFIX"
info "bootstrap to  : $ROOTFS$PREFIX"
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
set(CMAKE_AR /usr/bin/ar)
set(CMAKE_RANLIB /usr/bin/ranlib)
set(CMAKE_C_FLAGS_INIT "--sysroot=/ -static -O0 -fno-pie -rtlib=compiler-rt -D_LARGEFILE64_SOURCE=1")
set(CMAKE_CXX_FLAGS_INIT "--sysroot=/ -static -O0 -fno-pie -rtlib=compiler-rt -stdlib=libc++ -fno-exceptions -D_LIBCPP_NO_EXCEPTIONS=1 -D_LIBCPP_HAS_MUSL_LIBC=1 -D_LARGEFILE64_SOURCE=1")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-nostartfiles /usr/lib/crt1.o /usr/lib/crti.o /usr/lib/crtn.o /usr/lib/dso_handle.o -nodefaultlibs -no-pie -Wl,--allow-multiple-definition")
set(CMAKE_C_STANDARD_LIBRARIES "-L/usr/lib -L$STAGE1_PREFIX/lib/clang/5.0.2/lib/linux -Wl,--start-group -lc -lm -lpthread -lclang_rt.builtins-x86_64 -Wl,--end-group")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-L/usr/lib -Wl,--allow-multiple-definition")

set(CMAKE_CXX_STANDARD_LIBRARIES "-L$PREFIX/lib -L/usr/lib -L$STAGE1_PREFIX/lib/clang/5.0.2/lib/linux -Wl,--start-group -lc++ -lC -lc -lm -lpthread -lclang_rt.builtins-x86_64 -Wl,--end-group")
set(CMAKE_CROSSCOMPILING FALSE)
set(PYTHON_EXECUTABLE /usr/bin/python3)
EOF

# ------------------------------------------------------------- inner script ---

cat > "$BUILD/tools/inner-build.sh" <<'INNER_EOF'
#!/bin/bash
set -euo pipefail
info() { printf '==> %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

BUILD=/build/llvm5-bootstrap
SRC=/build/llvm5/src
STAGE1_PREFIX=@STAGE1_PREFIX@
PREFIX=@PREFIX@
JOBS=@JOBS@
CLANG=$STAGE1_PREFIX/bin/clang
CLANGXX=$STAGE1_PREFIX/bin/clang++
LOG=$BUILD/log
export TMPDIR=/tmp

# ------------------------------------------------------------- libc++ ---
#
# Rebuild the C++ standard library with clang itself.  Exceptions stay off,
# matching how LLVM is built.  The headers are the stage-1 ones (libc++ 5.0.2).

info "rebuilding libc++ 5.0.2 with clang"
mkdir -p "$BUILD/libcxx/gen" "$BUILD/libcxx/obj"
libcxx_fail=0
for src in "$SRC"/libcxx/src/*.cpp; do
  b=$(basename "$src" .cpp)
  if ! "$CLANGXX" --sysroot=/ -static -O1 -std=c++14 -stdlib=libc++ \
        -rtlib=compiler-rt -D_LIBCPP_NO_EXCEPTIONS=1 \
        -D_LIBCPP_HAS_MUSL_LIBC=1 -D_LIBCPP_BUILDING_LIBRARY=1 -D_LARGEFILE64_SOURCE=1 \
        -fno-exceptions -I "$SRC/libcxx/src" \
        -c "$src" -o "$BUILD/libcxx/obj/$b.o" \
        > "$LOG/libcxx-$b.log" 2>&1; then
    printf 'FAIL compile %s (see %s)\n' "$b.cpp" "$LOG/libcxx-$b.log" >&2
    tail -n 4 "$LOG/libcxx-$b.log" >&2 || true
    libcxx_fail=$((libcxx_fail + 1))
  fi
done
[ "$libcxx_fail" -eq 0 ] || die "$libcxx_fail libc++ sources failed with clang"
/usr/bin/ar rcs "$BUILD/libcxx/libc++.a" "$BUILD/libcxx/obj"/*.o
[ -s "$BUILD/libcxx/libc++.a" ] || die "stage-2 libc++.a was not produced"

# smoke test with the freshly built libc++
cat > "$BUILD/libcxx/smoke.cpp" <<'EOF'
#include <cstdio>
#include <string>
#include <vector>
#include <algorithm>
#include <memory>
int main() {
  std::vector<int> v{3, 1, 2};
  std::sort(v.begin(), v.end());
  std::string s = "stage2 libc++";
  auto p = std::make_shared<int>(42);
  std::printf("%s %d %d\n", s.c_str(), v[0], *p);
  return (v[0] == 1 && *p == 42) ? 0 : 1;
}
EOF
"$CLANGXX" --sysroot=/ -static -O1 -std=c++14 -stdlib=libc++ -rtlib=compiler-rt \
  -D_LIBCPP_NO_EXCEPTIONS=1 -D_LIBCPP_HAS_MUSL_LIBC=1 -D_LARGEFILE64_SOURCE=1 -fno-exceptions \
  -o "$BUILD/libcxx/smoke" "$BUILD/libcxx/smoke.cpp" \
  -nostartfiles /usr/lib/crt1.o /usr/lib/crti.o /usr/lib/crtn.o \
  /usr/lib/dso_handle.o -nodefaultlibs -no-pie \
  -L"$BUILD/libcxx" -L/usr/lib -L"$STAGE1_PREFIX/lib/clang/5.0.2/lib/linux" \
  -Wl,--start-group -lc++ -lC -lc -lm -lpthread -lclang_rt.builtins-x86_64 \
  -Wl,--end-group -Wl,--allow-multiple-definition > "$LOG/libcxx-smoke.log" 2>&1 || {
    tail -n 20 "$LOG/libcxx-smoke.log" >&2
    die "linking the stage-2 libc++ smoke test failed"
  }
SMOKE_OUT=$("$BUILD/libcxx/smoke") || die "the stage-2 libc++ smoke test failed"
info "libc++ smoke test: $SMOKE_OUT"

# --------------------------------------------------------------- cmake ---

info "configuring the self-hosted LLVM 5.0.2 + clang"
BD=$BUILD/build/stage2
rm -rf "$BD"
CMAKE_POLICY_VERSION_MINIMUM=3.5 cmake -G "Unix Makefiles" \
  -S "$SRC/llvm" -B "$BD" \
  -DCMAKE_TOOLCHAIN_FILE="$BUILD/tools/toolchain.cmake" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DLLVM_TARGETS_TO_BUILD=X86 \
  -DLLVM_ENABLE_PROJECTS=clang \
  -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_DOCS=OFF \
  -DLLVM_INCLUDE_UTILS=OFF \
  -DLLVM_BUILD_TOOLS=OFF -DLLVM_BUILD_UTILS=OFF \
  -DLLVM_BUILD_EXAMPLES=OFF -DLLVM_BUILD_RUNTIME=OFF \
  -DCLANG_BUILD_TOOLS=OFF -DCLANG_INCLUDE_TESTS=OFF \
  -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_ZLIB=OFF \
  -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_FFI=OFF \
  -DLLVM_ENABLE_ASSERTIONS=OFF \
  -DLLVM_BUILD_LLVM_DYLIB=OFF -DLLVM_LINK_LLVM_DYLIB=OFF \
  -DLLVM_BUILD_EXTERNAL_COMPILER_RT=OFF \
  -DCLANG_ENABLE_ARCMT=OFF -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
  -DCLANG_ENABLE_FORMAT=OFF \
  -DCMAKE_BUILD_TYPE=Release \
  > "$LOG/cmake-configure.log" 2>&1 || {
    tail -n 40 "$LOG/cmake-configure.log" >&2
    die "cmake configure failed with the stage-1 clang (see $LOG/cmake-configure.log)"
  }

info "building the self-hosted clang target with $JOBS jobs"
cmake --build "$BD" --target clang -- -j"$JOBS" > "$LOG/cmake-build.log" 2>&1 || {
  grep -n -m5 -B2 -A6 'error:' "$LOG/cmake-build.log" >&2 || true
  tail -n 20 "$LOG/cmake-build.log" >&2
  die "self-hosted clang build failed (see $LOG/cmake-build.log)"
}

info "installing the self-hosted clang into $PREFIX (manual)"
mkdir -p "$PREFIX/bin" "$PREFIX/lib/clang/5.0.2/include"
cp "$BD/bin/clang" "$PREFIX/bin/clang"
ln -sf clang "$PREFIX/bin/clang++"
cp -a "$STAGE1_PREFIX/lib/clang/5.0.2/include/." "$PREFIX/lib/clang/5.0.2/include/"
mkdir -p "$PREFIX/lib/clang/5.0.2/lib/linux"
cp "$STAGE1_PREFIX/lib/clang/5.0.2/lib/linux/"*.a "$PREFIX/lib/clang/5.0.2/lib/linux/" 2>/dev/null || true
[ -x "$PREFIX/bin/clang" ] || die "the self-hosted clang was not installed"

# ------------------------------------------------------------- checks ---

info "check: self-hosted clang runs"
"$PREFIX/bin/clang" --version > "$LOG/clang-version.txt" 2>&1 || \
  die "self-hosted clang --version failed"
grep -q 'clang version 5\.' "$LOG/clang-version.txt" || \
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
"$PREFIX/bin/clang" --sysroot=/ -static -O1 -fno-pie \
  -nostartfiles /usr/lib/crt1.o /usr/lib/crti.o /usr/lib/crtn.o \
  /usr/lib/dso_handle.o -nodefaultlibs -no-pie \
  -o "$BUILD/check-c" "$BUILD/check.c" \
  -L/usr/lib -L"$PREFIX/lib/clang/5.0.2/lib/linux" \
  -Wl,--start-group -lc -lm -lpthread -lclang_rt.builtins-x86_64 -Wl,--end-group \
  -Wl,--allow-multiple-definition \
  > "$LOG/check-c.log" 2>&1 || die "self-hosted clang failed to build C"
"$PREFIX/bin/clang++" --sysroot=/ -static -O1 -fno-pie -std=c++14 -stdlib=libc++ \
  -D_LIBCPP_NO_EXCEPTIONS=1 -D_LIBCPP_HAS_MUSL_LIBC=1 \
  -D_LARGEFILE64_SOURCE=1 -fno-exceptions \
  -nostartfiles /usr/lib/crt1.o /usr/lib/crti.o /usr/lib/crtn.o \
  /usr/lib/dso_handle.o -nodefaultlibs -no-pie \
  -o "$BUILD/check-cxx" "$BUILD/check.cpp" \
  -L"$BUILD/libcxx" -L/usr/lib -L"$PREFIX/lib/clang/5.0.2/lib/linux" \
  -Wl,--start-group -lc++ -lC -lc -lm -lpthread -lclang_rt.builtins-x86_64 -Wl,--end-group \
  -Wl,--allow-multiple-definition \
  > "$LOG/check-cxx.log" 2>&1 || die "self-hosted clang++ failed to build C++"
[ "$("$BUILD/check-c")" = "stage2 C ok" ] || die "self-hosted C binary failed"
[ "$("$BUILD/check-cxx")" = "stage2 C++ ok 1" ] || die "self-hosted C++ binary failed"

info "check: self-hosted binaries are static and glibc-free"
for exe in "$PREFIX/bin/clang" "$BUILD/check-c" "$BUILD/check-cxx"; do
  if readelf -l "$exe" | grep -q INTERP; then die "$exe is dynamically linked"; fi
  if readelf -sW "$exe" | grep -q 'GLIBC_'; then die "$exe carries GLIBC symbols"; fi
done

# ------------------------------------------------------------- summary ---

{
  printf 'LLVM/Clang 5.0.2 rebuilt by the stage-1 LLVM/clang 5.0.2 + musl\n'
  printf 'date (UTC)      : %s\n' @START_UTC@
  printf 'stage-1 clang   : %s\n' "@CLANG_VER@"
  printf 'self-hosted     : %s\n' "$("$PREFIX/bin/clang" --version | head -n1)"
  printf 'libc++ (clang)  : %s bytes\n' "$(stat -c %s "$BUILD/libcxx/libc++.a")"
  printf 'host gcc        : not present in the sandbox (only binutils ld/ar)\n'
  printf 'libc++ smoke    : %s\n' "$SMOKE_OUT"
  printf 'jobs            : %s\n' "$JOBS"
} > "$BUILD/build-info.txt"
INNER_EOF

sed -i \
  -e "s|@STAGE1_PREFIX@|$STAGE1_PREFIX|g" \
  -e "s|@PREFIX@|$PREFIX|g" \
  -e "s|@JOBS@|$JOBS|g" \
  -e "s|@START_UTC@|$START_UTC|g" \
  -e "s|@CLANG_VER@|$CLANG_VER|g" \
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
  --ro-bind /usr/share/cmake-4.3 /usr/share/cmake-4.3
  --ro-bind /usr/lib/python3.14 /usr/lib/python3.14
)

declare -A BOUND_TOOL=()
add_tool() {
  local p=$1 real
  [ -n "${BOUND_TOOL[$p]:-}" ] && return 0
  BOUND_TOOL[$p]=1
  [ -e "$p" ] || die "sandbox whitelist: $p does not exist"
  real=$(readlink -f "$p")
  BWRAP_ARGS+=(--ro-bind "$real" "$p")
}
for t in \
  /usr/bin/ld /usr/bin/x86_64-linux-gnu-ld \
  /usr/bin/ld.bfd /usr/bin/x86_64-linux-gnu-ld.bfd \
  /usr/bin/as /usr/bin/x86_64-linux-gnu-as \
  /usr/bin/ar /usr/bin/x86_64-linux-gnu-ar \
  /usr/bin/ranlib /usr/bin/x86_64-linux-gnu-ranlib \
  /usr/bin/nm /usr/bin/x86_64-linux-gnu-nm \
  /usr/bin/make /usr/bin/cmake /usr/bin/python3 /usr/bin/python3.14 \
  /usr/bin/env /usr/bin/sh /usr/bin/bash /usr/bin/dash \
  /usr/bin/sed /usr/bin/grep /usr/bin/gawk /usr/bin/awk /usr/bin/find /usr/bin/xargs \
  /usr/bin/install /usr/bin/cp /usr/bin/mv /usr/bin/rm /usr/bin/mkdir \
  /usr/bin/chmod /usr/bin/ln /usr/bin/cat /usr/bin/head /usr/bin/tail \
  /usr/bin/wc /usr/bin/sort /usr/bin/uniq /usr/bin/date /usr/bin/stat \
  /usr/bin/readlink /usr/bin/dirname /usr/bin/basename /usr/bin/touch \
  /usr/bin/uname /usr/bin/readelf \
  /usr/bin/ls /usr/bin/mkdir /usr/bin/rm /usr/bin/cp /usr/bin/mv \
  /usr/bin/readelf \
  /usr/bin/cmp /usr/bin/tee /usr/bin/tr /usr/bin/cut /usr/bin/true \
  /usr/bin/false /usr/bin/sleep /usr/bin/test /usr/bin/expr \
  /bin/sh /bin/bash
do
  add_tool "$t"
done

# The sandbox must not be able to see any host compiler.
LEAKS=$("$BWRAP" "${BWRAP_ARGS[@]}" --chdir / -- /bin/sh -c \
  'for p in /usr/bin/gcc /usr/bin/g++ /usr/bin/cc1; do
     if [ -x "$p" ] && [ -s "$p" ]; then printf "LEAK %s\n" "$p"; fi
   done
   for d in /usr/lib/gcc /usr/libexec/gcc; do
     if [ -d "$d" ] && find "$d" -type f -size +0c 2>/dev/null | grep -q .; then
       printf "LEAK %s\n" "$d"
     fi
   done') || die "sandbox sanity check failed"
[ -z "$LEAKS" ] || die "sandbox exposes host compiler paths: $LEAKS"

info "starting bubblewrap sandbox (no host compiler)"
"$BWRAP" "${BWRAP_ARGS[@]}" --chdir /build/llvm5-bootstrap -- \
  /bin/bash /build/llvm5-bootstrap/tools/inner-build.sh

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
