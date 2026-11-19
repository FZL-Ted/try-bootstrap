#!/usr/bin/env bash
#
# Stage 3a of the "reference host + musl" bootstrap chain: build LLVM/Clang
# 5.0.2 with the host C compiler, EDG 7.0 and musl only.
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
#   * the host gcc (restricted to the musl rootfs) compiles that C;
#   * gcc/g++/clang/clang++ are never asked to compile C++.
#
# Inputs:
#     ${ROOTFS:-rootfs-hostgcc}/        musl rootfs with EDG 5.1 and 7.0
#     llvm-project-5.x.tar.gz           LLVM 5.0.2 monorepo source
#
# Output (all inside the rootfs):
#     <rootfs>/build/llvm5/libcxx/libc++.a      libc++ 5.0.2 built via EDG
#     <rootfs>/build/llvm5/crt/libclang_rt.builtins-x86_64.a
#     <rootfs>/build/llvm5/build/stage1/       LLVM build tree
#     <rootfs>/opt/llvm5/                      installed LLVM + clang + libc++
#     <rootfs>/build/llvm5/build-info.txt
#
# Usage:
#     ./refhost-llvm5.x.sh
#     JOBS=8 ./refhost-llvm5.x.sh
#
# Overridable environment variables:
#     ROOTFS      rootfs directory (default: <script dir>/rootfs-hostgcc)
#     HOSTCC      host C compiler (default: gcc from PATH)
#     JOBS        parallel jobs (default: nproc --ignore=1)
#     TARBALL     LLVM source tarball
#     PREFIX      install prefix inside the rootfs (default: /opt/llvm5)
#     KEEP_SRC    if set, do not re-extract the source tree
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

JOBS=${JOBS:-$(nproc --ignore=1 2>/dev/null || nproc 2>/dev/null || echo 1)}
[ "$JOBS" -ge 1 ] 2>/dev/null || JOBS=1
PREFIX=${PREFIX:-/opt/llvm5}
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

TARBALL=${TARBALL:-$(find_input llvm-project-5.x.tar.gz || true)}
[ -n "$TARBALL" ] && [ -f "$TARBALL" ] || \
  die "llvm-project-5.x.tar.gz not found (set TARBALL=...)"
TARBALL_SHA=$(sha256sum "$TARBALL" | cut -d' ' -f1)

BUILD=$ROOTFS/build/llvm5
SRC=$BUILD/src
WORK=$BUILD

# ---------------------------------------------------------------- inputs ---

[ -x "$ROOTFS/bin/cc" ] || die "musl wrapper not found: $ROOTFS/bin/cc (run ./refhost-musl.sh)"
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
# sees a single self-contained tree at /build/llvm5.

if [ -z "${KEEP_SRC:-}" ] || [ ! -d "$SRC/llvm" ]; then
  info "extracting LLVM source into $SRC"
  rm -rf "$SRC"
  mkdir -p "$SRC"
  tar -xzf "$TARBALL" -C "$SRC" --strip-components=1 --exclude='.git' || \
    die "extracting $TARBALL failed"
fi
[ -f "$SRC/llvm/CMakeLists.txt" ] || die "unexpected source tree: $SRC/llvm missing"
[ -d "$SRC/libcxx/include" ] || die "unexpected source tree: $SRC/libcxx missing"

# LLVM 5 predates CMake 4: it forces CMP0051 to OLD, which CMake >= 4 rejects.
# The policy only affects how generator expressions in SOURCES are handled and
# NEW is the correct behaviour here.
if grep -q 'cmake_policy(SET CMP0051 OLD)' "$SRC/llvm/CMakeLists.txt"; then
  info "patching llvm/CMakeLists.txt: CMP0051 OLD -> NEW (CMake 4 compatibility)"
  sed -i 's/cmake_policy(SET CMP0051 OLD)/cmake_policy(SET CMP0051 NEW)/' \
    "$SRC/llvm/CMakeLists.txt"
fi

# libc++ 5 assumes glibc's strtoll_l/strtoull_l, which musl does not provide.
# The C locale is the only locale used by this bootstrap, so the plain
# functions are correct.
if grep -q 'strtoll_l(__a' "$SRC/libcxx/include/locale"; then
  info "patching libc++ locale: use strtoll/strtoull (musl has no *_l)"
  sed -i \
    's/strtoll_l(__a, &__p2, __base, _LIBCPP_GET_C_LOCALE)/strtoll(__a, \&__p2, __base)/' \
    "$SRC/libcxx/include/locale"
  sed -i \
    's/strtoull_l(__a, &__p2, __base, _LIBCPP_GET_C_LOCALE)/strtoull(__a, \&__p2, __base)/' \
    "$SRC/libcxx/include/locale"
fi

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
TOOLCHAIN=$BUILD/tools/toolchain.cmake
INNER=$BUILD/tools/inner-build.sh
GCCINC=$("$ROOTFS/bin/cc" -print-file-name=include)
[ -d "$GCCINC" ] || die "host compiler include directory not found: $GCCINC"

cat > "$SANDBOX_CC" <<EOF
#!/bin/sh
# Host C compiler restricted to the musl rootfs; C only, static output.
REAL_GCC='$HOSTCC_REAL'
SYSROOT=/
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
exec "\$REAL_GCC" --sysroot="\$SYSROOT" -static -D_LARGEFILE64_SOURCE=1 "\$@"
EOF
chmod +x "$SANDBOX_CC"

cat > "$SANDBOX_CXX" <<'WRAPPER'
#!/bin/bash
# EDG C++ -> C -> musl gcc driver with EDG automatic template instantiation
# and prelinking.  Prototype for refhost-llvm5.x.sh.
set -u
ROOTFS="@ROOTFS@"
EDG="@EDG@"
BASE="@BASE@"
CC="@CC@"
LIBCXX_INC="@LIBCXX_INC@"
GCCINC="@GCCINC@"
REAL_GCC="@REAL_GCC@"
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
      exec "$REAL_GCC" "$@"
    fi
    ;;
esac
case " $* " in
  *" -E "*)
    # Preprocess only: let EDG do it (same standard library view).
    exec "$EDG" --g++ --c++14 --gnu_version=50000 -D_GNU_SOURCE=1 -D__ELF__=1 \
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
              -D_LARGEFILE64_SOURCE=1 -D_LIBCPP_NO_EXCEPTIONS=1
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
              -D_LARGEFILE64_SOURCE=1 -D_LIBCPP_NO_EXCEPTIONS=1
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
  -e "s|@BASE@|/build/llvm5/edg-base|g" \
  -e "s|@CC@|/build/llvm5/tools/cc|g" \
  -e "s|@LIBCXX_INC@|/build/llvm5/src/libcxx/include|g" \
  -e "s|@GCCINC@|$GCCINC|g" \
  -e "s|@REAL_GCC@|$HOSTCC_REAL|g" \
  -e "s|@OPT@|$OPT|g" \
  -e "s|@PRELINK_ENABLE@|$USE_PRELINK|g" \
  -e "s|@PRELINK@|/build/llvm5/plbuild/edg_prelink|g" \
  -e "s|@LIBCXX_A@|/build/llvm5/libcxx/libc++.a|g" \
  -e "s|@LIB_C@|/build/edg7.0/lib/libC.a|g" \
  -e "s|@MANIFEST@|/build/llvm5/edg-obj-manifest.txt|g" \
  -e "s|@BUILDROOT@|/build/llvm5|g" \
  "$SANDBOX_CXX"
chmod +x "$SANDBOX_CXX"

cat > "$TOOLCHAIN" <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER /build/llvm5/tools/cc)
set(CMAKE_CXX_COMPILER /build/llvm5/tools/edg-cxx)
set(CMAKE_ASM_COMPILER /build/llvm5/tools/cc)
set(CMAKE_C_STANDARD_LIBRARIES "-lm -lpthread")
set(CMAKE_CXX_STANDARD_LIBRARIES "-L/build/llvm5/libcxx -lc++ -L/build/edg7.0/lib -lC -lm -lpthread")
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
EDG51=@EDG51@
BASE=@BASE@
EDG51_BASE=@EDG51_BASE@
LIBCXX_INC=$SRC/libcxx/include
EDG_LIB=@EDG_LIB@
JOBS=@JOBS@
PREFIX=@PREFIX@
OPT=@OPT@
LLVM_TARGET=@LLVM_TARGET@
USE_PRELINK=@PRELINK_ENABLE@
LOG=$BUILD/log
mkdir -p "$LOG"

# ------------------------------------------------------------- libc++ ---
#
# Build libc++ 5 with EDG -> C -> musl gcc.  Exceptions and RTTI are kept off
# for the library's own throw sites (the bootstrap uses -fno-exceptions), but
# the full container/iostream/locale code is built so that LLVM can use the
# standard library normally.

if [ -s "$BUILD/libcxx/libc++.a" ] && [ "${REBUILD_LIBCXX:-0}" != 1 ]; then
  info "reusing libc++ from a previous run ($BUILD/libcxx/libc++.a)"
else
info "building libc++ 5.0.2 with EDG + musl gcc"
mkdir -p "$BUILD/libcxx/gen" "$BUILD/libcxx/obj"
rm -f "$BUILD/libcxx/obj"/*.o "$BUILD/libcxx/libc++.a"
libcxx_fail=0
for src in "$SRC"/libcxx/src/*.cpp; do
  b=$(basename "$src" .cpp)
  if ! "$EDG" --g++ --c++14 --gnu_version=50000 \
        -D_GNU_SOURCE=1 -D__ELF__=1 \
        -D_LIBCPP_NO_EXCEPTIONS=1 -D_LIBCPP_HAS_MUSL_LIBC=1 \
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
done
[ "$libcxx_fail" -eq 0 ] || die "$libcxx_fail libc++ sources failed (see $LOG)"
ar rcs "$BUILD/libcxx/libc++.a" "$BUILD/libcxx/obj"/*.o
fi
[ -s "$BUILD/libcxx/libc++.a" ] || die "libc++.a was not produced"

# smoke test: C++14 + STL + threads, translated by EDG, compiled by musl gcc
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
EDG_TUSED=1 "$CXX" -std=c++14 -O1 -c "$BUILD/libcxx/smoke.cpp" -o "$BUILD/libcxx/smoke.o" \
  > "$LOG/libcxx-smoke.edg.log" 2>&1 || die "EDG failed on the libc++ smoke test"
"$CC" -o "$BUILD/libcxx/smoke" "$BUILD/libcxx/smoke.o" "$BUILD/libcxx/libc++.a" \
  -L"$EDG_LIB" -lC -lm -lpthread -Wl,-z,noexecstack -Wl,--allow-multiple-definition \
  > "$LOG/libcxx-smoke.link.log" 2>&1 || die "linking the libc++ smoke test failed"
SMOKE_OUT=$("$BUILD/libcxx/smoke") || die "the libc++ smoke test failed at run time"
info "libc++ smoke test: $SMOKE_OUT"

# --------------------------------------------------- compiler-rt builtins ---
#
# clang emits calls to the compiler-rt builtins for 128-bit operations and a
# few other things.  These sources are plain C (plus x86-64 assembly), so they
# are built here with the host gcc + musl; stage 2 can then link with clang
# alone, without the host gcc runtime.

if [ -s "$BUILD/crt/libclang_rt.builtins-x86_64.a" ] && [ "${REBUILD_CRT:-0}" != 1 ]; then
  info "reusing compiler-rt builtins from a previous run"
  crt_ok=$(ls "$BUILD/crt/obj" 2>/dev/null | wc -l); crt_fail=0
else
info "building compiler-rt builtins"
B=$SRC/compiler-rt/lib/builtins
mkdir -p "$BUILD/crt/obj"
rm -f "$BUILD/crt/obj"/*.o "$BUILD/crt/libclang_rt.builtins-x86_64.a"
GENERIC=$(awk '/^set\(GENERIC_SOURCES$/{f=1;next} f{ if ($0 ~ /\)/) {sub(/\).*/,"",$0); if ($0 ~ /[^ ]/) print; exit} print }' "$B/CMakeLists.txt" | sed 's/#.*//; s/^ *//; s/ *$//' | grep -v '^$')
EXTRA="emutls.c enable_execute_stack.c eprintf.c atomic.c clear_cache.c gcc_personality_v0.c x86_64/chkstk.S x86_64/chkstk2.S x86_64/floatdidf.c x86_64/floatdisf.c x86_64/floatdixf.c x86_64/floatundidf.S x86_64/floatundisf.S x86_64/floatundixf.S"
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

# ------------------------------------------------- EDG prelinker tool ---
#
# EDG's automatic instantiation flow needs util/edg_prelink.  It is a small
# C++ program from the EDG release; build it with EDG -> C -> musl gcc in
# -tused mode (the prelinker itself does not use automatic instantiation).

if [ "$USE_PRELINK" = 1 ]; then
info "building the EDG prelinker (util/edg_prelink)"
PLB=$BUILD/plbuild
mkdir -p "$PLB"
EDG_SRC=/build/edg7.0/src
cp "$EDG_SRC/util/edg_prelink.c" "$PLB/edg_prelink.cpp"
cp "$EDG_SRC/util/decode.c" "$PLB/decode.cpp"
EDG_TUSED=1 "$CXX" -std=c++14 "$OPT" -I "$EDG_SRC/src" -I "$EDG_SRC/util" \
  -c "$PLB/edg_prelink.cpp" -o "$PLB/edg_prelink.o" \
  > "$LOG/edg_prelink-1.log" 2>&1 || {
    tail -n 10 "$LOG/edg_prelink-1.log" >&2
    die "EDG failed to translate util/edg_prelink.c"
  }
EDG_TUSED=1 "$CXX" -std=c++14 "$OPT" -I "$EDG_SRC/src" -I "$EDG_SRC/util" \
  -c "$PLB/decode.cpp" -o "$PLB/decode.o" \
  > "$LOG/edg_prelink-2.log" 2>&1 || {
    tail -n 10 "$LOG/edg_prelink-2.log" >&2
    die "EDG failed to translate util/decode.c"
  }
"$CC" -o "$PLB/edg_prelink" "$PLB/edg_prelink.o" "$PLB/decode.o" \
  -L"$EDG_LIB" -lC -lm -Wl,--allow-multiple-definition \
  > "$LOG/edg_prelink-link.log" 2>&1 || {
    tail -n 10 "$LOG/edg_prelink-link.log" >&2
    die "linking edg_prelink failed"
  }
[ -x "$PLB/edg_prelink" ] || die "edg_prelink was not produced"
info "prelinker: $PLB/edg_prelink"
else
  info "EDG automatic instantiation/prelinker disabled (USE_PRELINK=1 enables it)"
fi

# --------------------------------------------------------------- cmake ---

info "configuring LLVM 5.0.2 + clang"
BD=$BUILD/build/stage1
if [ "${REUSE_BUILD:-0}" = 1 ] && [ -f "$BD/CMakeCache.txt" ]; then
  info "reusing existing build tree $BD"
else
  rm -rf "$BD"
  mkdir -p "$BD"
  rm -f "$BUILD/edg-obj-manifest.txt"
fi
if [ "${SKIP_CONFIGURE:-0}" = 1 ] && [ -f "$BD/CMakeCache.txt" ]; then
  info "skipping cmake configure (existing build tree)"
else
CMAKE_POLICY_VERSION_MINIMUM=3.5 cmake -G "Unix Makefiles" \
  -S "$SRC/llvm" -B "$BD" \
  -DCMAKE_TOOLCHAIN_FILE=@TOOLCHAIN@ \
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
  -DCMAKE_C_FLAGS="$OPT" -DCMAKE_CXX_FLAGS="$OPT" \
  > "$LOG/cmake-configure.log" 2>&1 || {
    tail -n 30 "$LOG/cmake-configure.log" >&2
    die "cmake configure failed (see $LOG/cmake-configure.log)"
  }
fi

info "building the clang target with $JOBS jobs (EDG -> C -> musl gcc)"
: > "$LOG/cmake-build.log"
attempt=0
last_state=""
while :; do
  attempt=$((attempt + 1))
  if cmake --build "$BD" --target "$LLVM_TARGET" -- -j"$JOBS" >> "$LOG/cmake-build.log" 2>&1; then
    info "$LLVM_TARGET target built (attempt $attempt)"
    break
  fi
  state=$(find "$BD" -name '*.o' -printf '%T@ %p\n' 2>/dev/null | sort | md5sum | cut -d' ' -f1)
  if [ "$state" = "$last_state" ] || [ "$attempt" -ge 40 ]; then
    grep -n -m5 -B2 -A6 'error:' "$LOG/cmake-build.log" >&2 || true
    tail -n 30 "$LOG/cmake-build.log" >&2
    die "clang build failed after $attempt attempts (see $LOG/cmake-build.log)"
  fi
  last_state=$state
  info "prelinker changed template assignments; retrying link (attempt $((attempt + 1)))"
done

if [ "$LLVM_TARGET" != clang ]; then
  info "target $LLVM_TARGET built; skipping clang install and checks"
  exit 0
fi

info "installing clang into $PREFIX (manual, no LLVM tool/header install)"
mkdir -p "$PREFIX/bin" "$PREFIX/lib/clang/5.0.2/include"
cp "$BD/bin/clang" "$PREFIX/bin/clang"
ln -sf clang "$PREFIX/bin/clang++"
cp -a "$SRC/clang/lib/Headers/." "$PREFIX/lib/clang/5.0.2/include/"
[ -x "$PREFIX/bin/clang" ] || die "clang was not installed into $PREFIX"
[ -x "$PREFIX/bin/clang++" ] || die "clang++ was not installed into $PREFIX"

# ---------------------------------------------- bootstrap prerequisites ---
#
# Stage 2 runs clang++ with the musl rootfs as its sysroot; make the pieces
# it needs discoverable at the standard locations.

info "installing libc++ headers and libraries for stage 2"
mkdir -p /usr/include/c++/v1 "$PREFIX/include/c++/v1"
cp -a "$LIBCXX_INC"/. /usr/include/c++/v1/
cp -a "$LIBCXX_INC"/. "$PREFIX/include/c++/v1/"
cp "$BUILD/libcxx/libc++.a" /usr/lib/libc++.a
cp "$BUILD/libcxx/libc++.a" "$PREFIX/lib/libc++.a"
# no libc++abi: EDG's runtime supplies the __cxa_* ABI entry points that the
# exception-free libc++ build needs.
: > "$BUILD/libcxx/empty.c"
"$CC" -c "$BUILD/libcxx/empty.c" -o "$BUILD/libcxx/empty.o"
ar rcs /usr/lib/libc++abi.a "$BUILD/libcxx/empty.o"
cp /usr/lib/libc++abi.a "$PREFIX/lib/libc++abi.a"
cp /build/edg7.0/lib/libC.a /usr/lib/libC.a
cp /build/edg7.0/lib/libC.a "$PREFIX/lib/libC.a"
# __dso_handle normally comes from crtbegin.o, which a clang-only toolchain does
# not have.  Supply the one definition libc++/libC need.
printf 'void *__dso_handle __attribute__((visibility("hidden"))) = &__dso_handle;\n' \
  > "$BUILD/dso_handle.c"
"$CC" -c "$BUILD/dso_handle.c" -o "$BUILD/dso_handle.o"
cp "$BUILD/dso_handle.o" /usr/lib/dso_handle.o
cp "$BUILD/dso_handle.o" "$PREFIX/lib/dso_handle.o"
# compiler-rt builtins where clang looks for them ($PREFIX/lib/clang/<ver>/lib/linux)
CLANG_VER=$("$PREFIX/bin/clang" --version 2>/dev/null | sed -n 's/.*clang version \([0-9][0-9.]*\).*/\1/p' | head -n1)
[ -n "$CLANG_VER" ] || CLANG_VER=5.0.2
mkdir -p "$PREFIX/lib/clang/$CLANG_VER/lib/linux"
cp "$BUILD/crt/libclang_rt.builtins-x86_64.a" \
   "$PREFIX/lib/clang/$CLANG_VER/lib/linux/libclang_rt.builtins-x86_64.a"

# ------------------------------------------------------------- checks ---

info "check: clang runs"
"$PREFIX/bin/clang" --version > "$LOG/clang-version.txt" 2>&1 || \
  die "clang --version failed"
grep -q 'clang version 5\.' "$LOG/clang-version.txt" || \
  die "unexpected clang version: $(cat "$LOG/clang-version.txt")"
"$PREFIX/bin/clang++" --version >/dev/null 2>&1 || die "clang++ does not run"

info "check: clang compiles C and C++ to objects (linked by musl gcc)"
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
"$PREFIX/bin/clang++" --sysroot=/ -O1 -std=c++14 -stdlib=libc++ \
  -fno-exceptions -D_LIBCPP_NO_EXCEPTIONS=1 \
  -c "$BUILD/check.cpp" -o "$BUILD/check-cxx.o" \
  > "$LOG/check-clang-cxx.log" 2>&1 || die "clang++ failed to compile C++"
"$CC" -o "$BUILD/check-c" "$BUILD/check-c.o" -Wl,-z,noexecstack \
  > "$LOG/check-link-c.log" 2>&1 || die "linking the clang C object failed"
"$CC" -o "$BUILD/check-cxx" "$BUILD/check-cxx.o" -L"$BUILD/libcxx" -lc++ \
  -L"$EDG_LIB" -lC -lm -lpthread -Wl,-z,noexecstack -Wl,--allow-multiple-definition \
  > "$LOG/check-link-cxx.log" 2>&1 || die "linking the clang C++ object failed"
[ "$("$BUILD/check-c")" = "clang C ok" ] || die "the clang C check failed at run time"
[ "$("$BUILD/check-cxx")" = "clang C++ ok 3" ] || die "the clang C++ check failed at run time"

info "check: stage-2 style link with clang alone (no host gcc, no host crtbegin)"
if "$PREFIX/bin/clang++" --sysroot=/ -static -O1 -fno-pie -std=c++14 -stdlib=libc++ \
     -fno-exceptions -D_LIBCPP_NO_EXCEPTIONS=1 \
     -nostartfiles /usr/lib/crt1.o /usr/lib/crti.o /usr/lib/crtn.o \
     /usr/lib/dso_handle.o -nodefaultlibs -no-pie \
     -o "$BUILD/check-clang-link" "$BUILD/check.cpp" \
     -L/usr/lib -L"$EDG_LIB" -L"$PREFIX/lib/clang/5.0.2/lib/linux" \
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

# ------------------------------------------------------------ read-only ---

info "summary"
{
  printf 'LLVM/Clang 5.0.2 built by host gcc (C only) + EDG 7.0 + musl in bwrap\n'
  printf 'date (UTC)      : %s\n' @START_UTC@
  printf 'rootfs          : %s\n' /
  printf 'source tarball  : %s\n' "@TARBALL@"
  printf 'tarball sha256  : %s\n' "@TARBALL_SHA@"
  printf 'host compiler   : %s\n' "@GCC_BANNER@"
  printf 'C++ translation : EDG 7.0 (%s)\n' "$("$EDG" --version 2>&1 | head -n1)"
  printf 'libc++          : %s objects, %s bytes\n' \
         "$(ls "$BUILD/libcxx/obj" | wc -l)" "$(stat -c %s "$BUILD/libcxx/libc++.a")"
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
  -e "s|@BUILD@|$ROOTFS_BUILD_PATH/llvm5|g" \
  -e "s|@CC@|/build/llvm5/tools/cc|g" \
  -e "s|@CXX@|/build/llvm5/tools/edg-cxx|g" \
  -e "s|@EDG@|/build/edg7.0/edgcpfe|g" \
  -e "s|@EDG51@|/build/edg5.1/edg-5.1/build/edgcpfe|g" \
  -e "s|@BASE@|/build/llvm5/edg-base|g" \
  -e "s|@EDG51_BASE@|/build/edg5.1/edg-5.1|g" \
  -e "s|@EDG_LIB@|/build/edg7.0/lib|g" \
  -e "s|@TOOLCHAIN@|/build/llvm5/tools/toolchain.cmake|g" \
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
  --ro-bind /usr/libexec/gcc/x86_64-linux-gnu/16 /usr/libexec/gcc/x86_64-linux-gnu/16
  --ro-bind /usr/lib/gcc/x86_64-linux-gnu/16 /usr/lib/gcc/x86_64-linux-gnu/16
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
  /usr/bin/gcc /usr/bin/x86_64-linux-gnu-gcc-16 \
  /usr/bin/as /usr/bin/x86_64-linux-gnu-as \
  /usr/bin/ld /usr/bin/x86_64-linux-gnu-ld \
  /usr/bin/ld.bfd /usr/bin/x86_64-linux-gnu-ld.bfd \
  /usr/bin/ar /usr/bin/x86_64-linux-gnu-ar \
  /usr/bin/ranlib /usr/bin/x86_64-linux-gnu-ranlib \
  /usr/bin/nm /usr/bin/x86_64-linux-gnu-nm \
  /usr/bin/objcopy /usr/bin/x86_64-linux-gnu-objcopy \
  /usr/bin/strip /usr/bin/x86_64-linux-gnu-strip \
  /usr/bin/make /usr/bin/cmake /usr/bin/python3 /usr/bin/python3.14 \
  /usr/bin/env /usr/bin/sh /usr/bin/bash /usr/bin/dash \
  /usr/bin/sed /usr/bin/grep /usr/bin/gawk /usr/bin/awk /usr/bin/find /usr/bin/xargs \
  /usr/bin/install /usr/bin/cp /usr/bin/mv /usr/bin/rm /usr/bin/mkdir \
  /usr/bin/chmod /usr/bin/ln /usr/bin/cat /usr/bin/head /usr/bin/tail \
  /usr/bin/wc /usr/bin/sort /usr/bin/uniq /usr/bin/date /usr/bin/stat \
  /usr/bin/readlink /usr/bin/dirname /usr/bin/basename /usr/bin/touch \
  /usr/bin/ls /usr/bin/mkdir /usr/bin/rm /usr/bin/cp /usr/bin/mv \
  /usr/bin/readelf /usr/bin/uname /usr/bin/md5sum /usr/bin/mktemp \
  /usr/bin/nm /usr/bin/x86_64-linux-gnu-nm \
  /usr/bin/cmp /usr/bin/tee /usr/bin/tr /usr/bin/cut /usr/bin/true \
  /usr/bin/false /usr/bin/sleep /usr/bin/test /usr/bin/expr \
  /bin/sh /bin/bash
do
  add_tool "$t"
done

info "starting bubblewrap sandbox"
printf 'sandbox rootfs: %s\n' "$ROOTFS"
"$BWRAP" "${BWRAP_ARGS[@]}" --chdir /build/llvm5 -- \
  /bin/bash /build/llvm5/tools/inner-build.sh

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
