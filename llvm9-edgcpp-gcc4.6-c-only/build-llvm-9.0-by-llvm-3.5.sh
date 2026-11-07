#!/usr/bin/env bash
# Build a self-contained LLVM/Clang 9.0.1 toolchain with the clang 3.5 static
# musl toolchain produced by ./build-llvm-3.5-toolchain-extra.sh.
#
# Two-stage bootstrap:
#   stage1: clang 3.5.2 (from the existing 3.5 toolchain) builds LLVM/Clang 9
#           and lld 9.  The stage1 link uses the host binutils ld via a
#           temporary -B directory, so lld 3.5 is not involved in bootstrapping.
#   stage2: the freshly built clang 9 builds compiler-rt 9, libunwind 9,
#           libc++abi 9 and libc++ 9.  The final toolchain links with lld 9.
#
# Inputs (read-only):
#   build/llvm3.5-edg7.0-gcc4.6c/toolchain   (built by build-llvm-3.5-toolchain-extra.sh)
#   llvm-project-9.0/{llvm,clang,lld,libcxx,libcxxabi,libunwind,compiler-rt}
#
# Outputs:
#   build/llvm9.0-llvm3.5/src      patched LLVM 9 source copy
#   build/llvm9.0-llvm3.5/log      per-stage logs
#   build/llvm9.0-llvm3.5/toolchain final toolchain + build-info.txt
#
# Usage:
#   ./build-llvm-9.0-by-llvm-3.5.sh
#
# Environment:
#   BASE=...        clang 3.5 toolchain (default:
#                   build/llvm3.5-edg7.0-gcc4.6c/toolchain)
#   MUSL=...        musl sysroot (default: $BASE/usr)
#   LLVM9=...       llvm-project-9.0 sources (default: <root>/llvm-project-9.0)
#   OUT=...         work/install root (default: build/llvm9.0-llvm3.5)
#   JOBS=...        parallel jobs (default: nproc)
#   TIMEOUT=...     per long command timeout (default: 7200)
#   STOP_AFTER=all  preflight|stage1|compiler-rt|musl|libunwind|libcxxabi|
#                   libcxx|verify|build-info|all
#   SKIP_BWRAP=1    skip the bwrap compile/run check
#
# Everything is static.  The final toolchain carries musl headers/static libs,
# Linux UAPI headers, compiler-rt builtins/crt, libc++, libc++abi and
# libunwind, so a static C++ program needs only the toolchain directory.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
BASE=${BASE:-$ROOT/build/llvm3.5-edg7.0-gcc4.6c/toolchain}
MUSL=${MUSL:-$BASE/usr}
LLVM9=${LLVM9:-$ROOT/llvm-project-9.0}
OUT=${OUT:-$ROOT/build/llvm9.0-llvm3.5}
JOBS=${JOBS:-$(nproc)}
TIMEOUT=${TIMEOUT:-7200}
STOP_AFTER=${STOP_AFTER:-all}
SKIP_BWRAP=${SKIP_BWRAP:-0}
RESUME=${RESUME:-0}
NINJA_RETRIES=${NINJA_RETRIES:-6}
STAGE1_JOBS=${STAGE1_JOBS:-$JOBS}

TREE=$OUT/src
TC=$OUT/toolchain
LOG=$OUT/log
SMOKE=$OUT/smoke
VERIFY=$OUT/verify
TIMINGS=$OUT/timings.txt
STAGE1_BIN=$OUT/stage1-bin

CC=${CC:-gcc}
HOST_TRIPLE=$("$CC" -dumpmachine 2>/dev/null || echo x86_64-linux-gnu)

CURRENT_STAGE=preflight
CURRENT_LOG=

info()  { printf '[llvm9] %s\n' "$*" >&2; }
warn()  { printf '[llvm9] WARNING: %s\n' "$*" >&2; }
die()   { printf '[llvm9] ERROR: %s\n' "$*" >&2; exit 1; }

catch_err() {
    local rc=$?
    printf '\n[llvm9] FAILED in stage %s (exit %s)\n' "$CURRENT_STAGE" "$rc" >&2
    if [ -n "$CURRENT_LOG" ] && [ -f "$CURRENT_LOG" ]; then
        printf -- '--- tail of %s ---\n' "$CURRENT_LOG" >&2
        tail -n 100 "$CURRENT_LOG" >&2 || true
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

# clang 3.5 occasionally segfaults on very large TUs; ninja resumes cleanly,
# so retry a failed build a bounded number of times.
ninja_retry() {
    local bld=$1
    shift
    local attempt
    for attempt in $(seq 1 "$NINJA_RETRIES"); do
        if timeout "$TIMEOUT" ninja -C "$bld" "$@" >>"$CURRENT_LOG" 2>&1; then
            return 0
        fi
        warn "ninja failed (attempt $attempt/$NINJA_RETRIES); retrying"
        sleep 2
    done
    return 1
}

# ---------------------------------------------------------------------------
# stage1-only libc++ header overlay: avoid make_shared's
# __shared_ptr_emplace/forward_as_tuple path, which intermittently crashes
# clang 3.5 while compiling LLVM 9.  The installed headers are untouched.
# ---------------------------------------------------------------------------
setup_bootstrap_libcxx() {
    rm -rf "$OUT/bootstrap-libcxx"
    cp -a "$BASE/include/c++/v1" "$OUT/bootstrap-libcxx"
    python3 - "$OUT/bootstrap-libcxx/memory" <<'PYMEM'
import sys
p = sys.argv[1]
s = open(p).read()
old = """shared_ptr<_Tp>::make_shared(_Args&& ...__args)
{
    static_assert( is_constructible<_Tp, _Args...>::value, "Can't construct object in make_shared" );
    typedef __shared_ptr_emplace<_Tp, allocator<_Tp> > _CntrlBlk;
    typedef allocator<_CntrlBlk> _A2;
    typedef __allocator_destructor<_A2> _D2;
    _A2 __a2;
    unique_ptr<_CntrlBlk, _D2> __hold2(__a2.allocate(1), _D2(__a2, 1));
    ::new(__hold2.get()) _CntrlBlk(__a2, _VSTD::forward<_Args>(__args)...);
    shared_ptr<_Tp> __r;
    __r.__ptr_ = __hold2.get()->get();
    __r.__cntrl_ = __hold2.release();
    __r.__enable_weak_this(__r.__ptr_, __r.__ptr_);
    return __r;
}"""
new = """shared_ptr<_Tp>::make_shared(_Args&& ...__args)
{
    // bootstrap libc++ for clang 3.5: avoid __shared_ptr_emplace's
    // forward_as_tuple, which intermittently crashes the clang 3.5 frontend.
    shared_ptr<_Tp> __r(new _Tp(_VSTD::forward<_Args>(__args)...));
    __r.__enable_weak_this(__r.__ptr_, __r.__ptr_);
    return __r;
}"""
if old not in s:
    raise SystemExit("libc++ make_shared body not found")
open(p, "w").write(s.replace(old, new))
PYMEM
    grep -q 'bootstrap libc++ for clang 3.5' "$OUT/bootstrap-libcxx/memory" || \
        die "failed to patch stage1 libc++ make_shared"
}

# ---------------------------------------------------------------------------
# 0. preflight, source copy, clang 9 driver patches
# ---------------------------------------------------------------------------
stage_preflight() {
    [ -x "$BASE/bin/clang" ] || die "missing $BASE/bin/clang; run ./build-llvm-3.5-toolchain-extra.sh first"
    [ -x "$BASE/bin/clang++" ] || die "missing $BASE/bin/clang++"
    [ -d "$BASE/usr/include" ] || die "missing $BASE/usr/include"
    [ -f "$BASE/usr/lib/libc.a" ] || die "missing $BASE/usr/lib/libc.a"
    [ -d "$BASE/include/c++/v1" ] || die "missing $BASE/include/c++/v1"
    [ -d "$MUSL/include" ] || die "missing musl headers: $MUSL/include"
    [ -f "$MUSL/lib/libc.a" ] || die "missing musl libc.a: $MUSL/lib/libc.a"
    [ -d "$LLVM9/llvm" ] || die "missing $LLVM9/llvm"
    for d in clang lld libcxx libcxxabi libunwind compiler-rt; do
        [ -d "$LLVM9/$d" ] || die "missing $LLVM9/$d"
    done
    command -v cmake >/dev/null || die "cmake not found"
    command -v ninja >/dev/null || die "ninja not found"
    command -v make >/dev/null || die "make not found"
    command -v perl >/dev/null || die "perl not found"
    command -v python3 >/dev/null || die "python3 not found"
    command -v timeout >/dev/null || die "timeout not found"
    command -v readelf >/dev/null || die "readelf not found"
    command -v file >/dev/null || die "file not found"
    [ -d "/usr/include/linux" ] || die "missing /usr/include/linux"
    [ -d "/usr/include/asm-generic" ] || die "missing /usr/include/asm-generic"
    [ -d "/usr/include/$HOST_TRIPLE/asm" ] || die "missing /usr/include/$HOST_TRIPLE/asm"
    host_ld=$(command -v ld) || die "host binutils ld not found"
    [ -x "$host_ld" ] || die "host ld is not executable: $host_ld"

    case "$OUT" in
        "$ROOT"/build/*) ;;
        *) die "refusing to remove OUT outside $ROOT/build: $OUT" ;;
    esac
    rm -rf "$OUT"
    mkdir -p "$TREE" "$LOG" "$SMOKE" "$VERIFY" "$STAGE1_BIN" "$TC"
    : >"$TIMINGS"
    ln -sfn "$host_ld" "$STAGE1_BIN/ld"

    stage_begin preflight
    info "base toolchain : $BASE"
    info "musl sysroot   : $MUSL"
    info "llvm 9 sources : $LLVM9"
    info "work/install   : $OUT"
    info "jobs           : $JOBS"
    info "host ld        : $host_ld"

    for d in llvm clang lld libcxx libcxxabi libunwind compiler-rt; do
        cp -a "$LLVM9/$d" "$TREE/"
    done

    # ---- clang 9 driver patches ------------------------------------------
    # 1. link libc++ together with its ABI library.
    perl -0pi -e 's/(  case ToolChain::CST_Libcxx:\n    CmdArgs\.push_back\("-lc\+\+"\);\n)/$1    CmdArgs.push_back("-lc++abi");\n/' \
        "$TREE/clang/lib/Driver/ToolChain.cpp"
    # 2. use the bundled ld.lld unless -fuse-ld is given.
    perl -0pi -e 's/(  StringRef UseLinker = A \? A->getValue\(\) : CLANG_DEFAULT_LINKER;\n)/$1\n  if (!A) {\n    std::string P = std::string(getDriver().getInstalledDir()) + "\/ld.lld";\n    if (llvm::sys::fs::can_execute(P))\n      return P;\n  }\n/' \
        "$TREE/clang/lib/Driver/ToolChain.cpp"
    # 3. treat the installation prefix as the default sysroot.
    perl -0pi -e 's/(std::string Linux::computeSysRoot\(\) const \{\n  if \(!getDriver\(\)\.SysRoot\.empty\(\)\)\n    return getDriver\(\)\.SysRoot;\n)/$1\n  {\n    std::string P = std::string(getDriver().getInstalledDir());\n    P = P.substr(0, P.find_last_of("\/"));\n    if (getVFS().exists(P))\n      return P;\n  }\n/' \
        "$TREE/clang/lib/Driver/ToolChains/Linux.cpp"

    grep -q '"-lc++abi"' "$TREE/clang/lib/Driver/ToolChain.cpp" || \
        die "driver patch 1 (-lc++abi) did not apply"
    grep -q 'getInstalledDir()) + "/ld.lld"' "$TREE/clang/lib/Driver/ToolChain.cpp" || \
        die "driver patch 2 (ld.lld) did not apply"
    grep -q 'P = P.substr(0, P.find_last_of("/"));' \
        "$TREE/clang/lib/Driver/ToolChains/Linux.cpp" || \
        die "driver patch 3 (sysroot) did not apply"

    # clang 3.5 eagerly instantiates std::pair<KeyT, ValueT> assignment
    # traits through DenseMapIterator while LLVM 9's json::Object still has
    # ObjectKey/Value incomplete.  Tell libc++ that DenseMapIterator itself is
    # assignable; this avoids instantiating the incomplete pair.  This is a
    # stage1-source-only bootstrap patch.
    python3 - "$TREE/llvm/include/llvm/ADT/DenseMap.h" <<'PYDENSE'
import sys
p = sys.argv[1]
s = open(p).read()
block = """
// toolchain-extra: clang 3.5 eagerly instantiates DenseMapIterator's
// value_type when libc++ 9's std::pair checks assignment traits.  LLVM 9's
// json::Object holds a DenseMap<incomplete ObjectKey, incomplete Value>, so
// tell the traits that the iterator itself is assignable without forcing the
// pair<KeyT, ValueT> instantiation.
namespace std {
template <typename KeyT, typename ValueT, typename KeyInfoT, typename Bucket,
          bool IsConst>
struct is_copy_assignable<
    ::llvm::DenseMapIterator<KeyT, ValueT, KeyInfoT, Bucket, IsConst>>
    : true_type {};
template <typename KeyT, typename ValueT, typename KeyInfoT, typename Bucket,
          bool IsConst>
struct is_nothrow_copy_assignable<
    ::llvm::DenseMapIterator<KeyT, ValueT, KeyInfoT, Bucket, IsConst>>
    : true_type {};
template <typename KeyT, typename ValueT, typename KeyInfoT, typename Bucket,
          bool IsConst>
struct is_move_assignable<
    ::llvm::DenseMapIterator<KeyT, ValueT, KeyInfoT, Bucket, IsConst>>
    : true_type {};
template <typename KeyT, typename ValueT, typename KeyInfoT, typename Bucket,
          bool IsConst>
struct is_nothrow_move_assignable<
    ::llvm::DenseMapIterator<KeyT, ValueT, KeyInfoT, Bucket, IsConst>>
    : true_type {};
} // namespace std

"""
tail = "#endif // LLVM_ADT_DENSEMAP_H"
if not s.rstrip().endswith(tail):
    raise SystemExit("DenseMap.h tail not found")
s = s.rstrip()
s = s[:-len(tail)] + block + tail + "\n"
open(p, "w").write(s)
PYDENSE
    grep -q 'is_copy_assignable<' "$TREE/llvm/include/llvm/ADT/DenseMap.h" || \
        die "failed to patch DenseMapIterator assignment traits"

    # clang 3.5 intermittently segfaults while instantiating libc++ 9's
    # make_shared/forward_as_tuple in this file.  Use the two-argument
    # shared_ptr constructor for the seven affected allocations; this is
    # ABI-compatible and avoids the frontend bug.
    python3 - "$TREE/llvm/lib/Support/VirtualFileSystem.cpp" <<'PYVFS'
import sys
p = sys.argv[1]
s = open(p).read()
repls = [
("""  return directory_iterator(
      std::make_shared<RealFSDirIter>(adjustPath(Dir, Storage), EC));""",
 """  return directory_iterator(std::shared_ptr<RealFSDirIter>(
      new RealFSDirIter(adjustPath(Dir, Storage), EC)));"""),
("""  return directory_iterator(
      std::make_shared<OverlayFSDirIterImpl>(Dir, *this, EC));""",
 """  return directory_iterator(std::shared_ptr<OverlayFSDirIterImpl>(
      new OverlayFSDirIterImpl(Dir, *this, EC)));"""),
("""    return directory_iterator(std::make_shared<InMemoryDirIterator>());""",
 """    return directory_iterator(
        std::shared_ptr<InMemoryDirIterator>(new InMemoryDirIterator()));"""),
("""    return directory_iterator(
        std::make_shared<InMemoryDirIterator>(*DirNode, Dir.str()));""",
 """    return directory_iterator(std::shared_ptr<InMemoryDirIterator>(
        new InMemoryDirIterator(*DirNode, Dir.str())));"""),
("""  return directory_iterator(std::make_shared<InMemoryDirIterator>());""",
 """  return directory_iterator(
      std::shared_ptr<InMemoryDirIterator>(new InMemoryDirIterator()));"""),
("""  return directory_iterator(std::make_shared<VFSFromYamlDirIterImpl>(
      Dir, D->contents_begin(), D->contents_end(),
      /*IterateExternalFS=*/IsFallthrough, *ExternalFS, EC));""",
 """  return directory_iterator(std::shared_ptr<VFSFromYamlDirIterImpl>(
      new VFSFromYamlDirIterImpl(
          Dir, D->contents_begin(), D->contents_end(),
          /*IterateExternalFS=*/IsFallthrough, *ExternalFS, EC)));"""),
("""    State = std::make_shared<detail::RecDirIterState>();""",
 """    State = std::shared_ptr<detail::RecDirIterState>(
        new detail::RecDirIterState());"""),
]
for a, b in repls:
    if a not in s:
        raise SystemExit("VirtualFileSystem make_shared site not found: " + a[:60])
    s = s.replace(a, b)
open(p, "w").write(s)
PYVFS
    grep -q 'make_shared' "$TREE/llvm/lib/Support/VirtualFileSystem.cpp" && \
        die "VirtualFileSystem still contains make_shared"

    setup_bootstrap_libcxx

    info "clang 9 driver patches applied"
    stage_end
    stop_after preflight
}

# ---------------------------------------------------------------------------
# 1. stage1: clang 9 + lld 9, built by clang 3.5 with host ld
# ---------------------------------------------------------------------------
stage_stage1() {
    stage_begin stage1
    local bld=$OUT/llvm
    local clang_src

    mkdir -p "$bld"
    # Host binutils ld for the bootstrap; the 3.5 launcher otherwise prefers
    # its own lld 3.5.  -fuse-ld=ld + -B<dir containing ld> has been verified.
    run_log "$CURRENT_LOG" cmake -S "$TREE/llvm" -B "$bld" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS_RELEASE="-O0 -DNDEBUG" \
        -DCMAKE_CXX_FLAGS_RELEASE="-O0 -DNDEBUG" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_C_COMPILER="$BASE/bin/clang" \
        -DCMAKE_CXX_COMPILER="$BASE/bin/clang++" \
        -DLLVM_TARGETS_TO_BUILD=X86 \
        -DLLVM_ENABLE_PROJECTS="clang;lld" \
        -DLLVM_EXTERNAL_CLANG_SOURCE_DIR="$TREE/clang" \
        -DLLVM_EXTERNAL_LLD_SOURCE_DIR="$TREE/lld" \
        -DLLVM_ENABLE_LIBCXX=ON \
        -DCLANG_DEFAULT_CXX_STDLIB=libc++ \
        -DCLANG_DEFAULT_RTLIB=compiler-rt \
        -DLLVM_ENABLE_LIBXML2=OFF \
        -DLLVM_ENABLE_TERMINFO=OFF \
        -DLLVM_ENABLE_ZLIB=OFF \
        -DLLVM_ENABLE_LIBEDIT=OFF \
        -DLLVM_ENABLE_PLUGINS=OFF \
        -DLLVM_ENABLE_WERROR=OFF \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_DOCS=OFF \
        -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DCLANG_INCLUDE_TESTS=OFF \
        -DCLANG_ENABLE_ARCMT=OFF \
        -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
        -DLLVM_TEMPORARILY_ALLOW_OLD_TOOLCHAIN=ON \
        -DCMAKE_C_FLAGS="-O2 -w -D_GNU_SOURCE -D_LARGEFILE64_SOURCE -D__inline__=inline -D__inline=inline" \
        -DCMAKE_CXX_FLAGS="-O2 -w -include cstdint -Wno-unknown-warning-option -D_GNU_SOURCE -D_LARGEFILE64_SOURCE -D__inline__=inline -D__inline=inline -nostdinc++ -isystem $OUT/bootstrap-libcxx" \
        -DCMAKE_EXE_LINKER_FLAGS="-static -fuse-ld=ld -B$STAGE1_BIN" \
        -DCMAKE_INSTALL_PREFIX="$TC"

    ninja_retry "$bld" -j"$STAGE1_JOBS" \
        clang lld llvm-config llvm-ar llvm-nm llvm-size llvm-objdump \
        llvm-readobj llvm-link llvm-as llvm-dis opt llc

    if [ -e "$bld/bin/clang-9" ]; then
        clang_src=$bld/bin/clang-9
    elif [ -e "$bld/bin/clang" ]; then
        clang_src=$bld/bin/clang
    else
        die "stage1 clang binary not found in $bld/bin"
    fi

    mkdir -p "$TC/bin" "$TC/lib" "$TC/include" "$TC/lib/cmake"
    cp -aL "$clang_src" "$TC/bin/clang-9"
    ln -sfn clang-9 "$TC/bin/clang"
    ln -sfn clang-9 "$TC/bin/clang++"
    cp -aL "$bld/bin/lld" "$TC/bin/lld"
    ln -sfn lld "$TC/bin/ld.lld"
    ln -sfn lld "$TC/bin/ld64.lld"
    for t in llvm-config llvm-ar llvm-nm llvm-size llvm-objdump \
             llvm-readobj llvm-link llvm-as llvm-dis opt llc; do
        cp -aL "$bld/bin/$t" "$TC/bin/"
    done
    ln -sfn llvm-ar "$TC/bin/llvm-ranlib"
    [ -d "$bld/lib/clang" ] || die "stage1 clang resource dir missing"
    cp -a "$bld/lib/clang" "$TC/lib/"
    if [ -d "$bld/lib/cmake/llvm" ]; then
        cp -a "$bld/lib/cmake/llvm" "$TC/lib/cmake/"
    fi

    "$TC/bin/clang" --version >/dev/null 2>&1 || die "stage1 clang does not run"
    "$TC/bin/ld.lld" --version >/dev/null 2>&1 || die "stage1 ld.lld does not run"
    info "stage1 clang: $("$TC/bin/clang" --version 2>&1 | head -n 1)"
    info "stage1 lld  : $("$TC/bin/ld.lld" --version 2>&1 | head -n 1)"
    stage_end
    stop_after stage1
}

# ---------------------------------------------------------------------------
# 2. compiler-rt 9 builtins + crt, built by stage1 clang 9
# ---------------------------------------------------------------------------
stage_compiler_rt() {
    stage_begin compiler-rt
    local bld=$OUT/compiler-rt
    local res builtins crtb crte

    mkdir -p "$bld"
    run_log "$CURRENT_LOG" cmake -S "$TREE/compiler-rt" -B "$bld" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DLLVM_CONFIG_PATH="$TC/bin/llvm-config" \
        -DCMAKE_C_COMPILER="$TC/bin/clang" \
        -DCMAKE_CXX_COMPILER="$TC/bin/clang++" \
        -DCMAKE_C_FLAGS="--sysroot=/ -rtlib=libgcc -O2 -w -D_GNU_SOURCE -D_LARGEFILE64_SOURCE -D__inline__=inline -D__inline=inline" \
        -DCMAKE_CXX_FLAGS="--sysroot=/ -rtlib=libgcc -O2 -w -D_GNU_SOURCE -D_LARGEFILE64_SOURCE -D__inline__=inline -D__inline=inline -nostdlib++ -nostdinc++ -isystem $BASE/include/c++/v1" \
        -DCMAKE_EXE_LINKER_FLAGS="-static" \
        -DCMAKE_INSTALL_PREFIX="$TC" \
        -DCOMPILER_RT_BUILD_BUILTINS=ON \
        -DCOMPILER_RT_BUILD_CRT=ON \
        -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
        -DCOMPILER_RT_BUILD_XRAY=OFF \
        -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
        -DCOMPILER_RT_BUILD_PROFILE=OFF \
        -DCOMPILER_RT_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_TESTS=OFF
    ninja_retry "$bld" -j"$JOBS"

    res=$(find "$TC/lib/clang" -mindepth 1 -maxdepth 1 -type d -print -quit)
    [ -n "$res" ] || die "cannot find clang 9 resource directory"
    mkdir -p "$res/lib/linux"

    builtins=$(find "$bld" -name 'libclang_rt.builtins-x86_64.a' -print -quit)
    crtb=$(find "$bld" -name 'clang_rt.crtbegin-x86_64.o' -print -quit)
    crte=$(find "$bld" -name 'clang_rt.crtend-x86_64.o' -print -quit)

    if [ -z "$builtins" ] || [ -z "$crtb" ] || [ -z "$crte" ]; then
        warn "compiler-rt build-tree artifacts not found; falling back to install"
        run_log "$CURRENT_LOG" cmake --install "$bld"
        builtins=$(find "$TC" -name 'libclang_rt.builtins-x86_64.a' -print -quit)
        crtb=$(find "$TC" -name 'clang_rt.crtbegin-x86_64.o' -print -quit)
        crte=$(find "$TC" -name 'clang_rt.crtend-x86_64.o' -print -quit)
    fi
    [ -n "$builtins" ] || die "libclang_rt.builtins-x86_64.a not found"
    [ -n "$crtb" ] || die "clang_rt.crtbegin-x86_64.o not found"
    [ -n "$crte" ] || die "clang_rt.crtend-x86_64.o not found"
    cp -a "$builtins" "$res/lib/linux/"
    cp -a "$crtb" "$res/lib/linux/"
    cp -a "$crte" "$res/lib/linux/"

    info "compiler-rt: $builtins"
    info "compiler-rt: $crtb $crte"
    stage_end
    stop_after compiler-rt
}

# ---------------------------------------------------------------------------
# 3. musl + Linux UAPI sysroot for the final toolchain
# ---------------------------------------------------------------------------
stage_musl() {
    stage_begin musl
    local inc=$TC/usr/include
    local lib=$TC/usr/lib

    mkdir -p "$inc" "$lib" "$inc/$HOST_TRIPLE"
    cp -aL "$MUSL/include/." "$inc/"
    cp -aL "$MUSL/lib/libc.a" \
            "$MUSL/lib/libm.a" \
            "$MUSL/lib/crt1.o" \
            "$MUSL/lib/crti.o" \
            "$MUSL/lib/crtn.o" \
            "$MUSL/lib/Scrt1.o" \
            "$MUSL/lib/rcrt1.o" \
            "$lib/"

    # Linux UAPI headers (musl does not ship them).
    mkdir -p "$inc/linux" "$inc/asm-generic" "$inc/$HOST_TRIPLE/asm"
    cp -a /usr/include/linux/. "$inc/linux/"
    cp -a /usr/include/asm-generic/. "$inc/asm-generic/"
    cp -a "/usr/include/$HOST_TRIPLE/asm/." "$inc/$HOST_TRIPLE/asm/"
    rm -rf "$inc/asm"
    ln -sfn "$HOST_TRIPLE/asm" "$inc/asm"
    if [ -d /usr/lib/linux ]; then
        cp -a /usr/lib/linux "$lib/"
    fi

    # clang 9 (compiler-rt) still asks for -lgcc_s/-lgcc_eh on Linux.
    for l in libpthread libdl librt libcrypt libutil libxnet libgcc_s libgcc_eh; do
        "$TC/bin/llvm-ar" rc "$lib/$l.a"
    done

    [ -f "$lib/libc.a" ] || die "musl libc.a missing in final sysroot"
    [ -f "$inc/stdio.h" ] || die "musl headers missing in final sysroot"
    [ -f "$inc/linux/version.h" ] || die "Linux UAPI headers missing"
    info "musl sysroot installed under $TC/usr"
    stage_end
    stop_after musl
}

# ---------------------------------------------------------------------------
# 4. libunwind 9
# ---------------------------------------------------------------------------
stage_libunwind() {
    stage_begin libunwind
    local bld=$OUT/libunwind

    mkdir -p "$bld"
    run_log "$CURRENT_LOG" cmake -S "$TREE/libunwind" -B "$bld" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DLLVM_CONFIG_PATH="$TC/bin/llvm-config" \
        -DCMAKE_C_COMPILER="$TC/bin/clang" \
        -DCMAKE_CXX_COMPILER="$TC/bin/clang++" \
        -DCMAKE_C_FLAGS="-O2 -w -D_GNU_SOURCE -D_LARGEFILE64_SOURCE -D__inline__=inline -D__inline=inline" \
        -DCMAKE_CXX_FLAGS="-O2 -w -D_GNU_SOURCE -D_LARGEFILE64_SOURCE -D__inline__=inline -D__inline=inline -nostdlib++ -nostdinc++ -isystem $TREE/libcxx/include -I$TREE/libcxxabi/include -D_LIBCPP_HAS_MUSL_LIBC" \
        -DCMAKE_EXE_LINKER_FLAGS="-static" \
        -DCMAKE_INSTALL_PREFIX="$TC" \
        -DLIBUNWIND_ENABLE_SHARED=OFF \
        -DLIBUNWIND_ENABLE_STATIC=ON \
        -DLIBUNWIND_ENABLE_ASSERTIONS=OFF \
        -DLIBUNWIND_ENABLE_WERROR=OFF \
        -DLLVM_INCLUDE_TESTS=OFF
    ninja_retry "$bld" -j"$JOBS"
    run_log "$CURRENT_LOG" cmake --install "$bld"
    mkdir -p "$TC/include"
    cp -a "$TREE/libunwind/include/." "$TC/include/"
    [ -f "$TC/lib/libunwind.a" ] || die "libunwind.a not installed"
    info "libunwind.a: $TC/lib/libunwind.a"
    stage_end
    stop_after libunwind
}

# ---------------------------------------------------------------------------
# 5. libc++abi 9
# ---------------------------------------------------------------------------
stage_libcxxabi() {
    stage_begin libcxxabi
    local bld=$OUT/libcxxabi
    local merge=$OUT/merge

    mkdir -p "$bld"
    run_log "$CURRENT_LOG" cmake -S "$TREE/libcxxabi" -B "$bld" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DLLVM_CONFIG_PATH="$TC/bin/llvm-config" \
        -DCMAKE_C_COMPILER="$TC/bin/clang" \
        -DCMAKE_CXX_COMPILER="$TC/bin/clang++" \
        -DCMAKE_C_FLAGS="-O2 -w -D_GNU_SOURCE -D_LARGEFILE64_SOURCE -D__inline__=inline -D__inline=inline" \
        -DCMAKE_CXX_FLAGS="-O2 -w -D_GNU_SOURCE -D_LARGEFILE64_SOURCE -D__inline__=inline -D__inline=inline -nostdlib++ -nostdinc++ -isystem $TREE/libcxx/include -I$TREE/libcxxabi/include -D_LIBCPP_HAS_MUSL_LIBC" \
        -DCMAKE_EXE_LINKER_FLAGS="-static" \
        -DCMAKE_INSTALL_PREFIX="$TC" \
        -DLIBCXXABI_ENABLE_SHARED=OFF \
        -DLIBCXXABI_ENABLE_STATIC=ON \
        -DLIBCXXABI_ENABLE_ASSERTIONS=OFF \
        -DLIBCXXABI_ENABLE_WERROR=OFF \
        -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
        -DLIBCXXABI_LIBCXX_INCLUDES="$TREE/libcxx/include" \
        -DLIBCXXABI_LIBUNWIND_INCLUDES="$TC/include" \
        -DLIBCXXABI_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_TESTS=OFF
    ninja_retry "$bld" -j"$JOBS" cxxabi
    run_log "$CURRENT_LOG" cmake --install "$bld"

    [ -f "$TC/lib/libc++abi.a" ] || die "libc++abi.a not installed"
    [ -f "$TC/lib/libunwind.a" ] || die "libunwind.a missing before merge"
    rm -rf "$merge"
    mkdir -p "$merge"
    (
        cd "$merge"
        "$TC/bin/llvm-ar" x "$TC/lib/libunwind.a"
        "$TC/bin/llvm-ar" q "$TC/lib/libc++abi.a" *.o
        "$TC/bin/llvm-ar" s "$TC/lib/libc++abi.a"
    )
    rm -rf "$merge"
    info "libc++abi.a (with libunwind objects): $TC/lib/libc++abi.a"
    stage_end
    stop_after libcxxabi
}

# ---------------------------------------------------------------------------
# 6. libc++ 9
# ---------------------------------------------------------------------------
stage_libcxx() {
    stage_begin libcxx
    local bld=$OUT/libcxx

    mkdir -p "$bld"
    run_log "$CURRENT_LOG" cmake -S "$TREE/libcxx" -B "$bld" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DLLVM_CONFIG_PATH="$TC/bin/llvm-config" \
        -DCMAKE_C_COMPILER="$TC/bin/clang" \
        -DCMAKE_CXX_COMPILER="$TC/bin/clang++" \
        -DCMAKE_C_FLAGS="-O2 -w -D_GNU_SOURCE -D_LARGEFILE64_SOURCE -D__inline__=inline -D__inline=inline" \
        -DCMAKE_CXX_FLAGS="-O2 -w -D_GNU_SOURCE -D_LARGEFILE64_SOURCE -D__inline__=inline -D__inline=inline -nostdlib++ -nostdinc++ -isystem $TREE/libcxx/include -I$TREE/libcxxabi/include -D_LIBCPP_HAS_MUSL_LIBC" \
        -DCMAKE_EXE_LINKER_FLAGS="-static" \
        -DCMAKE_INSTALL_PREFIX="$TC" \
        -DLIBCXX_ENABLE_SHARED=OFF \
        -DLIBCXX_ENABLE_STATIC=ON \
        -DLIBCXX_ENABLE_ASSERTIONS=OFF \
        -DLIBCXX_HAS_MUSL_LIBC=ON \
        -DLIBCXX_CXX_ABI=libcxxabi \
        -DLIBCXX_CXX_ABI_INCLUDE_PATHS="$TREE/libcxxabi/include" \
        -DLIBCXX_ENABLE_FILESYSTEM=OFF \
        -DLIBCXX_ENABLE_EXPERIMENTAL_LIBRARY=OFF \
        -DLIBCXX_INCLUDE_BENCHMARKS=OFF \
        -DLIBCXX_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_TESTS=OFF
    ninja_retry "$bld" -j"$JOBS" cxx cxx-generated-config
    run_log "$CURRENT_LOG" cmake --install "$bld"
    [ -f "$TC/lib/libc++.a" ] || die "libc++.a not installed"
    [ -d "$TC/include/c++/v1" ] || die "libc++ headers not installed"
    info "libc++.a: $TC/lib/libc++.a"
    stage_end
    stop_after libcxx
}

# ---------------------------------------------------------------------------
# 7. verification
# ---------------------------------------------------------------------------
verify_static_binary() {
    local f=$1
    if ! file "$f" | grep -q 'statically linked'; then
        printf 'FAIL: %s is not statically linked\n' "$f" >>"$VERIFY/results.txt"
        file "$f" >>"$VERIFY/results.txt" 2>&1 || true
        return 1
    fi
    if readelf -d "$f" 2>/dev/null | grep -q NEEDED; then
        printf 'FAIL: %s has NEEDED entries\n' "$f" >>"$VERIFY/results.txt"
        readelf -d "$f" >>"$VERIFY/results.txt" 2>&1 || true
        return 1
    fi
    return 0
}

verify_archive_provenance() {
    local ar=$1 name tmp obj comments bad=0 seen=0
    tmp=$(mktemp -d)
    name=$(basename "$ar")
    ( cd "$tmp" && "$TC/bin/llvm-ar" x "$ar" ) || {
        rm -rf "$tmp"
        die "cannot extract $ar"
    }
    for obj in "$tmp"/*.o; do
        [ -f "$obj" ] || continue
        comments=$(readelf -p .comment "$obj" 2>/dev/null || true)
        [ -n "$comments" ] || continue
        seen=$((seen + 1))
        if printf '%s' "$comments" | grep -qiE 'GCC|EDG'; then
            printf 'provenance: %s has non-clang producer in %s\n' \
                "$name" "$(basename "$obj")" >>"$VERIFY/results.txt"
            bad=1
        elif ! printf '%s' "$comments" | grep -q 'clang version 9'; then
            printf 'provenance: %s has unexpected producer in %s\n' \
                "$name" "$(basename "$obj")" >>"$VERIFY/results.txt"
            bad=1
        fi
    done
    rm -rf "$tmp"
    if [ "$seen" -eq 0 ]; then
        printf 'provenance: %s has no .comment objects\n' "$name" \
            >>"$VERIFY/results.txt"
    fi
    [ "$bad" -eq 0 ] || die "archive provenance check failed for $name"
    printf 'provenance: %s OK (%d objects with clang 9 .comment)\n' \
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
    strcpy(buf, "llvm9-musl-c");
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

    std::vector<std::string> v{"hello", "llvm9", "c++"};
    std::string s;
    for (const auto &x : v) s += x + " ";
    std::cout << s << "thread=" << n << " caught=" << caught << std::endl;
    return 0;
}
EOF

    if ! run_log "$CURRENT_LOG" "$TC/bin/clang" -static -O2 \
            "$SMOKE/c.c" -o "$SMOKE/c"; then
        die "C compile failed"
    fi
    timeout 60 "$SMOKE/c" >>"$VERIFY/results.txt" 2>&1 || die "C program failed"
    verify_static_binary "$SMOKE/c" || die "C static check failed"
    printf 'C: static ok\n' >>"$VERIFY/results.txt"

    if ! run_log "$CURRENT_LOG" "$TC/bin/clang++" -static -std=c++14 -O2 \
            "$SMOKE/cxx.cpp" -o "$SMOKE/cxx"; then
        die "C++ compile failed"
    fi
    timeout 60 "$SMOKE/cxx" >"$VERIFY/cxx.out" 2>&1 || die "C++ program failed"
    cat "$VERIFY/cxx.out" >>"$VERIFY/results.txt"
    verify_static_binary "$SMOKE/cxx" || die "C++ static check failed"
    printf 'C++: static ok\n' >>"$VERIFY/results.txt"

    "$TC/bin/clang++" -### -static -std=c++14 "$SMOKE/cxx.cpp" \
        -o "$SMOKE/cxx.dry" >"$VERIFY/linkline.txt" 2>&1 || true
    if ! grep -qF "$TC/bin/ld.lld" "$VERIFY/linkline.txt"; then
        cat "$VERIFY/linkline.txt" >>"$VERIFY/results.txt"
        die "link line does not use $TC/bin/ld.lld"
    fi
    printf 'lld: %s\n' "$("$TC/bin/ld.lld" --version 2>&1 | head -n 1)" \
        >>"$VERIFY/results.txt"
    printf 'link line: %s\n' \
        "$(grep -oF "$TC/bin/ld.lld" "$VERIFY/linkline.txt" | head -n 1)" \
        >>"$VERIFY/results.txt"

    verify_archive_provenance "$TC/lib/libc++.a"
    verify_archive_provenance "$TC/lib/libc++abi.a"
    verify_archive_provenance "$TC/lib/libunwind.a"

    # Stage1 artifacts are bootstrap-built by clang 3.5; record that rather
    # than claiming they were built by clang 9.
    printf 'bootstrap: %s\n' "$(readelf -p .comment "$TC/bin/clang-9" 2>/dev/null | grep -o 'clang version [0-9.]*' | head -n 1)" \
        >>"$VERIFY/results.txt"
    printf 'bootstrap: %s\n' "$(readelf -p .comment "$TC/bin/lld" 2>/dev/null | grep -o 'clang version [0-9.]*' | head -n 1)" \
        >>"$VERIFY/results.txt"

    if [ "$SKIP_BWRAP" = "1" ]; then
        printf 'bwrap: skipped (SKIP_BWRAP=1)\n' >>"$VERIFY/results.txt"
    elif command -v bwrap >/dev/null; then
        timeout "$TIMEOUT" bwrap --unshare-pid --die-with-parent --tmpfs / \
            --ro-bind "$TC" /tc --bind "$SMOKE" /work \
            --dev /dev --proc /proc --tmpfs /tmp \
            /tc/bin/clang++ -static -std=c++14 /work/cxx.cpp \
            -o /work/cxx_bwrap >>"$VERIFY/results.txt" 2>&1 || \
            die "bwrap C++ compile failed"
        timeout 60 bwrap --unshare-pid --die-with-parent --tmpfs / \
            --ro-bind "$SMOKE/cxx_bwrap" /cxx --dev /dev --proc /proc \
            /cxx >"$VERIFY/bwrap-cxx.out" 2>&1 || \
            die "bwrap C++ run failed"
        cat "$VERIFY/bwrap-cxx.out" >>"$VERIFY/results.txt"

        timeout "$TIMEOUT" bwrap --unshare-pid --die-with-parent --tmpfs / \
            --ro-bind "$TC" /tc --bind "$SMOKE" /work \
            --dev /dev --proc /proc --tmpfs /tmp \
            /tc/bin/clang -static /work/c.c -o /work/c_bwrap \
            >>"$VERIFY/results.txt" 2>&1 || die "bwrap C compile failed"
        timeout 60 bwrap --unshare-pid --die-with-parent --tmpfs / \
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
# 8. build-info
# ---------------------------------------------------------------------------
stage_build_info() {
    stage_begin build-info
    local cc_ver lld_ver base_ver musl_ver host_kernel
    cc_ver=$("$TC/bin/clang-9" --version 2>&1 | head -n 1)
    lld_ver=$("$TC/bin/ld.lld" --version 2>&1 | head -n 1)
    base_ver=$("$BASE/bin/clang-3.5" --version 2>&1 | head -n 1)
    musl_ver=$(cat "$ROOT/compiler-test/musl-1.2.6/VERSION" 2>/dev/null || echo unknown)
    host_kernel=$(uname -r)

    {
        echo "LLVM/Clang 9.0.1 static musl toolchain"
        echo "date (UTC)     : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "bootstrap      : $base_ver"
        echo "base toolchain : $BASE"
        echo "musl sysroot   : $MUSL"
        echo "llvm 9 sources : $LLVM9"
        echo "work/install   : $OUT"
        echo "toolchain      : $TC"
        echo
        echo "components:"
        echo "  clang        : $cc_ver"
        echo "                 stage1, built by clang 3.5.2"
        echo "  lld          : $lld_ver (ld.lld)"
        echo "                 stage1, built by clang 3.5.2"
        echo "  libc++       : 9.0.1 (llvm-project-9.0/libcxx, static, musl)"
        echo "  libc++abi    : 9.0.1 (libunwind 9 objects merged into libc++abi.a)"
        echo "  libunwind    : 9.0.1 (static)"
        echo "  compiler-rt  : 9.0.1 builtins + crtbegin/crtend"
        echo "  musl         : $musl_ver (from the clang 3.5 toolchain,"
        echo "                 -ffunction-sections rebuild)"
        echo "  Linux UAPI   : host $host_kernel ($HOST_TRIPLE)"
        echo
        echo "key cmake options:"
        echo "  common       : -G Ninja -DCMAKE_BUILD_TYPE=Release"
        echo "                 -DCMAKE_POLICY_VERSION_MINIMUM=3.5"
        echo "  stage1       : -DLLVM_TARGETS_TO_BUILD=X86"
        echo "                 -DLLVM_ENABLE_PROJECTS='clang;lld'"
        echo "                 -DLLVM_ENABLE_LIBCXX=ON"
        echo "                 -DCLANG_DEFAULT_CXX_STDLIB=libc++"
        echo "                 -DCLANG_DEFAULT_RTLIB=compiler-rt"
        echo "                 -DCMAKE_EXE_LINKER_FLAGS='-static -fuse-ld=ld -B$STAGE1_BIN'"
        echo "  compiler-rt  : -DCOMPILER_RT_BUILD_BUILTINS=ON"
        echo "                 -DCOMPILER_RT_BUILD_CRT=ON, all sanitizers/xray/"
        echo "                 libfuzzer/profile OFF"
        echo "  libc++abi    : -DLIBCXXABI_USE_LLVM_UNWINDER=ON"
        echo "                 libunwind.a manually merged into libc++abi.a"
        echo "  libc++       : -DLIBCXX_ENABLE_SHARED=OFF -DLIBCXX_HAS_MUSL_LIBC=ON"
        echo "                 -DLIBCXX_CXX_ABI=libcxxabi"
        echo "                 -DLIBCXX_ENABLE_FILESYSTEM=OFF"
        echo
        echo "clang 9 driver patches:"
        echo "  - AddCXXStdlibLibArgs: -lc++abi after -lc++"
        echo "  - GetLinkerPath: default to \$InstalledDir/ld.lld"
        echo "  - Linux::computeSysRoot: default sysroot is the install prefix"
        echo
        echo "build timings (seconds):"
        cat "$TIMINGS" 2>/dev/null || true
        echo
        echo "verification:"
        sed -n '1,240p' "$VERIFY/results.txt" 2>/dev/null || true
        echo
        echo "archive provenance:"
        echo "  libc++.a / libc++abi.a / libunwind.a objects carrying .comment"
        echo "  report clang version 9; no GCC 4.6/EDG objects."
        echo "  clang-9 and lld were built by the clang 3.5.2 bootstrap and"
        echo "  their .comment records that; they are not claimed as clang 9."
        echo
        echo "known limitations:"
        echo "  - Static executables only; shared libraries are not supported."
        echo "  - libc++ filesystem is disabled (LIBCXX_ENABLE_FILESYSTEM=OFF)."
        echo "  - No libstdc++; clang++ defaults to the bundled libc++."
        echo "  - stage1 is compiled at -O0 because clang 3.5's -O1/-O3"
        echo "    codegen intermittently segfaults on very large TUs"
        echo "    (ScalarEvolution.cpp, SemaChecking.cpp)."
        echo "  - the stage1 source copy patches LLVM's DenseMapIterator"
        echo "    assignment traits: clang 3.5 eagerly instantiates"
        echo "    DenseMap<incomplete-key, incomplete-value> via libc++ 9's"
        echo "    std::pair traits in JSON.h.  It also replaces seven"
        echo "    make_shared calls in VirtualFileSystem.cpp with"
        echo "    shared_ptr(new T(...)) to avoid a clang 3.5 frontend crash."
        echo "    Stage1/2 also define __inline__/__inline as inline because this"
        echo "    clang 3.5 build does not accept the GNU keyword spelling used"
        echo "    by its own SSE intrinsic headers."
        echo "    Stage1 uses a stage1-only libc++ memory header overlay whose"
        echo "    make_shared uses shared_ptr(new T(...)) instead of"
        echo "    __shared_ptr_emplace/forward_as_tuple; installed headers and"
        echo "    the final toolchain are unpatched."
        echo "  - llvm-config/opt/llc are copied from the stage1 build tree;"
        echo "    llvm-config reports build-tree paths and is not relocatable."
        echo "  - lld 9 and clang 9 are the bootstrap generation built by clang"
        echo "    3.5.2; libc++/libc++abi/libunwind/compiler-rt are built by"
        echo "    clang 9."
        echo
        echo "artifacts (sha256):"
        ( cd "$TC" && sha256sum bin/clang-9 bin/lld lib/libc++.a \
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
    if [ "$RESUME" = "1" ]; then
        [ -d "$TREE/llvm" ] || die "RESUME=1 but $TREE/llvm is missing"
        [ -x "$TC/bin/clang" ] || true
        mkdir -p "$LOG" "$SMOKE" "$VERIFY" "$STAGE1_BIN" "$TC"
        : >"$TIMINGS"
        grep -q 'bootstrap libc++ for clang 3.5' "$OUT/bootstrap-libcxx/memory" 2>/dev/null || \
            setup_bootstrap_libcxx
        info "RESUME=1: keeping $OUT and reusing the configured build trees"
    else
        stage_preflight
    fi
    stage_stage1
    stage_compiler_rt
    stage_musl
    stage_libunwind
    stage_libcxxabi
    stage_libcxx
    stage_verify
    stage_build_info

    info "LLVM 9 toolchain ready: $TC"
    info "build info: $TC/build-info.txt"
    info "logs: $LOG"
}

main "$@"
