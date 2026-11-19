#!/usr/bin/env bash
#
# Stage 3a-2 of the LLVM 3.5 bootstrap chain:
# build the LLVM "binutils replacement" tools with the stage-1 clang, most
# importantly lld, plus llvm-ar/llvm-ranlib/llvm-nm/llvm-readobj.  The next
# stage (refhost-llvm3.5.x-bootstrap.sh) uses these instead of host binutils.
#
# Run order:
#     ./refhost-llvm3.5.x.sh          # stage 3a: clang + libc++ 3.5
#     ./refhost-llvm3.5.x-2.sh        # this script: lld + llvm binutils
#     ./refhost-llvm3.5.x-bootstrap.sh
#
# The stage-1 LLVM tree was configured bootstrap-only, so it has no llvm-ar /
# llvm-nm / llvm-readobj targets yet.  This script reconfigures the existing
# stage-1 tree (keeping the EDG/gcc toolchain and all already-built LLVM
# libraries) and builds those tools.  lld is built separately as a standalone
# project against the stage-1 build tree, with the stage-1 clang driver, so
# lld itself is self-hosted by clang.
#
# Host tools used here: gcc (only for the EDG-generated C of the stage-1 LLVM
# tools), host binutils (to link lld itself), make/cmake/python3.  There is no
# host C++ compiler: lld and libc++ code is compiled by the stage-1 clang.
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

JOBS=${JOBS:-$(nproc --ignore=1 2>/dev/null || nproc 2>/dev/null || echo 1)}
[ "$JOBS" -ge 1 ] 2>/dev/null || JOBS=1

in_rootfs() {
  local p=$1
  case "$p" in "$ROOTFS"|"$ROOTFS"/*) p=${p#"$ROOTFS"} ;; esac
  case "$p" in "") p=/ ;; /*) ;; *) p=/$p ;; esac
  case "$p" in /) ;; */) p=${p%/} ;; esac
  printf '%s' "$p"
}

STAGE1_PREFIX=$(in_rootfs "${STAGE1_PREFIX:-/opt/llvm3.5}")
STAGE1_BUILD=$(in_rootfs "${STAGE1_BUILD:-build/llvm3.5}")
SRC_IN=$(in_rootfs "${SRC_DIR:-$STAGE1_BUILD/src}")
BUILD_IN=$(in_rootfs "${BUILD_DIR:-build/llvm3.5-2}")
STAGE1_BD_IN="$STAGE1_BUILD/build/stage1"
BUILD=$ROOTFS$BUILD_IN
SRC=$ROOTFS$SRC_IN
STAGE1_BD=$ROOTFS$STAGE1_BD_IN
LOG=$BUILD/log

[ -x "$ROOTFS$STAGE1_PREFIX/bin/clang" ] || die "stage-1 clang missing (run ./refhost-llvm3.5.x.sh first)"
[ -s "$ROOTFS$STAGE1_PREFIX/lib/libc++.a" ] || die "stage-1 libc++.a missing"
[ -s "$ROOTFS$STAGE1_PREFIX/lib/libC.a" ] || die "stage-1 libC.a missing"
[ -s "$ROOTFS$STAGE1_PREFIX/lib/dso_handle.o" ] || die "stage-1 dso_handle.o missing"
[ -d "$SRC/llvm" ] || die "LLVM source missing: $SRC/llvm"
[ -d "$SRC/lld" ] || die "lld source missing: $SRC/lld"
[ -f "$STAGE1_BD/CMakeCache.txt" ] || die "stage-1 build tree missing: $STAGE1_BD"

CLANG_VER=$("$ROOTFS$STAGE1_PREFIX/bin/clang" --version 2>/dev/null | sed -n 's/.*clang version \([0-9][0-9.]*\).*/\1/p' | head -n1)
[ -n "$CLANG_VER" ] || die "cannot determine stage-1 clang version"
LIBRT_DIR=$STAGE1_PREFIX/lib/clang/$CLANG_VER/lib/linux
[ -s "$ROOTFS$LIBRT_DIR/libclang_rt.builtins-x86_64.a" ] || die "stage-1 builtins missing"

info "stage-1 clang : $CLANG_VER"
info "rootfs        : $ROOTFS"
info "stage-1 build : $ROOTFS$STAGE1_BUILD"
info "source        : $SRC"
info "tools build   : $BUILD"
info "install       : $ROOTFS$STAGE1_PREFIX (lld + llvm binutils)"

START=$(date +%s)
START_UTC=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
mkdir -p "$BUILD/tools" "$BUILD/tmp" "$LOG"

# ---------------------------------------------------------- lld toolchain ---
# lld is compiled by the stage-1 clang and linked by host ld against the
# stage-1 LLVM libraries.  Standard libraries are the stage-1 libc++ 3.5 +
# EDG libC + compiler-rt builtins.
cat > "$BUILD/tools/toolchain-lld.cmake" <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER $STAGE1_PREFIX/bin/clang)
set(CMAKE_CXX_COMPILER $STAGE1_PREFIX/bin/clang++)
set(CMAKE_ASM_COMPILER $STAGE1_PREFIX/bin/clang)
set(CMAKE_AR /usr/bin/ar)
set(CMAKE_RANLIB /usr/bin/ranlib)
set(CMAKE_NM /usr/bin/nm)
set(CMAKE_LINKER /usr/bin/ld)
set(CMAKE_C_FLAGS_INIT "--sysroot=/ -static -O0 -fno-pie -rtlib=compiler-rt -D_GNU_SOURCE=1")
set(CMAKE_CXX_FLAGS_INIT "--sysroot=/ -static -O0 -fno-pie -rtlib=compiler-rt -stdlib=libc++ -fno-exceptions -fno-rtti -D_LIBCPP_NO_EXCEPTIONS=1 -D_LIBCPP_NO_RTTI=1 -D_LIBCPP_BUILD_STATIC=1 -D_GNU_SOURCE=1")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-nostartfiles /usr/lib/crt1.o /usr/lib/crti.o /usr/lib/crtn.o $STAGE1_PREFIX/lib/dso_handle.o -nodefaultlibs -Wl,--allow-multiple-definition")
set(CMAKE_C_STANDARD_LIBRARIES "-L/usr/lib -L$LIBRT_DIR -Wl,--start-group -lc -lm -lpthread -lclang_rt.builtins-x86_64 -Wl,--end-group")
set(CMAKE_CXX_STANDARD_LIBRARIES "-L$STAGE1_PREFIX/lib -L/usr/lib -L$LIBRT_DIR -Wl,--start-group -lc++ -lC -lc -lm -lpthread -lclang_rt.builtins-x86_64 -Wl,--end-group")
set(CMAKE_CROSSCOMPILING FALSE)
set(PYTHON_EXECUTABLE /usr/bin/python3)
EOF

# EDG-based toolchain for lld itself.  The stage-1 EDG wrapper links through
# host gcc/ld, so suppress the host C runtime and use musl's crt/libc
# explicitly; otherwise host gcc picks up the host glibc and fails on
# __ehdr_start.  CMake's compiler check is compile-only.
cat > "$BUILD/tools/toolchain-lld-edg.cmake" <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER $STAGE1_BUILD/tools/cc)
set(CMAKE_CXX_COMPILER $STAGE1_BUILD/tools/edg-cxx)
set(CMAKE_ASM_COMPILER $STAGE1_BUILD/tools/cc)
set(CMAKE_AR /usr/bin/ar)
set(CMAKE_RANLIB /usr/bin/ranlib)
set(CMAKE_NM /usr/bin/nm)
set(CMAKE_LINKER /usr/bin/ld)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
set(CMAKE_C_FLAGS_INIT "-static -fno-pie -D_GNU_SOURCE=1")
set(CMAKE_CXX_FLAGS_INIT "-static -fno-pie -fno-lto -fno-use-linker-plugin -D_GNU_SOURCE=1")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-nostdlib -nodefaultlibs -fno-use-linker-plugin -static -no-pie /usr/lib/crt1.o /usr/lib/crti.o /usr/lib/crtn.o $STAGE1_PREFIX/lib/dso_handle.o -Wl,--allow-multiple-definition")
set(CMAKE_C_STANDARD_LIBRARIES "-L/usr/lib -L$LIBRT_DIR -Wl,--start-group -lc -lm -lpthread -lclang_rt.builtins-x86_64 -Wl,--end-group")
set(CMAKE_CXX_STANDARD_LIBRARIES "-L/usr/lib -L$STAGE1_PREFIX/lib -L$LIBRT_DIR -Wl,--start-group -lc++ -lC -lc -lm -lpthread -lclang_rt.builtins-x86_64 -Wl,--end-group")
set(CMAKE_CROSSCOMPILING FALSE)
set(PYTHON_EXECUTABLE /usr/bin/python3)
EOF

# ------------------------------------------------------------ inner build ---
cat > "$BUILD/tools/inner-build.sh" <<'INNER_EOF'
#!/bin/bash
set -euo pipefail
info() { printf '==> %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

BUILD=@BUILD_IN@
SRC=@SRC_IN@
STAGE1_PREFIX=@STAGE1_PREFIX@
STAGE1_BD=@STAGE1_BD@
JOBS=@JOBS@
CLANG_VER=@CLANG_VER@
LOG=$BUILD/log
export TMPDIR=/tmp
export PATH="$STAGE1_PREFIX/bin:/usr/bin:/bin"

# Remove any lld symlink left by an earlier run: while building lld itself,
# the stage-1 clang must use the host ld (CMAKE_LINKER), not an old lld.
rm -f "$STAGE1_PREFIX/bin/ld" "$STAGE1_PREFIX/bin/ld.lld"

BD=$STAGE1_BD
LLD_BD=$BUILD/lld

# The stage-1 edg-cxx wrapper drops -nostdlib/-nodefaultlibs before invoking
# the host gcc linker; pass them through so lld links against musl's explicit
# crt/libc rather than host gcc's libgcc_eh.
if ! grep -q -- '-nostdlib|-nodefaultlibs|-nostartfiles' "$STAGE1_BD/../../tools/edg-cxx"; then
  python3 - "$STAGE1_BD/../../tools/edg-cxx" <<'PYEDGPASS'
import sys
p = sys.argv[1]
s = open(p).read()
old = '    -Wl,*|-L*|-l*) link_args+=("$a") ;;'
new = '    -nostdlib|-nodefaultlibs|-nostartfiles) link_args+=("$a") ;;\n' + old
if old in s and '-nodefaultlibs' not in s:
    s = s.replace(old, new, 1)
open(p, 'w').write(s)
PYEDGPASS
fi

# ---------------------------------------------------- llvm binutils tools ---
# Reconfigure the existing stage-1 tree with tools enabled.  Its compiler is
# still the EDG wrapper, so this reuses every already-built LLVM library and
# only compiles the tool front-ends themselves.
info "reconfiguring stage-1 LLVM tree for llvm-ar/llvm-nm/llvm-readobj/llvm-config"
CMAKE_POLICY_VERSION_MINIMUM=3.5 cmake -S "$SRC/llvm" -B "$BD" \
  -DLLVM_INCLUDE_TOOLS=ON \
  -DLLVM_BUILD_TOOLS=ON \
  -DLLVM_INCLUDE_UTILS=ON \
  -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_INCLUDE_DOCS=OFF -DLLVM_BUILD_EXAMPLES=OFF \
  > "$LOG/cmake-tools-configure.log" 2>&1 || {
    tail -n 30 "$LOG/cmake-tools-configure.log" >&2
    die "reconfiguring the stage-1 tree for tools failed"
  }

info "building llvm-config, llvm-ar, llvm-nm, llvm-readobj"
if ! cmake --build "$BD" --target llvm-config llvm-ar llvm-nm llvm-readobj \
      -- -j"$JOBS" > "$LOG/cmake-tools-build.log" 2>&1; then
  grep -n -m8 -B2 -A8 'error:' "$LOG/cmake-tools-build.log" >&2 || true
  tail -n 30 "$LOG/cmake-tools-build.log" >&2
  die "building the LLVM tools failed"
fi

for t in llvm-config llvm-ar llvm-nm llvm-readobj; do
  [ -x "$BD/bin/$t" ] || die "$BD/bin/$t was not produced"
  cp "$BD/bin/$t" "$STAGE1_PREFIX/bin/$t"
done
# llvm-ar has a 's' operation (ranlib); CMake/configure call ranlib without
# arguments beyond the archive name, so provide the conventional wrapper.
cat > "$STAGE1_PREFIX/bin/llvm-ranlib" <<EOF_RANLIB
#!/bin/sh
exec "$STAGE1_PREFIX/bin/llvm-ar" s "\$@"
EOF_RANLIB
chmod +x "$STAGE1_PREFIX/bin/llvm-ranlib"
info "installed llvm-ar/llvm-ranlib/llvm-nm/llvm-readobj/llvm-config"

# ------------------------------------------------------------------ lld ---
# lld is standalone and links against the stage-1 build tree's LLVM libraries.
# lld 3.5's standalone CMake unconditionally configures its lit tests and
# utils; those need variables only the LLVM top-level build provides.  Keep
# only lib + the lld executable for this bootstrap.
if grep -q '^add_subdirectory(test)$' "$SRC/lld/CMakeLists.txt"; then
  python3 - "$SRC/lld/CMakeLists.txt" <<'PYLLDCM'
import sys
p = sys.argv[1]
s = open(p).read()
for line in ('add_subdirectory(utils)\n', 'add_subdirectory(test)\n', 'add_subdirectory(docs)\n'):
    s = s.replace(line, '')
open(p, 'w').write(s)
PYLLDCM
fi

# Backport lld 3.9's handling of the modern GNU relaxable GOT relocations.
# Modern gcc/as emits R_X86_64_GOTPCRELX (41) / R_X86_64_REX_GOTPCRELX (42)
# for mov foo@GOTPCREL(%rip); lld 3.5 predates them and crashes in its
# relocation pass.  Treat them like R_X86_64_GOTPCREL (no relaxation) for the
# static, non-PIC links used by this bootstrap.
if ! grep -q 'R_X86_64_REX_GOTPCRELX' "$SRC/llvm/include/llvm/Support/ELF.h"; then
  info "patching lld 3.5: GOTPCRELX/REX_GOTPCRELX relocation types"
  python3 - "$SRC" <<'PYGOT35'
import sys
src = sys.argv[1]

def edit(path, old, new):
    p = src + '/' + path
    s = open(p).read()
    if old in s:
        s = s.replace(old, new, 1)
        open(p, 'w').write(s)
        return True
    return False

edit('llvm/include/llvm/Support/ELF.h',
     '  R_X86_64_IRELATIVE  = 37\n};',
     '  R_X86_64_IRELATIVE  = 37,\n'
     '  R_X86_64_GOTPCRELX  = 41,\n'
     '  R_X86_64_REX_GOTPCRELX = 42\n};')

edit('lld/lib/ReaderWriter/ELF/X86_64/X86_64RelocationHandler.cpp',
     '  case R_X86_64_PC32:\n  case R_X86_64_GOTPCREL:\n    relocPC32(location, relocVAddress, targetVAddress, ref.addend());',
     '  case R_X86_64_PC32:\n  case R_X86_64_GOTPCREL:\n'
     '  case R_X86_64_GOTPCRELX:\n  case R_X86_64_REX_GOTPCRELX:\n'
     '    relocPC32(location, relocVAddress, targetVAddress, ref.addend());')

edit('lld/lib/ReaderWriter/ELF/X86_64/X86_64RelocationPass.cpp',
     '    case R_X86_64_GOTPCREL:\n    case R_X86_64_GOTOFF64:\n      static_cast<Derived *>(this)->handleGOT(ref);',
     '    case R_X86_64_GOTPCREL:\n    case R_X86_64_GOTPCRELX:\n'
     '    case R_X86_64_REX_GOTPCRELX:\n    case R_X86_64_GOTOFF64:\n'
     '      static_cast<Derived *>(this)->handleGOT(ref);')

edit('lld/lib/ReaderWriter/ELF/X86_64/X86_64TargetHandler.cpp',
     '  LLD_KIND_STRING_ENTRY(R_X86_64_GOTPCREL),\n',
     '  LLD_KIND_STRING_ENTRY(R_X86_64_GOTPCREL),\n'
     '  LLD_KIND_STRING_ENTRY(R_X86_64_GOTPCRELX),\n'
     '  LLD_KIND_STRING_ENTRY(R_X86_64_REX_GOTPCRELX),\n')
PYGOT35
fi

# lld's old static GOT pass only creates GOT entries for DefinedAtom.  The
# musl linker-provided __init_array_start/end are AbsoluteAtom(0); leaving
# them as a direct GOTPCRELX made lld write a PC32 to address 0 and the
# resulting binary faulted in __libc_start_init.  Give absolute targets a real
# GOT entry containing their absolute value (zero for these symbols).
if ! grep -q 'dyn_cast<const AbsoluteAtom>(ref.target())' \
     "$SRC/lld/lib/ReaderWriter/ELF/X86_64/X86_64RelocationPass.cpp"; then
  info "patching lld 3.5: GOT entries for absolute GOTPCRELX targets"
  python3 - "$SRC/lld/lib/ReaderWriter/ELF/X86_64/X86_64RelocationPass.cpp" <<'PYGOTABS'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace('const GOTAtom *getGOT(const DefinedAtom *da) {',
              'const GOTAtom *getGOT(const Atom *da) {', 1)
old = ('    else if (const DefinedAtom *da = dyn_cast<const DefinedAtom>(ref.target()))\n'
       '      const_cast<Reference &>(ref).setTarget(getGOT(da));\n'
       '    return std::error_code();')
new = ('    else if (const DefinedAtom *da = dyn_cast<const DefinedAtom>(ref.target()))\n'
       '      const_cast<Reference &>(ref).setTarget(getGOT(da));\n'
       '    else if (const auto *aa = dyn_cast<const AbsoluteAtom>(ref.target()))\n'
       '      const_cast<Reference &>(ref).setTarget(getGOT(aa));\n'
       '    return std::error_code();')
if old in s:
    s = s.replace(old, new, 1)
open(p, 'w').write(s)
PYGOTABS
fi

info "configuring lld (standalone, against the stage-1 LLVM build tree)"
CMAKE_POLICY_VERSION_MINIMUM=3.5 rm -rf "$LLD_BD"
cmake -G "Unix Makefiles" \
  -S "$SRC/lld" -B "$LLD_BD" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DLLD_PATH_TO_LLVM_SOURCE="$SRC/llvm" \
  -DLLD_PATH_TO_LLVM_BUILD="$STAGE1_BD" \
  -DLLVM_RUNTIME_OUTPUT_INTDIR="$LLD_BD/bin" \
  -DLLVM_LIBRARY_OUTPUT_INTDIR="$LLD_BD/lib" \
  -DLLVM_INCLUDE_TESTS=OFF -DLLD_INCLUDE_TESTS=OFF \
  -DCMAKE_TOOLCHAIN_FILE="$BUILD/tools/toolchain-lld.cmake" \
  -DCMAKE_INSTALL_PREFIX="$STAGE1_PREFIX" \
  -DCMAKE_BUILD_TYPE=Release \
  > "$LOG/lld-configure.log" 2>&1 || {
    tail -n 40 "$LOG/lld-configure.log" >&2
    die "lld configure failed"
  }

info "building lld with the stage-1 clang"
if ! cmake --build "$LLD_BD" --target lld -- -j"$JOBS" > "$LOG/lld-build.log" 2>&1; then
  grep -n -m8 -B2 -A8 'error:' "$LOG/lld-build.log" >&2 || true
  tail -n 30 "$LOG/lld-build.log" >&2
  die "lld build failed"
fi
[ -x "$LLD_BD/bin/lld" ] || die "lld binary was not produced"
cp "$LLD_BD/bin/lld" "$STAGE1_PREFIX/bin/lld"
ln -sf lld "$STAGE1_PREFIX/bin/ld.lld"
ln -sf lld "$STAGE1_PREFIX/bin/lld-link"
info "installed lld + ld.lld/ld symlinks"

# ---------------------------------------------------------------- checks ---
info "check: lld / llvm-ar run"
"$STAGE1_PREFIX/bin/ld.lld" --help > "$LOG/ldlld-version.txt" 2>&1 || true
"$STAGE1_PREFIX/bin/llvm-ar" --version > "$LOG/llvm-ar-version.txt" 2>&1 || die "llvm-ar --version failed"
head -n1 "$LOG/ldlld-version.txt"

info "check: stage-1 clang can link through lld (ld symlink in $STAGE1_PREFIX/bin)"
cat > "$BUILD/check.c" <<'EOF'
#include <stdio.h>
int main(void) { printf("lld link ok\n"); return 0; }
EOF
"$STAGE1_PREFIX/bin/clang" -fuse-ld=lld --sysroot=/ -static -O1 -fno-pie \
  -nostartfiles /usr/lib/crt1.o /usr/lib/crti.o /usr/lib/crtn.o \
  "$STAGE1_PREFIX/lib/dso_handle.o" -nodefaultlibs \
  -o "$BUILD/check-lld" "$BUILD/check.c" \
  -L/usr/lib -L"$STAGE1_PREFIX/lib/clang/$CLANG_VER/lib/linux" \
  -Wl,--start-group -lc -lm -lpthread -lclang_rt.builtins-x86_64 -Wl,--end-group \
  -Wl,--allow-multiple-definition \
  > "$LOG/lld-link-check.log" 2>&1 || {
    tail -n 30 "$LOG/lld-link-check.log" >&2
    die "linking through lld failed"
  }
[ "$("$BUILD/check-lld")" = "lld link ok" ] || die "lld-linked binary failed"

{
  printf 'LLVM/Clang 3.5.2 tools stage: lld + llvm binutils\n'
  printf 'date (UTC)      : %s\n' @START_UTC@
  printf 'stage-1 clang   : %s\n' "@CLANG_VER@"
  printf 'lld             : lld 3.5 (LLVM 3.5)\n' 
  printf 'llvm-ar         : %s\n' "$(head -n1 "$LOG/llvm-ar-version.txt")"
  printf 'installed       : %s/bin/{lld,ld.lld,ld,llvm-ar,llvm-ranlib,llvm-nm,llvm-readobj}\n' "$STAGE1_PREFIX"
  printf 'jobs            : %s\n' "$JOBS"
} > "$BUILD/build-info.txt"
INNER_EOF

sed -i \
  -e "s|@BUILD_IN@|$BUILD_IN|g" \
  -e "s|@SRC_IN@|$SRC_IN|g" \
  -e "s|@STAGE1_PREFIX@|$STAGE1_PREFIX|g" \
  -e "s|@STAGE1_BD@|$STAGE1_BD_IN|g" \
  -e "s|@JOBS@|$JOBS|g" \
  -e "s|@CLANG_VER@|$CLANG_VER|g" \
  -e "s|@START_UTC@|$START_UTC|g" \
  "$BUILD/tools/inner-build.sh"
chmod +x "$BUILD/tools/inner-build.sh"

# ---------------------------------------------------------------- sandbox ---
BWRAP=$(command -v bwrap) || die "bwrap not found"
GCC_BIN=$(command -v gcc) || die "host gcc not found"
GCC_REAL=$(readlink -f "$GCC_BIN")
GCC_PREFIX=$("$GCC_BIN" -print-search-dirs | sed -n 's/^install: //p' | head -n1)
GCC_INC=$("$GCC_BIN" -print-file-name=include)
LIBATOMIC=$("$GCC_BIN" -print-file-name=libatomic.a)
CRT_GCC=$("$GCC_BIN" -print-file-name=crtbegin.o)
GCC_CRT_DIR=$(dirname "$CRT_GCC")

BWRAP_ARGS=(
  --die-with-parent --unshare-all
  --bind "$ROOTFS" /
  --proc /proc --dev /dev
  --bind "$BUILD/tmp" /tmp
  --ro-bind /usr/lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu
  --ro-bind /usr/lib64/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
  --ro-bind /etc/ld.so.cache /etc/ld.so.cache
)
[ -d /usr/lib/gcc ] && BWRAP_ARGS+=(--ro-bind /usr/lib/gcc /usr/lib/gcc)
[ -d /usr/libexec/gcc ] && BWRAP_ARGS+=(--ro-bind /usr/libexec/gcc /usr/libexec/gcc)
for d in /usr/share/cmake-*; do [ -d "$d" ] && BWRAP_ARGS+=(--ro-bind "$d" "$d"); done
PY_STDLIB=$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["stdlib"])' 2>/dev/null || true)
[ -n "$PY_STDLIB" ] && [ -d "$PY_STDLIB" ] && BWRAP_ARGS+=(--ro-bind "$PY_STDLIB" "$PY_STDLIB")
for d in "$GCC_PREFIX"/*-linux-gnu*; do
  [ -d "$d" ] && BWRAP_ARGS+=(--ro-bind "$d" "$d")
done
[ -d "$GCC_CRT_DIR" ] && BWRAP_ARGS+=(--ro-bind "$GCC_CRT_DIR" "$GCC_CRT_DIR")
[ -d "$GCC_INC" ] && BWRAP_ARGS+=(--ro-bind "$GCC_INC" "$GCC_INC")
[ -f "$LIBATOMIC" ] && BWRAP_ARGS+=(--ro-bind "$LIBATOMIC" "$LIBATOMIC")

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
  /usr/bin/gcc "$GCC_REAL" \
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

mkdir -p "$ROOTFS/usr/bin" "$ROOTFS/usr/lib/gcc" "$ROOTFS/usr/libexec/gcc"

info "starting bubblewrap sandbox (stage-1 clang; host binutils for lld link)"
"$BWRAP" "${BWRAP_ARGS[@]}" --chdir "$BUILD_IN" -- \
  /bin/bash "$BUILD_IN/tools/inner-build.sh"

find "$ROOTFS/usr/bin" -maxdepth 1 -type f -size 0 -delete 2>/dev/null || true
find "$ROOTFS/usr/lib/gcc" "$ROOTFS/usr/libexec/gcc" -type f -size 0 -delete 2>/dev/null || true
rmdir "$ROOTFS/usr/lib/gcc" "$ROOTFS/usr/libexec/gcc" 2>/dev/null || true

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
