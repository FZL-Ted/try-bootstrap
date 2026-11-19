#!/usr/bin/env bash
#
# Build the latest EDG C/C++ front end (release 7.0, from the
# edgcpp-compiler-7.0.tar.gz release tarball) with the EDG 5.1 front end that
# was itself built by the C-only GCC 4.6.4 toolchain in
# ./build/edg5.1-gcc4.6c/edg-5.1.
#
# EDG's front end emits C, not machine code: every C++ source is translated to
# a C file by the front end and that C file is then compiled by GCC 4.6.  This
# script reproduces that pipeline without CMake:
#
#   * the compiler sources are translated by EDG 5.1 (cfront ABI output),
#     compiled by GCC 4.6 and linked against the EDG 5.1 runtime library;
#   * the resulting EDG 7.0 front end then translates the EDG 7.0 runtime
#     sources (lib_src/) to C, which GCC 4.6 compiles into a second, matching
#     runtime library (7.0 Linux builds default to the Itanium ABI);
#   * two smoke tests are translated, compiled, linked against that 7.0
#     runtime and executed.
#
# Inputs that must already exist:
#
#   build/edg5.1-gcc4.6c/edg-5.1/build/edgcpfe   EDG 5.1 front end
#   build/edg5.1-gcc4.6c/edg-5.1/lib/libC.a      EDG 5.1 runtime library
#   compiler-test/ref-rootfs-gcc4.6-c-only       C-only GCC 4.6.4 + musl rootfs
#   edgcpp-compiler-7.0.tar.gz                   EDG 7.0 release tarball
#   edg-support/predefined/edg5.1/predefined_macros.txt
#                                                predefines table used by 5.1
#
# Everything the build produces goes under ./build/edg7.0-edg5.1:
#
#   src/             the extracted EDG 7.0 source tree
#   edgcpfe          the EDG 7.0 front end
#   lib/libC.a       the matching EDG 7.0 runtime library
#   base/            EDG_BASE directory for the new front end
#   gen/ obj/ rt/    generated C, objects, logs and smoke tests
#
# Usage:
#     ./build-edgcpp-by-edg-5.1.sh
#
# Overridable environment variables:
#     REF               reference rootfs (default: compiler-test/ref-rootfs-gcc4.6-c-only)
#     TARBALL           EDG 7.0 tarball (default: edgcpp-compiler-7.0.tar.gz)
#     EDG51             EDG 5.1 front end (default: build/edg5.1-gcc4.6c/edg-5.1/build/edgcpfe)
#     EDG51_BASE        EDG 5.1 base directory (default: build/edg5.1-gcc4.6c/edg-5.1)
#     PREDEF            predefined macros (default: edg-support/predefined/edg5.1/predefined_macros.txt)
#     WORK              build directory (default: build/edg7.0-edg5.1)
#     OPT               GCC optimization flag (default: -O2; use -O0 to speed up)
#     EDG_TIMEOUT       per-translation timeout in seconds (default: 1800)
#     GCC_TIMEOUT       per-compilation timeout in seconds (default: 1800)
#     EDG_GNU_VERSION   GNU emulation version for the 5.1 translator (default: 50000)
#
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
REF=${REF:-$ROOT/compiler-test/ref-rootfs-gcc4.6-c-only}
TARBALL=${TARBALL:-$ROOT/edgcpp-compiler-7.0.tar.gz}
EDG51=${EDG51:-$ROOT/build/edg5.1-gcc4.6c/edg-5.1/build/edgcpfe}
EDG51_BASE=${EDG51_BASE:-$ROOT/build/edg5.1-gcc4.6c/edg-5.1}
PREDEF=${PREDEF:-$ROOT/edg-support/predefined/edg5.1/predefined_macros.txt}
WORK=${WORK:-$ROOT/build/edg7.0-edg5.1}
SRC=$WORK/src
OPT=${OPT:--O2}
EDG_TIMEOUT=${EDG_TIMEOUT:-1800}
GCC_TIMEOUT=${GCC_TIMEOUT:-1800}
EDG_GNU_VERSION=${EDG_GNU_VERSION:-50000}

CC=$REF/usr/gcc4.6/bin/gcc
AR=$REF/usr/binutils/bin/ar
[ -x "$AR" ] || AR=ar

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

# ---------------------------------------------------------------- sanity ---

[ -d "$REF" ]     || die "reference rootfs not found: $REF"
[ -x "$CC" ]      || die "C compiler not found: $CC"
[ -f "$TARBALL" ] || die "release tarball not found: $TARBALL"
[ -s "$TARBALL" ] || die "release tarball is empty: $TARBALL"
command -v python3 >/dev/null 2>&1 || die "python3 not found"
[ -x "$EDG51" ]   || die "EDG 5.1 front end not found: $EDG51"
[ -d "$EDG51_BASE" ] || die "EDG 5.1 base directory not found: $EDG51_BASE"
[ -s "$EDG51_BASE/lib/libC.a" ] || \
  die "EDG 5.1 runtime library not found: $EDG51_BASE/lib/libC.a"
[ -d "$EDG51_BASE/include_c++" ] || \
  die "EDG 5.1 include_c++ not found: $EDG51_BASE/include_c++"
[ -f "$PREDEF" ]  || die "predefined macro table not found: $PREDEF"
[ -s "$PREDEF" ]  || die "predefined macro table is empty: $PREDEF"

# The build directory is removed and recreated, so never allow it to be an
# input directory (or the workspace root itself).
[ -n "$WORK" ] || die "empty build directory"
case "$WORK" in
  "$ROOT"|"$ROOT/build"|"$ROOT/build/edg5.1-gcc4.6c"|"$REF"|"$EDG51_BASE"|"/")
    die "refusing to use $WORK as the build directory" ;;
esac
case "$WORK" in
  "$ROOT/build"/*) ;;
  *) die "build directory must be inside $ROOT/build: $WORK" ;;
esac

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

V51_FULL=$("$EDG51" --version 2>&1) || die "EDG 5.1 front end failed to run"
V51=${V51_FULL%%$'\n'*}
case "$V51" in
  *"version 5.1"*) ;;
  *) die "unexpected EDG 5.1 version output: $V51" ;;
esac

TARBALL_SIZE=$(stat -c %s "$TARBALL")
TARBALL_SHA=$(sha256sum "$TARBALL" | cut -d' ' -f1)

info "host build with $CC"
info "cc version: $GCC_VERSION   sysroot: $GCC_SYSROOT"
info "EDG 5.1 front end: $EDG51 ($V51)"
info "source tarball: $TARBALL ($TARBALL_SIZE bytes, sha256 $TARBALL_SHA)"
info "build directory: $WORK"

rm -rf "$WORK"
mkdir -p "$WORK/includes" "$WORK/gen" "$WORK/obj" "$WORK/tools" \
         "$WORK/rt/gen" "$WORK/rt/obj" "$WORK/lib" "$WORK/base/lib" \
         "$WORK/log" "$WORK/tests" "$SRC"
touch "$WORK/.start"
START=$(date +%s)
START_UTC=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

# ------------------------------------------------------------ extract src ---

info "extracting $TARBALL to $SRC"
tar -xzf "$TARBALL" -C "$SRC" --strip-components=1 || \
  die "extracting $TARBALL failed"
[ -f "$SRC/src/cfe.c" ] || die "unexpected source tree: $SRC/src/cfe.c missing"
[ -f "$SRC/src/CMakeLists.txt" ] || die "missing $SRC/src/CMakeLists.txt"
[ -d "$SRC/lib_src" ] || die "missing $SRC/lib_src"
[ -f "$SRC/dev_tools/bin/edg-cmakedef" ] || \
  die "missing $SRC/dev_tools/bin/edg-cmakedef"

# ------------------------------------------------------- configuration ---
#
# The release's build system derives its macro configuration from cmake/*.cmakedef
# files.  edg-cmakedef is a standalone Python tool, so the same configuration
# can be generated without running CMake.

info "generating includes/cmake_defines.h from linux-gcc/base.cmakedef"
(
  cd "$SRC"
  python3 dev_tools/bin/edg-cmakedef cmake/macro-conf \
    linux-gcc/base.cmakedef print-defines
) > "$WORK/includes/cmake_defines.h" 2> "$WORK/log/edg-cmakedef.log" || \
  die "edg-cmakedef failed (see $WORK/log/edg-cmakedef.log)"
[ -s "$WORK/includes/cmake_defines.h" ] || \
  die "cmake_defines.h was not generated"

info "collecting runtime library defines from linux-gcc/cpprtlib.cmakedef"
(
  cd "$SRC"
  python3 dev_tools/bin/edg-cmakedef cmake/macro-conf \
    linux-gcc/cpprtlib.cmakedef print-values
) > "$WORK/log/cpprtlib-defines.txt" 2> "$WORK/log/edg-cmakedef-rt.log" || \
  die "edg-cmakedef failed for cpprtlib (see $WORK/log/edg-cmakedef-rt.log)"
RT_DEFINES=()
while IFS= read -r d; do
  [ -n "$d" ] && RT_DEFINES+=("-D$d")
done < "$WORK/log/cpprtlib-defines.txt"
[ "${#RT_DEFINES[@]}" -gt 0 ] || die "no runtime library defines were produced"

# ------------------------------------------------- common EDG 5.1 flags ---
#
# The front end sources are C++14 (CMake sets CMAKE_CXX_STANDARD 14) and are
# built by CMake with -fno-exceptions -fno-rtti.  GNU emulation is needed for
# musl's __builtin_va_list, and __CHAR_BIT__ is supplied the same way EDG's
# own driver supplies it.  EDG 5.1 predates __float128 support, so the three
# floating-point configuration macros are overridden to keep targ_def.h from
# requiring a 128-bit host floating-point type.
#
FE_COMMON=(
  --c++14 --g++ --gnu_version="$EDG_GNU_VERSION"
  --no_exceptions --no_rtti
  --edg_base_dir="$EDG51_BASE"
  -DUSE_CMAKE_DEFINES
  -D__CHAR_BIT__=8
  -DUSE_FLOAT128_FOR_HOST_FP_VALUE=0
  -DUSE_QUADMATH_LIBRARY=0
  -DFLOAT128_ENABLING_POSSIBLE=0
  -I"$WORK/includes"
  -I"$SRC/src"
  --sys_include="$EDG51_BASE/include_c++"
  --sys_include="$REF/usr/include"
  --sys_include="$GCC_INC"
  -tused
)

# ------------------------------------------------------------- mk_errinfo ---
#
# The front end needs err_codes.h and err_data.h, generated from the textual
# error tables by util/mk_errinfo (C++ since 6.0, but plain enough for 5.1).

info "building mk_errinfo with EDG 5.1"
(
  cd "$WORK"
  timeout "$EDG_TIMEOUT" "$EDG51" "${FE_COMMON[@]}" -I"$SRC/util" \
    --gen_c_file_name="$WORK/gen/mk_errinfo.int.c" \
    "$SRC/util/mk_errinfo.c"
) > "$WORK/log/mk_errinfo.edg.log" 2>&1 || \
  die "EDG 5.1 failed to translate util/mk_errinfo.c (see $WORK/log/mk_errinfo.edg.log)"
timeout "$GCC_TIMEOUT" "$CC" -std=gnu99 "$OPT" -w \
  -c "$WORK/gen/mk_errinfo.int.c" -o "$WORK/tools/mk_errinfo.o" \
  > "$WORK/log/mk_errinfo.cc.log" 2>&1 || \
  die "GCC $GCC_VERSION failed to compile mk_errinfo.int.c (see $WORK/log/mk_errinfo.cc.log)"
"$CC" -o "$WORK/mk_errinfo" "$WORK/tools/mk_errinfo.o" \
  -L"$EDG51_BASE/lib" -lC -lm -Wl,-z,noexecstack \
  > "$WORK/log/mk_errinfo.link.log" 2>&1 || \
  die "linking mk_errinfo failed (see $WORK/log/mk_errinfo.link.log)"
(
  cd "$WORK"
  ./mk_errinfo "$SRC/src/error_msg.txt" "$SRC/src/error_tag.txt" \
    "$WORK/includes/err_codes.h" "$WORK/includes/err_data.h"
) > "$WORK/log/mk_errinfo.run.log" 2>&1 || \
  die "running mk_errinfo failed (see $WORK/log/mk_errinfo.run.log)"
[ -s "$WORK/includes/err_codes.h" ] && [ -s "$WORK/includes/err_data.h" ] || \
  die "error message tables were not generated"

# ------------------------------------------------------ cpfe source list ---
#
# Parse the same list the release's CMake build uses instead of hard-coding
# it, so a newer release with added or removed files is handled.

info "extracting the cpfe source list from src/CMakeLists.txt"
python3 - "$SRC" > "$WORK/sources.txt" <<'PY' || die "could not extract the cpfe source list"
import os
import re
import sys

src = sys.argv[1]
text = open(os.path.join(src, "src", "CMakeLists.txt"), encoding="utf-8").read()
match = re.search(r"set\(CORE_FRONT_END_SOURCE_FILES(.*?)\)\n", text, re.S)
if match is None:
  raise SystemExit("CORE_FRONT_END_SOURCE_FILES not found")
files = match.group(1).split()
files += re.findall(r"add_src_file_if_present\(([^)]+)\)", text)
missing = [f for f in files
           if not os.path.isfile(os.path.join(src, "src", f))]
if missing:
  raise SystemExit("missing source files: " + " ".join(missing))
if not files:
  raise SystemExit("empty cpfe source list")
print("\n".join(files))
PY
SRC_COUNT=$(wc -l < "$WORK/sources.txt" | tr -d ' ')
[ "$SRC_COUNT" -gt 0 ] || die "no cpfe sources found"
info "cpfe sources: $SRC_COUNT"

# -------------------------------------------- translate and compile cpfe ---
#
# EDG 5.1 emits C for every translation unit; each C file is compiled by GCC
# 4.6.  The front end is linked against the 5.1 runtime library below because
# the emitted code is 5.1 cfront-ABI code.

info "translating $SRC_COUNT cpfe sources with EDG 5.1"
translate_fail=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  base=${f%.c}
  log=$WORK/log/fe-$base.edg.log
  if ! ( cd "$WORK" && timeout "$EDG_TIMEOUT" "$EDG51" "${FE_COMMON[@]}" \
           --gen_c_file_name="$WORK/gen/$base.int.c" "$SRC/src/$f" ) \
         > "$log" 2>&1; then
    printf 'FAIL translate %s (see %s)\n' "$f" "$log" >&2
    tail -n 6 "$log" >&2 || true
    translate_fail=$((translate_fail + 1))
  fi
done < "$WORK/sources.txt"
[ "$translate_fail" -eq 0 ] || \
  die "$translate_fail of $SRC_COUNT cpfe sources failed to translate (see $WORK/log)"

info "compiling the generated C with GCC $GCC_VERSION"
FE_OBJS=()
compile_fail=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  base=${f%.c}
  log=$WORK/log/fe-$base.cc.log
  if ! timeout "$GCC_TIMEOUT" "$CC" -std=gnu99 "$OPT" -w \
         -c "$WORK/gen/$base.int.c" -o "$WORK/obj/$base.o" \
         > "$log" 2>&1; then
    printf 'FAIL compile %s (see %s)\n' "$base.int.c" "$log" >&2
    tail -n 6 "$log" >&2 || true
    compile_fail=$((compile_fail + 1))
    continue
  fi
  [ -s "$WORK/obj/$base.o" ] || {
    printf 'FAIL empty object %s\n' "$WORK/obj/$base.o" >&2
    compile_fail=$((compile_fail + 1))
    continue
  }
  FE_OBJS+=("$WORK/obj/$base.o")
done < "$WORK/sources.txt"
[ "$compile_fail" -eq 0 ] || \
  die "$compile_fail of $SRC_COUNT cpfe sources failed to compile (see $WORK/log)"
[ "${#FE_OBJS[@]}" -eq "$SRC_COUNT" ] || \
  die "expected $SRC_COUNT front end objects, got ${#FE_OBJS[@]}"

# ------------------------------------------------------ link EDG 7.0 cpfe ---
#
# EDG 5.1 has no prelinker here: -tused emits template instantiations in every
# translation unit, so identical strong definitions occur more than once.  All
# translation units use the same flags, so the duplicates are identical and
# --allow-multiple-definition is safe.  (The real EDG build uses a prelinker.)

info "linking edgcpfe 7.0"
"$CC" -o "$WORK/edgcpfe" "${FE_OBJS[@]}" \
  -L"$EDG51_BASE/lib" -lC -lm \
  -Wl,-z,noexecstack -Wl,--allow-multiple-definition \
  > "$WORK/log/edgcpfe.link.log" 2>&1 || {
    tail -n 20 "$WORK/log/edgcpfe.link.log" >&2 || true
    die "linking edgcpfe failed (see $WORK/log/edgcpfe.link.log)"
  }
[ -x "$WORK/edgcpfe" ] || die "edgcpfe was not produced"
[ -s "$WORK/edgcpfe" ] || die "edgcpfe is empty"

V70_FULL=$("$WORK/edgcpfe" --version 2>&1) || die "edgcpfe --version failed"
V70=${V70_FULL%%$'\n'*}
case "$V70" in
  *"version 7.0"*) ;;
  *) die "unexpected EDG 7.0 version output: $V70" ;;
esac
info "edgcpfe: $V70"

# ---------------------------------------------------- EDG 7.0 base dir ---
#
# The front end reads lib/predefined_macros.txt from EDG_BASE and the C++
# headers from EDG_BASE/include.  Copy the release's headers so the result is
# self-contained.

info "installing EDG_BASE for the 7.0 front end"
cp "$PREDEF" "$WORK/base/lib/predefined_macros.txt"
cp -R "$SRC/include_c++" "$WORK/base/include"
cp -R "$SRC/include_c99" "$WORK/base/include_c99"
[ -s "$WORK/base/lib/predefined_macros.txt" ] || \
  die "predefined_macros.txt was not installed in the base directory"
[ -d "$WORK/base/include" ] || die "the 7.0 base directory has no include/"

# ------------------------------------------ EDG 7.0 runtime library ---
#
# 7.0 Linux builds default to the Itanium ABI (IA64_ABI=1), which the 5.1
# runtime library does not implement.  Build the matching runtime with the new
# front end.  lib_src is compiled with --c++23 --building_runtime, the same
# mode the release's CMake build uses.

info "translating the EDG 7.0 runtime sources with the new front end"
RT_SRC=("$SRC"/lib_src/*.c)
[ -e "${RT_SRC[0]}" ] || die "no runtime sources found in $SRC/lib_src"
RT_FLAGS=(
  --c++23 --g++ --building_runtime
  --edg_base_dir="$WORK/base"
  -DCHECKING=1 -DDEBUG=1
  "${RT_DEFINES[@]}"
  -I"$SRC/lib_src"
  --sys_include="$WORK/base/include"
  --sys_include="$REF/usr/include"
  --sys_include="$GCC_INC"
)
RT_OBJS=()
RT_FAIL=0
for src in "${RT_SRC[@]}"; do
  base=$(basename "$src" .c)
  gen=$WORK/rt/gen/$base.int.c
  obj=$WORK/rt/obj/$base.o
  if ! ( cd "$WORK" && timeout "$EDG_TIMEOUT" "$WORK/edgcpfe" "${RT_FLAGS[@]}" \
           --gen_c_file_name="$gen" "$src" ) \
         > "$WORK/log/rt-$base.edg.log" 2>&1; then
    printf 'FAIL translate runtime source %s (see %s)\n' \
      "$base.c" "$WORK/log/rt-$base.edg.log" >&2
    tail -n 6 "$WORK/log/rt-$base.edg.log" >&2 || true
    RT_FAIL=$((RT_FAIL + 1))
    continue
  fi
  if ! timeout "$GCC_TIMEOUT" "$CC" -std=gnu99 "$OPT" -w -fPIC \
         -c "$gen" -o "$obj" > "$WORK/log/rt-$base.cc.log" 2>&1; then
    printf 'FAIL compile runtime source %s (see %s)\n' \
      "$base.int.c" "$WORK/log/rt-$base.cc.log" >&2
    tail -n 6 "$WORK/log/rt-$base.cc.log" >&2 || true
    RT_FAIL=$((RT_FAIL + 1))
    continue
  fi
  [ -s "$obj" ] || { RT_FAIL=$((RT_FAIL + 1)); continue; }
  RT_OBJS+=("$obj")
done
[ "$RT_FAIL" -eq 0 ] || \
  die "$RT_FAIL of ${#RT_SRC[@]} runtime sources failed (see $WORK/log)"
[ "${#RT_OBJS[@]}" -eq "${#RT_SRC[@]}" ] || \
  die "expected ${#RT_SRC[@]} runtime objects, got ${#RT_OBJS[@]}"

info "creating lib/libC.a from ${#RT_OBJS[@]} runtime objects"
"$AR" rcs "$WORK/lib/libC.a" "${RT_OBJS[@]}" \
  > "$WORK/log/libC.ar.log" 2>&1 || \
  die "creating lib/libC.a failed (see $WORK/log/libC.ar.log)"
[ -s "$WORK/lib/libC.a" ] || die "lib/libC.a was not produced"
RT_AR_COUNT=$("$AR" t "$WORK/lib/libC.a" | wc -l | tr -d ' ')
[ "$RT_AR_COUNT" -eq "${#RT_OBJS[@]}" ] || \
  die "lib/libC.a contains $RT_AR_COUNT objects, expected ${#RT_OBJS[@]}"

# ---------------------------------------------------------- smoke tests ---
#
# These exercise the 7.0 front end and its own runtime library: virtual
# functions, templates, a lambda, range-for, if constexpr, and exceptions.

SMOKE=(
  --c++17 --g++
  -tused
  --edg_base_dir="$WORK/base"
  --sys_include="$WORK/base/include"
  --sys_include="$REF/usr/include"
  --sys_include="$GCC_INC"
)

cat > "$WORK/tests/smoke_cxx.cpp" <<'EOF'
struct Base { virtual int f() const { return 1; } };
struct Derived : Base { int f() const override { return 2; } };

template <class T> T twice(T v) { return v + v; }

int main() {
  Derived d;
  Base *p = &d;
  int a[3] = {1, 2, 3};
  int s = 0;
  for (int v : a) s += v;
  auto l = [](int x) { return x * 3; };
  if constexpr (sizeof(int) >= 4) s += 0;
  return (p->f() == 2 && twice(21) == 42 && s == 6 && l(2) == 6) ? 0 : 1;
}
EOF

cat > "$WORK/tests/smoke_eh.cpp" <<'EOF'
int main() {
  int r = 0;
  try { throw 42; }
  catch (int v) { r = v; }
  catch (...) { r = -1; }
  return r == 42 ? 0 : 1;
}
EOF

for name in smoke_cxx smoke_eh; do
  info "smoke test: $name"
  src=$WORK/tests/$name.cpp
  gen=$WORK/tests/$name.int.c
  obj=$WORK/tests/$name.o
  exe=$WORK/tests/$name.out
  ( cd "$WORK" && timeout "$EDG_TIMEOUT" "$WORK/edgcpfe" "${SMOKE[@]}" \
      --gen_c_file_name="$gen" "$src" ) \
    > "$WORK/log/$name.edg.log" 2>&1 || {
      tail -n 10 "$WORK/log/$name.edg.log" >&2 || true
      die "EDG 7.0 failed to translate $name.cpp (see $WORK/log/$name.edg.log)"
    }
  timeout "$GCC_TIMEOUT" "$CC" -std=gnu99 "$OPT" -w -c "$gen" -o "$obj" \
    > "$WORK/log/$name.cc.log" 2>&1 || {
      tail -n 10 "$WORK/log/$name.cc.log" >&2 || true
      die "GCC $GCC_VERSION failed to compile $name.int.c (see $WORK/log/$name.cc.log)"
    }
  "$CC" -o "$exe" "$obj" -L"$WORK/lib" -lC -lm -Wl,-z,noexecstack \
    > "$WORK/log/$name.link.log" 2>&1 || {
      tail -n 10 "$WORK/log/$name.link.log" >&2 || true
      die "linking $name failed (see $WORK/log/$name.link.log)"
    }
  "$exe" || die "smoke test $name failed at run time"
done

# ------------------------------------------------------------ read-only ---
#
# The build must not write to the release tarball or the reference rootfs.

TARBALL_SHA_AFTER=$(sha256sum "$TARBALL" | cut -d' ' -f1)
[ "$TARBALL_SHA_AFTER" = "$TARBALL_SHA" ] || \
  die "the release tarball was modified during the build"
REF_WRITES=$(find -L "$REF" -newer "$WORK/.start" -print -quit 2>/dev/null || true)
[ -z "$REF_WRITES" ] || \
  die "the reference rootfs was modified during the build: $REF_WRITES"

# ------------------------------------------------------------- summary ---

END=$(date +%s)
ELAPSED=$((END - START))
FE_SIZE=$(stat -c %s "$WORK/edgcpfe")
RT_SIZE=$(stat -c %s "$WORK/lib/libC.a")

{
  printf 'EDG 7.0 front end built with EDG 5.1\n'
  printf 'date (UTC)      : %s\n' "$START_UTC"
  printf 'source tarball  : %s\n' "$TARBALL"
  printf 'tarball size    : %s bytes\n' "$TARBALL_SIZE"
  printf 'tarball sha256  : %s\n' "$TARBALL_SHA"
  printf 'source files    : %s\n' "$SRC_COUNT"
  printf 'EDG 5.1         : %s\n' "$V51_FULL"
  printf 'EDG 7.0         : %s\n' "$V70_FULL"
  printf 'host C compiler : %s (%s)\n' "$CC" "$GCC_VERSION"
  printf 'sysroot         : %s\n' "$GCC_SYSROOT"
  printf 'optimization    : %s\n' "$OPT"
  printf 'gnu version     : %s\n' "$EDG_GNU_VERSION"
  printf 'front end       : %s (%s bytes)\n' "$WORK/edgcpfe" "$FE_SIZE"
  printf 'runtime library : %s (%s bytes, %s objects)\n' \
         "$WORK/lib/libC.a" "$RT_SIZE" "$RT_AR_COUNT"
  printf 'EDG_BASE        : %s\n' "$WORK/base"
  printf 'smoke tests     : smoke_cxx, smoke_eh (passed)\n'
  printf 'elapsed         : %s s\n' "$ELAPSED"
  printf 'notes           : 5.1 has no prelinker, so the front end link uses\n'
  printf '                  -Wl,--allow-multiple-definition for identical\n'
  printf '                  template instantiations emitted by -tused.\n'
  printf '                  __float128/_Float128 target support is disabled\n'
  printf '                  because EDG 5.1 cannot compile host __float128.\n'
} > "$WORK/build-info.txt"

info "done"
printf '\n'
printf 'front end   : %s (%s bytes)\n' "$WORK/edgcpfe" "$FE_SIZE"
printf 'version     : %s\n' "$V70"
printf 'runtime lib : %s (%s bytes, %s objects)\n' \
       "$WORK/lib/libC.a" "$RT_SIZE" "$RT_AR_COUNT"
printf 'EDG_BASE    : %s\n' "$WORK/base"
printf 'tests       : %s\n' "$(ls "$WORK"/tests/*.out 2>/dev/null | tr '\n' ' ')"
printf 'build log   : %s\n' "$WORK/log"
printf 'build info  : %s\n' "$WORK/build-info.txt"
printf 'elapsed     : %s s\n' "$ELAPSED"
