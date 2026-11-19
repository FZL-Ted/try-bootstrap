#!/usr/bin/env bash
#
# Stage 4: build LLVM/clang 9.0.1 with the *second-stage* LLVM/clang 5.0.2
# produced by the host-gcc chain (rootfs-hostgcc/opt/llvm5-bootstrap).
#
# The build runs inside a bubblewrap sandbox which contains NO host C or C++
# compiler, no host GCC installation, no host headers and no host C++ library.
# The host supplies only:
#   * binutils (ld/ar/as/ranlib/nm/readelf),
#   * the build tools make/cmake/python3 and coreutils,
#   * the shared libraries those tools need to start.
# All compilers, C/C++ headers and libraries used for the result come from the
# rootfs (clang 5.0.2 from stage 3b, musl, libc++ 5, EDG libC, compiler-rt).
#
# Inputs:
#     llvm-project-9.0.tar.gz            (next to this script or one level up)
#     ${ROOTFS:-rootfs-hostgcc}/         rootfs with the stage-3b toolchain
#
# Output (all inside the rootfs):
#     <rootfs>/build/llvm9/src/llvm-project-9.0/   source tree
#     <rootfs>/build/llvm9/build/stage1/           LLVM 9 build tree
#     <rootfs>/opt/llvm9/                          LLVM/clang 9 install
#     <rootfs>/build/llvm9/build-info.txt
#
# Usage:
#     ./tmp-llvm5-to-llvm9.sh
#     JOBS=8 ./tmp-llvm5-to-llvm9.sh
#     CONFIGURE_ONLY=1 ./tmp-llvm5-to-llvm9.sh
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

STAGE1_PREFIX=$(in_rootfs "${STAGE1_PREFIX:-/opt/llvm5-bootstrap}")
BUILD_IN=$(in_rootfs "${BUILD_DIR:-build/llvm9}")
PREFIX=$(in_rootfs "${PREFIX:-/opt/llvm9}")
BUILD=$ROOTFS$BUILD_IN
SRC=$BUILD/src
LOG=$BUILD/log

TARBALL=${TARBALL:-}
if [ -z "$TARBALL" ]; then
  for t in "$ROOT/llvm-project-9.0.tar.gz" "$ROOT/../llvm-project-9.0.tar.gz"; do
    if [ -f "$t" ]; then TARBALL=$t; break; fi
  done
fi
[ -n "$TARBALL" ] && [ -f "$TARBALL" ] || \
  die "llvm-project-9.0.tar.gz not found next to $ROOT or one level up"

command -v bwrap >/dev/null 2>&1 || die "bwrap (bubblewrap) not found"
BWRAP=$(command -v bwrap)

# ---------------------------------------------------------------- inputs ---

CLANG=$ROOTFS$STAGE1_PREFIX/bin/clang
CLANGXX=$ROOTFS$STAGE1_PREFIX/bin/clang++
[ -x "$CLANG" ] || die "stage-2 clang not found: $CLANG"
[ -x "$CLANGXX" ] || die "stage-2 clang++ not found: $CLANGXX"
[ -d "$ROOTFS/usr/include/c++/v1" ] || die "libc++ headers not found in the rootfs"
[ -f "$ROOTFS/usr/lib/libc++.a" ] || die "libc++.a not found in the rootfs"
[ -f "$ROOTFS/usr/lib/libC.a" ] || die "EDG C++ runtime libC.a not found in the rootfs"
[ -f "$ROOTFS/usr/lib/crt1.o" ] || die "musl start files not found in the rootfs"

CLANG_VER=$("$CLANG" --version 2>/dev/null | head -n1 || true)
case "$CLANG_VER" in
  *"clang version 5."*) ;;
  *) die "unexpected stage-2 clang: $CLANG_VER" ;;
esac

info "stage-2 clang : $CLANG_VER"
info "rootfs        : $ROOTFS"
info "stage-2 prefix: $ROOTFS$STAGE1_PREFIX"
info "source        : $SRC"
info "build tree    : $BUILD"
info "install to    : $ROOTFS$PREFIX"
info "jobs          : $JOBS"

START=$(date +%s)
START_UTC=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
mkdir -p "$BUILD/tools" "$BUILD/tmp" "$LOG" "$SRC"

# ----------------------------------------------------------- source tree ---

if [ "${KEEP_SRC:-0}" = 1 ] && [ -d "$SRC/llvm-project-9.0/llvm" ]; then
  info "reusing extracted LLVM 9 source tree"
else
  info "extracting $(basename "$TARBALL")"
  rm -rf "$SRC/llvm-project-9.0"
  tar xzf "$TARBALL" -C "$SRC"
fi
SRC_TOP=$SRC/llvm-project-9.0
[ -d "$SRC_TOP/llvm" ] || die "LLVM source tree missing: $SRC_TOP/llvm"
[ -d "$SRC_TOP/clang" ] || die "clang source tree missing: $SRC_TOP/clang"

# --------------------------------------------------- sandbox environment ---
#
# Paths are the ones seen from inside the sandbox (rootfs mounted at /).

cat > "$BUILD/tools/toolchain.cmake" <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER $STAGE1_PREFIX/bin/clang)
set(CMAKE_CXX_COMPILER $STAGE1_PREFIX/bin/clang++)
set(CMAKE_ASM_COMPILER $STAGE1_PREFIX/bin/clang)
set(CMAKE_AR /usr/bin/ar)
set(CMAKE_RANLIB /usr/bin/ranlib)
set(CMAKE_C_FLAGS_INIT "--sysroot=/ -static -O0 -fno-pie -D_LARGEFILE64_SOURCE=1")
set(CMAKE_CXX_FLAGS_INIT "--sysroot=/ -static -O0 -fno-pie -stdlib=libc++ -fno-exceptions -D_LIBCPP_NO_EXCEPTIONS=1 -D_LIBCPP_HAS_MUSL_LIBC=1 -D_LARGEFILE64_SOURCE=1")
set(CMAKE_C_FLAGS_RELEASE "-O0 -DNDEBUG" CACHE STRING "" FORCE)
set(CMAKE_CXX_FLAGS_RELEASE "-O0 -DNDEBUG" CACHE STRING "" FORCE)
set(CMAKE_EXE_LINKER_FLAGS_INIT "-nostartfiles /usr/lib/crt1.o /usr/lib/crti.o /usr/lib/crtn.o /usr/lib/dso_handle.o -nodefaultlibs -no-pie -Wl,--allow-multiple-definition")
set(CMAKE_C_STANDARD_LIBRARIES "-L/usr/lib -L$STAGE1_PREFIX/lib/clang/5.0.2/lib/linux -Wl,--start-group -lc -lm -lpthread -lclang_rt.builtins-x86_64 -Wl,--end-group")
set(CMAKE_CXX_STANDARD_LIBRARIES "-L/usr/lib -L$STAGE1_PREFIX/lib/clang/5.0.2/lib/linux -Wl,--start-group -lc++ -lC -lc -lm -lpthread -lclang_rt.builtins-x86_64 -Wl,--end-group")
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
PREFIX=@PREFIX@
JOBS=@JOBS@
CONFIGURE_ONLY=@CONFIGURE_ONLY@
CLANG=$STAGE1_PREFIX/bin/clang
CLANGXX=$STAGE1_PREFIX/bin/clang++
LOG=$BUILD/log
export TMPDIR=/tmp

info "compiler check with the stage-2 clang"
cat > "$BUILD/check.c" <<'EOF'
#include <stdio.h>
int main(void) { printf("llvm9-stage C ok\n"); return 0; }
EOF
cat > "$BUILD/check.cpp" <<'EOF'
#include <cstdio>
#include <string>
#include <vector>
#include <algorithm>
#include <memory>
int main() {
  std::vector<int> v{3, 1, 2};
  std::sort(v.begin(), v.end());
  auto p = std::make_shared<int>(42);
  std::printf("llvm9-stage C++ ok %s %d %d\n", "libc++", v[0], *p);
  return (v[0] == 1 && *p == 42) ? 0 : 1;
}
EOF
"$CLANG" --sysroot=/ -static -O1 -fno-pie \
  -nostartfiles /usr/lib/crt1.o /usr/lib/crti.o /usr/lib/crtn.o \
  /usr/lib/dso_handle.o -nodefaultlibs -no-pie \
  -o "$BUILD/check-c" "$BUILD/check.c" \
  -L/usr/lib -L"$STAGE1_PREFIX/lib/clang/5.0.2/lib/linux" \
  -Wl,--start-group -lc -lm -lpthread -lclang_rt.builtins-x86_64 -Wl,--end-group \
  -Wl,--allow-multiple-definition > "$LOG/check-c.log" 2>&1 || {
    tail -n 20 "$LOG/check-c.log" >&2; die "stage-2 clang failed to build C"; }
"$CLANGXX" --sysroot=/ -static -O1 -fno-pie -std=c++14 -stdlib=libc++ \
  -D_LIBCPP_NO_EXCEPTIONS=1 -D_LIBCPP_HAS_MUSL_LIBC=1 \
  -D_LARGEFILE64_SOURCE=1 -fno-exceptions \
  -nostartfiles /usr/lib/crt1.o /usr/lib/crti.o /usr/lib/crtn.o \
  /usr/lib/dso_handle.o -nodefaultlibs -no-pie \
  -o "$BUILD/check-cxx" "$BUILD/check.cpp" \
  -L/usr/lib -L"$STAGE1_PREFIX/lib/clang/5.0.2/lib/linux" \
  -Wl,--start-group -lc++ -lC -lc -lm -lpthread -lclang_rt.builtins-x86_64 -Wl,--end-group \
  -Wl,--allow-multiple-definition > "$LOG/check-cxx.log" 2>&1 || {
    tail -n 20 "$LOG/check-cxx.log" >&2; die "stage-2 clang++ failed to build C++"; }
[ "$("$BUILD/check-c")" = "llvm9-stage C ok" ] || die "stage-2 C binary failed"
[ "$("$BUILD/check-cxx")" = "llvm9-stage C++ ok libc++ 1 42" ] || die "stage-2 C++ binary failed"

# --------------------------------------------------------------- cmake ---

info "configuring LLVM 9.0.1 + clang"
BD=$BUILD/build/stage1
if [ "$CONFIGURE_ONLY" = 1 ]; then
  rm -rf "$BD"
fi
CMAKE_POLICY_VERSION_MINIMUM=3.5 cmake -G "Unix Makefiles" \
  -S "$SRC/llvm" -B "$BD" \
  -DCMAKE_TOOLCHAIN_FILE="$BUILD/tools/toolchain.cmake" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_BUILD_TYPE=Release \
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
  -DLLVM_ENABLE_LIBEDIT=OFF \
  -DLLVM_ENABLE_ASSERTIONS=OFF \
  -DLLVM_APPEND_VC_REV=OFF \
  -DLLVM_BUILD_LLVM_DYLIB=OFF -DLLVM_LINK_LLVM_DYLIB=OFF \
  -DCLANG_ENABLE_ARCMT=OFF -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
  -DCLANG_ENABLE_FORMAT=OFF \
  > "$LOG/cmake-configure.log" 2>&1 || {
    tail -n 60 "$LOG/cmake-configure.log" >&2
    die "cmake configure failed (see $LOG/cmake-configure.log)"
  }

if [ "$CONFIGURE_ONLY" = 1 ]; then
  info "CONFIGURE_ONLY=1: configuration finished, not building"
  exit 0
fi

info "building the LLVM 9 clang target with $JOBS jobs"
cmake --build "$BD" --target clang -- -j"$JOBS" > "$LOG/cmake-build.log" 2>&1 || {
  grep -n -m8 -B2 -A8 'error:' "$LOG/cmake-build.log" >&2 || true
  tail -n 30 "$LOG/cmake-build.log" >&2
  die "LLVM 9 build failed (see $LOG/cmake-build.log)"
}

info "installing LLVM 9 clang into $PREFIX (manual)"
rm -rf "$PREFIX/bin" "$PREFIX/lib/clang/9.0.1"
mkdir -p "$PREFIX/bin" "$PREFIX/lib/clang/9.0.1/include" "$PREFIX/lib/clang/9.0.1/lib/linux"
cp "$BD/bin/clang" "$PREFIX/bin/clang"
ln -sf clang "$PREFIX/bin/clang++"
cp -a "$BD/lib/clang/9.0.1/include/." "$PREFIX/lib/clang/9.0.1/include/"
cp "$STAGE1_PREFIX/lib/clang/5.0.2/lib/linux/"*.a "$PREFIX/lib/clang/9.0.1/lib/linux/" 2>/dev/null || true

# ------------------------------------------------------------- checks ---

info "check: LLVM 9 clang runs"
"$PREFIX/bin/clang" --version > "$LOG/clang-version.txt" 2>&1 || \
  die "LLVM 9 clang --version failed"
grep -q 'clang version 9\.0' "$LOG/clang-version.txt" || \
  die "unexpected installed clang: $(cat "$LOG/clang-version.txt")"

info "check: LLVM 9 clang compiles and links C and C++ by itself"
"$PREFIX/bin/clang" --sysroot=/ -static -O1 -fno-pie \
  -nostartfiles /usr/lib/crt1.o /usr/lib/crti.o /usr/lib/crtn.o \
  /usr/lib/dso_handle.o -nodefaultlibs -no-pie \
  -o "$BUILD/check9-c" "$BUILD/check.c" \
  -L/usr/lib -L"$PREFIX/lib/clang/9.0.1/lib/linux" \
  -Wl,--start-group -lc -lm -lpthread -lclang_rt.builtins-x86_64 -Wl,--end-group \
  -Wl,--allow-multiple-definition > "$LOG/check9-c.log" 2>&1 || {
    tail -n 20 "$LOG/check9-c.log" >&2; die "LLVM 9 clang failed to build C"; }
"$PREFIX/bin/clang++" --sysroot=/ -static -O1 -fno-pie -std=c++14 -stdlib=libc++ \
  -D_LIBCPP_NO_EXCEPTIONS=1 -D_LIBCPP_HAS_MUSL_LIBC=1 \
  -D_LARGEFILE64_SOURCE=1 -fno-exceptions \
  -nostartfiles /usr/lib/crt1.o /usr/lib/crti.o /usr/lib/crtn.o \
  /usr/lib/dso_handle.o -nodefaultlibs -no-pie \
  -o "$BUILD/check9-cxx" "$BUILD/check.cpp" \
  -L/usr/lib -L"$PREFIX/lib/clang/9.0.1/lib/linux" \
  -Wl,--start-group -lc++ -lC -lc -lm -lpthread -lclang_rt.builtins-x86_64 -Wl,--end-group \
  -Wl,--allow-multiple-definition > "$LOG/check9-cxx.log" 2>&1 || {
    tail -n 20 "$LOG/check9-cxx.log" >&2; die "LLVM 9 clang++ failed to build C++"; }
[ "$("$BUILD/check9-c")" = "llvm9-stage C ok" ] || die "LLVM 9 C binary failed"
[ "$("$BUILD/check9-cxx")" = "llvm9-stage C++ ok libc++ 1 42" ] || die "LLVM 9 C++ binary failed"

info "check: LLVM 9 binaries are static and glibc-free"
for exe in "$PREFIX/bin/clang" "$BUILD/check9-c" "$BUILD/check9-cxx"; do
  if readelf -l "$exe" | grep -q INTERP; then die "$exe is dynamically linked"; fi
  if readelf -sW "$exe" | grep -q 'GLIBC_'; then die "$exe carries GLIBC symbols"; fi
done

# ------------------------------------------------------------- summary ---

{
  printf 'LLVM/Clang 9.0.1 built by the stage-2 LLVM/clang 5.0.2 + musl/libc++ 5\n'
  printf 'date (UTC)      : %s\n' @START_UTC@
  printf 'stage-2 clang   : %s\n' "@CLANG_VER@"
  printf 'result          : %s\n' "$("$PREFIX/bin/clang" --version | head -n1)"
  printf 'host gcc        : not present in the sandbox (only binutils ld/ar)\n'
  printf 'jobs            : %s\n' "$JOBS"
} > "$BUILD/build-info.txt"
INNER_EOF

CONFIGURE_ONLY=${CONFIGURE_ONLY:-0}
sed -i \
  -e "s|@BUILD_IN@|$BUILD_IN|g" \
  -e "s|@SRC_IN@|$BUILD_IN/src/llvm-project-9.0|g" \
  -e "s|@STAGE1_PREFIX@|$STAGE1_PREFIX|g" \
  -e "s|@PREFIX@|$PREFIX|g" \
  -e "s|@JOBS@|$JOBS|g" \
  -e "s|@CONFIGURE_ONLY@|$CONFIGURE_ONLY|g" \
  -e "s|@START_UTC@|$START_UTC|g" \
  -e "s|@CLANG_VER@|$CLANG_VER|g" \
  "$BUILD/tools/inner-build.sh"
chmod +x "$BUILD/tools/inner-build.sh"

# ------------------------------------------------------------ sandbox ---
#
# No host gcc/g++/cc1, no /usr/lib/gcc, no host C++ headers or libraries are
# visible.  The listed host binaries are the whole whitelist.

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

# cmake's data directory (versioned)
for d in /usr/share/cmake-*; do
  [ -d "$d" ] && BWRAP_ARGS+=(--ro-bind "$d" "$d")
done
# Python runtime for cmake's PythonInterp check
for d in /usr/lib/python3.* /usr/local/lib/python3.*; do
  [ -d "$d" ] && BWRAP_ARGS+=(--ro-bind "$d" "$d")
done

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
  /usr/bin/objcopy /usr/bin/strip \
  /usr/bin/make /usr/bin/cmake /usr/bin/python3 \
  /usr/bin/env /usr/bin/sh /usr/bin/bash /usr/bin/dash \
  /usr/bin/sed /usr/bin/grep /usr/bin/gawk /usr/bin/awk /usr/bin/find /usr/bin/xargs \
  /usr/bin/install /usr/bin/cp /usr/bin/mv /usr/bin/rm /usr/bin/mkdir \
  /usr/bin/chmod /usr/bin/ln /usr/bin/cat /usr/bin/head /usr/bin/tail \
  /usr/bin/wc /usr/bin/sort /usr/bin/uniq /usr/bin/date /usr/bin/stat \
  /usr/bin/readlink /usr/bin/dirname /usr/bin/basename /usr/bin/touch \
  /usr/bin/uname /usr/bin/readelf \
  /usr/bin/ls /usr/bin/cmp /usr/bin/tee /usr/bin/tr /usr/bin/cut \
  /usr/bin/true /usr/bin/false /usr/bin/sleep /usr/bin/test /usr/bin/expr \
  /usr/bin/mktemp /usr/bin/printf /usr/bin/diff \
  /bin/sh /bin/bash
do
  add_tool "$t"
done

# Record the exact host bindings so the sandbox contents can be audited.
{
  printf 'bwrap'
  printf ' %q' "${BWRAP_ARGS[@]}"
  printf '\n'
} > "$BUILD/tools/sandbox-args.txt"
info "host bindings manifest: $BUILD/tools/sandbox-args.txt"

# The sandbox must not be able to see any host compiler.
LEAKS=$("$BWRAP" "${BWRAP_ARGS[@]}" --chdir / -- /bin/sh -c \
  'for p in /usr/bin/gcc /usr/bin/g++ /usr/bin/c++ /usr/bin/cc1 /usr/bin/clang /usr/bin/clang++; do
     if [ -x "$p" ] && [ -s "$p" ]; then printf "LEAK %s\n" "$p"; fi
   done
   for d in /usr/lib/gcc /usr/libexec/gcc; do
     if [ -d "$d" ] && find "$d" -type f -size +0c 2>/dev/null | grep -q .; then
       printf "LEAK %s\n" "$d"
     fi
   done') || die "sandbox sanity check failed"
[ -z "$LEAKS" ] || die "sandbox exposes host compiler paths: $LEAKS"

info "starting bubblewrap sandbox (no host compiler, clang 5 from the rootfs)"
"$BWRAP" "${BWRAP_ARGS[@]}" --chdir "$BUILD_IN" -- \
  /bin/bash "$BUILD_IN/tools/inner-build.sh"

# bubblewrap creates empty mount-point files in the backing rootfs for the
# --ro-bind destinations that did not exist; drop those stubs.
for d in "$ROOTFS/usr/bin" "$ROOTFS/bin"; do
  find "$d" -maxdepth 1 -type f -size 0 -delete 2>/dev/null || true
done

END=$(date +%s)
ELAPSED=$((END - START))
info "done ($ELAPSED s)"
printf '\n'
printf 'LLVM 9 prefix : %s\n' "$ROOTFS$PREFIX"
printf 'clang         : %s\n' "$ROOTFS$PREFIX/bin/clang"
printf 'build info    : %s\n' "$BUILD/build-info.txt"
printf 'build logs    : %s\n' "$LOG"
printf 'elapsed       : %s s\n' "$ELAPSED"
