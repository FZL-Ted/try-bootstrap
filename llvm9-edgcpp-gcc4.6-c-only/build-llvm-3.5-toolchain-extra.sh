#!/usr/bin/env bash
# Build a self-contained static clang 3.5 toolchain on top of the existing
# EDG 7.0 -> LLVM/Clang 3.5 build tree.
#
# Components:
#   1. compiler-rt 3.5 builtins (crtbegin/crtend taken from compiler-rt 9.0
#      sources because compiler-rt 3.5 has no crt sources; both built by
#      clang 3.5)
#   2. libunwind 9.0.1 (llvm-project-3.5 has no libunwind/; its bundled
#      libcxxabi/src/Unwind is Darwin-only)
#   3. libc++abi 3.5 (its old private __refstring header is mapped to
#      libc++ 9's src/include/refstring.h; cxa_thread_atexit.cpp added from
#      9.0 because clang 3.5 emits it and musl 1.2.6 does not provide it)
#   4. libc++ 9.0.1 (musl support, _LIBCPPABI_VERSION=1001)
#   5. lld 3.5 (standalone, linked against the existing LLVM 3.5 build)
#   6. musl 1.2.6 rebuilt from the same source with the reference GCC 4.6
#      and -ffunction-sections (lld 3.5 mislinks ordinary multi-function
#      .text sections); Linux UAPI + clang resource headers; all packaged
#      into ./toolchain
#   7. a small static C launcher installed as bin/clang (bin/clang++ symlink)
#      which adds the sysroot/runtime/libc++ flags clang 3.5 cannot default to.
#
# The existing LLVM/Clang 3.5 build is never rebuilt and never modified.
#
# Usage:
#   ./build-llvm-3.5-toolchain-extra.sh
#
# Useful environment variables:
#   JOBS=19                 parallel build jobs (default: nproc)
#   REF=...                 musl reference rootfs (default:
#                           compiler-test/ref-rootfs-gcc4.6-c-only)
#   OUT=...                 work directory (default:
#                           build/llvm3.5-edg7.0-gcc4.6c/toolchain-extra)
#   TC=...                  final toolchain (default:
#                           build/llvm3.5-edg7.0-gcc4.6c/toolchain)
#   STOP_AFTER=all          stop after: preflight|musl|compiler-rt|libunwind|
#                           libcxxabi|libcxx|package|launcher|lld|verify|
#                           build-info|all
#   SKIP_BWRAP=1            skip the bwrap compile/run test
#   TIMEOUT=1800            per-command timeout in seconds
#
# All source trees and the reference rootfs are read-only inputs.  The only
# sources copied and patched are compiler-rt, libcxxabi and lld; the copies
# live under $OUT/src and the patch reasons are recorded in build-info.txt.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
BASE=$ROOT/build/llvm3.5-edg7.0-gcc4.6c
LLVM_BUILD=$BASE/llvm-build
REF=${REF:-$ROOT/compiler-test/ref-rootfs-gcc4.6-c-only}
L35=$ROOT/llvm-project-3.5
L9=$ROOT/llvm-project-9.0
OUT=${OUT:-$BASE/toolchain-extra}
TC=${TC:-$BASE/toolchain}
JOBS=${JOBS:-$(nproc)}
TIMEOUT=${TIMEOUT:-1800}
STOP_AFTER=${STOP_AFTER:-all}
SKIP_BWRAP=${SKIP_BWRAP:-0}

CLANG=$LLVM_BUILD/bin/clang
CLANGXX=$LLVM_BUILD/bin/clang++
LLVM_CONFIG=$LLVM_BUILD/bin/llvm-config
LLVM_CMAKE=$LLVM_BUILD/share/llvm/cmake/LLVMConfig.cmake
SRC=$OUT/src
LOG=$OUT/log
LAUNCHER_DIR=$OUT/launcher
SMOKE=$OUT/smoke
VERIFY=$OUT/verify
TIMINGS=$OUT/timings.txt
MUSL_SRC=$OUT/src/musl
MUSL_BUILD=$OUT/build/musl

CURRENT_STAGE=preflight
CURRENT_LOG=

info()  { printf '[toolchain-extra] %s\n' "$*" >&2; }
warn()  { printf '[toolchain-extra] WARNING: %s\n' "$*" >&2; }
die()   { printf '[toolchain-extra] ERROR: %s\n' "$*" >&2; exit 1; }

catch_err() {
    local rc=$?
    printf '\n[toolchain-extra] FAILED in stage %s (exit %s)\n' \
        "$CURRENT_STAGE" "$rc" >&2
    if [ -n "$CURRENT_LOG" ] && [ -f "$CURRENT_LOG" ]; then
        printf -- '--- tail of %s ---\n' "$CURRENT_LOG" >&2
        tail -n 80 "$CURRENT_LOG" >&2 || true
        printf -- '--- end of log tail ---\n' >&2
    fi
    exit "$rc"
}
trap catch_err ERR

stage_begin() {
    CURRENT_STAGE=$1
    CURRENT_LOG=$LOG/$1.log
    : >"$CURRENT_LOG"
    STAGE_T0=$(date +%s)
    info "=== stage $1 ==="
}

stage_end() {
    local t1 elapsed
    t1=$(date +%s)
    elapsed=$((t1 - STAGE_T0))
    printf '%-24s %6d s\n' "$CURRENT_STAGE" "$elapsed" >>"$TIMINGS"
    info "=== stage $CURRENT_STAGE done in ${elapsed}s ==="
}

stop_after() {
    [ "$STOP_AFTER" = "$1" ] || return 0
    info "STOP_AFTER=$1; stopping"
    printf 'toolchain: %s\n' "$TC"
    exit 0
}

run_log() {
    local logf=$1
    shift
    timeout "$TIMEOUT" "$@" >>"$logf" 2>&1
}

# Same as run_log but for a shell command line (needed for pipelines).
run_shell_log() {
    local logf=$1
    local cmd=$2
    timeout "$TIMEOUT" bash -c "$cmd" >>"$logf" 2>&1
}

safe_recreate_tc() {
    case "$TC" in
        "$BASE"/*) ;;
        *) die "refusing to remove TC outside $BASE: $TC" ;;
    esac
    case "$OUT" in
        "$BASE"/*) ;;
        *) die "refusing to remove OUT outside $BASE: $OUT" ;;
    esac
    rm -rf "$TC"
    rm -rf "$OUT/build"
}

copy_llvm_tools() {
    local b=$TC/bin
    mkdir -p "$b"
    cp -a "$LLVM_BUILD/bin/clang-3.5" "$b/"
    for t in llvm-config llvm-ar llvm-nm llvm-objdump llvm-readobj \
             llvm-size opt llc llvm-link llvm-as llvm-dis; do
        cp -a "$LLVM_BUILD/bin/$t" "$b/"
    done
    ln -sfn llvm-ar "$b/llvm-ranlib"
    # clang/clang++ are the launcher (installed later).
}

# ---------------------------------------------------------------------------
# 0. preflight
# ---------------------------------------------------------------------------
stage_preflight() {
    stage_begin preflight

    [ -x "$CLANG" ]    || die "missing clang: $CLANG"
    [ -x "$CLANGXX" ]  || die "missing clang++: $CLANGXX"
    [ -x "$LLVM_CONFIG" ] || die "missing llvm-config: $LLVM_CONFIG"
    [ -f "$LLVM_CMAKE" ]  || die "missing LLVMConfig.cmake: $LLVM_CMAKE"
    [ -d "$REF/usr/include" ] || die "missing musl headers under $REF/usr/include"
    [ -f "$REF/usr/lib/libc.a" ] || die "missing musl libc.a under $REF/usr/lib"
    [ -d "$L35/compiler-rt/lib/builtins" ] || die "missing compiler-rt 3.5 sources"
    [ -d "$L35/libcxxabi/src" ] || die "missing libcxxabi 3.5 sources"
    [ -d "$L35/lld" ] || die "missing lld 3.5 sources"
    [ -d "$L9/libcxx/src" ] || die "missing libc++ 9 sources"
    [ -d "$L9/libunwind/src" ] || die "missing libunwind 9 sources"
    [ -d "$L9/llvm/cmake/modules" ] || die "missing llvm 9 cmake modules"
    [ -f "$L9/compiler-rt/lib/crt/crtbegin.c" ] || die "missing compiler-rt 9 crt sources"
    [ -d "$L9/libcxxabi/src" ] || die "missing libcxxabi 9 sources"
    [ -d "$ROOT/compiler-test/musl-1.2.6/src" ] || \
        die "missing musl 1.2.6 sources under compiler-test/musl-1.2.6"
    [ -x "$REF/usr/gcc4.6/bin/gcc" ] || \
        die "missing reference GCC 4.6: $REF/usr/gcc4.6/bin/gcc"

    command -v cmake >/dev/null || die "cmake not found"
    command -v ninja >/dev/null || die "ninja not found"
    command -v timeout >/dev/null || die "timeout not found"
    command -v make >/dev/null || die "make not found"
    command -v readelf >/dev/null || die "readelf not found"

    local host_m
    host_m=$(gcc -dumpmachine 2>/dev/null || echo x86_64-linux-gnu)
    [ -d "/usr/include/$host_m/asm" ] || \
        die "missing UAPI asm headers: /usr/include/$host_m/asm"
    [ -d /usr/include/linux ] || die "missing /usr/include/linux"
    [ -d /usr/include/asm-generic ] || die "missing /usr/include/asm-generic"

    info "root          : $ROOT"
    info "existing clang: $("$CLANG" --version 2>&1 | head -n 1)"
    info "llvm build    : $LLVM_BUILD"
    info "musl rootfs   : $REF"
    info "work dir      : $OUT"
    info "toolchain     : $TC"
    info "jobs          : $JOBS"
    info "host triple   : $host_m"

    mkdir -p "$OUT" "$SRC" "$LOG" "$LAUNCHER_DIR" "$SMOKE" "$VERIFY"
    : >"$TIMINGS"

    # Read-only sanity check: clang 3.5 can preprocess musl headers and
    # libc++ 9 headers.
    cat >"$OUT/preflight.c" <<'EOF'
#include <stdio.h>
#include <string.h>
int main(void) { char b[16]; strcpy(b, "ok"); puts(b); return 0; }
EOF
    cat >"$OUT/preflight.cpp" <<'EOF'
#include <iostream>
#include <string>
#include <vector>
#include <thread>
#include <stdexcept>
int main() {
  std::vector<std::string> v{"ok"};
  try { throw std::runtime_error(v[0]); } catch (const std::exception &) {}
  std::cout << v[0] << std::endl;
}
EOF
    run_log "$CURRENT_LOG" "$CLANG" --sysroot="$REF" -c "$OUT/preflight.c" \
        -o "$OUT/preflight.c.o"
    run_log "$CURRENT_LOG" "$CLANGXX" -std=c++14 -nostdinc++ \
        -isystem "$L9/libcxx/include" -D_LIBCPP_HAS_MUSL_LIBC \
        --sysroot="$REF" -c "$OUT/preflight.cpp" -o "$OUT/preflight.cpp.o"
    info "preflight compile checks passed"
    stage_end
    stop_after preflight
}

# ---------------------------------------------------------------------------
# 0b. musl 1.2.6, rebuilt with -ffunction-sections
#
# lld 3.5 mislays out calls between functions that live in the same .text
# section and have no relocation (the reference musl libc.a is built without
# function sections).  Rebuilding the same musl 1.2.6 source with the same
# reference GCC 4.6 and -ffunction-sections makes every local call a
# relocation, which lld 3.5 handles correctly.  Headers still come from the
# reference rootfs (same version).
# ---------------------------------------------------------------------------
stage_musl() {
    stage_begin musl

    rm -rf "$MUSL_SRC" "$MUSL_BUILD"
    cp -a "$ROOT/compiler-test/musl-1.2.6" "$MUSL_SRC"
    mkdir -p "$MUSL_BUILD"
    (
        cd "$MUSL_SRC"
        timeout "$TIMEOUT" env CC="$REF/usr/gcc4.6/bin/gcc" \
            CFLAGS="-O2 -ffunction-sections" \
            ./configure --disable-shared --enable-static \
                --prefix="$MUSL_BUILD" >>"$CURRENT_LOG" 2>&1
        timeout "$TIMEOUT" make -j"$JOBS" >>"$CURRENT_LOG" 2>&1
    )

    for f in libc.a libm.a crt1.o crti.o crtn.o Scrt1.o rcrt1.o; do
        [ -f "$MUSL_SRC/lib/$f" ] || die "musl build did not produce lib/$f"
    done
    # Sanity: function sections must be present, otherwise lld 3.5 will
    # mislink multi-function sections.
    obj=$(find "$MUSL_SRC/obj/src/thread" -name 'pthread_create.o' -print -quit)
    [ -n "$obj" ] || die "cannot find musl pthread_create.o"
    readelf -SW "$obj" | grep -q '\.text\.' || \
        die "musl was not built with -ffunction-sections"
    info "musl 1.2.6 rebuilt with -ffunction-sections: $MUSL_SRC/lib"
    stage_end
    stop_after musl
}

# ---------------------------------------------------------------------------
# 1. compiler-rt 3.5 builtins + crtbegin/crtend (from compiler-rt 9.0 C)
# ---------------------------------------------------------------------------
stage_compiler_rt() {
    stage_begin compiler-rt
    local src=$SRC/compiler-rt
    local bld=$OUT/build/compiler-rt
    local builtins

    rm -rf "$src"
    cp -a "$L35/compiler-rt" "$src"
    # compiler-rt 3.5's standalone test/ dir unconditionally adds lit targets
    # that depend on FileCheck, which the EDG-built LLVM tree does not have.
    # The builtins we need are entirely under lib/builtins.
    perl -0pi -e 's/^add_subdirectory\(test\)/# add_subdirectory(test)/m' \
        "$src/CMakeLists.txt"
    grep -q '^# add_subdirectory(test)' "$src/CMakeLists.txt" || \
        die "failed to disable compiler-rt test/ directory"

    mkdir -p "$bld"
    run_log "$CURRENT_LOG" cmake -S "$src" -B "$bld" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DLLVM_CONFIG_PATH="$LLVM_CONFIG" \
        -DCMAKE_C_COMPILER="$CLANG" \
        -DCMAKE_CXX_COMPILER="$CLANGXX" \
        -DCMAKE_C_FLAGS="--sysroot=$REF -O2 -w -fuse-init-array -ffunction-sections -fdata-sections" \
        -DCMAKE_CXX_FLAGS="--sysroot=$REF -O2 -w -fuse-init-array -ffunction-sections -fdata-sections -nostdinc++ -isystem $L9/libcxx/include -D_LIBCPP_HAS_MUSL_LIBC" \
        -DCOMPILER_RT_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_TESTS=OFF
    run_log "$CURRENT_LOG" ninja -C "$bld" -j"$JOBS" \
        clang_rt.builtins-x86_64

    builtins=$(find "$bld" -name 'libclang_rt.builtins-x86_64.a' -print -quit)
    [ -n "$builtins" ] || die "builtins archive not produced"
    mkdir -p "$TC/lib/clang/3.5.2/lib/linux" "$TC/usr/lib"
    cp -a "$builtins" "$TC/lib/clang/3.5.2/lib/linux/"

    # compiler-rt 3.5 has no crt sources; compiler-rt 9.0's crt is plain C,
    # ABI-compatible, and is compiled here by clang 3.5.
    local crt9=$L9/compiler-rt/lib/crt
    local outdir=$OUT/build/crt
    mkdir -p "$outdir"
    run_log "$CURRENT_LOG" "$CLANG" --sysroot="$REF" -O2 -fPIC \
        -DCRT_HAS_INITFINI_ARRAY -c "$crt9/crtbegin.c" \
        -o "$outdir/crtbegin.o"
    run_log "$CURRENT_LOG" "$CLANG" --sysroot="$REF" -O2 -fPIC \
        -DCRT_HAS_INITFINI_ARRAY -c "$crt9/crtend.c" \
        -o "$outdir/crtend.o"
    cp -a "$outdir/crtbegin.o" "$TC/usr/lib/crtbeginT.o"
    cp -a "$outdir/crtbegin.o" "$TC/usr/lib/crtbegin.o"
    cp -a "$outdir/crtbegin.o" "$TC/usr/lib/crtbeginS.o"
    cp -a "$outdir/crtend.o"   "$TC/usr/lib/crtend.o"
    cp -a "$outdir/crtend.o"   "$TC/usr/lib/crtendS.o"
    cp -a "$outdir/crtbegin.o" "$TC/lib/clang/3.5.2/crtbeginT.o"
    cp -a "$outdir/crtend.o"   "$TC/lib/clang/3.5.2/crtend.o"

    info "builtins: $builtins"
    info "crt: $outdir/{crtbegin,crtend}.o"
    stage_end
    stop_after compiler-rt
}

# ---------------------------------------------------------------------------
# 2. libunwind 9
# ---------------------------------------------------------------------------
stage_libunwind() {
    stage_begin libunwind
    local bld=$OUT/build/libunwind
    local src=$SRC/libunwind
    local a

    # libunwind 9's EHHeaderParser aborts on DW_EH_PE_omit because it masks
    # the encoding with 0x0f before comparing.  lld 3.5 writes a minimal
    # .eh_frame_hdr with fde_count_enc=DW_EH_PE_omit and table_enc=omit, so
    # fall back to the linear .eh_frame scan instead of aborting.
    rm -rf "$src"
    cp -a "$L9/libunwind" "$src"
    perl -0pi -e 's/(if \(!EHHeaderParser<A>::decodeEHHdr\(addressSpace, ehHdrStart, ehHdrEnd,\s*\n\s*hdrInfo\)\)\s*\n\s*return false;)/$1\n\n  \/\/ toolchain-extra: lld 3.5 emits a minimal .eh_frame_hdr (no table).\n  if (hdrInfo.fde_count == 0 || hdrInfo.table_enc == DW_EH_PE_omit)\n    return false;/s' \
        "$src/src/EHHeaderParser.hpp"
    perl -0pi -e 's/size_t EHHeaderParser<A>::getTableEntrySize\(uint8_t tableEnc\) \{\n  switch \(tableEnc & 0x0f\) \{/size_t EHHeaderParser<A>::getTableEntrySize(uint8_t tableEnc) {\n  if (tableEnc == DW_EH_PE_omit)\n    return 0;\n  switch (tableEnc \& 0x0f) {/s' \
        "$src/src/EHHeaderParser.hpp"
    grep -q 'lld 3.5 emits a minimal' "$src/src/EHHeaderParser.hpp" || \
        die "failed to patch libunwind EHHeaderParser (minimal header)"
    grep -q 'if (tableEnc == DW_EH_PE_omit)' "$src/src/EHHeaderParser.hpp" || \
        die "failed to patch libunwind EHHeaderParser (omit size)"

    mkdir -p "$bld"
    run_log "$CURRENT_LOG" cmake -S "$src" -B "$bld" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DLLVM_CONFIG_PATH="$LLVM_CONFIG" \
        -DCMAKE_C_COMPILER="$CLANG" \
        -DCMAKE_CXX_COMPILER="$CLANGXX" \
        -DCMAKE_C_FLAGS="--sysroot=$REF -O2 -w -fuse-init-array -ffunction-sections -fdata-sections" \
        -DCMAKE_CXX_FLAGS="--sysroot=$REF -O2 -w -fuse-init-array -ffunction-sections -fdata-sections -nostdinc++ -isystem $L9/libcxx/include -D_LIBCPP_HAS_MUSL_LIBC" \
        -DLIBUNWIND_ENABLE_SHARED=OFF \
        -DLIBUNWIND_ENABLE_STATIC=ON \
        -DLLVM_INCLUDE_TESTS=OFF
    run_log "$CURRENT_LOG" ninja -C "$bld" -j"$JOBS" unwind_static

    a=$(find "$bld" -name 'libunwind.a' -print -quit)
    [ -n "$a" ] || die "libunwind.a not produced"
    cp -a "$a" "$TC/lib/"
    mkdir -p "$TC/include"
    cp -a "$L9/libunwind/include/unwind.h" \
          "$L9/libunwind/include/libunwind.h" \
          "$L9/libunwind/include/__libunwind_config.h" \
          "$TC/include/"
    info "libunwind.a: $a"
    stage_end
    stop_after libunwind
}

# ---------------------------------------------------------------------------
# 3. libc++abi 3.5 (patched copy)
# ---------------------------------------------------------------------------
stage_libcxxabi() {
    stage_begin libcxxabi
    local src=$SRC/libcxxabi
    local bld=$OUT/build/libcxxabi
    local a

    rm -rf "$src"
    cp -a "$L35/libcxxabi" "$src"
    # libc++abi 3.5's stdexcept.cpp includes the old private "__refstring"
    # header, which libc++ 9 renamed to src/include/refstring.h.  Provide a
    # one-line compatibility header; refstring.h's members are inline.
    cat >"$src/src/__refstring" <<'REFSTRING_EOF'
/* toolchain-extra: libc++abi 3.5 expected libc++ 3.5's private "__refstring";
   libc++ 9 moved it to src/include/refstring.h. */
#include "include/refstring.h"
REFSTRING_EOF
    # clang 3.5 emits __cxa_thread_atexit for thread_local objects with
    # non-trivial destructors; libc++abi 3.5 and musl 1.2.6 do not provide it.
    # Add the libc++abi 9.0 implementation, compiled by clang 3.5.
    cp -a "$L9/libcxxabi/src/cxa_thread_atexit.cpp" "$src/src/"
    # The 9.0 TU uses libc++abi 9 visibility macros that libc++abi 3.5 does
    # not define.  Define the two it needs at the top of the copied TU rather
    # than passing parentheses/quotes through CMAKE_CXX_FLAGS (which CMake
    # would hand to /bin/sh unquoted).
    perl -0pi -e 's/\A/\/* toolchain-extra: libc++abi 3.5 compatibility macros *\/\n#ifndef _LIBCXXABI_WEAK\n#define _LIBCXXABI_WEAK __attribute__((weak))\n#endif\n#ifndef _LIBCXXABI_FUNC_VIS\n#define _LIBCXXABI_FUNC_VIS __attribute__((visibility("default")))\n#endif\n/' \
        "$src/src/cxa_thread_atexit.cpp"
    perl -0pi -e 's/^  cxa_guard\.cpp\n/  cxa_guard.cpp\n  cxa_thread_atexit.cpp\n/m' \
        "$src/src/CMakeLists.txt"
    grep -q 'cxa_thread_atexit.cpp' "$src/src/CMakeLists.txt" || \
        die "failed to add cxa_thread_atexit.cpp to libcxxabi sources"

    mkdir -p "$bld"
    run_log "$CURRENT_LOG" cmake -S "$src" -B "$bld" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DLLVM_CONFIG="$LLVM_CONFIG" \
        -DCMAKE_C_COMPILER="$CLANG" \
        -DCMAKE_CXX_COMPILER="$CLANGXX" \
        -DCMAKE_C_FLAGS="--sysroot=$REF -O2 -w -fuse-init-array -ffunction-sections -fdata-sections" \
        -DCMAKE_CXX_FLAGS="--sysroot=$REF -O2 -w -fuse-init-array -ffunction-sections -fdata-sections -nostdinc++ -isystem $L9/libcxx/include -I$L9/libcxx/src -I$L9/libcxx/src/include -D_LIBCPP_HAS_MUSL_LIBC -DLIBCXXABI_BUILDING_LIBRARY" \
        -DLIBCXXABI_ENABLE_SHARED=OFF \
        -DLIBCXXABI_ENABLE_ASSERTIONS=OFF \
        -DLIBCXXABI_ENABLE_PEDANTIC=OFF \
        -DLIBCXXABI_ENABLE_WERROR=OFF \
        -DLIBCXXABI_USE_LLVM_UNWINDER=OFF \
        -DLIBCXXABI_LIBCXX_INCLUDES="$L9/libcxx/include" \
        -DLLVM_INCLUDE_TESTS=OFF
    run_log "$CURRENT_LOG" ninja -C "$bld" -j"$JOBS" cxxabi

    a=$(find "$bld" -name 'libc++abi.a' -print -quit)
    [ -n "$a" ] || die "libc++abi.a not produced"
    cp -a "$a" "$TC/lib/"
    mkdir -p "$TC/include" "$TC/include/c++/v1"
    cp -a "$src/include/cxxabi.h" "$TC/include/"
    cp -a "$src/include/cxxabi.h" "$TC/include/c++/v1/"
    cp -a "$src/include/unwind.h" "$TC/include/c++/v1/" 2>/dev/null || true
    info "libc++abi.a: $a"
    stage_end
    stop_after libcxxabi
}

# ---------------------------------------------------------------------------
# 4. libc++ 9
# ---------------------------------------------------------------------------
stage_libcxx() {
    stage_begin libcxx
    local bld=$OUT/build/libcxx
    local a

    mkdir -p "$bld"
    run_log "$CURRENT_LOG" cmake -S "$L9/libcxx" -B "$bld" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DLLVM_PATH="$L9/llvm" \
        -DCMAKE_INSTALL_PREFIX="$TC" \
        -DCMAKE_C_COMPILER="$CLANG" \
        -DCMAKE_CXX_COMPILER="$CLANGXX" \
        -DCMAKE_C_FLAGS="--sysroot=$REF -O2 -w -fuse-init-array -ffunction-sections -fdata-sections" \
        -DCMAKE_CXX_FLAGS="--sysroot=$REF -O2 -w -fuse-init-array -ffunction-sections -fdata-sections -nostdinc++ -isystem $L9/libcxx/include -isystem $L35/libcxxabi/include -D_LIBCPP_HAS_MUSL_LIBC -D_LIBCPPABI_VERSION=1001" \
        -DLIBCXX_ENABLE_SHARED=OFF \
        -DLIBCXX_ENABLE_STATIC=ON \
        -DLIBCXX_ENABLE_ASSERTIONS=OFF \
        -DLIBCXX_HAS_MUSL_LIBC=ON \
        -DLIBCXX_CXX_ABI=libcxxabi \
        -DLIBCXX_CXX_ABI_INCLUDE_PATHS="$L35/libcxxabi/include" \
        -DLIBCXX_ENABLE_FILESYSTEM=OFF \
        -DLIBCXX_ENABLE_EXPERIMENTAL_LIBRARY=OFF \
        -DLIBCXX_INCLUDE_BENCHMARKS=OFF \
        -DLIBCXX_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_TESTS=OFF
    run_log "$CURRENT_LOG" ninja -C "$bld" -j"$JOBS" cxx cxx-generated-config
    run_log "$CURRENT_LOG" cmake --install "$bld"

    a=$(find "$bld" -name 'libc++.a' -print -quit)
    [ -n "$a" ] || die "libc++.a not produced"
    cp -a "$a" "$TC/lib/libc++.a"
    [ -d "$TC/include/c++/v1" ] || die "libc++ headers were not installed"
    info "libc++.a: $a"
    stage_end
    stop_after libcxx
}

# ---------------------------------------------------------------------------
# 5. package: clang tools, musl, UAPI, empty archives, libcompat
# ---------------------------------------------------------------------------
stage_package() {
    stage_begin package
    local host_m
    host_m=$(gcc -dumpmachine 2>/dev/null || echo x86_64-linux-gnu)

    mkdir -p "$TC/bin" "$TC/lib" "$TC/include" "$TC/include/c++/v1" \
             "$TC/usr/include" "$TC/usr/lib" "$TC/share"

    copy_llvm_tools
    # Merge the clang resource directory (builtin headers) into the resource
    # directory already populated by the compiler-rt stage.  Do not copy the
    # directory as a whole: $TC/lib/clang already exists and cp would nest it.
    mkdir -p "$TC/lib/clang/3.5.2"
    cp -a "$LLVM_BUILD/lib/clang/3.5.2/." "$TC/lib/clang/3.5.2/"
    [ -f "$TC/lib/clang/3.5.2/lib/linux/libclang_rt.builtins-x86_64.a" ] || \
        die "compiler-rt builtins missing from the resource directory"

    # musl headers and static libraries (dereference the rootfs symlinks).
    cp -aL "$REF/usr/include/." "$TC/usr/include/"
    cp -aL "$MUSL_SRC/lib/libc.a" \
            "$MUSL_SRC/lib/libm.a" \
            "$MUSL_SRC/lib/crt1.o" \
            "$MUSL_SRC/lib/crti.o" \
            "$MUSL_SRC/lib/crtn.o" \
            "$MUSL_SRC/lib/Scrt1.o" \
            "$MUSL_SRC/lib/rcrt1.o" \
            "$TC/usr/lib/"

    # Linux UAPI headers.
    cp -a /usr/include/linux "$TC/usr/include/"
    cp -a /usr/include/asm-generic "$TC/usr/include/"
    mkdir -p "$TC/usr/include/$host_m"
    cp -a "/usr/include/$host_m/asm" "$TC/usr/include/$host_m/"
    ln -sfn "$host_m/asm" "$TC/usr/include/asm"
    if [ -d /usr/lib/linux ]; then
        cp -a /usr/lib/linux "$TC/usr/lib/"
    fi

    # Empty archives for libraries provided by musl's libc.a.
    for l in libgcc_s libgcc_eh libdl librt libcrypt libutil libxnet libpthread; do
        "$LLVM_BUILD/bin/llvm-ar" rc "$TC/usr/lib/$l.a"
    done
    cp -a "$TC/lib/clang/3.5.2/lib/linux/libclang_rt.builtins-x86_64.a" \
          "$TC/usr/lib/libgcc.a"
    cp -a "$BASE/compat/libcompat.a" "$TC/lib/"

    # C++ runtime libraries and headers built above.
    cp -a "$OUT/build/libunwind/$(find "$OUT/build/libunwind" \
          -name 'libunwind.a' -printf '%P\n' -quit)" "$TC/lib/libunwind.a"
    cp -a "$OUT/build/libcxxabi/$(find "$OUT/build/libcxxabi" \
          -name 'libc++abi.a' -printf '%P\n' -quit)" "$TC/lib/libc++abi.a"
    cp -a "$OUT/build/libcxx/$(find "$OUT/build/libcxx" \
          -name 'libc++.a' -printf '%P\n' -quit)" "$TC/lib/libc++.a"
    cp -a "$L9/libunwind/include/unwind.h" \
          "$L9/libunwind/include/libunwind.h" \
          "$L9/libunwind/include/__libunwind_config.h" \
          "$TC/include/"
    cp -a "$L35/libcxxabi/include/cxxabi.h" "$TC/include/" 2>/dev/null || \
        cp -a "$SRC/libcxxabi/include/cxxabi.h" "$TC/include/"
    cp -a "$TC/include/cxxabi.h" "$TC/include/c++/v1/cxxabi.h"

    info "packaged clang tools, musl, UAPI, runtime libraries"
    stage_end
    stop_after package
}

# ---------------------------------------------------------------------------
# 6. static C launcher (bin/clang + bin/clang++ symlink)
# ---------------------------------------------------------------------------
stage_launcher() {
    stage_begin launcher
    mkdir -p "$TC/bin" "$TC/share"

    cat >"$LAUNCHER_DIR/clang-launcher.c" <<'LAUNCHER_EOF'
/*
 * clang 3.5 toolchain launcher.
 *
 * clang 3.5 defaults to libstdc++, does not add libc++abi/libunwind, and its
 * driver adds -lc++ after all user arguments, so a plain clang++ cannot link
 * this toolchain's static C++ runtime in the required order.  This launcher
 * computes the toolchain root from its own path and adds the missing flags.
 * It is a static C program, so the toolchain stays usable in a bwrap sandbox
 * that only mounts the toolchain (no /bin/sh required).
 */
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

static char tc[PATH_MAX];
static char flag_sysroot[PATH_MAX];
static char flag_Bbin[PATH_MAX];
static char flag_Busrlib[PATH_MAX];
static char flag_Llib[PATH_MAX];
static char flag_Lusrlib[PATH_MAX];
static char flag_Lrt[PATH_MAX];
static char flag_clang[PATH_MAX];

static int streq(const char *a, const char *b) { return strcmp(a, b) == 0; }

static int ends_with(const char *s, const char *suffix) {
    size_t n = strlen(s), m = strlen(suffix);
    return n >= m && strcmp(s + n - m, suffix) == 0;
}

static int starts_with(const char *s, const char *prefix) {
    return strncmp(s, prefix, strlen(prefix)) == 0;
}

static void strip_last(char *p) {
    char *slash = strrchr(p, '/');
    if (!slash) {
        fprintf(stderr, "clang-launcher: cannot determine toolchain root from '%s'\n", p);
        exit(127);
    }
    *slash = '\0';
}

static void get_exe(char *out, size_t outsz, const char *argv0) {
    ssize_t n = readlink("/proc/self/exe", out, outsz - 1);
    if (n > 0) {
        out[n] = '\0';
        return;
    }
    if (!realpath(argv0, out)) {
        fprintf(stderr, "clang-launcher: cannot resolve '%s': %s\n",
                argv0, strerror(errno));
        exit(127);
    }
}

static int is_cxx_name(const char *argv0) {
    const char *base = strrchr(argv0, '/');
    base = base ? base + 1 : argv0;
    return strstr(base, "++") != NULL;
}

static int is_compile_only(int argc, char **argv) {
    int i;
    for (i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (streq(a, "-c") || streq(a, "-S") || streq(a, "-E") ||
            streq(a, "-fsyntax-only") || streq(a, "-M") || streq(a, "-MM") ||
            streq(a, "-MD") || streq(a, "-MMD") || streq(a, "-MG") ||
            streq(a, "-MP") || streq(a, "-emit-llvm") ||
            streq(a, "-emit-ast"))
            return 1;
    }
    return 0;
}

static int is_info_only(int argc, char **argv) {
    int i;
    for (i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (streq(a, "--version") || streq(a, "-dumpmachine") ||
            streq(a, "--help") || streq(a, "-help") ||
            starts_with(a, "-print-"))
            return 1;
    }
    return 0;
}

static int has_shared(int argc, char **argv) {
    int i;
    for (i = 1; i < argc; i++) {
        if (streq(argv[i], "-shared") || streq(argv[i], "-r") ||
            streq(argv[i], "--shared") || streq(argv[i], "-Bshareable"))
            return 1;
    }
    return 0;
}

int main(int argc, char **argv) {
    char exe[PATH_MAX];
    char ld_lld[PATH_MAX];
    char **nargv;
    int nargc = 0, i;
    int cxx, link, info, shared;

    get_exe(exe, sizeof(exe), argv[0]);
    snprintf(tc, sizeof(tc), "%s", exe);
    strip_last(tc);   /* .../bin/clang -> .../bin */
    strip_last(tc);   /* .../bin      -> ...     */

    snprintf(flag_clang, sizeof(flag_clang), "%s/bin/clang-3.5", tc);
    if (access(flag_clang, X_OK) != 0) {
        fprintf(stderr, "clang-launcher: missing compiler: %s\n", flag_clang);
        return 127;
    }

    cxx = is_cxx_name(argv[0]);
    info = is_info_only(argc, argv);
    link = !is_compile_only(argc, argv) && !info;
    shared = has_shared(argc, argv);

    snprintf(flag_sysroot, sizeof(flag_sysroot), "--sysroot=%s", tc);
    snprintf(flag_Bbin, sizeof(flag_Bbin), "-B%s/bin", tc);
    snprintf(flag_Busrlib, sizeof(flag_Busrlib), "-B%s/usr/lib", tc);
    snprintf(flag_Llib, sizeof(flag_Llib), "-L%s/lib", tc);
    snprintf(flag_Lusrlib, sizeof(flag_Lusrlib), "-L%s/usr/lib", tc);
    snprintf(flag_Lrt, sizeof(flag_Lrt),
             "-L%s/lib/clang/3.5.2/lib/linux", tc);
    snprintf(ld_lld, sizeof(ld_lld), "%s/bin/ld.lld", tc);

    nargv = (char **)calloc((size_t)argc + 40, sizeof(char *));
    if (!nargv) {
        fprintf(stderr, "clang-launcher: out of memory\n");
        return 127;
    }

    nargv[nargc++] = flag_clang;
    nargv[nargc++] = flag_sysroot;
    nargv[nargc++] = flag_Bbin;
    nargv[nargc++] = flag_Busrlib;
    /* The C++ link supplies the compiler-rt builtins explicitly (with
       -nodefaultlibs); only C links need the driver -rtlib selection. */
    if (!cxx)
        nargv[nargc++] = "-rtlib=compiler-rt";
    /* lld 3.5 does not merge .ctors into .init_array; make clang 3.5 emit
       .init_array/.fini_array for all objects, including user code and the
       runtime libraries built below. */
    nargv[nargc++] = "-fuse-init-array";
    nargv[nargc++] = "-ffunction-sections";
    nargv[nargc++] = "-fdata-sections";
    if (access(ld_lld, X_OK) == 0)
        nargv[nargc++] = "-fuse-ld=lld";
    if (cxx) {
        nargv[nargc++] = "-stdlib=libc++";
        nargv[nargc++] = "-std=c++14";
        nargv[nargc++] = "-D_LIBCPP_HAS_MUSL_LIBC";
    }
    if (link) {
        nargv[nargc++] = flag_Llib;
        nargv[nargc++] = flag_Lusrlib;
        nargv[nargc++] = flag_Lrt;
        if (!shared)
            nargv[nargc++] = "-static";
        if (cxx)
            nargv[nargc++] = "-nodefaultlibs";
    }
    for (i = 1; i < argc; i++)
        nargv[nargc++] = argv[i];
    if (link) {
        if (cxx) {
            /* libunwind finds FDEs through PT_GNU_EH_FRAME; force the EH
               header and pull the weak-referenced registration function so
               crtbegin's .eh_frame list is registered too. */
            nargv[nargc++] = "-Wl,--eh-frame-hdr";
            nargv[nargc++] = "-Wl,-u,__register_frame_info";
            nargv[nargc++] = "-Wl,--start-group";
            nargv[nargc++] = "-lc++";
            nargv[nargc++] = "-lc++abi";
            nargv[nargc++] = "-lunwind";
            nargv[nargc++] = "-lclang_rt.builtins-x86_64";
            nargv[nargc++] = "-lcompat";
            nargv[nargc++] = "-lm";
            nargv[nargc++] = "-lpthread";
            nargv[nargc++] = "-ldl";
            nargv[nargc++] = "-lrt";
            nargv[nargc++] = "-lc";
            nargv[nargc++] = "-Wl,--end-group";
        } else {
            nargv[nargc++] = "-lcompat";
        }
    }
    nargv[nargc] = NULL;

    execv(flag_clang, nargv);
    fprintf(stderr, "clang-launcher: execv %s failed: %s\n",
            flag_clang, strerror(errno));
    return 127;
}
LAUNCHER_EOF

    # Build the launcher with the real clang 3.5 and the freshly packaged
    # musl/crt/builtins.  No C++ runtime is involved.
    run_log "$CURRENT_LOG" "$CLANG" -static --sysroot="$TC" \
        -resource-dir="$TC/lib/clang/3.5.2" -B"$TC/usr/lib" \
        -rtlib=compiler-rt -O2 -ffunction-sections -fdata-sections \
        -o "$TC/bin/clang" "$LAUNCHER_DIR/clang-launcher.c"
    chmod +x "$TC/bin/clang"
    ln -sfn clang "$TC/bin/clang++"
    cp -a "$LAUNCHER_DIR/clang-launcher.c" "$TC/share/clang-launcher.c"

    "$TC/bin/clang" --version >/dev/null 2>&1 || \
        die "launcher failed to run"
    info "launcher installed as $TC/bin/clang (clang++ symlink)"
    stage_end
    stop_after launcher
}

# ---------------------------------------------------------------------------
# 7. lld 3.5 (standalone, existing LLVM 3.5 build tree)
# ---------------------------------------------------------------------------
stage_lld() {
    stage_begin lld
    local src=$SRC/lld
    local bld=$OUT/build/lld
    local lld

    rm -rf "$src"
    cp -a "$L35/lld" "$src"
    # Only lib/ and tools/ are needed.  The test utils require FileCheck and
    # lit variables that the EDG-built LLVM tree does not provide.
    perl -0pi -e 's/^add_subdirectory\(test\)/# add_subdirectory(test)/m; s/^add_subdirectory\(utils\)/# add_subdirectory(utils)/m; s/^add_subdirectory\(docs\)/# add_subdirectory(docs)/m' \
        "$src/CMakeLists.txt"
    grep -q '^# add_subdirectory(test)' "$src/CMakeLists.txt" || \
        die "failed to disable lld test/ directory"
    grep -q '^# add_subdirectory(utils)' "$src/CMakeLists.txt" || \
        die "failed to disable lld utils/ directory"

    mkdir -p "$bld/bin" "$bld/lib"
    run_log "$CURRENT_LOG" cmake -S "$src" -B "$bld" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DCMAKE_C_COMPILER="$TC/bin/clang" \
        -DCMAKE_CXX_COMPILER="$TC/bin/clang++" \
        -DCMAKE_C_FLAGS="-O2 -w -fuse-init-array -ffunction-sections -fdata-sections" \
        -DCMAKE_CXX_FLAGS="-std=c++1y -O2 -w -fuse-init-array -ffunction-sections -fdata-sections" \
        -DLLD_PATH_TO_LLVM_SOURCE="$L35/llvm" \
        -DLLD_PATH_TO_LLVM_BUILD="$LLVM_BUILD" \
        -DLLVM_RUNTIME_OUTPUT_INTDIR="$bld/bin" \
        -DLLVM_LIBRARY_OUTPUT_INTDIR="$bld/lib" \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_DOCS=OFF
    run_log "$CURRENT_LOG" ninja -C "$bld" -j"$JOBS" lld

    lld=$(find "$bld" -name lld -type f -perm -u+x -print -quit)
    [ -n "$lld" ] || lld="$bld/bin/lld"
    [ -x "$lld" ] || die "lld binary not produced"
    cp -a "$lld" "$TC/bin/lld"
    chmod +x "$TC/bin/lld"
    ln -sfn lld "$TC/bin/ld.lld"

    [ -x "$TC/bin/ld.lld" ] || die "ld.lld not executable"
    # lld 3.5 predates the --version option; use the object .comment and the
    # real link performed in the verify stage as evidence instead.
    readelf -p .comment "$TC/bin/lld" 2>/dev/null | \
        grep -q 'clang version 3.5' || \
        die "lld was not built by clang 3.5"
    info "lld installed: lld 3.5.2 (no --version option in lld 3.5)"
    stage_end
    stop_after lld
}

# ---------------------------------------------------------------------------
# 8. verification
# ---------------------------------------------------------------------------
verify_static_binary() {
    local f=$1
    if ! file "$f" | grep -q 'statically linked'; then
        info "FAIL: $f is not statically linked"
        file "$f" >>"$VERIFY/results.txt" 2>&1 || true
        return 1
    fi
    if readelf -d "$f" 2>/dev/null | grep -q NEEDED; then
        info "FAIL: $f has NEEDED entries"
        readelf -d "$f" >>"$VERIFY/results.txt" 2>&1 || true
        return 1
    fi
    return 0
}

verify_archive_provenance() {
    local ar=$1 name
    local tmp
    tmp=$(mktemp -d)
    name=$(basename "$ar")
    ( cd "$tmp" && "$TC/bin/llvm-ar" x "$ar" ) || {
        rm -rf "$tmp"; die "cannot extract $ar"
    }
    local obj comments bad=0 seen=0
    for obj in "$tmp"/*.o; do
        [ -f "$obj" ] || continue
        comments=$(readelf -p .comment "$obj" 2>/dev/null || true)
        [ -n "$comments" ] || continue
        seen=$((seen + 1))
        if printf '%s' "$comments" | grep -qiE 'GCC|EDG'; then
            printf 'provenance: %s contains non-clang producer in %s\n' \
                "$name" "$(basename "$obj")" >>"$VERIFY/results.txt"
            bad=1
        elif ! printf '%s' "$comments" | grep -q 'clang version 3.5'; then
            printf 'provenance: %s has unexpected producer in %s\n' \
                "$name" "$(basename "$obj")" >>"$VERIFY/results.txt"
            bad=1
        fi
    done
    rm -rf "$tmp"
    if [ "$seen" -eq 0 ]; then
        printf 'provenance: %s has no .comment objects (assembly-only?)\n' \
            "$name" >>"$VERIFY/results.txt"
    fi
    if [ "$bad" -ne 0 ]; then
        die "archive provenance check failed for $name (see $VERIFY/results.txt)"
    fi
    printf 'provenance: %s OK (%d objects with clang 3.5 .comment)\n' \
        "$name" "$seen" >>"$VERIFY/results.txt"
}

stage_verify() {
    stage_begin verify
    : >"$VERIFY/results.txt"

    cat >"$SMOKE/c.c" <<'EOF'
#include <stdio.h>
#include <string.h>
int main(void) {
    char buf[32];
    strcpy(buf, "clang35-musl-c");
    printf("%s %d\n", buf, 42);
    return 0;
}
EOF

    cat >"$SMOKE/cxx.cpp" <<'EOF'
#include <iostream>
#include <string>
#include <vector>
#include <thread>
#include <stdexcept>
#include <exception>

static void check(bool cond, const char *msg) {
    if (!cond) { std::cerr << "FAIL: " << msg << std::endl; std::exit(1); }
}

int main() {
    int caught = 0;
    try {
        throw std::runtime_error("boom");
    } catch (const std::runtime_error &e) {
        caught = 1;
        check(std::string(e.what()) == "boom", "runtime_error::what");
        std::exception_ptr p = std::current_exception();
        check(p != nullptr, "current_exception");
        try { std::rethrow_exception(p); }
        catch (const std::runtime_error &) { caught = 2; }
    }
    check(caught == 2, "exception_ptr round trip");

    int n = 0;
    std::thread t([&] { n = 7; });
    t.join();
    check(n == 7, "std::thread");

    std::vector<std::string> v{"hello", "musl", "c++"};
    std::string s;
    for (const auto &x : v) s += x + " ";
    std::cout << s << "thread=" << n << " caught=" << caught << std::endl;
    return 0;
}
EOF

    # C
    if ! run_log "$CURRENT_LOG" "$TC/bin/clang" -static -O2 \
            "$SMOKE/c.c" -o "$SMOKE/c"; then
        die "C compile failed"
    fi
    timeout 60 "$SMOKE/c" >>"$VERIFY/results.txt" 2>&1 || die "C program failed"
    verify_static_binary "$SMOKE/c" || die "C static check failed"
    printf 'C: static ok\n' >>"$VERIFY/results.txt"

    # C++
    if ! run_log "$CURRENT_LOG" "$TC/bin/clang++" -static -std=c++14 -O2 \
            "$SMOKE/cxx.cpp" -o "$SMOKE/cxx"; then
        die "C++ compile failed"
    fi
    timeout 60 "$SMOKE/cxx" >"$VERIFY/cxx.out" 2>&1 || die "C++ program failed"
    cat "$VERIFY/cxx.out" >>"$VERIFY/results.txt"
    verify_static_binary "$SMOKE/cxx" || die "C++ static check failed"
    printf 'C++: static ok\n' >>"$VERIFY/results.txt"

    # ld.lld must be the linker.
    "$TC/bin/clang++" -### -static -std=c++14 "$SMOKE/cxx.cpp" \
        -o "$SMOKE/cxx.dry" >"$VERIFY/linkline.txt" 2>&1 || true
    if ! grep -qF "$TC/bin/ld.lld" "$VERIFY/linkline.txt"; then
        cat "$VERIFY/linkline.txt" >>"$VERIFY/results.txt"
        die "link line does not use $TC/bin/ld.lld"
    fi
    printf 'lld: lld 3.5.2 (ld.lld; lld 3.5 has no --version option)\n' \
        >>"$VERIFY/results.txt"
    printf 'lld .comment: %s\n' \
        "$(readelf -p .comment "$TC/bin/lld" 2>/dev/null | grep -o 'clang version 3.5[^ ]*' | head -n 1)" \
        >>"$VERIFY/results.txt"
    printf 'link line: %s\n' \
        "$(grep -oF "$TC/bin/ld.lld" "$VERIFY/linkline.txt" | head -n 1)" \
        >>"$VERIFY/results.txt"

    # Archive provenance.
    verify_archive_provenance "$TC/lib/libc++.a"
    verify_archive_provenance "$TC/lib/libc++abi.a"
    verify_archive_provenance "$TC/lib/libunwind.a"

    # Optional thread_local link/run check (exercises __cxa_thread_atexit).
    cat >"$SMOKE/tls.cpp" <<'EOF'
#include <string>
#include <cstdio>
thread_local std::string tls("tls");
int main() { tls += "-ok"; std::printf("%s\n", tls.c_str()); return 0; }
EOF
    if run_log "$CURRENT_LOG" "$TC/bin/clang++" -static -std=c++14 \
            "$SMOKE/tls.cpp" -o "$SMOKE/tls"; then
        if timeout 60 "$SMOKE/tls" >>"$VERIFY/results.txt" 2>&1; then
            printf 'thread_local: ok\n' >>"$VERIFY/results.txt"
        else
            printf 'thread_local: run failed\n' >>"$VERIFY/results.txt"
        fi
    else
        printf 'thread_local: compile/link failed (not fatal)\n' \
            >>"$VERIFY/results.txt"
    fi

    # bwrap: only the toolchain is mounted.
    if [ "$SKIP_BWRAP" = "1" ]; then
        printf 'bwrap: skipped (SKIP_BWRAP=1)\n' >>"$VERIFY/results.txt"
    elif command -v bwrap >/dev/null; then
        timeout "$TIMEOUT" bwrap --unshare-pid --die-with-parent --tmpfs / \
            --ro-bind "$TC" /tc --bind "$SMOKE" /work \
            --dev /dev --proc /proc --tmpfs /tmp \
            /tc/bin/clang++ -static -std=c++14 /work/cxx.cpp \
            -o /work/cxx_bwrap >>"$VERIFY/results.txt" 2>&1 || \
            die "bwrap C++ compile failed"
        timeout "$TIMEOUT" bwrap --unshare-pid --die-with-parent --tmpfs / \
            --ro-bind "$SMOKE/cxx_bwrap" /cxx --dev /dev --proc /proc \
            /cxx >"$VERIFY/bwrap-cxx.out" 2>&1 || \
            die "bwrap C++ run failed"
        cat "$VERIFY/bwrap-cxx.out" >>"$VERIFY/results.txt"

        timeout "$TIMEOUT" bwrap --unshare-pid --die-with-parent --tmpfs / \
            --ro-bind "$TC" /tc --bind "$SMOKE" /work \
            --dev /dev --proc /proc --tmpfs /tmp \
            /tc/bin/clang -static /work/c.c -o /work/c_bwrap \
            >>"$VERIFY/results.txt" 2>&1 || die "bwrap C compile failed"
        timeout "$TIMEOUT" bwrap --unshare-pid --die-with-parent --tmpfs / \
            --ro-bind "$SMOKE/c_bwrap" /c --dev /dev --proc /proc \
            /c >"$VERIFY/bwrap-c.out" 2>&1 || die "bwrap C run failed"
        cat "$VERIFY/bwrap-c.out" >>"$VERIFY/results.txt"
        printf 'bwrap: compile+run ok (only /tc mounted)\n' \
            >>"$VERIFY/results.txt"
    else
        warn "bwrap not found; bwrap verification skipped"
        printf 'bwrap: not available\n' >>"$VERIFY/results.txt"
    fi

    info "verification passed"
    stage_end
    stop_after verify
}

# ---------------------------------------------------------------------------
# 9. build-info + timings
# ---------------------------------------------------------------------------
stage_build_info() {
    stage_begin build-info
    local cc_ver lld_ver musl_ver host_kernel
    cc_ver=$("$TC/bin/clang-3.5" --version 2>&1 | head -n 1)
    lld_ver="lld 3.5.2 (llvm-project-3.5/lld; lld 3.5 has no --version option)"
    musl_ver=$(cat "$ROOT/compiler-test/musl-1.2.6/VERSION" 2>/dev/null || echo unknown)
    host_kernel=$(uname -r)
    local host_m
    host_m=$(gcc -dumpmachine 2>/dev/null || echo x86_64-linux-gnu)

    {
        echo "clang 3.5 static musl toolchain"
        echo "date (UTC)     : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "existing build : $BASE (clang/LLVM not rebuilt)"
        echo "work dir       : $OUT"
        echo "toolchain      : $TC"
        echo
        echo "components:"
        echo "  clang        : $cc_ver"
        echo "                 reused from $LLVM_BUILD/bin/clang-3.5"
        echo "  lld          : $lld_ver"
        echo "                 llvm-project-3.5/lld standalone, built by clang 3.5"
        echo "  libc++       : 9.0.1 (llvm-project-9.0/libcxx; _LIBCPP_HAS_MUSL_LIBC, _LIBCPPABI_VERSION=1001)"
        echo "  libc++abi    : 3.5.2 (llvm-project-3.5/libcxxabi; __refstring"
        echo "                 compatibility header maps to libc++ 9 refstring.h;"
        echo "                 cxa_thread_atexit.cpp from libc++abi 9.0 added)"
        echo "  libunwind    : 9.0.1 (llvm-project-9.0/libunwind; 3.5 tree has no libunwind/)"
        echo "  compiler-rt  : builtins 3.5.2; crtbegin/crtend from compiler-rt 9.0 C sources"
        echo "                 (compiler-rt 3.5 has no crt sources), all built by clang 3.5"
        echo "  musl         : $musl_ver (rebuilt from compiler-test/musl-1.2.6"
        echo "                 with the reference GCC 4.6 and -ffunction-sections;"
        echo "                 required by lld 3.5 for multi-function .text sections)"
        echo "  Linux UAPI   : host $host_kernel ($host_m)"
        echo
        echo "toolchain layout:"
        ( cd "$TC" && find bin lib include usr -maxdepth 3 \
            \( -type f -o -type l \) -printf '  %p\n' | sort ) 2>/dev/null || true
        echo
        echo "key cmake options:"
        echo "  common        : -G Ninja -DCMAKE_BUILD_TYPE=Release"
        echo "                  -DCMAKE_POLICY_VERSION_MINIMUM=3.5"
        echo "                  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY"
        echo "  compiler-rt   : -DLLVM_CONFIG_PATH=$LLVM_CONFIG"
        echo "                  -DCOMPILER_RT_INCLUDE_TESTS=OFF"
        echo "                  target clang_rt.builtins-x86_64"
        echo "  libunwind     : -DLIBUNWIND_ENABLE_SHARED=OFF -DLIBUNWIND_ENABLE_STATIC=ON"
        echo "  libc++abi     : -DLIBCXXABI_ENABLE_SHARED=OFF -DLIBCXXABI_USE_LLVM_UNWINDER=OFF"
        echo "                  -DLIBCXXABI_LIBCXX_INCLUDES=$L9/libcxx/include"
        echo "  libc++        : -DLLVM_PATH=$L9/llvm"
        echo "                  -DLIBCXX_ENABLE_SHARED=OFF -DLIBCXX_HAS_MUSL_LIBC=ON"
        echo "                  -DLIBCXX_CXX_ABI=libcxxabi -DLIBCXX_ENABLE_FILESYSTEM=OFF"
        echo "                  CXX flags include -D_LIBCPPABI_VERSION=1001"
        echo "  lld           : -DLLD_PATH_TO_LLVM_SOURCE=$L35/llvm"
        echo "                  -DLLD_PATH_TO_LLVM_BUILD=$LLVM_BUILD"
        echo "                  -DLLVM_RUNTIME_OUTPUT_INTDIR=... -DLLVM_LIBRARY_OUTPUT_INTDIR=..."
        echo
        echo "build timings (seconds):"
        cat "$TIMINGS" 2>/dev/null || true
        echo
        echo "verification:"
        sed -n '1,200p' "$VERIFY/results.txt" 2>/dev/null || true
        echo
        echo "archive provenance:"
        echo "  every object with a .comment section in libc++.a, libc++abi.a,"
        echo "  libunwind.a reports 'clang version 3.5.2'; no GCC 4.6.4/EDG objects."
        echo
        echo "known limitations:"
        echo "  - Static executables only; shared libraries are not supported."
        echo "  - C++14 is the highest supported language mode with clang 3.5;"
        echo "    std::uncaught_exceptions (C++17) is not available."
        echo "  - libc++ filesystem is disabled (LIBCXX_ENABLE_FILESYSTEM=OFF)."
        echo "  - libc++abi 3.5 keeps its stdexcept.cpp; a generated __refstring"
        echo "    header maps its old private header to libc++ 9's src/include/refstring.h."
        echo "  - libunwind 9.0.1 and compiler-rt 9.0 crt sources are used because"
        echo "    the 3.5 source tree lacks working Linux libunwind/crt sources."
        echo "  - clang/clang++ are a thin static launcher; clang-3.5 is the real"
        echo "    compiler.  The launcher defaults to -static and C++14."
        echo "  - lld 3.5 is old; only static ELF linking is verified."
        echo "  - Linux UAPI headers are taken from the host."
        echo "  - llvm-config/opt/llc are copied from the existing build tree;"
        echo "    llvm-config reports build-tree paths and is not relocatable."
        echo "  - musl 1.2.6 is rebuilt from the same source with"
        echo "    -ffunction-sections because lld 3.5 mislinks ordinary"
        echo "    multi-function .text sections that lack local-call relocations."
        echo "  - User code and the C++ runtime are compiled with"
        echo "    -fuse-init-array -ffunction-sections -fdata-sections for lld 3.5."
        echo
        echo "patch/deviations:"
        echo "  - compiler-rt copy: test/ directory disabled (no FileCheck in the"
        echo "    EDG-built LLVM tree)."
        echo "  - libcxxabi copy: a generated __refstring compatibility header maps"
        echo "    libc++abi 3.5's old private header to libc++ 9's"
        echo "    src/include/refstring.h (stdexcept.cpp is kept);"
        echo "    cxa_thread_atexit.cpp from libc++abi 9.0 added (with two"
        echo "    compatibility visibility macros; clang 3.5 emits"
        echo "    __cxa_thread_atexit; musl 1.2.6 does not provide it)."
        echo "  - lld copy: test/, utils/, docs/ disabled (missing FileCheck/lit"
        echo "    variables in the EDG-built LLVM tree)."
        echo "  - libunwind EHHeaderParser: tolerate lld 3.5's minimal .eh_frame_hdr"
        echo "    (fde_count/table encoding omitted) and fall back to linear scan."
        echo
        echo "artifacts (sha256):"
        ( cd "$TC" && sha256sum bin/clang-3.5 bin/lld lib/libc++.a \
            lib/libc++abi.a lib/libunwind.a 2>/dev/null ) || true
    } >"$TC/build-info.txt"

    cp -a "$TC/build-info.txt" "$OUT/build-info.txt"
    info "wrote $TC/build-info.txt"
    stage_end
    stop_after build-info
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    mkdir -p "$OUT" "$LOG" "$SRC" "$LAUNCHER_DIR" "$SMOKE" "$VERIFY"
    : >"$TIMINGS"
    safe_recreate_tc

    stage_preflight
    stage_musl
    stage_compiler_rt
    stage_libunwind
    stage_libcxxabi
    stage_libcxx
    stage_package
    stage_launcher
    stage_lld
    stage_verify
    stage_build_info

    info "toolchain ready: $TC"
    info "build info     : $TC/build-info.txt"
    info "logs           : $LOG"
}

main "$@"
