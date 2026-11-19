#!/usr/bin/env bash
#
# Build LLVM 9 with the EDG 7.0 stage-2 C++ front end on top of the C-only
# GCC 4.6.4 + musl reference toolchain.
#
# Prerequisites (in the workspace root, one level above this script):
#   compiler-test/ref-rootfs-gcc4.6-c-only   C-only GCC 4.6.4 + musl + binutils
#   build/edg7.0-stage2/edgcpfe              EDG 7.0 stage-2 front end
#                                            (./build-edgcpp-stage2.sh)
#   build/edg7.0-edg5.1/base/                EDG 7.0 base (include, include_c99)
#   build/edg7.0-edg5.1/lib/libC.a           EDG 7.0 runtime library
#   llvm-project/                            LLVM 9.0.1 sources
#
# Inputs shipped next to this script (files/):
#   compat/atomic_decls.h, compat/atomic_compat.c, compat/weaken_inline.py
#   driver/edg-cxx, driver/cc46
#   predefined_macros.txt                    gnu-mode macro table for libc++ 9
#
# Environment variables:
#   REF          reference rootfs   (default: <root>/compiler-test/ref-rootfs-gcc4.6-c-only)
#   EDG_STAGE2   EDG 7.0 stage-2 dir (default: <root>/build/edg7.0-stage2)
#   EDG_STAGE1   EDG 7.0 stage-1 dir (default: <root>/build/edg7.0-edg5.1)
#   LLVM_SRC     LLVM 9 sources      (default: <root>/llvm-project)
#   WORK         work directory      (default: <root>/build/llvm-9-edg-7)
#   JOBS         parallel jobs       (default: nproc)
#   EDG_TIMEOUT  per-TU EDG timeout  (default: 3600)
#
# Current milestone: llvm-tblgen only.  The script deliberately exits after the
# llvm-tblgen verification; the full LLVM library and clang stages are written
# below the exit and are executed once that line is removed.
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$SCRIPT_DIR")
FILES=$SCRIPT_DIR/files
REF=${REF:-$ROOT/compiler-test/ref-rootfs-gcc4.6-c-only}
EDG_STAGE2=${EDG_STAGE2:-$ROOT/build/edg7.0-stage2}
EDG_STAGE1=${EDG_STAGE1:-$ROOT/build/edg7.0-edg5.1}
LLVM_SRC=${LLVM_SRC:-$ROOT/llvm-project}
WORK=${WORK:-$ROOT/build/llvm-9-edg-7}
JOBS=${JOBS:-$(nproc)}
EDG_TIMEOUT=${EDG_TIMEOUT:-3600}
export EDG_TIMEOUT
export EDG_ROOT="$ROOT"
export EDG_REF="$REF"

CC=$REF/usr/gcc4.6/bin/gcc
AR=$REF/usr/binutils/bin/ar
NM=$REF/usr/binutils/bin/nm
OBJCOPY=$REF/usr/binutils/bin/objcopy
LIBCXX=$LLVM_SRC/libcxx/include
LOG=$WORK/log

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

# ---------------------------------------------------------------- sanity ---

[ -d "$REF" ]                              || die "reference rootfs not found: $REF"
[ -x "$CC" ]                               || die "C compiler not found: $CC"
[ -x "$EDG_STAGE2/edgcpfe" ]               || die "EDG 7.0 stage-2 front end not found: $EDG_STAGE2/edgcpfe"
[ -d "$EDG_STAGE1/base/include" ]          || die "EDG 7.0 base not found: $EDG_STAGE1/base"
[ -s "$EDG_STAGE1/lib/libC.a" ]            || die "EDG 7.0 runtime library not found: $EDG_STAGE1/lib/libC.a"
[ -d "$LLVM_SRC/llvm" ]                    || die "LLVM sources not found: $LLVM_SRC/llvm"
[ -d "$FILES/compat" ]                     || die "missing input directory: $FILES/compat"
[ -d "$FILES/driver" ]                     || die "missing input directory: $FILES/driver"
[ -f "$FILES/predefined_macros.txt" ]      || die "missing $FILES/predefined_macros.txt"
command -v python3 >/dev/null              || die "python3 is required"
command -v cmake   >/dev/null              || die "cmake is required"
command -v ninja   >/dev/null              || die "ninja is required"

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

info "reference toolchain: $CC (GCC $GCC_VERSION), sysroot $GCC_SYSROOT"
info "EDG 7.0 stage-2  : $EDG_STAGE2/edgcpfe"
info "EDG 7.0 base     : $EDG_STAGE1/base"
info "LLVM sources     : $LLVM_SRC"
info "work directory   : $WORK"

rm -rf "$WORK"
mkdir -p "$WORK/log"

# ======================================================================
# Stage 1: EDG 7.0 stage-2 front end and its base directory
# ======================================================================
#
# The stage-2 front end is already built (build-edgcpp-stage2.sh).  It is
# copied into the work directory together with its EDG_BASE (include/
# include_c99/lib); files/predefined_macros.txt replaces the base's macro
# table with the gnu-mode table libc++ 9 needs.

info "stage 1: staging the EDG 7.0 stage-2 front end"
cp "$EDG_STAGE2/edgcpfe" "$WORK/edgcpfe"
chmod +x "$WORK/edgcpfe"
mkdir -p "$WORK/edg/lib"
cp -r "$EDG_STAGE1/base/include" "$WORK/edg/"
cp -r "$EDG_STAGE1/base/include_c99" "$WORK/edg/"
cp "$FILES/predefined_macros.txt" "$WORK/edg/lib/predefined_macros.txt"
"$WORK/edgcpfe" --version 2>&1 | grep -q 'version 7.0' || die "unexpected EDG version output"
EDG=$WORK/edgcpfe
EDG_BASE=$WORK/edg
info "EDG 7.0: $("$EDG" --version 2>&1 | head -1)"

# ======================================================================
# Stage 2: compat layer
# ======================================================================

info "stage 2: building the compat layer"
cp -r "$FILES/compat/." "$WORK/compat/"
chmod +x "$WORK/compat/weaken_inline.py"
mkdir -p "$WORK/compat/obj"
"$CC" -std=gnu99 -O2 -w -c "$WORK/compat/atomic_compat.c" -o "$WORK/compat/obj/atomic_compat.o"
"$AR" rcs "$WORK/compat/libcompat.a" "$WORK/compat/obj/atomic_compat.o"
info "libcompat.a: $("$AR" t "$WORK/compat/libcompat.a" | wc -l) objects"

# ======================================================================
# Stage 3: libc++ 9
# ======================================================================

OUT=$WORK/lib
mkdir -p "$OUT" "$WORK/lcx" "$WORK/lcxobj"

info "stage 3: building libc++ 9 (33 TUs) with EDG 7.0"
lcx_fail=0
for src in "$LLVM_SRC"/libcxx/src/*.cpp; do
  base=$(basename "$src" .cpp)
  if ! (
    cd "$WORK"
    "$EDG" --edg_base_dir="$EDG_BASE" \
      --c++14 --g++ --gnu_version=50000 -tused -w \
      -D__ELF__ -D_GNU_SOURCE -D_LARGEFILE64_SOURCE \
      -D_LIBCPP_BUILDING_LIBRARY -D_LIBCPP_HAS_MUSL_LIBC \
      -I "$LIBCXX" \
      --sys_include="$REF/usr/include" \
      --sys_include="$GCC_INC" \
      --gen_c_file_name="$WORK/lcx/$base.int.c" "$src"
  ) >"$LOG/$base.edg.log" 2>&1; then
    printf 'libc++ EDG failure: %s\n' "$base" >&2; lcx_fail=1; continue
  fi
  python3 "$WORK/compat/weaken_inline.py" "$WORK/lcx/$base.int.c"
  "$CC" -std=gnu99 -O0 -w -Wl,-z,noexecstack \
        -include "$WORK/compat/atomic_decls.h" \
        -c "$WORK/lcx/$base.int.c" -o "$WORK/lcxobj/$base.o" >"$LOG/$base.gcc.log" 2>&1 || {
    printf 'libc++ gcc failure: %s\n' "$base" >&2; lcx_fail=1; }
done
[ "$lcx_fail" -eq 0 ] || die "libc++ build failed (see $LOG/*.log)"
"$AR" rcs "$OUT/libc++_ia64.a" "$WORK"/lcxobj/*.o
info "libc++_ia64.a: $(ls "$WORK"/lcxobj/*.o | wc -l) objects, $(stat -c %s "$OUT/libc++_ia64.a") bytes"

# ======================================================================
# Stage 4: EDG 7.0 runtime library (weak overlap with libc++)
# ======================================================================

info "stage 4: weakening the EDG 7.0 runtime overlap with libc++"
cp "$EDG_STAGE1/lib/libC.a" "$WORK/libC_full.a"
"$NM" --defined-only "$OUT/libc++_ia64.a" | awk '{print $3}' | grep -v '^$' | sort -u > "$WORK/lx_syms.txt"
"$NM" --defined-only "$WORK/libC_full.a"   | awk '{print $3}' | grep -v '^$' | sort -u > "$WORK/rt_syms.txt"
comm -12 "$WORK/lx_syms.txt" "$WORK/rt_syms.txt" > "$WORK/ov_syms.txt"
info "runtime/libc++ symbol overlap: $(wc -l < "$WORK/ov_syms.txt") (weakening runtime copies)"
rm -rf "$WORK/rtextract"; mkdir -p "$WORK/rtextract"
(
  cd "$WORK/rtextract"
  "$AR" x "$WORK/libC_full.a"
)
mkdir -p "$WORK/rtweak"
for o in "$WORK"/rtextract/*.o; do
  b=$(basename "$o")
  common=$("$NM" --defined-only "$o" | awk '{print $3}' | grep -v '^$' | sort -u | comm -12 - "$WORK/ov_syms.txt" || true)
  if [ -n "$common" ]; then
    "$OBJCOPY" $(printf -- '-W %s ' $common) "$o" "$WORK/rtweak/$b" || cp "$o" "$WORK/rtweak/$b"
  else
    cp "$o" "$WORK/rtweak/$b"
  fi
done
"$AR" rcs "$OUT/libC_ia64_weak.a" "$WORK"/rtweak/*.o
info "libC_ia64_weak.a: $(ls "$WORK"/rtweak/*.o | wc -l) objects, $(stat -c %s "$OUT/libC_ia64_weak.a") bytes"

# ======================================================================
# Stage 5: CMake C++ driver
# ======================================================================

info "stage 5: installing the CMake C++ driver"
mkdir -p "$WORK/driver"
cp "$FILES/driver/edg-cxx" "$FILES/driver/cc46" "$WORK/driver/"
chmod +x "$WORK/driver/edg-cxx" "$WORK/driver/cc46"
"$WORK/driver/edg-cxx" --version | grep -q '4.6.4' || die "driver --version check failed"

# ======================================================================
# Stage 6: libc++ smoke tests
# ======================================================================

info "stage 6: libc++ smoke tests"
TESTS=$WORK/tests
mkdir -p "$TESTS"
cat > "$TESTS/vector_string.cpp" <<'EOF'
#include <vector>
#include <string>
#include <algorithm>
int main() {
  std::vector<int> v{3, 1, 2};
  std::sort(v.begin(), v.end());
  std::string s = "hello";
  s += " world";
  return (v[0] == 1 && v[2] == 3 && s.size() == 11 && s[6] == 'w') ? 0 : 1;
}
EOF
cat > "$TESTS/iostream_eh.cpp" <<'EOF'
#include <iostream>
#include <string>
#include <vector>
#include <stdexcept>
int main() {
  std::vector<int> v{1, 2, 3};
  std::cout << "hello " << v.size() << "\n";
  std::string s = "42";
  int n = std::stoi(s);
  std::cout << "stoi=" << n << "\n";
  try { v.at(5); }
  catch (const std::out_of_range &e) { std::cout << "caught: " << e.what() << "\n"; }
  return (n == 42) ? 0 : 1;
}
EOF
cat > "$TESTS/multi_tu_a.cpp" <<'EOF'
#include <string>
#include <iostream>
std::string make();
int bump(int x);
int main() { std::cout << make() << " " << bump(1) << "\n"; return 0; }
EOF
cat > "$TESTS/multi_tu_b.cpp" <<'EOF'
#include <string>
#include <vector>
std::string make() { return "multi-tu"; }
int bump(int x) { std::vector<int> v{x, x + 1}; return v[0] + v[1] - x; }
EOF

"$WORK/driver/edg-cxx" "$TESTS/vector_string.cpp" -o "$TESTS/vector_string" >>"$LOG/tests.log" 2>&1 \
  || die "smoke test vector_string did not compile/link"
"$TESTS/vector_string" || die "smoke test vector_string failed at run time"

"$WORK/driver/edg-cxx" "$TESTS/iostream_eh.cpp" -o "$TESTS/iostream_eh" >>"$LOG/tests.log" 2>&1 \
  || die "smoke test iostream_eh did not compile/link"
out=$("$TESTS/iostream_eh") || die "smoke test iostream_eh failed at run time"
printf '%s\n' "$out"
printf '%s\n' "$out" | grep -q 'hello 3'   || die "unexpected iostream output"
printf '%s\n' "$out" | grep -q 'stoi=42'   || die "unexpected stoi output"
printf '%s\n' "$out" | grep -q 'caught: vector' || die "out_of_range was not caught"

"$WORK/driver/edg-cxx" "$TESTS/multi_tu_a.cpp" "$TESTS/multi_tu_b.cpp" \
  -o "$TESTS/multi_tu" >>"$LOG/tests.log" 2>&1 || die "smoke test multi_tu did not compile/link"
"$TESTS/multi_tu" | grep -q 'multi-tu 2' || die "unexpected multi_tu output"
info "smoke tests passed (vector/string, iostream + std::stoi + exceptions, multi-TU)"

# ======================================================================
# Stage 7: LLVM 9 CMake configuration and llvm-tblgen
# ======================================================================

info "stage 7: configuring LLVM 9 (CMake + Ninja)"
cmake -G Ninja -S "$LLVM_SRC/llvm" -B "$WORK/llvm-build" \
  -DCMAKE_C_COMPILER="$WORK/driver/cc46" \
  -DCMAKE_CXX_COMPILER="$WORK/driver/edg-cxx" \
  -DCMAKE_ASM_COMPILER="$CC" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DLLVM_FORCE_USE_OLD_TOOLCHAIN=ON \
  -DLLVM_TARGETS_TO_BUILD=X86 \
  -DLLVM_ENABLE_PROJECTS= \
  -DLLVM_ENABLE_TERMINFO=OFF \
  -DLLVM_ENABLE_ZLIB=OFF \
  -DLLVM_ENABLE_LIBXML2=OFF \
  -DLLVM_ENABLE_ASSERTIONS=OFF \
  -DLLVM_ENABLE_BINDINGS=OFF \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_INCLUDE_DOCS=OFF \
  -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DCMAKE_CXX_STANDARD=14 \
  -DCMAKE_CXX_COMPILER_ABI=ELF \
  -DCMAKE_C_COMPILER_ABI=ELF \
  -DCMAKE_BUILD_TYPE=Release >>"$LOG/cmake-configure.log" 2>&1 \
  || die "LLVM CMake configuration failed (see $LOG/cmake-configure.log)"

info "stage 7: building llvm-tblgen (-j $JOBS)"
cmake --build "$WORK/llvm-build" --target llvm-tblgen -j "$JOBS" \
  >>"$LOG/tblgen-build.log" 2>&1 \
  || die "llvm-tblgen build failed (see $LOG/tblgen-build.log)"

TBLGEN=$WORK/llvm-build/bin/llvm-tblgen
[ -x "$TBLGEN" ] || die "llvm-tblgen was not produced"
"$TBLGEN" --version 2>&1 | grep -q 'LLVM version 9' || die "unexpected llvm-tblgen version"
info "llvm-tblgen: $("$TBLGEN" --version 2>&1 | sed -n '2p')"

info "stage 7: llvm-tblgen functional test (X86.td)"
"$TBLGEN" --print-records "$LLVM_SRC/llvm/lib/Target/X86/X86.td" \
  -I "$LLVM_SRC/llvm/include" -I "$LLVM_SRC/llvm/lib/Target/X86" \
  >"$LOG/tblgen-smoke.txt" 2>&1 || die "llvm-tblgen failed on X86.td"
info "X86.td records: $(wc -l < "$LOG/tblgen-smoke.txt") lines"

printf '\n'
printf 'milestone reached: llvm-tblgen built with EDG 7.0 stage-2\n'
printf '  front end       : %s\n' "$EDG"
printf '  EDG base        : %s\n' "$EDG_BASE"
printf '  libc++          : %s\n' "$OUT/libc++_ia64.a"
printf '  EDG runtime     : %s\n' "$OUT/libC_ia64_weak.a"
printf '  compat library  : %s\n' "$WORK/compat/libcompat.a"
printf '  CMake C++ driver: %s\n' "$WORK/driver/edg-cxx"
printf '  llvm-tblgen     : %s\n' "$TBLGEN"
printf '  build logs      : %s\n' "$LOG"

# ======================================================================
# EARLY EXIT
# ======================================================================
# The LLVM library / clang stages below are intentionally not executed in this
# run (LLVM takes hours).  Remove the next `exit 0` to continue the build.
info "stopping here: full LLVM libraries and clang are the next stages"
exit 0

# ======================================================================
# Stage 8 (later): full LLVM libraries and tools
# ======================================================================

info "stage 8: building all LLVM libraries and tools (-j $JOBS, keep going)"
cmake --build "$WORK/llvm-build" -j "$JOBS" -- -k 0 >>"$LOG/llvm-full.log" 2>&1 \
  || die "LLVM build failed (see $LOG/llvm-full.log)"
info "LLVM libraries built: $(ls "$WORK/llvm-build"/lib/*.a | wc -l) archives"

# ======================================================================
# Stage 9 (later): clang (stage-1)
# ======================================================================

info "stage 9: configuring clang"
cmake -S "$LLVM_SRC/llvm" -B "$WORK/llvm-build" \
  -DLLVM_ENABLE_PROJECTS=clang >>"$LOG/cmake-clang.log" 2>&1 \
  || die "clang CMake configuration failed (see $LOG/cmake-clang.log)"
info "stage 9: building clang (-j $JOBS)"
cmake --build "$WORK/llvm-build" --target clang -j "$JOBS" \
  >>"$LOG/clang-build.log" 2>&1 || die "clang build failed (see $LOG/clang-build.log)"
CLANG=$WORK/llvm-build/bin/clang
[ -x "$CLANG" ] || die "clang was not produced"
"$CLANG" --version | grep -q 'clang version 9' || die "unexpected clang version"
info "clang: $("$CLANG" --version 2>&1 | head -1)"

# ======================================================================
# Stage 10 (later): stage-2 libc++ / libc++abi built by clang
# ======================================================================

info "stage 10: building libc++ with the stage-1 clang"
cmake -S "$LLVM_SRC/libcxx" -B "$WORK/libcxx-clang" \
  -G Ninja -DCMAKE_C_COMPILER="$CLANG" -DCMAKE_CXX_COMPILER="$CLANG" \
  -DLLVM_PATH="$WORK/llvm-build" >>"$LOG/libcxx-clang.log" 2>&1 \
  || die "stage-2 libc++ configuration failed"
cmake --build "$WORK/libcxx-clang" -j "$JOBS" >>"$LOG/libcxx-clang.log" 2>&1 \
  || die "stage-2 libc++ build failed"

printf '\nbuild finished (all stages)\n'
