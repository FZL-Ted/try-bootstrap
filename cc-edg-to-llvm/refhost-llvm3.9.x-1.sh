#!/usr/bin/env bash
#
# Stage 3a of the "reference host + musl" bootstrap chain: build LLVM/Clang
# 3.9.0 with the host C compiler, EDG 7.0 and musl only.
#
# The whole build runs inside a bubblewrap sandbox whose root is the musl
# rootfs prepared by ./refhost-musl.sh.  The host compiler and a short,
# explicit whitelist of host binaries are bind-mounted read-only; no host
# header or library is used by the produced code (only the compiler's own
# runtime and the shared libraries the host tools themselves need).
#
# The C++ rule of the earlier stages is preserved:
#
#   * EDG 7.0 translates every C++ translation unit to C;
#   * the host compiler (gcc by default, clang supported) is used as a C-only
#     compiler restricted to the musl rootfs;
#   * g++/clang++ are never asked to compile C++.
#
# Inputs:
#     ${ROOTFS:-rootfs-hostgcc}/        musl rootfs with EDG 7.0
#     llvm-project-3.9.x.tar.gz         LLVM 3.9.0 monorepo source
#
# Output (all inside the rootfs):
#     <rootfs>/build/llvm3.9/libcxx/libc++.a      libc++ 3.9 built via EDG
#     <rootfs>/build/llvm3.9/crt/libclang_rt.builtins-x86_64.a
#     <rootfs>/build/llvm3.9/build/stage1/       LLVM build tree
#     <rootfs>/opt/llvm3.9/                      installed clang + libc++ (isolated)
#     <rootfs>/build/llvm3.9/build-info.txt
#
# Host clang compatibility:
#     HOSTCC=clang ROOTFS=rootfs-clang ./refhost-llvm3.9.x-1.sh
#     (the rootfs must have been built by clang; the script derives
#      --gcc-toolchain, compiler-rt builtins and host libatomic automatically)
#
# Usage:
#     ./refhost-llvm3.9.x-1.sh
#     JOBS=16 ./refhost-llvm3.9.x-1.sh
#
# Overridable environment variables:
#     ROOTFS      rootfs directory (default: <script dir>/rootfs-hostgcc)
#     HOSTCC      host C compiler: gcc or clang (default: gcc from PATH)
#     JOBS        parallel jobs (default: nproc --ignore=1)
#     TARBALL     LLVM source tarball
#     PREFIX      install prefix inside the rootfs (default: /opt/llvm3.9)
#     KEEP_SRC    if set, do not re-extract the source tree
#     CONFIGURE_ONLY=1  stop after cmake configure
#     LLVM_TARGET       cmake target (default: clang)
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
[ -d "$ROOTFS" ] || die "rootfs not found: $ROOTFS (run ./refhost-musl.sh first)"
ROOTFS=$(cd "$ROOTFS" && pwd -P)
case "$ROOTFS" in
  "$ROOT"/*) ;;
  *) die "ROOTFS must be a directory inside $ROOT: $ROOTFS" ;;
esac

HOSTCC=${HOSTCC:-gcc}
HOSTCC=$(command -v "$HOSTCC" || true)
[ -n "$HOSTCC" ] && [ -x "$HOSTCC" ] || die "host C compiler not found (HOSTCC=${HOSTCC:-gcc})"
HOSTCC_REAL=$(readlink -f "$HOSTCC")
HOSTCC_VERSION=$("$HOSTCC_REAL" --version | head -n 1)
case "$HOSTCC_VERSION" in
  *clang*|*Clang*) HOSTCC_KIND=clang ;;
  *)               HOSTCC_KIND=gcc ;;
esac
WRAPPER_EXTRA=
LIBATOMIC=
GCC_PREFIX=
GCC_LIBDIR=
GCC_C=
GCC_C_REAL=
if [ "$HOSTCC_KIND" = clang ]; then
  # Host clang only: no host gcc is needed or bound.  The clang link driver
  # gets musl crt/libc and the stage-1 libc++/libC/builtins explicitly, and
  # host lld is used via -fuse-ld=lld.
  WRAPPER_EXTRA="-Qunused-arguments"
else
  GCC_C=$(command -v gcc || true)
  [ -n "$GCC_C" ] && [ -x "$GCC_C" ] || die "host gcc not found"
  GCC_C_REAL=$(readlink -f "$GCC_C")
fi

JOBS=${JOBS:-16}
[ "$JOBS" -ge 1 ] 2>/dev/null || JOBS=1
PREFIX=${PREFIX:-/opt/llvm3.9}
# Optimization for EDG-generated C.  -O0 is the default: the front end emits
# a lot of C and LLVM/clang, unlike EDG itself, is large enough that -O1 makes
# the bootstrap many times slower.
OPT=${OPT:--O0}
LLVM_TARGET=${LLVM_TARGET:-clang}
USE_PRELINK=${USE_PRELINK:-0}

find_input() {
  local name=$1 dir
  for dir in "$ROOT" "$ROOT/.." "$ROOT/../../edgcpp-try"; do
    if [ -f "$dir/$name" ]; then
      printf '%s/%s\n' "$(cd "$dir" && pwd -P)" "$name"
      return 0
    fi
  done
  return 1
}

TARBALL=${TARBALL:-$(find_input llvm-project-3.9.x.tar.gz || true)}
[ -n "$TARBALL" ] && [ -f "$TARBALL" ] || \
  die "llvm-project-3.9.x.tar.gz not found (set TARBALL=...)"
TARBALL_SHA=$(sha256sum "$TARBALL" | cut -d' ' -f1)

BUILD=$ROOTFS/build/llvm3.9
SRC=$BUILD/src
WORK=$BUILD

# ---------------------------------------------------------------- inputs ---

[ -x "$ROOTFS/bin/cc" ] || die "musl wrapper not found: $ROOTFS/bin/cc (run ./refhost-musl.sh)"
ROOTFS_CC_REAL=$(sed -n "s/^REAL_GCC='\([^']*\)'.*/\1/p" "$ROOTFS/bin/cc" | head -n 1)
[ -n "$ROOTFS_CC_REAL" ] && [ -x "$ROOTFS_CC_REAL" ] || \
  die "cannot determine the host compiler behind $ROOTFS/bin/cc"
[ "$(readlink -f "$ROOTFS_CC_REAL")" = "$(readlink -f "$HOSTCC_REAL")" ] || \
  die "rootfs was built with $ROOTFS_CC_REAL, but HOSTCC=$HOSTCC_REAL; use the matching ROOTFS/HOSTCC"
[ -x "$ROOTFS/build/edg7.0/edgcpfe" ] || \
  die "EDG 7.0 front end not found (run ./refhost-edg7.0.sh)"
[ -d "$ROOTFS/build/edg7.0/base" ] || die "EDG 7.0 base directory not found"
[ -x "$ROOTFS/build/edg5.1/edg-5.1/build/edgcpfe" ] || \
  die "EDG 5.1 front end not found (run ./refhost-edg5.1.sh)"
command -v bwrap >/dev/null 2>&1 || die "bwrap (bubblewrap) not found"
BWRAP=$(command -v bwrap)

# Verify the rootfs really is the musl one the earlier stages produced.
printf '#include <features.h>\n' | "$ROOTFS/bin/cc" -dM -E -x c - 2>/dev/null | \
  grep -q '__GLIBC__' && die "$ROOTFS/bin/cc still uses glibc headers"

GCC_BANNER=$("$HOSTCC_REAL" --version | head -n 1)
info "host compiler : $HOSTCC_REAL"
info "                $GCC_BANNER"
info "rootfs        : $ROOTFS (musl)"
info "LLVM tarball  : $TARBALL ($(stat -c %s "$TARBALL") bytes)"
info "jobs          : $JOBS"
info "install prefix: $PREFIX"
mkdir -p "$BUILD" "$BUILD/tools" "$BUILD/log" "$BUILD/tmp"

START=$(date +%s)
START_UTC=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

# ------------------------------------------------------- source + patches ---
#
# Everything is extracted and patched inside the rootfs so that the sandbox
# sees a single self-contained tree at /build/llvm3.9.

if [ -z "${KEEP_SRC:-}" ] || [ ! -d "$SRC/llvm" ]; then
  info "extracting LLVM source into $SRC"
  rm -rf "$SRC"
  mkdir -p "$SRC"
  tar -xzf "$TARBALL" -C "$SRC" --strip-components=1 --exclude='.git' || \
    die "extracting $TARBALL failed"
fi
[ -f "$SRC/llvm/CMakeLists.txt" ] || die "unexpected source tree: $SRC/llvm missing"
[ -d "$SRC/libcxx/include" ] || die "unexpected source tree: $SRC/libcxx missing"
[ -d "$SRC/clang" ] || die "unexpected source tree: $SRC/clang missing"
[ -d "$SRC/compiler-rt/lib/builtins" ] || die "unexpected source tree: $SRC/compiler-rt missing"

# All 3.9 source patches live under edg-support/llvm-3.9 and are applied
# host-side, before the sandbox starts.  This keeps the compatibility patches
# reviewable and avoids embedding sed/Python edits in this script.
[ -d "$SRC/libcxx/src" ] || die "unexpected source tree: $SRC/libcxx/src missing"
[ -d "$SRC/libcxx/include" ] || die "unexpected source tree: $SRC/libcxx/include missing"
[ -x "$ROOT/edg-support/llvm-3.9/apply.sh" ] || \
  die "missing $ROOT/edg-support/llvm-3.9/apply.sh"
info "applying LLVM 3.9 compatibility patches from edg-support/llvm-3.9"
"$ROOT/edg-support/llvm-3.9/apply.sh" "$SRC" || die "applying 3.9 patches failed"

# ------------------------------------------------------- EDG macro table ---
#
# EDG's predefined macro table is generated for clang and gates most standard
# macros on the "clang" modes.  We drive the front end in its GNU mode (so
# libc++ takes its GCC paths and the emitted C is plain GNU C), therefore the
# clang-gated entries are merged into the gnu/gcc/gpp modes, keeping the
# original gnu definitions where they already exist.

EDG_BASE=$BUILD/edg-base
info "preparing EDG base directory with GNU-mode predefined macros"
rm -rf "$EDG_BASE"
mkdir -p "$EDG_BASE"
cp -a "$ROOTFS/build/edg7.0/base/." "$EDG_BASE/"
python3 - "$EDG_BASE/lib/predefined_macros.txt" <<'PY'
import sys
p = sys.argv[1]
lines = open(p).read().splitlines()
asserted = set()
entries = []
for line in lines:
    s = line.strip()
    if not s or s.startswith('#'):
        entries.append((line, None, None)); continue
    parts = s.split()
    if len(parts) < 4:
        entries.append((line, None, None)); continue
    mode, name = parts[0], parts[3]
    entries.append((line, mode, name))
    if 'clang' not in mode:
        asserted.add(name)
out = []
for line, mode, name in entries:
    if mode is None or 'clang' not in mode:
        out.append(line); continue
    if name in asserted:
        continue
    for old, new in (('clang_cpp', 'gpp'), ('clang_c', 'gcc'), ('clang', 'gnu')):
        line = line.replace(old, new, 1)
    out.append(line)
open(p, 'w').write('\n'.join(out) + '\n')
PY
# EDG derives these from --gnu_version=50000; make the table agree.
sed -i -E \
  's/^(gpp no +__GNUG__) +[0-9]+$/\1 5/; s/^(gnu no +__GNUC__) +[0-9]+$/\1 5/; s/^(gnu no +__GNUC_MINOR__) +[0-9]+$/\1 0/; s/^(gnu no +__GNUC_PATCHLEVEL__) +[0-9]+$/\1 0/' \
  "$EDG_BASE/lib/predefined_macros.txt"
# Drop entries EDG itself defines (the front end rejects redefinition).
drop_conflict() {
  local macro=$1
  awk -v m="$macro" '!(NF >= 3 && $3 == m)' \
    "$EDG_BASE/lib/predefined_macros.txt" > "$EDG_BASE/lib/pm.new"
  mv "$EDG_BASE/lib/pm.new" "$EDG_BASE/lib/predefined_macros.txt"
}
for m in __VERSION__; do drop_conflict "$m"; done

# --------------------------------------------------- sandbox environment ---
#
# All in-sandbox paths are absolute as seen from the rootfs mounted at /.

SANDBOX_CC=$BUILD/tools/cc
SANDBOX_CXX=$BUILD/tools/edg-cxx
cp "$ROOT/edg-support/llvm-3.9/edg-clang-atomic.h" "$BUILD/edg-clang-atomic.h"
TOOLCHAIN=$BUILD/tools/toolchain.cmake
INNER=$BUILD/tools/inner-build.sh
if [ "$HOSTCC_KIND" = clang ]; then
  GCCINC=${GCCINC:-$ROOTFS/usr/include}
else
  GCCINC=${GCCINC:-$("$GCC_C" -print-file-name=include)}
fi
[ -d "$GCCINC" ] || die "host compiler include directory not found: $GCCINC"

cat > "$SANDBOX_CC" <<EOF
#!/bin/sh
# Host C compiler restricted to the musl rootfs; C only, static output.
REAL_GCC='$HOSTCC_REAL'
REAL_GCC_EDG='$GCC_C_REAL'
SYSROOT=/
HOSTCC_KIND='$HOSTCC_KIND'
WRAPPER_EXTRA='$WRAPPER_EXTRA'
BUILTINS_A='/build/llvm3.9/crt/libclang_rt.builtins-x86_64.a'
LIBATOMIC='$LIBATOMIC'
SHIM='/build/llvm3.9/edg-clang-atomic.h'
expect_x=0
for arg do
  if [ "\$expect_x" -eq 1 ]; then
    case \$arg in
      c++|c++-header|objective-c++|objective-c++-header)
        echo "cc: this toolchain is C-only; refusing '-x \$arg'" >&2; exit 1 ;;
    esac
    expect_x=0; continue
  fi
  case \$arg in
    -x) expect_x=1 ;;
    *.cpp|*.cc|*.cxx|*.c++|*.C|*.CPP|*.CC|*.CXX)
      echo "cc: this toolchain is C-only; refusing C++ source '\$arg'" >&2; exit 1 ;;
  esac
done
# EDG-generated C uses GCC's __sync_* / __atomic_* with void* casts that
# clang 22 rejects; use the host gcc C compiler for those generated files.
int_c=0
for arg do
  case \$arg in *.int.c) int_c=1 ;; esac
done
if [ "\$int_c" -eq 1 ]; then
  if [ "\$HOSTCC_KIND" = clang ]; then
    exec "\$REAL_GCC" \$WRAPPER_EXTRA --sysroot="\$SYSROOT" -static \
      -include "\$SHIM" -D_GNU_SOURCE=1 \
      -Ufopen64 -Ufreopen64 -Ufseeko64 -Uftello64 -Utmpfile64 -Ufgetpos64 -Ufsetpos64 \
      -Ufstat64 -Ufstatvfs64 -Ulstat64 -Uopen64 -Ustat64 -Ustatvfs64 "\$@"
  fi
  exec "\$REAL_GCC_EDG" --sysroot="\$SYSROOT" -static -D_GNU_SOURCE=1 \
    -Ufopen64 -Ufreopen64 -Ufseeko64 -Uftello64 -Utmpfile64 -Ufgetpos64 -Ufsetpos64 \
    -Ufstat64 -Ufstatvfs64 -Ulstat64 -Uopen64 -Ustat64 -Ustatvfs64 "\$@"
fi
if [ "\$HOSTCC_KIND" = clang ]; then
  # Answer CMake compiler queries with host clang; do not invoke host gcc.
  case " \$* " in
    *" --version "*|*" -dumpmachine "*|*" -dumpversion "*|*" -print-file-name="*|*" -print-prog-name="*|*" -print-sysroot "*|*" -print-search-dirs "*)
      exec "\$REAL_GCC" \$WRAPPER_EXTRA "\$@" ;;
  esac
  link_mode=1
  for arg do
    case \$arg in -c|-E|-S) link_mode=0 ;; esac
  done
  if [ "\$link_mode" -eq 1 ]; then
    # Host clang + host lld, with all startup/runtime inputs explicit.
    # -nostdlib suppresses clang's implicit crt/libgcc/libc++ search.
    dso=
    [ -f /build/llvm3.9/dso_handle.o ] && dso=/build/llvm3.9/dso_handle.o
    exec "\$REAL_GCC" \$WRAPPER_EXTRA -fuse-ld=lld -static \
      -nostdlib -nodefaultlibs -nostartfiles -nostdlib++ \
      --sysroot="\$SYSROOT" -fno-pie -no-pie \
      -L"\$SYSROOT/usr/lib" -L/build/llvm3.9/libcxx -L/build/edg7.0/lib \
      -D_GNU_SOURCE=1 -Ufopen64 -Ufreopen64 -Ufseeko64 -Uftello64 -Utmpfile64 -Ufgetpos64 -Ufsetpos64 \
      -Ufstat64 -Ufstatvfs64 -Ulstat64 -Uopen64 -Ustat64 -Ustatvfs64 \
      "\$@" "\$BUILTINS_A" "\$dso" \
      /usr/lib/crt1.o /usr/lib/crti.o /usr/lib/crtn.o \
      -Wl,--start-group -lc -Wl,--end-group -Wl,--allow-multiple-definition
  else
    exec "\$REAL_GCC" \$WRAPPER_EXTRA --sysroot="\$SYSROOT" -static -fno-pie -no-pie -L"\$SYSROOT/usr/lib" -D_GNU_SOURCE=1 -Ufopen64 -Ufreopen64 -Ufseeko64 -Uftello64 -Utmpfile64 -Ufgetpos64 -Ufsetpos64 -Ufstat64 -Ufstatvfs64 -Ulstat64 -Uopen64 -Ustat64 -Ustatvfs64 "\$@"
  fi
else
  exec "\$REAL_GCC" --sysroot="\$SYSROOT" -static -D_GNU_SOURCE=1 -Ufopen64 -Ufreopen64 -Ufseeko64 -Uftello64 -Utmpfile64 -Ufgetpos64 -Ufsetpos64 -Ufstat64 -Ufstatvfs64 -Ulstat64 -Uopen64 -Ustat64 -Ustatvfs64 "\$@"
fi
EOF
chmod +x "$SANDBOX_CC"

cat > "$SANDBOX_CXX" <<'WRAPPER'
#!/bin/bash
# EDG C++ -> C -> musl gcc driver with EDG automatic template instantiation
# and prelinking.  Prototype for refhost-llvm3.9.x-1.sh.
set -u
ROOTFS="@ROOTFS@"
EDG="@EDG@"
BASE="@BASE@"
CC="@CC@"
LIBCXX_INC="@LIBCXX_INC@"
GCCINC="@GCCINC@"
REAL_GCC="@REAL_GCC@"
REAL_GCC_QUERY="@REAL_GCC@"
PRELINK="@PRELINK@"
LIBCXX_A="@LIBCXX_A@"
LIB_C="@LIB_C@"
MANIFEST="@MANIFEST@"
BUILDROOT="@BUILDROOT@"
OPT="@OPT@"
PRELINK_ENABLE="@PRELINK_ENABLE@"

die() { echo "edg-cxx: $*" >&2; exit 1; }

args=()
for a in "$@"; do
  if [ "${a#@}" != "$a" ] && [ -f "${a#@}" ]; then
    while IFS= read -r line; do args+=($line); done < "${a#@}"
  else
    args+=("$a")
  fi
done
set -- "${args[@]}"

# Query modes are answered by the host compiler (CMake detects a GNU driver).
case " $* " in
  *" --version "*|*" -v "*|*" -dumpmachine "*|*" -dumpversion "*|*" -print-file-name="*|*" -print-prog-name="*|*" -print-sysroot "*|*" -print-search-dirs "*|*" -dumpspecs "*)
    if ! printf '%s\n' "$@" | grep -qE '\.(cpp|cc|cxx|c\+\+|C|CPP|CC|CXX)$'; then
      exec "$REAL_GCC_QUERY" "$@"
    fi
    ;;
esac
case " $* " in
  *" -E "*)
    # Preprocess only: let EDG do it (same standard library view).
    exec "$EDG" --g++ --c++14 --gnu_version=50000 -D_GNU_SOURCE=1 -D__ELF__=1 -DEDG_BOOTSTRAP_NO_SSE2=1 \
      --edg_base_dir="$BASE" --sys_include="$LIBCXX_INC" --sys_include="$BASE/include" \
      --sys_include="$ROOTFS/usr/include" --sys_include="$GCCINC" "${@:2}"
    ;;
esac

compile=0
srcs=()
out=""
depfile=""
deptarget=""
edg_args=()
cc_args=()
link_args=()
record_args=()      # original compile args, minus source/-o/-c/dep: for the .ti cmd
stdopt="c++14"
no_exceptions=0
no_rtti=0
skip_arg=0
argv=("$@")
i=0
while [ $i -lt ${#argv[@]} ]; do
  a=${argv[$i]}
  case "$a" in
    -c) compile=1 ;;
    -shared|-r) link_args+=("$a") ;;
    -o) i=$((i+1)); out=${argv[$i]} ;;
    -MD|-MMD|-MP|-M) ;;
    -MF) i=$((i+1)); depfile=${argv[$i]} ;;
    -MT|-MQ) i=$((i+1)); deptarget=${argv[$i]} ;;
    -std=*) case "$a" in
        -std=c++11|-std=gnu++11) stdopt=c++11 ;;
        -std=c++14|-std=gnu++14|-std=c++1y|-std=gnu++1y) stdopt=c++14 ;;
        -std=c++17|-std=gnu++17|-std=c++1z|-std=gnu++1z) stdopt=c++17 ;;
        -std=c++20|-std=gnu++20|-std=c++2a|-std=gnu++2a) stdopt=c++20 ;;
        -std=c++23|-std=gnu++23|-std=c++2b|-std=gnu++2b) stdopt=c++23 ;;
        -std=*) stdopt=c++14 ;;
      esac
      record_args+=("$a") ;;
    -fno-exceptions) no_exceptions=1; cc_args+=("$a"); record_args+=("$a") ;;
    -fexceptions) no_exceptions=0 ;;
    -fno-rtti) no_rtti=1; cc_args+=("$a"); record_args+=("$a") ;;
    -frtti) no_rtti=0 ;;
    -I) i=$((i+1)); edg_args+=("-I${argv[$i]}"); cc_args+=("-I${argv[$i]}"); record_args+=("-I${argv[$i]}") ;;
    -isystem) i=$((i+1)); edg_args+=("--sys_include=${argv[$i]}"); record_args+=("-isystem" "${argv[$i]}") ;;
    -iquote) i=$((i+1)); edg_args+=("-I${argv[$i]}"); record_args+=("-iquote" "${argv[$i]}") ;;
    -include) i=$((i+1)); edg_args+=("--preinclude=${argv[$i]}"); cc_args+=("-include" "${argv[$i]}"); record_args+=("-include" "${argv[$i]}") ;;
    -I*|-D*|-U*) edg_args+=("$a"); cc_args+=("$a"); record_args+=("$a") ;;
    -isystem*) edg_args+=("--sys_include=${a#-isystem}"); record_args+=("$a") ;;
    -include*) edg_args+=("--preinclude=${a#-include}"); cc_args+=("$a"); record_args+=("$a") ;;
    --definition_list_file=*|--ii_file=*|--template_info_file=*)
      edg_args+=("$a") ;;
    -Wl,*|-L*|-l*) link_args+=("$a") ;;
    -W*|-O*|-g*|-m*|-pthread|-fPIC|-fpic|-fno-omit-frame-pointer|-fno-strict-aliasing|--param*|-pipe|-fvisibility*|-fno-semantic-interposition|-fno-plt|-fcf-protection*|-fstack-protector*|-D_FORTIFY_SOURCE*|-fdebug-prefix-map=*|-ffile-prefix-map=*|-fmacro-prefix-map=*)
      cc_args+=("$a"); link_args+=("$a"); record_args+=("$a") ;;
    -fuse-ld=*|-static|-static-libgcc|-rdynamic|-s) link_args+=("$a") ;;
    *.cpp|*.cc|*.cxx|*.c++|*.C|*.CPP|*.CC|*.CXX) srcs+=("$a") ;;
    *.o|*.obj|*.a|*.so|*.so.*) link_args+=("$a") ;;
    -x) i=$((i+1)); record_args+=("-x" "${argv[$i]}") ;;
    -f*) cc_args+=("$a"); link_args+=("$a"); record_args+=("$a") ;;
    -) srcs+=("-") ;;
    -*) ;;
    *) link_args+=("$a") ;;
  esac
  i=$((i+1))
done

if [ "$compile" = 1 ]; then
  [ ${#srcs[@]} -gt 0 ] || die "no C++ source on the command line"
  status=0
  for s in "${srcs[@]}"; do
    if [ -n "$out" ]; then o=$out; else b=$(basename "$s"); o=${b%.*}.o; fi
    case "$o" in
      *CMakeTmp*|*CMakeScratch*) tused=1 ;;
      *) tused=${EDG_TUSED:-0} ;;
    esac
    if [ "$PRELINK_ENABLE" != 1 ] || [ "$tused" = 1 ]; then
      xflags=(--g++ --"$stdopt" --gnu_version=50000 -D_GNU_SOURCE=1 -D__ELF__=1
              -DEDG_BOOTSTRAP_NO_SSE2=1
              -Ufopen64 -Ufreopen64 -Ufseeko64 -Uftello64 -Utmpfile64 -Ufgetpos64 -Ufsetpos64 -Ufstat64 -Ufstatvfs64 -Ulstat64 -Uopen64 -Ustat64 -Ustatvfs64 -D_LIBCPP_NO_EXCEPTIONS=1 -D_LIBCPP_NO_RTTI=1 -D_LIBCPP_BUILD_STATIC=1
              -D_LIBCPP_HAS_MUSL_LIBC=1 -tused
              --edg_base_dir="$BASE" --sys_include="$LIBCXX_INC"
              --sys_include="$BASE/include" --sys_include="$ROOTFS/usr/include"
              --sys_include="$GCCINC")
      [ "$no_exceptions" = 1 ] && xflags+=(--no_exceptions)
      [ "$no_rtti" = 1 ] && xflags+=(--no_rtti)
      gen="$o.int.c"
      "$EDG" "${xflags[@]}" "${edg_args[@]}" --gen_c_file_name="$gen" "$s" || { status=1; continue; }
      "$CC" -std=gnu99 -fcommon "$OPT" -w -fno-asynchronous-unwind-tables -fno-unwind-tables -fno-pie -c "$gen" -o "$o" "${cc_args[@]}" || { status=1; continue; }
      rm -f "$gen"
    else
      ti="${o%.o}.ti"
      ii="${o%.o}.ii"
      gen="${o%.o}.int.c"
      xflags=(--g++ --"$stdopt" --gnu_version=50000 -D_GNU_SOURCE=1 -D__ELF__=1
              -DEDG_BOOTSTRAP_NO_SSE2=1
              -Ufopen64 -Ufreopen64 -Ufseeko64 -Uftello64 -Utmpfile64 -Ufgetpos64 -Ufsetpos64 -Ufstat64 -Ufstatvfs64 -Ulstat64 -Uopen64 -Ustat64 -Ustatvfs64 -D_LIBCPP_NO_EXCEPTIONS=1 -D_LIBCPP_NO_RTTI=1 -D_LIBCPP_BUILD_STATIC=1
              -D_LIBCPP_HAS_MUSL_LIBC=1
              --edg_base_dir="$BASE" --sys_include="$LIBCXX_INC"
              --sys_include="$BASE/include" --sys_include="$ROOTFS/usr/include"
              --sys_include="$GCCINC"
              --template_info_file="$ti" --ii_file="$ii")
      [ "$no_exceptions" = 1 ] && xflags+=(--no_exceptions)
      [ "$no_rtti" = 1 ] && xflags+=(--no_rtti)
      "$EDG" "${xflags[@]}" "${edg_args[@]}" --gen_c_file_name="$gen" "$s" || { status=1; continue; }
      "$CC" -std=gnu99 -fcommon "$OPT" -w -fno-asynchronous-unwind-tables -fno-unwind-tables -fno-pie -c "$gen" -o "$o" "${cc_args[@]}" || { status=1; continue; }
      rm -f "$gen"
      # Write the driver information the prelinker needs at the top of the .ti
      # file.  The recorded command must recompile this file into the same
      # object when the prelinker appends the source file and its options.
      abs_o=$(cd "$(dirname "$o")" && pwd)/$(basename "$o")
      abs_s=$(cd "$(dirname "$s")" && pwd)/$(basename "$s")
      cmd="$0"
      for x in "${record_args[@]}"; do cmd="$cmd $(printf '%q' "$x")"; done
      cmd="$cmd -o $(printf '%q' "$abs_o") -c"
      # drop any stale leading driver lines
      grep -v -E '^(cmd:|dir:|fnm:)' "$ti" > "$ti.body" 2>/dev/null || : > "$ti.body"
      {
        printf 'cmd:%s\n' "$cmd"
        printf 'dir:%s\n' "$(pwd)"
        printf 'fnm:%s\n' "$abs_s"
        cat "$ti.body"
      } > "$ti.new" && mv "$ti.new" "$ti"
      rm -f "$ti.body"
      # remember the object for the link-time prelink pass
      printf '%s\n' "$abs_o" >> "$MANIFEST"
    fi
    if [ -n "$depfile" ] && [ $status -eq 0 ]; then
      printf '%s: %s\n' "${deptarget:-$o}" "$s" > "$depfile"
    fi
  done
  exit $status
fi

# ---------------------------------------------------------------- link ---
if [ "$PRELINK_ENABLE" = 1 ] && [ -e "$MANIFEST" ] && [ -s "$MANIFEST" ] && [ -x "$PRELINK" ]; then
  case " $* " in
    *" -shared "*|*" -r "*) ;;
    *)
      if [ -n "$out" ]; then
        tmpmark=$(mktemp)
        mapfile -t objs < <(awk '!seen[$0]++' "$MANIFEST")
        pre_args=(-q -f gnu -a 1)
        for o in "${objs[@]}"; do [ -f "$o" ] && pre_args+=("$o"); done
        [ -f "$LIBCXX_A" ] && pre_args+=("$LIBCXX_A")
        [ -f "$LIB_C" ] && pre_args+=("$LIB_C")
        "$PRELINK" "${pre_args[@]}" >/dev/null 2>&1 || true
        changed=0
        for o in "${objs[@]}"; do
          if [ -f "$o" ] && [ "$o" -nt "$tmpmark" ]; then changed=1; break; fi
        done
        rm -f "$tmpmark"
        if [ "$changed" = 1 ]; then
          echo "edg-cxx: prelinker updated template instantiations; relinking" >&2
          exit 1
        fi
      fi
      ;;
  esac
fi
[ -n "$out" ] && link_args+=(-o "$out")
exec "$CC" -no-pie -Wl,--allow-multiple-definition "${link_args[@]}"

WRAPPER
sed -i \
  -e "s|@ROOTFS@|/|g" \
  -e "s|@EDG@|/build/edg7.0/edgcpfe|g" \
  -e "s|@BASE@|/build/llvm3.9/edg-base|g" \
  -e "s|@CC@|/build/llvm3.9/tools/cc|g" \
  -e "s|@LIBCXX_INC@|/build/llvm3.9/src/libcxx/include|g" \
  -e "s|@GCCINC@|$GCCINC|g" \
  -e "s|@REAL_GCC@|$HOSTCC_REAL|g" \
  -e "s|@OPT@|$OPT|g" \
  -e "s|@PRELINK_ENABLE@|$USE_PRELINK|g" \
  -e "s|@PRELINK@|/build/llvm3.9/plbuild/edg_prelink|g" \
  -e "s|@LIBCXX_A@|/build/llvm3.9/libcxx/libc++.a|g" \
  -e "s|@LIB_C@|/build/edg7.0/lib/libC.a|g" \
  -e "s|@MANIFEST@|/build/llvm3.9/edg-obj-manifest.txt|g" \
  -e "s|@BUILDROOT@|/build/llvm3.9|g" \
  "$SANDBOX_CXX"
chmod +x "$SANDBOX_CXX"

cat > "$TOOLCHAIN" <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER /build/llvm3.9/tools/cc)
set(CMAKE_CXX_COMPILER /build/llvm3.9/tools/edg-cxx)
set(CMAKE_ASM_COMPILER /build/llvm3.9/tools/cc)
set(CMAKE_C_STANDARD_LIBRARIES "-lm -lpthread")
set(CMAKE_CXX_STANDARD_LIBRARIES "-L/build/llvm3.9/libcxx -lc++ -L/build/edg7.0/lib -lC -lm -lpthread")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-Wl,--allow-multiple-definition")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-Wl,--allow-multiple-definition")
set(CMAKE_CROSSCOMPILING FALSE)
set(PYTHON_EXECUTABLE /usr/bin/python3)
EOF

# ------------------------------------------------------------- inner script ---

cat > "$INNER" <<'INNER_EOF'
#!/bin/bash
# Runs inside bwrap with the musl rootfs mounted at /.
set -euo pipefail
info() { printf '==> %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

BUILD=@BUILD@
SRC=$BUILD/src
CC=@CC@
CXX=@CXX@
EDG=@EDG@
BASE=@BASE@
LIBCXX_INC=$SRC/libcxx/include
EDG_LIB=@EDG_LIB@
JOBS=@JOBS@
PREFIX=@PREFIX@
OPT=@OPT@
LLVM_TARGET=@LLVM_TARGET@
HOSTCC_KIND=@HOSTCC_KIND@
LOG=$BUILD/log
mkdir -p "$LOG"

# --------------------------------------------------- compiler-rt builtins ---
#
# clang emits calls to the compiler-rt builtins for 128-bit operations and a
# few other things.  These sources are plain C (plus a little x86-64 assembly),
# so they are built here with the host compiler + musl; stage 3b can then link
# with clang alone, without the host compiler runtime.
#
# 3.9 notes: atomic.c is commented out in GENERIC_SOURCES (it needs clang's
# __c11_atomic_* builtins); emutls.c and chkstk*.S do not exist in 3.9; the
# three x86_64/floatundi*.S files use a bare .rodata directive that GNU as
# rejects, so the generic C versions from GENERIC_SOURCES provide those symbols.

if [ -s "$BUILD/crt/libclang_rt.builtins-x86_64.a" ] && [ "${REBUILD_CRT:-0}" != 1 ]; then
  info "reusing compiler-rt builtins from a previous run"
  crt_ok=$(ls "$BUILD/crt/obj" 2>/dev/null | wc -l); crt_fail=0
else
info "building compiler-rt builtins"
B=$SRC/compiler-rt/lib/builtins
mkdir -p "$BUILD/crt/obj"
rm -f "$BUILD/crt/obj"/*.o "$BUILD/crt/libclang_rt.builtins-x86_64.a"
GENERIC=$(awk '/^set\(GENERIC_SOURCES$/{f=1;next} f{ if ($0 ~ /\)/) {sub(/\).*/,"",$0); if ($0 ~ /[^ ]/) print; exit} print }' "$B/CMakeLists.txt" | sed 's/#.*//; s/^ *//; s/ *$//' | grep -v '^$')
EXTRA="enable_execute_stack.c eprintf.c clear_cache.c gcc_personality_v0.c x86_64/floatdidf.c x86_64/floatdisf.c x86_64/floatdixf.c"
crt_ok=0; crt_fail=0
for f in $GENERIC $EXTRA; do
  [ -f "$B/$f" ] || { printf 'missing builtin source %s\n' "$f" >&2; crt_fail=$((crt_fail+1)); continue; }
  o="$BUILD/crt/obj/$(printf '%s' "$f" | tr '/' '_' | sed 's/\.[cS]$//').o"
  if "$CC" -O1 -w -fPIC -c "$B/$f" -o "$o" > "$LOG/crt-$(basename "$f").log" 2>&1; then
    crt_ok=$((crt_ok+1))
  else
    crt_fail=$((crt_fail+1))
  fi
done
[ "$crt_ok" -gt 0 ] || die "no compiler-rt builtins could be compiled"
ar rcs "$BUILD/crt/libclang_rt.builtins-x86_64.a" "$BUILD/crt/obj"/*.o
info "compiler-rt builtins: $crt_ok compiled, $crt_fail skipped"
fi

# ------------------------------------------------------------- libc++ ---
#
# Build libc++ 3.9 with EDG -> C -> musl gcc.  Exceptions and RTTI are kept off
# for the library's own throw sites (the bootstrap uses -fno-exceptions), but
# the container/thread/string code is built so that LLVM can use the standard
# library normally.  iostreams/locale are not exercised by the smoke test.

if [ -s "$BUILD/libcxx/libc++.a" ] && [ "${REBUILD_LIBCXX:-0}" != 1 ]; then
  info "reusing libc++ from a previous run ($BUILD/libcxx/libc++.a)"
  libcxx_count=$(ls "$BUILD/libcxx/obj" 2>/dev/null | wc -l)
else
info "building libc++ 3.9 with EDG + musl gcc"
mkdir -p "$BUILD/libcxx/gen" "$BUILD/libcxx/obj"
rm -f "$BUILD/libcxx/obj"/*.o "$BUILD/libcxx/libc++.a"
libcxx_fail=0
libcxx_count=0
for src in "$SRC"/libcxx/src/*.cpp; do
  b=$(basename "$src" .cpp)
  if ! "$EDG" --g++ --c++14 --gnu_version=50000 \
        -D_GNU_SOURCE=1 -D__ELF__=1 \
        -D_LIBCPP_NO_EXCEPTIONS=1 -D_LIBCPP_NO_RTTI=1 -D_LIBCPP_BUILD_STATIC=1 \
        -D_LIBCPP_HAS_MUSL_LIBC=1 -D_LIBCPP_HAS_GCC_ATOMIC_IMP=1 \
        -D_LIBCPP_BUILDING_LIBRARY=1 \
        --edg_base_dir="$BASE" \
        --sys_include="$LIBCXX_INC" --sys_include="$BASE/include" \
        --sys_include=/usr/include --sys_include=@GCCINC@ \
        -I "$SRC/libcxx/src" -tused \
        --gen_c_file_name="$BUILD/libcxx/gen/$b.int.c" "$src" \
        > "$LOG/libcxx-$b.edg.log" 2>&1; then
    printf 'FAIL translate %s (see %s)\n' "$b.cpp" "$LOG/libcxx-$b.edg.log" >&2
    tail -n 4 "$LOG/libcxx-$b.edg.log" >&2 || true
    libcxx_fail=$((libcxx_fail + 1)); continue
  fi
  if ! "$CC" -std=gnu99 -fcommon ${OPT} -w -c "$BUILD/libcxx/gen/$b.int.c" \
        -o "$BUILD/libcxx/obj/$b.o" > "$LOG/libcxx-$b.cc.log" 2>&1; then
    printf 'FAIL compile %s (see %s)\n' "$b.int.c" "$LOG/libcxx-$b.cc.log" >&2
    tail -n 4 "$LOG/libcxx-$b.cc.log" >&2 || true
    libcxx_fail=$((libcxx_fail + 1)); continue
  fi
  libcxx_count=$((libcxx_count + 1))
done
[ "$libcxx_fail" -eq 0 ] || die "$libcxx_fail libc++ sources failed (see $LOG)"
ar rcs "$BUILD/libcxx/libc++.a" "$BUILD/libcxx/obj"/*.o
fi
[ -s "$BUILD/libcxx/libc++.a" ] || die "libc++.a was not produced"

# smoke test: C++11 containers + threads, translated by EDG, compiled by musl gcc
cat > "$BUILD/libcxx/smoke.cpp" <<'EOF'
#include <atomic>
#include <condition_variable>
#include <cstdio>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include <algorithm>
int main() {
  std::vector<int> v{3, 1, 2};
  std::sort(v.begin(), v.end());
  std::string s = "libc++";
  s += " ok";
  auto p = std::make_shared<int>(7);
  std::atomic<int> a(0);
  std::mutex m; std::condition_variable cv; bool ready = false;
  std::thread t([&] { std::lock_guard<std::mutex> g(m); a.fetch_add(1); ready = true; cv.notify_one(); });
  { std::unique_lock<std::mutex> l(m); cv.wait(l, [&] { return ready; }); }
  t.join();
  std::printf("%s %d %d %d\n", s.c_str(), v[0], *p, a.load());
  return (v[0] == 1 && *p == 7 && a.load() == 1) ? 0 : 1;
}
EOF
EDG_TUSED=1 "$CXX" -std=c++11 -O1 -c "$BUILD/libcxx/smoke.cpp" -o "$BUILD/libcxx/smoke.o" \
  > "$LOG/libcxx-smoke.edg.log" 2>&1 || die "EDG failed on the libc++ smoke test"
"$CC" -o "$BUILD/libcxx/smoke" "$BUILD/libcxx/smoke.o" "$BUILD/libcxx/libc++.a" \
  -L"$EDG_LIB" -lC -lm -lpthread -Wl,-z,noexecstack -Wl,--allow-multiple-definition \
  > "$LOG/libcxx-smoke.link.log" 2>&1 || die "linking the libc++ smoke test failed"
SMOKE_OUT=$("$BUILD/libcxx/smoke") || die "the libc++ smoke test failed at run time"
info "libc++ smoke test: $SMOKE_OUT"

# --------------------------------------------------------------- cmake ---

info "configuring LLVM 3.9.0 + clang"
BD=$BUILD/build/stage1
if [ "${REUSE_BUILD:-0}" = 1 ] && [ -f "$BD/CMakeCache.txt" ]; then
  info "reusing existing build tree $BD"
else
  rm -rf "$BD"
  mkdir -p "$BD"
fi
if [ "${SKIP_CONFIGURE:-0}" = 1 ] && [ -f "$BD/CMakeCache.txt" ]; then
  info "skipping cmake configure (existing build tree)"
else
CMAKE_POLICY_VERSION_MINIMUM=3.5 cmake -G "Unix Makefiles" \
  -S "$SRC/llvm" -B "$BD" \
  -DCMAKE_TOOLCHAIN_FILE=@TOOLCHAIN@ \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DLLVM_TARGETS_TO_BUILD=X86 \
  -DLLVM_EXTERNAL_CLANG_SOURCE_DIR="$SRC/clang" \
  -DLLVM_EXTERNAL_CLANG_BUILD=ON \
  -DLLVM_INCLUDE_TOOLS=ON -DLLVM_BUILD_TOOLS=OFF \
  -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_INCLUDE_DOCS=OFF -DLLVM_INCLUDE_UTILS=ON \
  -DLLVM_BUILD_EXAMPLES=OFF \
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
  -DCMAKE_C_FLAGS="$OPT" -DCMAKE_CXX_FLAGS="$OPT" \
  > "$LOG/cmake-configure.log" 2>&1 || {
    tail -n 40 "$LOG/cmake-configure.log" >&2
    die "cmake configure failed (see $LOG/cmake-configure.log)"
  }
fi

if [ "${CONFIGURE_ONLY:-0}" = 1 ]; then
  info "CONFIGURE_ONLY=1: stopping after cmake configure"
  exit 0
fi

# ---------------------------------------------------- big-TU-first order ---
#
# After configure, reorder the object prerequisites in every generated
# build.make so the largest C++ translation units start earliest.  This
# shortens the tail of the EDG translation phase; it is a pure scheduling
# optimization and is tolerated if the generated files do not match.

cat > "$BUILD/tools/sort-build-make.py" <<'SORTMAKE_EOF'
import glob
import os
import re
import sys

bd = sys.argv[1]
obj_src = {}
sizes = {}

def size_of(path):
    if path not in sizes:
        try:
            sizes[path] = os.path.getsize(path)
        except OSError:
            sizes[path] = 0
    return sizes[path]

build_makes = glob.glob(os.path.join(bd, "**", "build.make"), recursive=True)
for bm in build_makes:
    with open(bm) as f:
        lines = f.read().splitlines()
    for ln in lines:
        m = re.match(r"^(\S+\.o): (/\S+\.(?:cpp|cc|cxx|c\+\+))$", ln)
        if m:
            obj_src[m.group(1)] = m.group(2)
reordered = 0
for bm in build_makes:
    with open(bm) as f:
        lines = f.read().splitlines()
    out = []
    i = 0
    changed = False
    while i < len(lines):
        m = re.match(r"^(\S+\.a): (\S+\.o)$", lines[i])
        if not m:
            out.append(lines[i]); i += 1; continue
        target = m.group(1)
        block = []
        while i < len(lines):
            mm = re.match(r"^(\S+\.a): (\S+\.o)$", lines[i])
            if not mm or mm.group(1) != target:
                break
            block.append(lines[i]); i += 1
        if len(block) > 1:
            def key(ln):
                obj = re.match(r"^\S+\.a: (\S+\.o)$", ln).group(1)
                return -size_of(obj_src.get(obj, ""))
            block.sort(key=key)
            out.extend(block)
            changed = True
        else:
            out.extend(block)
    if changed:
        reordered += 1
        with open(bm, "w") as f:
            f.write("\n".join(out) + "\n")
print("reordered object build order in %d build.make files" % reordered)
SORTMAKE_EOF
info "biggest-TU-first: reordering object prerequisites in build.make files"
python3 "$BUILD/tools/sort-build-make.py" "$BD" > "$LOG/big-first.log" 2>&1 || true
cat "$LOG/big-first.log" 2>/dev/null || true

info "building the $LLVM_TARGET target with $JOBS jobs (EDG -> C -> $HOSTCC_KIND)"
if ! cmake --build "$BD" --target "$LLVM_TARGET" -- -j"$JOBS" > "$LOG/cmake-build.log" 2>&1; then
  grep -n -m8 -B2 -A8 'error:' "$LOG/cmake-build.log" >&2 || true
  tail -n 40 "$LOG/cmake-build.log" >&2
  die "$LLVM_TARGET build failed (see $LOG/cmake-build.log)"
fi
info "$LLVM_TARGET target built"

if [ "$LLVM_TARGET" != clang ]; then
  info "target $LLVM_TARGET built; skipping clang install and checks"
  exit 0
fi

# ------------------------------------------------------------ install ---
#
# Install into the isolated prefix only.  The existing llvm5 chain keeps
# /usr/include/c++/v1 and /usr/lib/libc++*.a untouched.

CLANG_VER=$("$BD/bin/clang" --version 2>/dev/null | sed -n 's/.*clang version \([0-9][0-9.]*\).*/\1/p' | head -n1)
[ -n "$CLANG_VER" ] || CLANG_VER=3.9.0
info "installing clang into $PREFIX (clang $CLANG_VER)"
mkdir -p "$PREFIX/bin" "$PREFIX/lib/clang/$CLANG_VER/include" \
         "$PREFIX/include/c++/v1" "$PREFIX/lib"
cp "$BD/bin/clang" "$PREFIX/bin/clang"
ln -sf clang "$PREFIX/bin/clang++"
cp -a "$SRC/clang/lib/Headers/." "$PREFIX/lib/clang/$CLANG_VER/include/"
cp -a "$LIBCXX_INC"/. "$PREFIX/include/c++/v1/"
cp "$BUILD/libcxx/libc++.a" "$PREFIX/lib/libc++.a"
# no libc++abi: EDG's runtime supplies the __cxa_* ABI entry points that the
# exception-free libc++ build needs.
: > "$BUILD/libcxx/empty.c"
"$CC" -c "$BUILD/libcxx/empty.c" -o "$BUILD/libcxx/empty.o"
ar rcs "$PREFIX/lib/libc++abi.a" "$BUILD/libcxx/empty.o"
cp "$EDG_LIB/libC.a" "$PREFIX/lib/libC.a"
# __dso_handle normally comes from crtbegin.o, which a clang-only toolchain
# does not have.  Supply the one definition libc++/libC need.
printf 'void *__dso_handle __attribute__((visibility("hidden"))) = &__dso_handle;\n' \
  > "$BUILD/dso_handle.c"
"$CC" -c "$BUILD/dso_handle.c" -o "$BUILD/dso_handle.o"
cp "$BUILD/dso_handle.o" "$PREFIX/lib/dso_handle.o"
mkdir -p "$PREFIX/lib/clang/$CLANG_VER/lib/linux"
cp "$BUILD/crt/libclang_rt.builtins-x86_64.a" \
   "$PREFIX/lib/clang/$CLANG_VER/lib/linux/libclang_rt.builtins-x86_64.a"
[ -x "$PREFIX/bin/clang" ] || die "clang was not installed into $PREFIX"
[ -x "$PREFIX/bin/clang++" ] || die "clang++ was not installed into $PREFIX"

# ------------------------------------------------------------- checks ---

info "check: clang runs"
"$PREFIX/bin/clang" --version > "$LOG/clang-version.txt" 2>&1 || \
  die "clang --version failed"
grep -q 'clang version 3\.9' "$LOG/clang-version.txt" || \
  die "unexpected clang version: $(cat "$LOG/clang-version.txt")"
"$PREFIX/bin/clang++" --version >/dev/null 2>&1 || die "clang++ does not run"

info "check: clang compiles C and C++ to objects (linked by the host driver)"
cat > "$BUILD/check.c" <<'EOF'
#include <stdio.h>
int main(void) { printf("clang C ok\n"); return 0; }
EOF
cat > "$BUILD/check.cpp" <<'EOF'
#include <cstdio>
#include <string>
#include <vector>
int main() {
  std::vector<int> v{1, 2, 3};
  std::string s = "clang C++ ok";
  std::printf("%s %zu\n", s.c_str(), v.size());
  return 0;
}
EOF
"$PREFIX/bin/clang" --sysroot=/ -O1 -c "$BUILD/check.c" -o "$BUILD/check-c.o" \
  > "$LOG/check-clang-c.log" 2>&1 || die "clang failed to compile C"
"$PREFIX/bin/clang++" --sysroot=/ -O1 -std=c++11 -stdlib=libc++ \
  -fno-exceptions -D_LIBCPP_NO_EXCEPTIONS=1 -D_LIBCPP_NO_RTTI=1 -D_LIBCPP_BUILD_STATIC=1 -D_LIBCPP_HAS_MUSL_LIBC=1 \
  -c "$BUILD/check.cpp" -o "$BUILD/check-cxx.o" \
  > "$LOG/check-clang-cxx.log" 2>&1 || { tail -n 10 "$LOG/check-clang-cxx.log" >&2; die "clang++ failed to compile C++"; }
"$CC" -o "$BUILD/check-c" "$BUILD/check-c.o" -Wl,-z,noexecstack \
  > "$LOG/check-link-c.log" 2>&1 || die "linking the clang C object failed"
"$CC" -o "$BUILD/check-cxx" "$BUILD/check-cxx.o" -L"$PREFIX/lib" -lc++ \
  -L"$EDG_LIB" -lC -lm -lpthread -Wl,-z,noexecstack -Wl,--allow-multiple-definition \
  > "$LOG/check-link-cxx.log" 2>&1 || { tail -n 10 "$LOG/check-link-cxx.log" >&2; die "linking the clang C++ object failed"; }
[ "$("$BUILD/check-c")" = "clang C ok" ] || die "the clang C check failed at run time"
[ "$("$BUILD/check-cxx")" = "clang C++ ok 3" ] || die "the clang C++ check failed at run time"

info "check: stage-2 style link with clang alone (no host gcc, no host crtbegin)"
if "$PREFIX/bin/clang++" --sysroot=/ -static -O1 -fno-pie -std=c++11 -stdlib=libc++ \
     -fno-exceptions -D_LIBCPP_NO_EXCEPTIONS=1 -D_LIBCPP_NO_RTTI=1 -D_LIBCPP_BUILD_STATIC=1 -D_LIBCPP_HAS_MUSL_LIBC=1 \
     -nostartfiles /usr/lib/crt1.o /usr/lib/crti.o /usr/lib/crtn.o \
     "$PREFIX/lib/dso_handle.o" -nodefaultlibs \
     -o "$BUILD/check-clang-link" "$BUILD/check.cpp" \
     -L"$PREFIX/lib" -L/usr/lib -L"$PREFIX/lib/clang/$CLANG_VER/lib/linux" \
     -Wl,--start-group -lc++ -lC -lc -lm -lpthread \
     -lclang_rt.builtins-x86_64 -Wl,--end-group \
     -Wl,--allow-multiple-definition \
     > "$LOG/check-clang-link.log" 2>&1; then
  OUT=$("$BUILD/check-clang-link") && [ "$OUT" = "clang C++ ok 3" ] && \
    echo "stage-2 style self-contained clang link: OK" > "$LOG/check-clang-link.txt" || \
    echo "stage-2 style self-contained clang link: runtime failure" > "$LOG/check-clang-link.txt"
else
  echo "stage-2 style self-contained clang link: link failed (host ld/libgcc needed)" \
    > "$LOG/check-clang-link.txt"
fi
cat "$LOG/check-clang-link.txt"

info "check: everything is static and glibc-free"
for exe in "$PREFIX/bin/clang" "$BUILD/check-c" "$BUILD/check-cxx"; do
  if readelf -l "$exe" | grep -q INTERP; then
    die "$exe is dynamically linked"
  fi
  if readelf -sW "$exe" | grep -q 'GLIBC_'; then
    die "$exe carries GLIBC symbols"
  fi
done

# ------------------------------------------------------------- summary ---

{
  printf 'LLVM/Clang 3.9.1 built by host %s (C only) + EDG 7.0 + musl in bwrap\n' "@HOSTCC_KIND@"
  printf 'date (UTC)      : %s\n' @START_UTC@
  printf 'rootfs          : %s\n' /
  printf 'source tarball  : %s\n' "@TARBALL@"
  printf 'tarball sha256  : %s\n' "@TARBALL_SHA@"
  printf 'host compiler   : %s\n' "@GCC_BANNER@"
  printf 'host kind       : %s\n' @HOSTCC_KIND@
  printf 'C++ translation : EDG 7.0 (%s)\n' "$("$EDG" --version 2>&1 | head -n1)"
  printf 'libc++          : %s objects, %s bytes\n' \
         "$libcxx_count" "$(stat -c %s "$BUILD/libcxx/libc++.a")"
  printf 'compiler-rt     : %s builtins compiled, %s skipped\n' "$crt_ok" "$crt_fail"
  printf 'clang           : %s\n' "$("$PREFIX/bin/clang" --version | head -n1)"
  printf 'libc++ smoke    : %s\n' "$SMOKE_OUT"
  printf 'jobs            : %s\n' "$JOBS"
  printf 'compiler rule   : all C++ sources were translated to C by EDG;\n'
  printf '                  the host compiler was never used for C++.\n'
} > "$BUILD/build-info.txt"
INNER_EOF

# substitute the /-view paths for the inner script
ROOTFS_BUILD_PATH="/build"
sed -i \
  -e "s|@BUILD@|$ROOTFS_BUILD_PATH/llvm3.9|g" \
  -e "s|@CC@|/build/llvm3.9/tools/cc|g" \
  -e "s|@CXX@|/build/llvm3.9/tools/edg-cxx|g" \
  -e "s|@EDG@|/build/edg7.0/edgcpfe|g" \
  -e "s|@EDG51@|/build/edg5.1/edg-5.1/build/edgcpfe|g" \
  -e "s|@BASE@|/build/llvm3.9/edg-base|g" \
  -e "s|@EDG51_BASE@|/build/edg5.1/edg-5.1|g" \
  -e "s|@EDG_LIB@|/build/edg7.0/lib|g" \
  -e "s|@TOOLCHAIN@|/build/llvm3.9/tools/toolchain.cmake|g" \
  -e "s|@JOBS@|$JOBS|g" \
  -e "s|@PREFIX@|$PREFIX|g" \
  -e "s|@OPT@|$OPT|g" \
  -e "s|@LLVM_TARGET@|$LLVM_TARGET|g" \
  -e "s|@PRELINK_ENABLE@|$USE_PRELINK|g" \
  -e "s|@GCCINC@|$GCCINC|g" \
  -e "s|@TARBALL@|$TARBALL|g" \
  -e "s|@TARBALL_SHA@|$TARBALL_SHA|g" \
  -e "s|@START_UTC@|$START_UTC|g" \
  -e "s|@GCC_BANNER@|$GCC_BANNER|g" \
  -e "s|@HOSTCC_KIND@|$HOSTCC_KIND|g" \
    "$INNER"
chmod +x "$INNER"

# ------------------------------------------------------------ sandbox ---
#
# Explicit read-only whitelist of host binaries.  Only these paths (and the
# host runtime they need to start) are visible inside the sandbox; /usr/include
# and every host C/C++ library used for building stay outside.

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

mkdir -p "$ROOTFS/usr/bin" "$ROOTFS/usr/lib/gcc" "$ROOTFS/usr/libexec/gcc"

# Host gcc runtime (crtbegin.o/libgcc) is needed even when the host compiler
# is clang, because the clang driver uses it for start files and libgcc.
GCC_BIN=$(command -v gcc || true)
[ -n "$GCC_BIN" ] || die "host gcc runtime not found (needed for crtbegin/libgcc)"
GCC_LIBEXEC=$(dirname "$("$GCC_BIN" -print-prog-name=cc1)")
GCC_LIBDIR_GCC=$(dirname "$("$GCC_BIN" -print-file-name=crtbegin.o)")
mkdir -p "$ROOTFS$GCC_LIBEXEC" "$ROOTFS$GCC_LIBDIR_GCC"
BWRAP_ARGS+=(
  --ro-bind "$GCC_LIBEXEC" "$GCC_LIBEXEC"
  --ro-bind "$GCC_LIBDIR_GCC" "$GCC_LIBDIR_GCC"
)

for d in /usr/share/cmake-*; do
  [ -d "$d" ] && BWRAP_ARGS+=(--ro-bind "$d" "$d")
done
PY_STDLIB=$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["stdlib"])' 2>/dev/null || true)
if [ -n "$PY_STDLIB" ] && [ -d "$PY_STDLIB" ]; then
  BWRAP_ARGS+=(--ro-bind "$PY_STDLIB" "$PY_STDLIB")
fi

if [ "$HOSTCC_KIND" = clang ]; then
  CLANG_RESOURCE=$("$HOSTCC_REAL" -print-resource-dir 2>/dev/null || true)
  if [ -n "$CLANG_RESOURCE" ] && [ -d "$CLANG_RESOURCE" ]; then
    mkdir -p "$ROOTFS$CLANG_RESOURCE"
    BWRAP_ARGS+=(--ro-bind "$CLANG_RESOURCE" "$CLANG_RESOURCE")
  fi
  for d in /usr/lib/llvm-*; do
    [ -d "$d" ] && BWRAP_ARGS+=(--ro-bind "$d" "$d")
  done
  [ -n "$LIBATOMIC" ] && BWRAP_ARGS+=(--ro-bind "$LIBATOMIC" "$LIBATOMIC")
  HOST_LLD=$(command -v ld.lld || true)
  if [ -n "$HOST_LLD" ]; then
    BWRAP_ARGS+=(--ro-bind "$(readlink -f "$HOST_LLD")" /usr/bin/ld.lld)
  fi
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

add_tool "$HOSTCC"
add_tool "$HOSTCC_REAL"
[ -n "$GCC_C" ] && add_tool "$GCC_C"
[ -n "$GCC_C_REAL" ] && add_tool "$GCC_C_REAL"
for t in \
  /usr/bin/as /usr/bin/ld /usr/bin/ld.bfd \
  /usr/bin/ar /usr/bin/ranlib /usr/bin/nm \
  /usr/bin/objcopy /usr/bin/strip /usr/bin/readelf \
  /usr/bin/make /usr/bin/cmake /usr/bin/python3 \
  /usr/bin/env /usr/bin/sh /usr/bin/bash /usr/bin/dash \
  /usr/bin/sed /usr/bin/grep /usr/bin/gawk /usr/bin/awk /usr/bin/find /usr/bin/xargs \
  /usr/bin/install /usr/bin/cp /usr/bin/mv /usr/bin/rm /usr/bin/mkdir \
  /usr/bin/chmod /usr/bin/ln /usr/bin/cat /usr/bin/head /usr/bin/tail \
  /usr/bin/wc /usr/bin/sort /usr/bin/uniq /usr/bin/date /usr/bin/stat \
  /usr/bin/readlink /usr/bin/dirname /usr/bin/basename /usr/bin/touch \
  /usr/bin/ls /usr/bin/mktemp /usr/bin/cmp /usr/bin/tee /usr/bin/tr /usr/bin/cut \
  /usr/bin/uname \
  /usr/bin/true /usr/bin/false /usr/bin/sleep /usr/bin/test /usr/bin/expr \
  /usr/bin/printf /usr/bin/diff \
  /bin/sh /bin/bash
do
  add_tool "$t"
done
for t in \
  /usr/bin/x86_64-linux-gnu-as /usr/bin/x86_64-linux-gnu-ld \
  /usr/bin/x86_64-linux-gnu-ld.bfd /usr/bin/x86_64-linux-gnu-ar \
  /usr/bin/x86_64-linux-gnu-ranlib /usr/bin/x86_64-linux-gnu-nm \
  /usr/bin/x86_64-linux-gnu-objcopy /usr/bin/x86_64-linux-gnu-strip
do
  add_tool_opt "$t"
done

info "starting bubblewrap sandbox"
printf 'sandbox rootfs: %s\n' "$ROOTFS"
"$BWRAP" "${BWRAP_ARGS[@]}" --chdir /build/llvm3.9 -- \
  /bin/bash /build/llvm3.9/tools/inner-build.sh

# bubblewrap creates empty mount-point files in the backing rootfs for every
# --ro-bind destination that did not exist; drop those stubs.
find "$ROOTFS/usr/bin" -maxdepth 1 -type f -size 0 -delete 2>/dev/null || true
find "$ROOTFS/usr/lib/gcc" "$ROOTFS/usr/libexec/gcc" -type f -size 0 -delete 2>/dev/null || true
rmdir "$ROOTFS/usr/lib/gcc" "$ROOTFS/usr/libexec/gcc" 2>/dev/null || true

END=$(date +%s)
ELAPSED=$((END - START))
info "done ($ELAPSED s)"
printf '\n'
printf 'LLVM/clang prefix : %s\n' "$ROOTFS$PREFIX"
printf 'clang             : %s\n' "$ROOTFS$PREFIX/bin/clang"
printf 'libc++            : %s\n' "$BUILD/libcxx/libc++.a"
printf 'compiler-rt       : %s\n' "$BUILD/crt/libclang_rt.builtins-x86_64.a"
printf 'build info        : %s\n' "$BUILD/build-info.txt"
printf 'build logs        : %s\n' "$BUILD/log"
printf 'elapsed           : %s s\n' "$ELAPSED"
