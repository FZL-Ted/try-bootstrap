#!/usr/bin/env bash
#
# Stage 2 of the LLVM 3.9 bootstrap chain:
# build lld 3.9 and the LLVM binutils replacements with the stage-1 clang.
# Host binutils are allowed in this stage (to link lld and the tools), but no
# host C++ compiler is used: all C/C++ code is compiled by the stage-1 clang
# 3.9 with the stage-1 libc++ 3.9.
#
# Run order:
#     ./refhost-llvm3.9.x-1.sh
#     ./refhost-llvm3.9.x-2.sh
#     ./refhost-llvm3.9.x-bootstrap.sh
#
# Output goes into the stage-1 prefix:
#     <rootfs>/opt/llvm3.9/bin/{lld,ld.lld,lld-link,llvm-ar,llvm-ranlib,
#                                llvm-nm,llvm-readobj,llvm-config}
#
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

ROOTFS=${ROOTFS:-$ROOT/rootfs-hostgcc}
case "$ROOTFS" in /*) ;; *) ROOTFS=$PWD/$ROOTFS ;; esac
[ -d "$ROOTFS" ] || die "rootfs not found: $ROOTFS"
ROOTFS=$(cd "$ROOTFS" && pwd -P)
case "$ROOTFS" in "$ROOT"/*) ;; *) die "ROOTFS must be inside $ROOT: $ROOTFS" ;; esac

JOBS=${JOBS:-16}
[ "$JOBS" -ge 1 ] 2>/dev/null || JOBS=1

in_rootfs() {
  local p=$1
  case "$p" in "$ROOTFS"|"$ROOTFS"/*) p=${p#"$ROOTFS"} ;; esac
  case "$p" in "") p=/ ;; /*) ;; *) p=/$p ;; esac
  case "$p" in /) ;; */) p=${p%/} ;; esac
  printf '%s' "$p"
}

STAGE1_PREFIX=$(in_rootfs "${STAGE1_PREFIX:-/opt/llvm3.9}")
STAGE1_BUILD=$(in_rootfs "${STAGE1_BUILD:-build/llvm3.9}")
SRC_IN=$(in_rootfs "${SRC_DIR:-$STAGE1_BUILD/src}")
BUILD_IN=$(in_rootfs "${BUILD_DIR:-build/llvm3.9-tools}")
BUILD=$ROOTFS$BUILD_IN
SRC=$ROOTFS$SRC_IN
LOG=$BUILD/log

[ -x "$ROOTFS$STAGE1_PREFIX/bin/clang" ] || die "stage-1 clang missing (run ./refhost-llvm3.9.x-1.sh first)"
[ -s "$ROOTFS$STAGE1_PREFIX/lib/libc++.a" ] || die "stage-1 libc++.a missing"
[ -s "$ROOTFS$STAGE1_PREFIX/lib/libC.a" ] || die "stage-1 libC.a missing"
[ -s "$ROOTFS$STAGE1_PREFIX/lib/dso_handle.o" ] || die "stage-1 dso_handle.o missing"
[ -d "$SRC/llvm" ] || die "LLVM source missing: $SRC/llvm"
[ -d "$SRC/lld" ] || die "lld source missing: $SRC/lld"
[ -x "$ROOT/edg-support/llvm-3.9/apply.sh" ] || die "missing edg-support/llvm-3.9/apply.sh"
"$ROOT/edg-support/llvm-3.9/apply.sh" "$SRC" >/dev/null || die "applying 3.9 patches failed"

CLANG_VER=$("$ROOTFS$STAGE1_PREFIX/bin/clang" --version 2>/dev/null | sed -n 's/.*clang version \([0-9][0-9.]*\).*/\1/p' | head -n1)
[ -n "$CLANG_VER" ] || die "cannot determine stage-1 clang version"
LIBRT_DIR=$STAGE1_PREFIX/lib/clang/$CLANG_VER/lib/linux
[ -s "$ROOTFS$LIBRT_DIR/libclang_rt.builtins-x86_64.a" ] || die "stage-1 builtins missing"

info "stage-1 clang : $CLANG_VER"
info "rootfs        : $ROOTFS"
info "stage-1 prefix: $ROOTFS$STAGE1_PREFIX"
info "source        : $SRC"
info "tools build   : $BUILD"
info "jobs          : $JOBS"

START=$(date +%s)
START_UTC=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
mkdir -p "$BUILD/tools" "$BUILD/tmp" "$LOG"

# ---------------------------------------------------------- toolchain ---
# Stage-1 clang + stage-1 libc++ 3.9; host binutils link lld and the tools.
cat > "$BUILD/tools/toolchain.cmake" <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER $STAGE1_PREFIX/bin/clang)
set(CMAKE_CXX_COMPILER $STAGE1_PREFIX/bin/clang++)
set(CMAKE_ASM_COMPILER $STAGE1_PREFIX/bin/clang)
set(CMAKE_AR /usr/bin/ar)
set(CMAKE_RANLIB /usr/bin/ranlib)
set(CMAKE_NM /usr/bin/nm)
set(CMAKE_LINKER /usr/bin/ld)
set(CMAKE_C_FLAGS_INIT "--sysroot=/ -static -O0 -fno-pie -rtlib=compiler-rt -Ufopen64 -Ufreopen64 -Ufseeko64 -Uftello64 -Utmpfile64 -Ufgetpos64 -Ufsetpos64 -Ufstat64 -Ufstatvfs64 -Ulstat64 -Uopen64 -Ustat64 -Ustatvfs64 -D_GNU_SOURCE=1")
set(CMAKE_CXX_FLAGS_INIT "--sysroot=/ -static -O0 -fno-pie -rtlib=compiler-rt -stdlib=libc++ -fno-exceptions -fno-rtti -D_LIBCPP_NO_EXCEPTIONS=1 -D_LIBCPP_NO_RTTI=1 -D_LIBCPP_BUILD_STATIC=1 -D_LIBCPP_HAS_MUSL_LIBC=1 -Ufopen64 -Ufreopen64 -Ufseeko64 -Uftello64 -Utmpfile64 -Ufgetpos64 -Ufsetpos64 -Ufstat64 -Ufstatvfs64 -Ulstat64 -Uopen64 -Ustat64 -Ustatvfs64 -D_GNU_SOURCE=1")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-nostartfiles /usr/lib/crt1.o /usr/lib/crti.o /usr/lib/crtn.o $STAGE1_PREFIX/lib/dso_handle.o -nodefaultlibs -Wl,--allow-multiple-definition")
set(CMAKE_C_STANDARD_LIBRARIES "-L/usr/lib -L$LIBRT_DIR -Wl,--start-group -lc -lm -lpthread -lclang_rt.builtins-x86_64 -Wl,--end-group")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-L/usr/lib -Wl,--allow-multiple-definition")
set(CMAKE_CXX_STANDARD_LIBRARIES "-L$STAGE1_PREFIX/lib -L/usr/lib -L$LIBRT_DIR -Wl,--start-group -lc++ -lC -lc -lm -lpthread -lclang_rt.builtins-x86_64 -Wl,--end-group")
set(CMAKE_CROSSCOMPILING FALSE)
set(PYTHON_EXECUTABLE /usr/bin/python3)
EOF

cat > "$BUILD/tools/inner-build.sh" <<'INNER_EOF'
#!/bin/bash
set -euo pipefail
info() { printf '==> %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

BUILD=@BUILD_IN@
SRC=@SRC_IN@
STAGE1_PREFIX=@STAGE1_PREFIX@
JOBS=@JOBS@
CLANG_VER=@CLANG_VER@
LOG=$BUILD/log
export TMPDIR=/tmp
export PATH="$STAGE1_PREFIX/bin:/usr/bin:/bin"

BD=$BUILD/build/tools
rm -rf "$BD"
info "configuring lld 3.9 + LLVM binutils with stage-1 clang"
CMAKE_POLICY_VERSION_MINIMUM=3.5 cmake -G "Unix Makefiles" \
  -S "$SRC/llvm" -B "$BD" \
  -DCMAKE_TOOLCHAIN_FILE="$BUILD/tools/toolchain.cmake" \
  -DCMAKE_INSTALL_PREFIX="$STAGE1_PREFIX" \
  -DLLVM_TARGETS_TO_BUILD=X86 \
  -DLLVM_EXTERNAL_LLD_SOURCE_DIR="$SRC/lld" \
  -DLLVM_EXTERNAL_LLD_BUILD=ON \
  -DLLVM_INCLUDE_TOOLS=ON -DLLVM_BUILD_TOOLS=ON \
  -DLLVM_INCLUDE_UTILS=ON \
  -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_INCLUDE_DOCS=OFF -DLLVM_BUILD_EXAMPLES=OFF \
  -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_ZLIB=OFF \
  -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_FFI=OFF \
  -DLLVM_ENABLE_ASSERTIONS=OFF -DLLVM_APPEND_VC_REV=OFF \
  -DLLVM_BUILD_EXTERNAL_COMPILER_RT=OFF \
  -DHAVE_CXXABI_H=0 \
  -DCMAKE_BUILD_TYPE=Release \
  > "$LOG/cmake-tools-configure.log" 2>&1 || {
    tail -n 40 "$LOG/cmake-tools-configure.log" >&2
    die "lld 3.9 configure failed"
  }

info "building targets: lld llvm-ar llvm-nm llvm-readobj llvm-config"
if ! cmake --build "$BD" --target lld llvm-ar llvm-nm llvm-readobj llvm-config \
      -- -j"$JOBS" > "$LOG/cmake-tools-build.log" 2>&1; then
  grep -n -m8 -B2 -A8 'error:' "$LOG/cmake-tools-build.log" >&2 || true
  tail -n 30 "$LOG/cmake-tools-build.log" >&2
  die "lld 3.9 build failed"
fi

for t in lld llvm-ar llvm-nm llvm-readobj llvm-config; do
  [ -x "$BD/bin/$t" ] || die "$BD/bin/$t was not produced"
  cp "$BD/bin/$t" "$STAGE1_PREFIX/bin/$t"
done
# 3.9's CMake generates llvm-ranlib as a symlink to llvm-ar.
if [ -e "$BD/bin/llvm-ranlib" ]; then
  cp -a "$BD/bin/llvm-ranlib" "$STAGE1_PREFIX/bin/llvm-ranlib"
else
  ln -sf llvm-ar "$STAGE1_PREFIX/bin/llvm-ranlib"
fi
ln -sf lld "$STAGE1_PREFIX/bin/ld.lld"
ln -sf lld "$STAGE1_PREFIX/bin/lld-link"
info "installed lld/ld.lld/llvm-ar/llvm-ranlib/llvm-nm/llvm-readobj"

info "check: lld 3.9 links static musl C and pthread"
cat > "$BUILD/check.c" <<'EOF'
#include <pthread.h>
#include <stdio.h>
static void *f(void *p) { return p; }
int main(void) {
  pthread_t t;
  pthread_create(&t, 0, f, 0);
  pthread_join(t, 0);
  printf("lld 3.9 C ok\n");
  return 0;
}
EOF
"$STAGE1_PREFIX/bin/clang" -fuse-ld=lld --sysroot=/ -static -O1 -fno-pie \
  -nostartfiles /usr/lib/crt1.o /usr/lib/crti.o /usr/lib/crtn.o \
  "$STAGE1_PREFIX/lib/dso_handle.o" -nodefaultlibs \
  -o "$BUILD/check-lld" "$BUILD/check.c" \
  -L/usr/lib -L"$STAGE1_PREFIX/lib/clang/$CLANG_VER/lib/linux" \
  -Wl,--start-group -lc -lm -lpthread -lclang_rt.builtins-x86_64 -Wl,--end-group \
  -Wl,--allow-multiple-definition > "$LOG/lld-link-check.log" 2>&1 || {
    tail -n 30 "$LOG/lld-link-check.log" >&2
    die "lld 3.9 failed to link the C/pthread check"
  }
[ "$("$BUILD/check-lld")" = "lld 3.9 C ok" ] || die "lld 3.9 C/pthread binary failed"

info "check: llvm-ar creates an archive"
printf 'int x;\n' > "$BUILD/x.c"
"$STAGE1_PREFIX/bin/clang" --sysroot=/ -c "$BUILD/x.c" -o "$BUILD/x.o"
"$STAGE1_PREFIX/bin/llvm-ar" rcs "$BUILD/x.a" "$BUILD/x.o"
"$STAGE1_PREFIX/bin/llvm-nm" "$BUILD/x.a" | grep -q ' x' || die "llvm-nm cannot inspect llvm-ar archive"

{
  printf 'LLVM/Clang 3.9 tools stage: lld 3.9 + LLVM binutils\n'
  printf 'date (UTC)      : %s\n' @START_UTC@
  printf 'stage-1 clang   : %s\n' "@CLANG_VER@"
  printf 'lld             : %s\n' "$("$STAGE1_PREFIX/bin/ld.lld" --version 2>&1 | head -n1)"
  printf 'llvm-ar         : %s\n' "$("$STAGE1_PREFIX/bin/llvm-ar" --version 2>&1 | head -n1)"
  printf 'jobs            : %s\n' "$JOBS"
} > "$BUILD/build-info.txt"
INNER_EOF

sed -i \
  -e "s|@BUILD_IN@|$BUILD_IN|g" \
  -e "s|@SRC_IN@|$SRC_IN|g" \
  -e "s|@STAGE1_PREFIX@|$STAGE1_PREFIX|g" \
  -e "s|@JOBS@|$JOBS|g" \
  -e "s|@CLANG_VER@|$CLANG_VER|g" \
  -e "s|@START_UTC@|$START_UTC|g" \
  "$BUILD/tools/inner-build.sh"
chmod +x "$BUILD/tools/inner-build.sh"

# ---------------------------------------------------------------- sandbox ---
BWRAP=$(command -v bwrap) || die "bwrap not found"
BWRAP_ARGS=(
  --die-with-parent --unshare-all
  --bind "$ROOTFS" /
  --proc /proc --dev /dev
  --bind "$BUILD/tmp" /tmp
  --ro-bind /usr/lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu
  --ro-bind /usr/lib64/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
  --ro-bind /etc/ld.so.cache /etc/ld.so.cache
)
for d in /usr/share/cmake-*; do [ -d "$d" ] && BWRAP_ARGS+=(--ro-bind "$d" "$d"); done
PY_STDLIB=$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["stdlib"])' 2>/dev/null || true)
[ -n "$PY_STDLIB" ] && [ -d "$PY_STDLIB" ] && BWRAP_ARGS+=(--ro-bind "$PY_STDLIB" "$PY_STDLIB")
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
  /usr/bin/ld /usr/bin/ld.bfd /usr/bin/as /usr/bin/ar /usr/bin/ranlib \
  /usr/bin/nm /usr/bin/objcopy /usr/bin/strip /usr/bin/readelf \
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
do add_tool "$t"; done
mkdir -p "$ROOTFS/usr/bin"
info "starting bubblewrap sandbox (stage-1 clang; host binutils for lld link)"
"$BWRAP" "${BWRAP_ARGS[@]}" --chdir "$BUILD_IN" -- /bin/bash "$BUILD_IN/tools/inner-build.sh"
find "$ROOTFS/usr/bin" -maxdepth 1 -type f -size 0 -delete 2>/dev/null || true

END=$(date +%s); ELAPSED=$((END-START))
info "done ($ELAPSED s)"
printf '\n'
printf 'lld             : %s\n' "$ROOTFS$STAGE1_PREFIX/bin/ld.lld"
printf 'llvm-ar         : %s\n' "$ROOTFS$STAGE1_PREFIX/bin/llvm-ar"
printf 'llvm-nm         : %s\n' "$ROOTFS$STAGE1_PREFIX/bin/llvm-nm"
printf 'llvm-readobj    : %s\n' "$ROOTFS$STAGE1_PREFIX/bin/llvm-readobj"
printf 'build info      : %s\n' "$BUILD/build-info.txt"
printf 'build logs      : %s\n' "$LOG"
printf 'elapsed         : %s s\n' "$ELAPSED"
