#!/bin/bash
# =============================================================================
# 3-build-musl-gcc.sh — rebuild musl 1.2.6 in full with gcc46 ("musl-gcc")
# =============================================================================
# The compiler is the **stage-1 gcc 4.6.4.1 that xcc built**
# (rootfs3/build/gcc-4.6.4.1/gcc/xgcc). With a real C compiler behind it, this
# build can do more than an xcc-driven one:
#
#   * **no target is skipped**:
#       - src/complex/* (68 files): xcc has no _Complex, gcc has;
#       - src/process/posix_spawn.c: xcc's type checking is too strict here, gcc
#         has no such problem;
#       - long double is no longer squeezed into a double: on x86_64 gcc gives a
#         genuine 80-bit x87 type, so the LDBL_* overrides that a double-only
#         long double needs are **not** applied;
#       - bits/alltypes.h is musl's **original generated** version: gcc uses
#         musl's own stdarg.h, so no va_list bridge is needed.
#   * CFLAGS mirror musl's own Makefile: `-std=c99 -ffreestanding -nostdinc`,
#     `-D_XOPEN_SOURCE=700`, `-Os -pipe`; `-fno-stack-protector` and
#     `-fno-tree-loop-distribute-patterns` are applied to every object; crt
#     targets additionally get `-DCRT`.
#
# Assembler/linker: GCC has no assembler of its own, so `as`/`ld` come from the
# self-built binutils (rootfs3/usr/binutils/bin) when they exist, or from xcc's
# own as/ld otherwise (see ASLD). xcc's as cannot assemble the x86_64 arch .s
# files (x87/SSE instructions), so two fallback passes cover that case: a failed
# arch .s is replaced by the generic C implementation of the same logical path
# ([4b]), and longjmp/sigsetjmp, which have no usable generic version, get a
# hand-written equivalent ([4c]). The [4c] pass always installs its two objects.
#
# Output: rootfs3/usr/musl-gcc/{include,lib}. The global sysroot is left alone by
#       default: ./3-build-musl-xcc.sh [5.5] points rootfs3/usr/{include,lib} at
#       musl-1, and ./3-adjust-rootfs-current.sh repoints it at musl-gcc.
#       MATERIALIZE_SYSROOT=1 only adds sysroot entries that are still missing.
# Log: results/3-build-musl-gcc.log
#
# Usage:
#   ./3-build-musl-gcc.sh                 # full build + archive + report
#   SELFTEST=1 ./3-build-musl-gcc.sh      # extra end-to-end self-test (with _Complex / long double)
#   JOBS=20 ./3-build-musl-gcc.sh
#   FORCE_SRC=1 ./3-build-musl-gcc.sh     # unpack again
#   NO_ARCHIVE=1 ./3-build-musl-gcc.sh    # compile only, do not archive libc.a
#   SKIP_COMPLEX=1 ./3-build-musl-gcc.sh  # also skip src/complex and posix_spawn
#   MATERIALIZE_SYSROOT=1 ./3-build-musl-gcc.sh   # add the missing global sysroot entries
#   ASLD=binutils|xcc|host ./3-build-musl-gcc.sh  # where as/ld come from (default
#                                        #   auto: the self-built binutils when
#                                        #   rootfs3/usr/binutils/bin exists, else
#                                        #   xcc's as/ld, which cannot assemble
#                                        #   GCC's assembly dialect)
#   ALLOW_HOST_AS=1 ./3-build-musl-gcc.sh # same as ASLD=host (diagnostic only)
#
# Host tools — the [0/7] check verifies: bash make unzip sed awk grep find sort
# uniq ar cp mv rm mkdir ln cat head tail wc tr cut xargs stat sha256sum file tee
# comm. The script also calls chmod, cmp, ls, basename, dirname, nproc and date,
# plus realpath when MATERIALIZE_SYSROOT=1.
# **Never used**: host gcc/cc/as/ld/cpp, host /usr/include, host /usr/lib.
# Compiling is done by gcc46; assembling and linking by the self-built binutils
# (or by xcc's as/ld when ASLD selects them: -B injection, see the gcc46-cc
# wrapper below).
#
# -----------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=3-lib/common.sh
source "$ROOT/3-lib/common.sh"   # for warn() and record() only; everything else is defined here
ROOTFS="$ROOT/rootfs3"
XCCDIR="$ROOTFS/usr/xcc-musl"                  # xcc's as/ld: the fallback assembler (GCC has none)
GCCDIR="$ROOTFS/build/gcc-4.6.4.1/gcc"       # the gcc that xcc built (all-gcc output)
GCC="$GCCDIR/xgcc"
GINCLUDE="$ROOTFS/src/gcc-4.6.4.1/gcc/gcc/ginclude"  # gcc's own stddef.h/stdarg.h (source tree, not installed)
SRC_ZIP="$ROOT/musl-1.2.6.zip"
OUT_INC="$ROOTFS/usr/musl-gcc/include"
OUT_LIB="$ROOTFS/usr/musl-gcc/lib"
COMPAT="$ROOTFS/usr/musl-gcc-compat"          # helper dir for this build (hand-written .s etc.)
COMPAT_INC="$COMPAT/shim"                     # unused here: gcc takes musl's own stdarg.h
LOGDIR="$ROOT/results"
LOG="$LOGDIR/3-build-musl-gcc.log"

ARCH="${ARCH:-x86_64}"
JOBS="${JOBS:-$(nproc)}"
FORCE_SRC="${FORCE_SRC:-0}"
NO_ARCHIVE="${NO_ARCHIVE:-0}"
SELFTEST="${SELFTEST:-0}"
SKIP_COMPLEX="${SKIP_COMPLEX:-0}"             # 0 = build everything (src/complex included; gcc has _Complex)
OPT="${OPT:-"-Os -pipe"}"                      # musl's own CFLAGS_AUTO

work="$ROOTFS/build/musl-gcc"
tree="$work/musl-1.2.6"
objdir="$work/obj"
logdir="$work/log"
manifest="$work/manifest.tsv"
skipped="$work/skipped.txt"                    # targets explicitly skipped (for the report)

die()  { echo "error: $*" >&2; exit 1; }
note() { printf '\n==> %s\n' "$*"; }

# gcc46 wrapper: **the order of the -B prefixes matters**. Only as/ld may live in
#   the first prefix, so those come from xcc or from the self-built binutils (the
#   constraint forbids the host's); `cc1`/`cc1plus` are not there and are found in
#   the gcc build directory that follows.
#   Two traps, both hit in practice:
#     1) With only `-B$GCCDIR`, GCC finds the forwarding script `$GCCDIR/as` in its
#        own build directory. That script execs the assembler GCC was configured
#        with (--with-as, i.e. the self-built binutils as), so the ASLD choice is
#        silently overridden and the fact that "xcc's as cannot assemble the
#        x87/SSE arch .s files" stays hidden;
#     2) With `-B$XCCDIR/bin` first, `cc1`/`cpp` are taken from xcc's directory as
#        well (it holds as/ld/cc1/cpp), and 1340 of 1349 targets fail.
#   The fix: symlink only xcc's **as/ld** into a dedicated directory
#   $work/asld-bin and put that first.
#   `-isystem <srcdir>/ginclude` supplies gcc's own stddef.h/stdarg.h from the
#   source tree; musl compiles with -nostdinc, so they must be given explicitly
#   (without this the build fails with `fatal error: stddef.h`).
# ---------------------------------------------------------------- assembler/linker
# Constraint: the host binutils must not be used. Three sources are possible:
#   * `binutils` (**the default when the self-built binutils exist**):
#     `rootfs3/usr/binutils/bin/{as,ld}`, the real GNU as/ld built by
#     ./3-build-binutils.sh from xcc. They accept GCC's assembly dialect
#     (`.file`/`.cfi_*`/SSE), so this is the compliant path;
#   * `xcc`: xcc's own as/ld (plus the as adapter below). ⚠️ xcc's as cannot
#     handle GCC's assembly dialect (`.file`/`.cfi_startproc` report
#     `unknown directive`, and there is no SSE support), so this path is bound to
#     fail and is kept for comparison only;
#   * `host`: diagnostic mode only (also reachable as ALLOW_HOST_AS=1): it drops
#     the dedicated -B prefix and lets GCC resolve as/ld through the forwarding
#     scripts in its build directory. The stage-1 gcc was configured with
#     --with-as/--with-ld pointing at the self-built binutils, so in this
#     configuration those scripts still run those binutils; the mode exists only
#     to answer "does cc1 generate correct code".
ASLD="${ASLD:-auto}"     # auto|binutils|xcc|host
[ "${ALLOW_HOST_AS:-0}" = 1 ] && ASLD=host      # shorthand for ASLD=host
if [ "$ASLD" = auto ]; then
  if [ -x "$ROOTFS/usr/binutils/bin/as" ] && [ -x "$ROOTFS/usr/binutils/bin/ld" ]; then
    ASLD=binutils
  else
    ASLD=xcc
    warn "self-built binutils not found: rootfs3/usr/binutils/bin/{as,ld}; falling back to xcc's as/ld (this step will fail)"
    warn "run ./3-build-binutils.sh first, then retry"
  fi
fi

if [ "$ASLD" = host ]; then
  warn "ASLD=host (= ALLOW_HOST_AS=1): **using the host binutils** (violates the constraint; diagnostics only, never for products)"
  B_PREFIX=""
elif [ "$ASLD" = binutils ]; then  # real GNU as/ld: no filter/shim wrapper needed (they accept --64 and "-")
  mkdir -p "$work/asld-bin"
  ln -sfn "$ROOTFS/usr/binutils/bin/as" "$work/asld-bin/as"
  ln -sfn "$ROOTFS/usr/binutils/bin/ld" "$work/asld-bin/ld"
  B_PREFIX="-B$work/asld-bin"
  echo "    assembler/linker: self-built binutils $ROOTFS/usr/binutils/bin/{as,ld}"
else
  echo "    assembler/linker: xcc's own $XCCDIR/bin/{as,ld} (⚠️ cannot assemble GCC's dialect; this step will fail)"
  mkdir -p "$work/asld-bin"
  # GCC's driver invokes the assembler as `as --64 -o out.o in.s` and may pass `-`
  # for assembly read from stdin (musl filters CFI through a pipe). The adapter
  # drops the size/CPU options and turns `-` into a temporary file, so xcc's as is
  # always called with a plain source file name.
  cat > "$work/asld-bin/as" <<'AS_EOF'
#!/bin/sh
# Generated by 3-build-musl-gcc.sh: assembler adapter for the GCC driver
# (front end for xcc's as). Lives in <rootfs>/build/musl-gcc/asld-bin/.
rootfs=$(cd "$(dirname "$0")/../../.." && pwd)
xccas="$rootfs/usr/xcc-musl/bin/as"
tmp=
n=$#
i=0
while [ $i -lt $n ]; do
  a=$1; shift
  case "$a" in
    --64|-m64|-march=*|-mtune=*) ;;
    -)
      tmp="${TMPDIR:-/tmp}/xcc-as-stdin.$$"
      cat > "$tmp"
      set -- "$@" "$tmp" ;;
    *) set -- "$@" "$a" ;;
  esac
  i=$((i+1))
done
[ -z "$tmp" ] || trap 'rm -f "$tmp"' EXIT
exec "$xccas" "$@"
AS_EOF
  chmod 755 "$work/asld-bin/as"
  ln -sfn "$XCCDIR/bin/ld" "$work/asld-bin/ld"
  B_PREFIX="-B$work/asld-bin"
fi

# A compliant run (ASLD != host) must remove any DIAGNOSTIC-ONLY marker in the
# build tree and in the install directory, so diagnostic artifacts are not
# mistaken for regular ones.
if [ "$ASLD" != host ]; then
  rm -f "$work/DIAGNOSTIC-ONLY.txt" "$ROOTFS/usr/musl-gcc/DIAGNOSTIC-ONLY.txt"
fi

# Compiler driver: only as/ld live in the **first** -B prefix (nothing else may be
# taken from there), the second is the gcc build directory (which provides
# cc1/cc1plus). ginclude supplies stddef.h under -nostdinc.
cat > "$work/gcc46-cc" <<'WRAP_EOF'
#!/bin/sh
DIR=$(cd "$(dirname "$0")" && pwd)
ROOTFS=$(cd "$DIR/../.." && pwd)
exec "$ROOTFS/build/gcc-4.6.4.1/gcc/xgcc" \
  -B"$DIR/asld-bin" -B"$ROOTFS/build/gcc-4.6.4.1/gcc" \
  -isystem "$ROOTFS/src/gcc-4.6.4.1/gcc/gcc/ginclude" "$@"
WRAP_EOF
if [ "$ASLD" = host ]; then
  # Diagnostic mode: remove asld-bin as well, so GCC falls back to the forwarding
  # scripts in its build directory (`gcc/as`, collect-ld). With --with-as/--with-ld
  # those run the self-built binutils, not the host's; the mode only answers
  # "does cc1 generate correct code".
  rm -rf "$work/asld-bin"
  cat > "$work/gcc46-cc" <<'WRAP_EOF'
#!/bin/sh
DIR=$(cd "$(dirname "$0")" && pwd)
ROOTFS=$(cd "$DIR/../.." && pwd)
exec "$ROOTFS/build/gcc-4.6.4.1/gcc/xgcc" \
  -B"$ROOTFS/build/gcc-4.6.4.1/gcc" \
  -isystem "$ROOTFS/src/gcc-4.6.4.1/gcc/gcc/ginclude" "$@"
WRAP_EOF
fi
chmod 755 "$work/gcc46-cc"
XCC="$work/gcc46-cc"

mkdir -p "$LOGDIR"
exec > >(tee "$LOG") 2>&1

# ---------------------------------------------------------------- 0. Precondition checks
note "[0/7] Checking the inputs and host tools"
[ -f "$SRC_ZIP" ] || die "$SRC_ZIP not found"
[ -x "$GCC" ] || die "$GCC not found (run ./3-build-gcc46-xcc.sh all-gcc first)"
[ -d "$GINCLUDE" ] || die "$GINCLUDE not found"
for f in as ld; do
  [ -x "$XCCDIR/bin/$f" ] || die "missing $XCCDIR/bin/$f (run ./3-build-xcc-musl.sh first)"
done
for t in bash make unzip sed awk grep find sort uniq ar cp mv rm mkdir \
         ln cat head tail wc tr cut xargs stat sha256sum file tee comm; do
  command -v "$t" >/dev/null 2>&1 || die "missing host tool: $t"
done
echo "    source package : $(basename "$SRC_ZIP")"
echo "    sha256 : $(sha256sum "$SRC_ZIP" | cut -d' ' -f1)"
echo "    gcc    : $("$GCC" --version 2>/dev/null | head -1)  ($(sha256sum "$GCC" | cut -c1-16))"
case "$ASLD" in
  binutils) echo "    as/ld  : $ROOTFS/usr/binutils/bin/{as,ld} (self-built)  ($(sha256sum "$ROOTFS/usr/binutils/bin/as" | cut -c1-16))" ;;
  xcc)      echo "    as/ld  : $XCCDIR/bin/{as,ld}  ($(sha256sum "$XCCDIR/bin/as" | cut -c1-16))  ⚠️ xcc's as cannot assemble GCC's dialect; this step will fail" ;;
  host)     echo "    as/ld  : ⚠️ **host binutils** (diagnostic run, violates the constraint)" ;;
esac
echo "    ARCH   : $ARCH"

# ---------------------------------------------------------------- 1. Unpack the source
note "[1/7] Unpacking the musl sources into $tree"
mkdir -p "$work" "$objdir" "$logdir"
if [ "$FORCE_SRC" = 1 ] || [ ! -d "$tree" ]; then
  rm -rf "$tree"
  unzip -q -o "$SRC_ZIP" -d "$work"
fi
[ -d "$tree" ] || die "$tree not found after unpacking"
VERSION="$(cat "$tree/VERSION")"
echo "    musl VERSION = $VERSION"

# ------------------------------------------------- 2. Generate the config headers
note "[2/7] Generating bits/alltypes.h, bits/syscall.h, internal/version.h and the stdarg shim"
mkdir -p "$tree/obj/include/bits" "$tree/obj/src/internal"
( cd "$tree"
  sed -f tools/mkalltypes.sed "arch/$ARCH/bits/alltypes.h.in" include/alltypes.h.in \
    > obj/include/bits/alltypes.h.raw
  # gcc build: use musl's **original generated** alltypes.h. gcc uses musl's own
  # stdarg.h (`#define __NEED_va_list` + `#include <bits/alltypes.h>`), so no
  # va_list bridge is needed; the bridged version makes gcc report
  # `unknown type name '__isoc_va_list'`.
  cp obj/include/bits/alltypes.h.raw obj/include/bits/alltypes.h
  cp "arch/$ARCH/bits/syscall.h.in" obj/include/bits/syscall.h
  sed -n -e 's/__NR_/SYS_/p' < "arch/$ARCH/bits/syscall.h.in" \
      >> obj/include/bits/syscall.h
  printf '#define VERSION "%s"\n' "$VERSION" > obj/src/internal/version.h
)
echo "    alltypes.h    $(wc -l < "$tree/obj/include/bits/alltypes.h") lines (musl's raw version; gcc uses its own stdarg.h)"
echo "    long double   gcc x86_64 = real 80-bit x87, LDBL_* is **not** overridden"
echo "    syscall.h     $(wc -l < "$tree/obj/include/bits/syscall.h") lines"

# ------------------------------------------------- 3. Derive the object list (mirror musl)
note "[3/7] Deriving the object list (mirrors musl's Makefile ALL_OBJS)"
# Ask musl's own Makefile: `make -n ARCH=x86_64` expands ALL_OBJS and prints the
# compile/archive command for each entry; extracting obj/**.o from that gives
# exactly musl's list, including its REPLACED_OBJS de-duplication (e.g.
# src/thread/x86_64/__set_thread_area.o replaces src/thread/__set_thread_area.o).
# `-n` only prints, so no compiler is started.
#
# Source extension: ALL_OBJS entries carry none (crt/crt1, src/string/memset),
# while musl's sources are .c or .s (crt/x86_64/crti comes from crti.s,
# src/string/x86_64/memset from memset.s). So probe .c/.s/.S and take the one
# that exists.
all_list="$work/all-objs.txt"
( cd "$tree" && make -n ARCH="$ARCH" 2>/dev/null || true ) \
  | grep -oE 'obj/[^ ]+\.o' | sed 's|^obj/||' | sort -u > "$all_list"
[ -s "$all_list" ] || die "could not obtain ALL_OBJS from musl's Makefile (make -n failed)"

# Object name -> source file (probe .c/.s/.S)
src_of() {
  local base="$1" ext
  for ext in c s S; do
    if [ -f "$tree/$base.$ext" ]; then printf '%s\n' "$base.$ext"; return 0; fi
  done
  return 1
}

# ldso/ is not part of the static libc.a (dynamic loader / dlopen path, unused for
# static linking); crt/ is compiled separately as crt1.o/crti.o/crtn.o.
# Only ldso and crt are excluded; src/complex is **included by default** because
# gcc supports _Complex. With SKIP_COMPLEX=1 it is dropped as well, together with
# posix_spawn.c (xcc cannot compile either).
if [ "$SKIP_COMPLEX" = 1 ]; then
  grep -v '^ldso/' "$all_list" | grep -v '^crt/' | grep -v '^src/complex/' > "$work/libc-objs.txt"
else
  grep -v '^ldso/' "$all_list" | grep -v '^crt/' > "$work/libc-objs.txt"
fi
excluded_complex=$(grep -c '^src/complex/' "$all_list" || true)
# With SKIP_COMPLEX=1, also exclude posix_spawn.c and list every skipped target in
# skipped.txt (the report shows it verbatim); otherwise those targets would linger
# as failures in the manifest and clutter the report.
: > "$skipped"
if [ "$SKIP_COMPLEX" = 1 ]; then
  {
    echo "# Explicitly skipped targets (this run only needs musl to build and pass the self-test)"
    echo "# 1) xcc does not support _Complex, so src/complex/* is skipped:"
    grep '^src/complex/' "$all_list" | sed 's/^/src\/complex\t/'
    echo "# 2) xcc's type checking is too strict for posix_spawn.c, so it is skipped;"
    echo "#    musl-1's libc.a therefore has no posix_spawn/system family:"
    echo -e "src/process/posix_spawn.c\tposix_spawn unavailable"
  } >> "$skipped"
  # Drop the posix_spawn.c object from the target list
  grep -v '^src/process/posix_spawn\.o$' "$work/libc-objs.txt" > "$work/libc-objs.txt.tmp"
  mv "$work/libc-objs.txt.tmp" "$work/libc-objs.txt"
  echo "    skip list ($skipped):"
  sed 's/^/      /' "$skipped"
fi
: > "$work/crt-objs.txt"
while IFS= read -r rel; do
  src="$(src_of "${rel%.o}")" || die "source file not found: ${rel%.o}{.c,.s,.S}"
  printf '%s\t%s\n' "$src" "$(basename "${rel%.o}")" >> "$work/crt-objs.txt"
done < <(grep '^crt/' "$all_list")

total=$(wc -l < "$work/libc-objs.txt")
crtn=$(wc -l < "$work/crt-objs.txt")
echo "    ALL_OBJS=$(wc -l < "$all_list")  libc targets=$total  crt targets=$crtn"
echo "    excluded src/complex (xcc has no _Complex): $excluded_complex"
echo "    src/thread/__set_thread_area.o excluded: $(grep -c '^src/thread/__set_thread_area\.o$' "$work/libc-objs.txt" || true) (expected 0)"
grep -E '^src/thread/(x86_64/)?__set_thread_area' "$work/libc-objs.txt" | sed 's/^/      /'

# ---------------------------------------------------------------- 4. Compile file by file
note "[4/7] Compiling file by file with gcc46 ($JOBS parallel)"
M="$tree"
# The -I order matches musl's CFLAGS_ALL. With -nostdinc only musl's headers and
# gcc's ginclude are visible; the latter is injected by the gcc46-cc wrapper with
# -isystem.
INCS="-I$M/arch/$ARCH -I$M/arch/generic -I$M/obj/src/internal \
-I$M/src/include -I$M/src/internal -I$M/obj/include -I$M/include"
CFLAGS="$INCS -D_XOPEN_SOURCE=700 -ffreestanding -std=c99 -nostdinc \
-fno-stack-protector -fno-tree-loop-distribute-patterns $OPT"
echo "    CFLAGS: $CFLAGS"

rm -rf "$objdir"; mkdir -p "$objdir" "$logdir"
: > "$manifest"
export XCC M CFLAGS objdir logdir
compile_one() {
  local rel="$1" o err rc=0 src="" ext
  # rel is an object name (src/string/memset.o); the source suffix must be probed
  # separately because musl has both .c and .s sources.
  # Note: a child process cannot see the parent script's functions, so probe inline
  # here (do not call src_of).
  for ext in c s S; do
    if [ -f "$M/${rel%.o}.$ext" ]; then src="${rel%.o}.$ext"; break; fi
  done
  if [ -z "$src" ]; then
    printf 'fail\t%s\t%s\n' "$rel" "source file not found" > "$objdir/${rel%.o}.status.$$"
    return
  fi
  o="$objdir/${rel%.o}.o"
  err="$logdir/$(printf '%s' "$rel" | tr '/' '_').err"
  mkdir -p "$(dirname "$o")"
  "$XCC" -c $CFLAGS -o "$o" "$M/$src" > "$err" 2>&1 || rc=$?
  if [ "$rc" = 0 ]; then
    printf 'ok\t%s\t%s\n' "$rel" "$o" > "$objdir/${rel%.o}.status.$$"
  else
    printf 'fail\t%s\t%s\n' "$rel" "$(head -1 "$err" 2>/dev/null || true)" \
      > "$objdir/${rel%.o}.status.$$"
  fi
}
export -f compile_one
xargs -r -P "$JOBS" -I{} bash -c 'compile_one "$@"' _ {} < "$work/libc-objs.txt"

find "$objdir" -name '*.status.*' -print0 | xargs -0 -r cat >> "$manifest"
find "$objdir" -name '*.status.*' -delete
sort -o "$manifest" -k2,2 "$manifest"

# ---- 4b. Fallback pass: replace an arch .s that fails to assemble with the generic C version ---
# musl's REPLACED_OBJS drops the generic C version of an object whenever an
# arch-specific version exists (the arch version is trusted). When xcc's as cannot
# assemble those x86_64 .s files (x87/SSE instructions), memset/memcpy/memmove/
# setjmp and friends end up with no implementation at all. The generic C versions
# are right there in the source tree (they are what architectures without their own
# assembly use), so compile them in and replace the failed manifest entries.
#
# Example: src/string/x86_64/memset.o fails -> generic src/string/memset.c
fallback_pairs="$work/fallback-pairs.txt"
: > "$fallback_pairs"
awk -F'\t' '$1=="fail" && $2 ~ /\.o$/ {print $2}' "$manifest" | while IFS= read -r rel; do
  base="${rel%.o}"                         # src/string/x86_64/memset
  sub="$(printf '%s' "$base" | sed -E 's|^(src/[^/]+)/[^/]+/|\1/|')"
  [ "$sub" != "$base" ] || continue        # not in an arch subdirectory: nothing to fall back to
  # Some generic .c files are **empty** (src/setjmp/longjmp.c and
  # src/signal/sigsetjmp.c are placeholders for architectures that need no
  # implementation of their own). An empty file produces no symbols, so using it as
  # a substitute would make the symbol vanish entirely (longjmp then fails to link);
  # skip it and leave the symbol to the hand-written assembly pass ([4c]).
  if [ -s "$tree/$sub.c" ]; then
    printf '%s\t%s\n' "$sub.c" "$base.o" >> "$fallback_pairs"
  fi
done
if [ -s "$fallback_pairs" ]; then
  echo "    fallback pass (generic C replacing the arch assembly that fails):"
  : > "$work/fallback-manifest.tsv"
  while IFS=$'\t' read -r fsrc fobj; do
    [ -n "$fsrc" ] || continue
    fo="$objdir/${fobj%.o}.o"
    mkdir -p "$(dirname "$fo")"
    ferr="$logdir/fallback_$(printf '%s' "$fobj" | tr '/' '_').err"
    if "$XCC" -c $CFLAGS -o "$fo" "$tree/$fsrc" > "$ferr" 2>&1; then
      printf 'ok\t%s\t%s\n' "$fobj" "$fo" >> "$work/fallback-manifest.tsv"
      printf '      %-40s <- %s\n' "$fobj" "$fsrc"
    else
      printf 'fail\t%s\t%s\n' "$fobj" "$(head -1 "$ferr")" >> "$work/fallback-manifest.tsv"
      printf '      %-40s <- %s  (still failed)\n' "$fobj" "$fsrc"
    fi
  done < "$fallback_pairs"
  # Replace the status of the affected targets with the fallback results (keyed on
  # the target name in field 2).
  fst=; frel=; fmsg=
  awk -F'\t' 'NR==FNR{new[$2]=$0; next} {if ($2 in new) print new[$2]; else print}' \
      "$work/fallback-manifest.tsv" "$manifest" > "$manifest.tmp"
  mv "$manifest.tmp" "$manifest"
  sort -o "$manifest" -k2,2 "$manifest"
fi

ok=$(grep -c '^ok' "$manifest" || true)
bad=$(grep -c '^fail' "$manifest" || true)
echo "    compiled ok $ok / failed $bad (total $total)"
if [ "$bad" != 0 ]; then
  echo "    failed files (first diagnostic):"
  awk -F'\t' '$1=="fail"{printf "      %-52s %s\n", $2, $3}' "$manifest"
fi

# ---- 4c. Hand-written assembly for the original .s that xcc's assembler rejects --------
# musl's src/setjmp/x86_64/{longjmp,setjmp}.s and src/signal/x86_64/sigsetjmp.s
# contain forms xcc's assembler rejects (longjmp uses `adc`, sigsetjmp uses
# `popq 64(%rdi)' / `pushq 64(%rbx)' / `call setjmp@PLT'), and their generic C
# versions are empty files. The files below rewrite those routines using only
# instructions xcc's assembler supports; this pass always runs and replaces the
# manifest entries for the two objects, also when binutils' as assembled the
# originals. (setjmp itself assembles fine and is not touched.)
handasm="$COMPAT/asm"
mkdir -p "$handasm"
cat > "$handasm/longjmp.s" <<'LONGJMP_EOF'
/* Rewrite of musl's src/setjmp/x86_64/longjmp.s.
   xcc's assembler rejects the original `adc' pair, so the value selection is done
   with test/jne/mov instead. It returns `val ? val : 1' (0 maps to 1). */
.text
.global _longjmp
.global longjmp
.type _longjmp,@function
.type longjmp,@function
_longjmp:
longjmp:
	mov %esi,%eax
	test %esi,%esi
	jne .Lval_done
	mov $1,%eax
.Lval_done:
	mov (%rdi),%rbx
	mov 8(%rdi),%rbp
	mov 16(%rdi),%r12
	mov 24(%rdi),%r13
	mov 32(%rdi),%r14
	mov 40(%rdi),%r15
	mov 48(%rdi),%rsp
	jmp *56(%rdi)
LONGJMP_EOF
cat > "$handasm/sigsetjmp.s" <<'SIGSETJMP_EOF'
/* Rewrite of musl's src/signal/x86_64/sigsetjmp.s.
   The original uses `popq 64(%rdi)', `pushq 64(%rbx)' and `call setjmp@PLT', none
   of which xcc's assembler accepts. This version reserves one stack slot
   (sub $8,%rsp), keeps the caller's return address on the stack, saves the caller's
   %rbx in __ss[1] (offset 80), calls `setjmp` directly and tail-jumps to
   __sigsetjmp_tail (which saves/restores the signal mask in __ss at offset 72; on
   x86_64 that is 8 bytes and does not reach offset 80). */
.text
.global sigsetjmp
.global __sigsetjmp
.type sigsetjmp,@function
.type __sigsetjmp,@function
sigsetjmp:
__sigsetjmp:
	test %esi,%esi
	jz .Lno_savemask

	sub $8,%rsp
	mov 8(%rsp),%rax          /* caller's return address */
	mov %rax,64(%rdi)         /* save it in __fl */
	mov %rbx,80(%rdi)         /* save caller's rbx in __ss[1] */
	mov %rdi,%rbx
	call setjmp
	mov %rbx,%rdi
	mov %eax,%esi
	mov 64(%rbx),%rax         /* restore the caller's return address */
	mov %rax,8(%rsp)          /* (siglongjmp reused this stack slot) */
	mov 80(%rbx),%rbx         /* restore caller's rbx */
	add $8,%rsp
	jmp __sigsetjmp_tail

.Lno_savemask:
	jmp setjmp
SIGSETJMP_EOF
: > "$work/handasm-manifest.tsv"
handasm_one() {
  local name="$1" dir="$2" obj rel
  obj="$objdir/src/$dir/x86_64/$name.o"
  rel="src/$dir/x86_64/$name.o"
  mkdir -p "$(dirname "$obj")"
  "$XCC" -c -o "$obj" "$handasm/$name.s" || die "hand-written assembly failed: $handasm/$name.s"
  printf 'ok\t%s\t%s\n' "$rel" "$obj" >> "$work/handasm-manifest.tsv"
}
handasm_one longjmp setjmp
handasm_one sigsetjmp signal
# Merge into the manifest by name; these entries replace the earlier failed ones.
hst=; hrel=; ho=
awk -F'\t' 'NR==FNR{new[$2]=$0; next} {if ($2 in new) print new[$2]; else print}' \
    "$work/handasm-manifest.tsv" "$manifest" > "$manifest.tmp"
mv "$manifest.tmp" "$manifest"
sort -o "$manifest" -k2,2 "$manifest"
echo "    supplied by hand-written assembly: $(cut -f2 "$work/handasm-manifest.tsv" | tr '\n' ' ')"


note "[5/7] Installing headers and archiving libc.a into ${OUT_INC%/include} and ${OUT_LIB}"
mkdir -p "$OUT_INC/bits" "$OUT_LIB"

# 5.1 Public headers: include/ + arch/generic/bits + arch/$ARCH/bits (the last wins
# on clashing names).
# Only **musl's own** headers are replaced; OUT_INC is not wiped wholesale.
# OUT_INC here is rootfs3/usr/musl-gcc/include, a standalone snapshot of musl;
# third-party headers (gmp.h/mpfr.h/...) go to rootfs3/usr/include, so the two do
# not collide. Keeping "replace only our own files" means a re-run cannot delete
# unrelated content in the same directory (a blanket `rm -rf usr/include` would
# wipe gmp.h and friends).
mkdir -p "$OUT_INC" "$OUT_INC/bits"
rm -rf "$OUT_INC/bits"
while IFS= read -r h; do
  rm -f "$OUT_INC/${h#$M/include/}"
done < <(find "$M/include" -maxdepth 1 -type f)
while IFS= read -r d; do
  rm -rf "$OUT_INC/${d#$M/include/}"
done < <(find "$M/include" -mindepth 1 -maxdepth 1 -type d)
cp -a "$M/include/." "$OUT_INC/"
cp -a "$M/arch/generic/bits/." "$OUT_INC/bits/"
cp -a "$M/arch/$ARCH/bits/." "$OUT_INC/bits/"
# A bulk `cp -a` occasionally misses files (once only 65 of 91 top-level headers
# arrived), so compare and re-copy explicitly.
while IFS= read -r h; do
  rel="${h#$M/include/}"
  cmp -s "$h" "$OUT_INC/$rel" || cp -f "$h" "$OUT_INC/$rel"
done < <(find "$M/include" -type f)
src_n=$(find "$M/include" -type f | wc -l)
dst_n=$(find "$OUT_INC" -type f -name '*.h' -o -type f -name '*.in' | wc -l)
[ "$dst_n" -ge "$src_n" ] || die "public header install incomplete (source $src_n, installed $dst_n)"
rm -f "$OUT_INC/bits/alltypes.h.in" "$OUT_INC/bits/syscall.h.in"
cp -f "$M/obj/include/bits/alltypes.h" "$OUT_INC/bits/alltypes.h"
cp -f "$M/obj/include/bits/syscall.h"  "$OUT_INC/bits/syscall.h"

echo "    include/: $(find "$OUT_INC" -type f | wc -l) headers"

# 5.2 crt objects: crt1.o (static entry point), rcrt1.o (static PIE), Scrt1.o (PIE)
#     and crti.o/crtn.o (init/fini sections). They are not in the step-4 libc list,
#     so compile them here with the same CFLAGS (arch .s files go through xcc's as
#     when that assembler is in use).
while IFS=$'\t' read -r rel base; do
  [ -n "$rel" ] || continue
  mkdir -p "$work/obj/crt"          # obj/ was wiped and recreated at the start of step 4
  errf="$logdir/crt_$(printf '%s' "$base" | tr '/' '_').err"
  rc=0
  "$XCC" -c $CFLAGS -DCRT -o "$work/obj/crt/$base.o" "$M/$rel" > "$errf" 2>&1 || rc=$?
  if [ "$rc" != 0 ] || [ ! -f "$work/obj/crt/$base.o" ]; then
    echo "    compiling crt/$rel failed (rc=$rc)"
    sed 's/^/      /' "$errf" | head -5
    die "crt target compile failed: $rel"
  fi
  cp -f "$work/obj/crt/$base.o" "$OUT_LIB/$base.o"
  printf '      %s.o  <- %s\n' "$base" "$rel"
done < "$work/crt-objs.txt"
for c in crt1.o crti.o crtn.o; do
  [ -f "$OUT_LIB/$c" ] || die "missing $OUT_LIB/$c"
done
ls "$OUT_LIB"/*.o | sed 's|.*/|      |'

if [ "$NO_ARCHIVE" != 1 ]; then
  # 5.3 libc.a: archive with flat member names (`/` -> `+`), so every member has a
  # plain unique name instead of a path that some ar/ld implementations mishandle.
  stage="$work/ar-stage"
  rm -rf "$stage"; mkdir -p "$stage"
  : > "$work/ar-list.txt"
  # Clear the loop variables: bash's `read` reuses the previous value for fields a
  # line does not provide, so a stale name could leak into the archive list.
  mst=; mrel=; mo=;
  while IFS=$'\t' read -r mst mrel mo; do
    [ "$mst" = ok ] || continue
    flat="$(printf '%s' "${mrel%.o}" | tr '/' '+').o"
    ln -f "$mo" "$stage/$flat" 2>/dev/null || cp -f "$mo" "$stage/$flat"
    printf '%s\n' "$flat" >> "$work/ar-list.txt"
  done < "$manifest"
  rm -f "$OUT_LIB/libc.a"
  ( cd "$stage" && xargs -r ar rcs "$OUT_LIB/libc.a" < "$work/ar-list.txt" )
  echo "    libc.a: $(stat -c%s "$OUT_LIB/libc.a") bytes, $(ar t "$OUT_LIB/libc.a" | wc -l) members, sha256 $(sha256sum "$OUT_LIB/libc.a" | cut -c1-16)"
  # Spot check: x86_64's __set_thread_area must come from the .s, not a generic fallback
  echo "    member containing __set_thread_area: $(ar t "$OUT_LIB/libc.a" | grep -i set_thread_area | tr '\n' ' ')"
fi

# 5.3b Placeholder libm.a: **musl merges all math functions into libc.a**, so the
# sysroot has no separate libm. GCC's build system still writes `-lm` in places
# (build/genautomata gets `BUILD_LIBS += -lm`), and xcc's ld then fails with
# "m: library not found", which kills the target build. So ship a **valid**
# archive: xcc's ld rejects an 8-byte empty archive (with only "!<arch>\n" it
# reports "Global header" and fails), hence a placeholder symbol that is never
# referenced. The math symbols themselves are resolved by the `-lc` (libc.a) that
# follows on the link line.
note "[5.3/7] Generating the placeholder libm.a (musl has no separate libm, but GCC writes -lm)"
mkdir -p "$work"
cat > "$work/libm_stub.c" <<'EOF'
/* Placeholder so that `-lm` has a valid archive to open.
   musl has no separate libm: every math function lives in libc.a, and the
   math symbols are resolved by the `-lc` that follows on the command line. */
void __xcc_libm_placeholder(void) {}
EOF
"$XCC" -c -o "$work/libm_stub.o" "$work/libm_stub.c" \
  || die "compiling the libm placeholder object failed"
rm -f "$OUT_LIB/libm.a"
ar rcs "$OUT_LIB/libm.a" "$work/libm_stub.o" || die "generating libm.a failed"
echo "    libm.a: $(stat -c%s "$OUT_LIB/libm.a") bytes (placeholder; math symbols come from libc.a)"

# ---------------------------------------------------------------- 5.4 Compare with musl-1
# This step rebuilds the same musl with a different compiler (xcc -> gcc46), so the
# comparison is a result in itself: structure and size differ (the hashes **must**
# differ, the compilers differ; and this build does **not** skip complex/posix_spawn,
# so the member count should go up).
MUSL_XCC="$ROOTFS/usr/musl-1"
note "[5.4/7] Comparing with musl-1 (the xcc-built one)"
if [ -f "$MUSL_XCC/lib/libc.a" ]; then
  mc_x=$(ar t "$MUSL_XCC/lib/libc.a" | wc -l); mc_g=$(ar t "$OUT_LIB/libc.a" | wc -l)
  echo "    musl-1(xcc)  : $(stat -c%s "$MUSL_XCC/lib/libc.a") bytes / $mc_x members / $(sha256sum "$MUSL_XCC/lib/libc.a" | cut -c1-16)"
  echo "    musl-gcc     : $(stat -c%s "$OUT_LIB/libc.a") bytes / $mc_g members / $(sha256sum "$OUT_LIB/libc.a" | cut -c1-16)"
  echo "    member count difference: $((mc_g - mc_x)) (complex/posix_spawn are no longer skipped in this build)"
  for c in crt1.o crti.o crtn.o; do
    printf '    %-8s xcc=%s gcc=%s bytes\n' "$c" \
      "$(stat -c%s "$MUSL_XCC/lib/$c" 2>/dev/null || echo n/a)" \
      "$(stat -c%s "$OUT_LIB/$c" 2>/dev/null || echo n/a)"
  done
else
  warn "$MUSL_XCC/lib/libc.a not found, skipping the comparison"
fi

# ------------------------------------------------- 5.5 Land the final sysroot (optional)
# By default the global sysroot is left alone: ./3-build-musl-xcc.sh [5.5] points
# rootfs3/usr/{include,lib} at musl-1 (the libc the xcc chain targets).
# MATERIALIZE_SYSROOT=1 additionally links this snapshot's top-level entries into
# usr/{include,lib} as **relative symlinks** (idempotent: entries that already exist
# are kept, so to repoint a landed sysroot at musl-gcc run
# ./3-adjust-rootfs-current.sh).
# musl-gcc's bits/alltypes.h is already musl's original generated version (gcc uses
# musl's own stdarg.h and needs no va_list bridge; the bridged copy stays in
# usr/xcc-musl/shim/ for the xcc chain), so nothing has to be split here.
if [ "${MATERIALIZE_SYSROOT:-0}" = 1 ]; then
  note "[5.5/7] Landing the final sysroot: $ROOTFS/usr/{include,lib} pointing at musl-gcc"
  mkdir -p "$ROOTFS/usr/include" "$ROOTFS/usr/lib"

  n_inc=0; n_lib=0
  # Always link with **relative** paths: rootfs3 must work as a root filesystem
  # (bwrap/chroot), and absolute links would point at non-existent host paths after
  # the root change (observed: `Cannot open file: <stdio.h>` in a bare root).
  real_inc="$(cd "$OUT_INC" && pwd)"; real_lib="$(cd "$OUT_LIB" && pwd)"
  for e in "$OUT_INC"/*; do
    b="$(basename "$e")"
    if [ ! -e "$ROOTFS/usr/include/$b" ]; then
      ln -sfn "$(realpath --relative-to="$ROOTFS/usr/include" "$real_inc/$b")" \
              "$ROOTFS/usr/include/$b"; n_inc=$((n_inc+1))
    fi
  done
  for e in "$OUT_LIB"/*; do
    b="$(basename "$e")"
    if [ ! -e "$ROOTFS/usr/lib/$b" ]; then
      ln -sfn "$(realpath --relative-to="$ROOTFS/usr/lib" "$real_lib/$b")" \
              "$ROOTFS/usr/lib/$b"; n_lib=$((n_lib+1))
    fi
  done
  echo "    usr/include: added $n_inc links ($(find "$ROOTFS/usr/include" -maxdepth 1 | wc -l) top-level entries in total)"
  echo "    usr/lib    : added $n_lib links"
  [ -f "$ROOTFS/usr/lib/libc.a" ] || die "no libc.a in the sysroot"
  [ -f "$ROOTFS/usr/include/stdio.h" ] || die "no stdio.h in the sysroot"
  # Entry links: usr/bin/{include,lib} point at this musl too
  ln -sfn ../musl-gcc/include "$ENTRYDIR/include" 2>/dev/null || true
  ln -sfn ../musl-gcc/lib     "$ENTRYDIR/lib"     2>/dev/null || true
fi

# ---------------------------------------------------------------- 6. Report
note "[6/7] Generating the report"
{
  echo "# musl $VERSION / **gcc46** build report (3-build-musl-gcc.sh)"
  echo
  echo "generated : $(date -Iseconds)"
  echo "source    : musl-1.2.6.zip sha256=$(sha256sum "$SRC_ZIP" | cut -d' ' -f1)"
  echo "compiler  : $("$GCC" --version 2>/dev/null | head -1)"
  echo "  xgcc sha256=$(sha256sum "$GCC" | cut -d' ' -f1)"
  echo "  cc1  sha256=$(sha256sum "$GCCDIR/cc1" | cut -d' ' -f1)"
  echo "  (assembly/linking is still done by xcc's as/ld)"
  echo "  as   sha256=$(sha256sum "$XCCDIR/bin/as"  | cut -d' ' -f1)"
  echo "  ld   sha256=$(sha256sum "$XCCDIR/bin/ld"  | cut -d' ' -f1)"
  echo
  echo "## Compile statistics"
  echo
  echo "| item | count |"
  echo "|---|---|"
  echo "| libc objects (excluding crt/ldso) | $total |"
  echo "| of which src/complex (**not** skipped in this build) | $excluded_complex |"
  echo "| compiled ok | $ok |"
  echo "| compiled failed | $bad |"
  if [ -s "$skipped" ]; then
    echo
    echo "## Explicitly skipped targets (intentional reduction)"
    echo
    echo '```'
    cat "$skipped"
    echo '```'
  fi
  if [ "$bad" != 0 ]; then
    echo
    echo "## Failed files"
    echo
    echo "| source file | first diagnostic |"
    echo "|---|---|"
    awk -F'\t' '$1=="fail"{printf "| %s | %s |\n", $2, $3}' "$manifest"
  fi
} > "$work/SUMMARY.txt"
echo "    $work/SUMMARY.txt"

# ---------------------------------------------------------------- 7. Self-test
if [ "$SELFTEST" = 1 ]; then
  note "[7/7] Self-test: compile/link/run with gcc46 + the musl-gcc just installed"
  st="$work/selftest"; mkdir -p "$st"
  cat > "$st/t.c" <<'EOF'
/* The three classic paths (TLS/malloc/floating-point printf) plus this build's
   extra capabilities: _Complex and a true 80-bit long double. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <complex.h>
#include <math.h>
int main(void) {
  char *p = malloc(80000);
  void *q = calloc(10000, 8);
  if (!p || !q) return 1;
  memset(p, 0, 80000);
  strcpy(p, "musl-gcc");
  double complex z = 3.0 + 4.0 * I;
  double m = cabs(z);
  long double ld = 1.5L;
  printf("%s %zu %.3f %d %d %.1f %d\n", p, strlen(p), 1.0/3.0, (int)sizeof(void*),
         (int)sizeof(long double), m, (int)(ld * 2));
  free(p); free(q);
  return 0;
}
EOF
  # The self-test links against the musl-gcc that was just built and passes its
  # headers and crt/library explicitly (the gcc46-cc wrapper only adds -B and
  # -isystem <ginclude>); -nostdlib keeps GCC from looking for a libgcc that does
  # not exist yet.
  incs=(-I"$OUT_INC" -isystem "$GINCLUDE")
  "$XCC" "${incs[@]}" -c -o "$st/t.o" "$st/t.c" || die "self-test compile failed"
  if "$XCC" "${incs[@]}" -nostdlib -o "$st/t" "$st/t.o" \
       "$OUT_LIB/crt1.o" "$OUT_LIB/crti.o" "$OUT_LIB/crtn.o" -L"$OUT_LIB" -lc; then
    out="$("$st/t")" || die "self-test program run failed (exit code $?)"
    echo "    $out"
    echo "$out" | grep -q '^musl-gcc 8 0.333 8 16 5.0 3$' \
      || die "unexpected self-test output (expected: musl-gcc 8 0.333 8 16 5.0 3)"
    echo "    $(file -b "$st/t")"
    echo "    ✅ _Complex (cabs=5.0) and long double (sizeof=16, 1.5*2=3) both work"
  else
    die "self-test link failed"
  fi
fi

note "Done"
echo "  headers : $OUT_INC"
echo "  library : $OUT_LIB/libc.a + crt1.o crti.o crtn.o"
echo "  report  : $work/SUMMARY.txt"
echo "  log     : $LOG"

# ---- Record status (common.sh's record writes results/3-STATE.env) ----
record MUSL_GCC_ASLD "$ASLD"
record MUSL_GCC_LIBC "$OUT_LIB/libc.a"
if [ -f "$OUT_LIB/libc.a" ]; then
  record MUSL_GCC_LIBC_SIZE "$(stat -c%s "$OUT_LIB/libc.a")"
  record MUSL_GCC_LIBC_SHA256 "$(sha256sum "$OUT_LIB/libc.a" | cut -c1-16)"
  record MUSL_GCC_LIBC_MEMBERS "$(ar t "$OUT_LIB/libc.a" 2>/dev/null | wc -l)"
fi
