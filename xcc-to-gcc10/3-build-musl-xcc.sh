#!/bin/bash
#
# 3-build-musl-xcc.sh — build musl 1.2.6 with **xcc-xcclib** (the second-generation xcc:
#   static, no glibc, linked against the libc bundled with xcc) and install it into
#   rootfs3/usr/musl-1/{include,lib}; by default the result is also landed as the
#   **global sysroot** rootfs3/usr/{include,lib} (see [5.5]).
#
# Chain position: ./3-build-xcc-boot.sh produces xcc-xcclib, this script turns it into
# musl-1, and ./3-build-xcc-musl.sh then builds xcc-musl (the third generation) against
# this libc. musl-1 is therefore the **target libc of the xcc chain** and its final
# sysroot.
#
# Log: results/3-build-musl-xcc.log.
#
# ⚠️ Afterwards, ./3-adjust-rootfs-current.sh repoints the global sysroot from musl-1 to
#    `musl-gcc` (the musl rebuilt in full by the GCC 4.6 route, 1349 members) — that is
#    the target libc of the GCC route; musl-1 only serves the xcc chain.
#
# Why the object list is reproduced from musl's Makefile instead of guessed:
#
#   * The list cannot be "every *.c minus a few arch directories"; it has to be musl's
#     own ALL_OBJS:
#         BASE_SRCS     = *.c in src/*/  src/malloc/mallocng/  crt/  ldso/
#         ARCH_SRCS     = $ARCH/*.[csS] below those directories
#         REPLACED_OBJS = ARCH_SRCS with /$ARCH/ stripped
#         ALL_OBJS      = BASE_SRCS + ARCH_SRCS - REPLACED_OBJS
#     This matters because musl replaces a generic C file with an arch file of the same
#     name (REPLACED_OBJS) rather than excluding directories. A list that merely excluded
#     *other* arch directories still contains x86_64 (the arch being built), so
#     src/thread/__set_thread_area.c (the generic fallback, which returns -ENOSYS on
#     x86_64) and src/thread/x86_64/__set_thread_area.s would both be compiled and
#     archived; the linker picks the generic one first, so __init_tp() always fails and
#     __init_tls() calls a_crash() (`hlt`): the program SIGSEGVs before main as soon as
#     it first touches TLS or a large malloc. Applying musl's own rule drops the generic
#     version and the x86_64 .s takes effect.
#
#   * Archive members use flattened names (src+string+strlen.o): a path inside an ar
#     member name can come back truncated, and the linker only looks at symbols, never at
#     member names.
#
#   * va_list bridge (solved by the shim generated here): xcc declares its
#     `__builtin_va_list` only in its own stdarg.h, while musl's alltypes.h.in defines
#     va_list with `TYPEDEF __builtin_va_list va_list;`. So the generated
#     musl-1/include/bits/alltypes.h starts with `#include <stdarg.h>` — resolving to
#     usr/xcc-musl/shim/stdarg.h, a copy of xcc's stdarg.h plus the __isoc_va_list
#     alias — and its two typedefs are replaced by plain __DEFINED_* flags. The mutual
#     inclusion of stdarg.h and alltypes.h terminates because the file included first is
#     processed to completion before the second is entered, and because alltypes.h then
#     sees __DEFINED_va_list already set (xcc's `#pragma once` does not stop this
#     recursion, so that guard — not the pragma — is what ends it).
#     va_start/va_arg/va_end/va_copy also come from that stdarg.h.
#
#   * **Deliberately skipped** (this round only needs musl to compile and self-test):
#       - all 68 files of src/complex/: xcc has no `_Complex` support. libc.a therefore
#         carries no complex math functions (cabs/cexp/... live in src/complex/*.c).
#         **This is a deliberate reduction** and does not affect linking or running C
#         programs; a later stage that needs complex support would first have to teach
#         xcc `_Complex` (or patch it). The skip list is built in [3/7], written to
#         skipped.txt and quoted in SUMMARY.txt by [6/7].
#       - src/process/posix_spawn.c (1 file): xcc's type checking is too strict for it, so
#         posix_spawn/system are unavailable in musl-1 (recorded in the report).
#       - ldso (the dynamic loader): not needed for static linking.
#
# Output:
#   rootfs3/usr/musl-1/include/     musl public headers (incl. generated bits/alltypes.h, bits/syscall.h)
#   rootfs3/usr/musl-1/lib/libc.a   musl static library
#   rootfs3/usr/musl-1/lib/{crt1.o,crti.o,crtn.o}   entry / init / fini objects
#   rootfs3/usr/musl-1/lib/{Scrt1.o,rcrt1.o}        PIE and static-PIE start objects (built too, unused here)
#   rootfs3/usr/musl-1/lib/libm.a                   placeholder archive (musl has no separate libm, but GCC writes -lm)
#   rootfs3/usr/xcc-musl/shim/{stdarg.h,bits/alltypes.h}  va_list bridge (picked up by the wrapper's -I)
#   rootfs3/usr/{include,lib}/                      **global sysroot**: relative links into musl-1 ([5.5])
#   rootfs3/build/musl-1/musl-1.2.6/                unpacked source tree
#   rootfs3/build/musl-1/{obj,manifest.tsv,SUMMARY.txt}
#   results/3-build-musl-xcc.log                      full log
#
# Usage:
#   ./3-build-musl-xcc.sh                # unpack + headers + compile + archive + report + land sysroot
#   JOBS=8 ./3-build-musl-xcc.sh         # parallelism (default nproc)
#   FORCE_SRC=1 ./3-build-musl-xcc.sh    # unpack again
#   NO_ARCHIVE=1 ./3-build-musl-xcc.sh   # compile only, do not build libc.a
#   SELFTEST=1 ./3-build-musl-xcc.sh     # after archiving, link and run a self-test program
#   LAND_SYSROOT=0 ./3-build-musl-xcc.sh # do not land the global sysroot (musl-1 snapshot only)
#   SKIP_COMPLEX=0 ./3-build-musl-xcc.sh # no skip list and keep src/process/posix_spawn.o ([3/7])
#
# Note: this script neither reads nor writes patches-3/. The va_list bridge is solved by
#       the stdarg.h shim generated here; the only source rewrites are the generated
#       bits/alltypes.h and the LDBL_* block appended to arch/$ARCH/bits/float.h.
#
# ---------------------------------------------------------------------------
# Host tools used — full disclosure: apart from the xcc-xcclib toolchain in rootfs3, this
# script only calls the host binaries listed below; all of them unpack, edit text, archive
# or drive, none of them is a compiler:
#
#   /usr/bin/bash       runs this script and the parallel compile jobs
#   /usr/bin/make       only `make -n ARCH=x86_64`, so musl's own Makefile prints the
#                       authoritative object list (nothing is compiled)
#   /usr/bin/unzip      unpacks musl-1.2.6.zip
#   /usr/bin/sed        generates bits/alltypes.h (mkalltypes.sed) and edits float.h
#   /usr/bin/grep sort  list arithmetic and totals (uniq and comm are only probed for
#                       existence in [0/7], never called)
#   /usr/bin/awk(gawk)  writes the manifest and report rows
#   /usr/bin/find cp mv rm mkdir ln dirname basename cat head tail wc tr cut xargs
#                       file plumbing (realpath is used only in [5.5], for relative links)
#   /usr/bin/cmp        checks the installed headers against the source tree
#   /usr/bin/ar         archives the .o files xcc produced into libc.a (GNU binutils ar)
#   /usr/bin/stat sha256sum file    record sizes, hashes and file types
#   /usr/bin/date nproc report timestamp; default job count
#   /usr/bin/tee        mirrors the whole run into results/3-build-musl-xcc.log
#
# Never used: host gcc/cc/clang/ld/as/cpp, host /usr/include and /usr/lib.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
ROOTFS="$ROOT/rootfs3"
XCCDIR="$ROOTFS/usr/xcc-xcclib"
XCC="$XCCDIR/bin/xcc"
SRC_ZIP="$ROOT/musl-1.2.6.zip"
XCCSRC="$ROOT/xcc"                      # xcc source tree (only its bundled stdarg.h is used)
OUT_INC="$ROOTFS/usr/musl-1/include"
OUT_LIB="$ROOTFS/usr/musl-1/lib"
COMPAT="$ROOTFS/usr/xcc-musl"                 # root of the xcc-musl compatibility layer
COMPAT_INC="$COMPAT/shim"                     # -I shim: stdarg.h here, bridged bits/alltypes.h added by [5.5]
LOGDIR="$ROOT/results"
LOG="$LOGDIR/3-build-musl-xcc.log"

ARCH="${ARCH:-x86_64}"
JOBS="${JOBS:-$(nproc)}"
FORCE_SRC="${FORCE_SRC:-0}"
NO_ARCHIVE="${NO_ARCHIVE:-0}"
SELFTEST="${SELFTEST:-0}"
SKIP_COMPLEX="${SKIP_COMPLEX:-1}"             # 1 = drop posix_spawn.o and write the skip list; src/complex/* is excluded either way ([3/7])

work="$ROOTFS/build/musl-1"
tree="$work/musl-1.2.6"
objdir="$work/obj"
logdir="$work/log"
manifest="$work/manifest.tsv"
skipped="$work/skipped.txt"                    # explicitly skipped targets (reported in SUMMARY.txt)

die()  { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }
note() { printf '\n==> %s\n' "$*"; }

mkdir -p "$LOGDIR"
exec > >(tee "$LOG") 2>&1

# ---------------------------------------------------------------- 0. Precondition checks
note "[0/7] Checking the inputs and host tools"
[ -f "$SRC_ZIP" ] || die "$SRC_ZIP not found"
[ -d "$XCCSRC/include" ] || die "3- source tree not found: $XCCSRC"
for f in xcc cc1 cpp as ld; do
  [ -x "$XCCDIR/bin/$f" ] || die "missing $XCCDIR/bin/$f (run ./3-build-xcc-boot.sh first)"
done
for t in bash make unzip sed awk grep find sort uniq ar cp mv rm mkdir \
         ln cat head tail wc tr cut xargs stat sha256sum file tee comm; do
  command -v "$t" >/dev/null 2>&1 || die "missing host tool: $t"
done
echo "    source : $(basename "$SRC_ZIP")"
echo "    sha256 : $(sha256sum "$SRC_ZIP" | cut -d' ' -f1)"
echo "    xcc    : $("$XCC" -v | tr '\n' ' ')  ($(sha256sum "$XCC" | cut -c1-16))"
echo "    ARCH   : $ARCH"

# ------------------------------------------------------------------ 1. Unpack the source
note "[1/7] Unpacking the musl sources into $tree"
mkdir -p "$work" "$objdir" "$logdir"
if [ "$FORCE_SRC" = 1 ] || [ ! -d "$tree" ]; then
  rm -rf "$tree"
  unzip -q -o "$SRC_ZIP" -d "$work"
fi
[ -d "$tree" ] || die "$tree not found after unpacking"
VERSION="$(cat "$tree/VERSION")"
echo "    musl VERSION = $VERSION"

# ------------------------------------------------- 2. Generate config headers + va_list shim
note "[2/7] Generating bits/alltypes.h, bits/syscall.h, internal/version.h and the stdarg shim"
mkdir -p "$tree/obj/include/bits" "$tree/obj/src/internal" "$COMPAT_INC"
( cd "$tree"
  sed -f tools/mkalltypes.sed "arch/$ARCH/bits/alltypes.h.in" include/alltypes.h.in \
    > obj/include/bits/alltypes.h.raw
  # va_list bridge: pull in the shim's stdarg.h on the first line and turn the two
  # builtin_va_list typedefs into plain __DEFINED_* markers (the types come from
  # stdarg.h, see the file header). Only this generated header is rewritten.
  { printf '/* 3-build-musl-xcc.sh: va_list/__isoc_va_list come from <stdarg.h> (the xcc-musl shim) */\n'
    printf '#include <stdarg.h>\n'
    cat obj/include/bits/alltypes.h.raw
  } > obj/include/bits/alltypes.h
  sed -i \
    -e 's|^typedef __builtin_va_list va_list;$|#define __DEFINED_va_list 1|' \
    -e 's|^typedef __builtin_va_list __isoc_va_list;$|#define __DEFINED___isoc_va_list 1|' \
    obj/include/bits/alltypes.h
  cp "arch/$ARCH/bits/syscall.h.in" obj/include/bits/syscall.h
  sed -n -e 's/__NR_/SYS_/p' < "arch/$ARCH/bits/syscall.h.in" \
      >> obj/include/bits/syscall.h
  printf '#define VERSION "%s"\n' "$VERSION" > obj/src/internal/version.h
)
# xcc's bundled stdarg.h, copied verbatim: it provides __builtin_va_list and
# va_start/va_arg/va_end/va_copy, plus the __isoc_va_list alias musl needs (appended
# below). The generated alltypes.h includes it on its first line.
cp -f "$XCCSRC/include/stdarg.h" "$COMPAT_INC/stdarg.h"
cat >> "$COMPAT_INC/stdarg.h" <<'EOF'

/* Appended by 3-build-musl-xcc.sh: musl treats __isoc_va_list as a synonym for va_list */
typedef __builtin_va_list __isoc_va_list;
EOF
echo "    alltypes.h    $(wc -l < "$tree/obj/include/bits/alltypes.h") lines (first line is #include <stdarg.h>)"

# xcc's long double is just the 8-byte double (sizeof(long double)==8, measured), while
# musl's arch/x86_64/bits/float.h declares LDBL_MANT_DIG=64 / LDBL_MAX_EXP=16384 (x87,
# 80-bit). With those values musl's math code takes its "80-bit long double" branches and
# reads the 8-byte objects xcc produces as 16-byte ones (frexpl and friends) — a segfault
# at run time. So **before compiling**, LDBL_* is overridden with the double values, which
# makes the `#if LDBL_MANT_DIG == 53 && LDBL_MAX_EXP == 1024` branches win — those are
# exactly musl's implementations for "long double is double".
# It has to happen in the source tree, not just in the installed sysroot: libc.a itself
# must be built under that assumption.
ldbl_f="$tree/arch/$ARCH/bits/float.h"
if ! grep -q '3-build-musl-xcc.sh: xcc long double' "$ldbl_f"; then
  # Prefix every original `#define LDBL_*` with `#undef`, then append the override block
  # below (its own #undef + #define pairs come last, so they win).
  sed -i -e 's|^#define LDBL_|#undef LDBL_\n#define LDBL_|' "$ldbl_f"
  cat >> "$ldbl_f" <<'LDBL_EOF'

/* ---- 3-build-musl-xcc.sh: xcc long double == double (8 bytes) ----
   xcc has no 80-bit long double: sizeof(long double)==sizeof(double)==8. Overriding
   LDBL_* with the double values makes src/math/*.c take the
   LDBL_MANT_DIG==53 && LDBL_MAX_EXP==1024 branches (musl's "long double is just
   double" implementations), instead of reading 8-byte values with the x87 80-bit
   layout. */
#undef LDBL_MANT_DIG
#undef LDBL_MIN_EXP
#undef LDBL_MAX_EXP
#undef LDBL_DIG
#undef LDBL_MIN_10_EXP
#undef LDBL_MAX_10_EXP
#undef LDBL_EPSILON
#undef LDBL_TRUE_MIN
#undef LDBL_MIN
#undef LDBL_MAX
#undef DECIMAL_DIG
#define LDBL_MANT_DIG    DBL_MANT_DIG
#define LDBL_MIN_EXP     DBL_MIN_EXP
#define LDBL_MAX_EXP     DBL_MAX_EXP
#define LDBL_DIG         DBL_DIG
#define LDBL_MIN_10_EXP  DBL_MIN_10_EXP
#define LDBL_MAX_10_EXP  DBL_MAX_10_EXP
#define LDBL_EPSILON     DBL_EPSILON
#define LDBL_TRUE_MIN    DBL_TRUE_MIN
#define LDBL_MIN         DBL_MIN
#define LDBL_MAX         DBL_MAX
#define DECIMAL_DIG      DBL_DIG
LDBL_EOF
  echo "    arch/$ARCH/bits/float.h: LDBL_* overridden for xcc's long double (= double)"
fi
echo "    syscall.h     $(wc -l < "$tree/obj/include/bits/syscall.h") lines"
echo "    stdarg shim   $COMPAT_INC/stdarg.h"

# ------------------------------------------------- 3. Derive the object list (copy musl)
note "[3/7] Deriving the object list (mirrors musl's Makefile ALL_OBJS)"
# Ask musl's own Makefile: `make -n ARCH=x86_64` expands ALL_OBJS and prints the
# compile/archive command of each object, so obj/**.o can be scraped out of it. The result
# matches musl exactly, including the REPLACED_OBJS deduplication (for example
# src/thread/x86_64/__set_thread_area.o replacing src/thread/__set_thread_area.o), and
# `-n` only prints, so no compiler is started.
#
# Source extensions: names in ALL_OBJS carry no extension (crt/crt1, src/string/memset)
# while the source may be .c or .s (crt/x86_64/crti comes from crti.s,
# src/string/x86_64/memset from memset.s), so probe .c/.s/.S and take the first that
# exists.
all_list="$work/all-objs.txt"
( cd "$tree" && make -n ARCH="$ARCH" 2>/dev/null || true ) \
  | grep -oE 'obj/[^ ]+\.o' | sed 's|^obj/||' | sort -u > "$all_list"
[ -s "$all_list" ] || die "could not obtain ALL_OBJS from musl's Makefile (make -n failed)"

# Target name -> source file (probes .c/.s/.S)
src_of() {
  local base="$1" ext
  for ext in c s S; do
    if [ -f "$tree/$base.$ext" ]; then printf '%s\n' "$base.$ext"; return 0; fi
  done
  return 1
}

# ldso/ stays out of the static libc.a (dynamic loader and dlopen paths, unused when
# linking statically); crt/ is compiled separately, in [5.2], into the start objects
# (crt1.o, crti.o, crtn.o, Scrt1.o, rcrt1.o).
# xcc has no _Complex, so every src/complex/* file fails to compile, and there is no
# generic C fallback for them (other arch directories do not have one either). They are
# excluded explicitly and recorded; using <complex.h> from a C program will fail, which is
# a known and accepted limitation.
grep -v '^ldso/' "$all_list" | grep -v '^crt/' | grep -v '^src/complex/' > "$work/libc-objs.txt"
excluded_complex=$(grep -c '^src/complex/' "$all_list" || true)
# Also drop the remaining file that is known not to compile and does not affect this
# round's goal (posix_spawn.c) and record it in skipped.txt so the report lists it
# honestly; leaving it in would only produce a `fail` row in the manifest and force the
# fallback pass to mop up, which is noise.
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
note "[4/7] Compiling file by file with xcc ($JOBS parallel)"
M="$tree"
# The -I order is musl's own CFLAGS_ALL order with the shim prepended (it supplies the
# stdarg.h va_list bridge); -D_XOPEN_SOURCE=700, -ffreestanding and -std=c99 come from
# CFLAGS_ALL/CFLAGS_C99FSE, while musl's -nostdinc (CFLAGS_C99FSE) and its default
# -Os -pipe (CFLAGS_AUTO) are not passed.
INCS="-I$COMPAT_INC -I$M/arch/$ARCH -I$M/arch/generic -I$M/obj/src/internal \
-I$M/src/include -I$M/src/internal -I$M/obj/include -I$M/include"
CFLAGS="$INCS -D_XOPEN_SOURCE=700 -ffreestanding -std=c99"
echo "    CFLAGS: $CFLAGS"

rm -rf "$objdir"; mkdir -p "$objdir" "$logdir"
: > "$manifest"
export XCC M CFLAGS objdir logdir
compile_one() {
  local rel="$1" o err rc=0 src="" ext
  # rel is the target name (src/string/memset.o). The source extension has to be probed
  # separately: musl sources are both .c and .s. src_of is not exported to the subshells
  # xargs starts, so the probe is inlined here instead of calling it.
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

# ---- 4b. Fallback pass: an arch .s that fails is replaced by the generic C version ----
# musl's REPLACED_OBJS drops the generic C file whenever an arch-specific version exists
# (it trusts the arch one). xcc's assembler cannot assemble the x86_64 .s sources — it
# reports `unknown instruction`, `illegal operand` or `line end expected` on mnemonics such
# as movzbq, `imul %r8,%rax`, adc, popq, fnstsw, movsb and `setjmp@PLT`, plus `inline asm:
# unsupported constraint "=x"` for the math ones — so memset/memcpy/memmove, the x87 math
# helpers and friends would end up with no implementation at all. The generic C versions
# are in the source tree (musl uses them for arches without that assembly); they are
# compiled here and replace the failed manifest rows.
#
# Example: src/string/x86_64/memset.o fails -> generic src/string/memset.c
fallback_pairs="$work/fallback-pairs.txt"
: > "$fallback_pairs"
awk -F'\t' '$1=="fail" && $2 ~ /\.o$/ {print $2}' "$manifest" | while IFS= read -r rel; do
  base="${rel%.o}"                         # src/string/x86_64/memset
  sub="$(printf '%s' "$base" | sed -E 's|^(src/[^/]+)/[^/]+/|\1/|')"
  [ "$sub" != "$base" ] || continue        # not under an arch subdirectory: no generic version to fall back to
  # Note: some generic .c files in musl are **empty** (for example src/setjmp/longjmp.c and
  # src/signal/sigsetjmp.c: placeholders for arches that need no implementation of their
  # own). Compiling one yields zero symbols, so substituting it would make the symbol
  # vanish entirely (longjmp failed to link in the GMP self-test), so such files are
  # skipped and left to the hand-written assembly in 4c.
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
  # Replace the manifest row of each fallback target with its new status. The three
  # assignments are only a defensive reset; the merge itself is keyed by target name in
  # awk below.
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

# ---- 4c. Hand-written assembly for the original .s files xcc-xcclib's assembler -------
#          cannot handle and for which musl has no generic C version
# musl's src/setjmp/x86_64/longjmp.s uses `adc', and src/signal/x86_64/sigsetjmp.s uses
# `popq 64(%rdi)' / `pushq 64(%rbx)' / `call setjmp@PLT' — xcc's assembler rejects all of
# those forms (unknown instruction / line end expected) — while their generic C versions
# are empty files. Equivalent rewrites that stay within the instructions xcc's assembler
# supports are generated here.
# (setjmp.s itself assembles fine, so it is not included.)
handasm="$COMPAT/asm"
mkdir -p "$handasm"
cat > "$handasm/longjmp.s" <<'LONGJMP_EOF'
/* Stand-in for musl src/setjmp/x86_64/longjmp.s.
   xcc's assembler does not support `adc %esi,%eax', so the value is computed with
   a test/jne pair instead. It returns `val ? val : 1' (0 maps to 1). */
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
/* Stand-in for musl src/signal/x86_64/sigsetjmp.s.
   The original's `popq 64(%rdi)' / `pushq 64(%rbx)' (it parks the caller's return
   address in the jmp_buf's __fl word) and `call setjmp@PLT' are not accepted by xcc's
   assembler.
   Instead: one stack slot is reserved (sub $8,%rsp), so the caller's return address
   stays at 8(%rsp) while setjmp runs. The caller's %rbx is saved in __ss[1] (offset
   80), the jmp_buf pointer is kept in %rbx across the setjmp call, and %rbx is
   restored before the tail jump. __sigsetjmp_tail saves/restores the signal mask in
   __ss (offset 72); on x86_64 that is 8 bytes and does not reach offset 80. */
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
# Merge into the manifest (a same-name row wins: these two replace the `fail` rows above)
hst=; hrel=; ho=
awk -F'\t' 'NR==FNR{new[$2]=$0; next} {if ($2 in new) print new[$2]; else print}' \
    "$work/handasm-manifest.tsv" "$manifest" > "$manifest.tmp"
mv "$manifest.tmp" "$manifest"
sort -o "$manifest" -k2,2 "$manifest"
echo "    supplied by hand-written assembly: $(cut -f2 "$work/handasm-manifest.tsv" | tr '\n' ' ')"


note "[5/7] Installing headers and archiving libc.a into ${OUT_INC%/include} and ${OUT_LIB}"
mkdir -p "$OUT_INC/bits" "$OUT_LIB"

# 5.1 Public headers: include/ + arch/generic/bits + arch/$ARCH/bits (the latter
#     overrides same-name files)
# Only **musl's own** headers are replaced; OUT_INC is never wiped. OUT_INC is
# rootfs3/usr/musl-1/include, an independent snapshot of musl, while third-party headers
# (gmp.h/mpfr.h/...) go into rootfs3/usr/include later, so the two never share a directory
# — but the "replace only my own files" pattern is kept so that re-running this script
# cannot delete unrelated files that happen to sit next to them (a wholesale
# `rm -rf` of the include directory is what deletes third-party headers such as gmp.h).
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
# cp -a has been seen to silently drop files (one copy left only 65 of the ~91 top-level
# headers), so verify every header explicitly and repair it.
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

# 5.2 crt objects: crt1.o (entry) plus crti.o/crtn.o (init/fini sections); musl's crt list
#     also has Scrt1.o and rcrt1.o (PIE and static-PIE start objects), which this same loop
#     builds and installs as well. None of them is in the step-4 libc list, so they are
#     compiled here with the same CFLAGS (the arch .s files run through xcc's assembler
#     too).
while IFS=$'\t' read -r rel base; do
  [ -n "$rel" ] || continue
  mkdir -p "$work/obj/crt"          # obj/ was cleared at the start of step 4, so its crt/ subdirectory has to be recreated here
  errf="$logdir/crt_$(printf '%s' "$base" | tr '/' '_').err"
  rc=0
  "$XCC" -c $CFLAGS -o "$work/obj/crt/$base.o" "$M/$rel" > "$errf" 2>&1 || rc=$?
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
  # 5.3a libc.a: members get flattened names. A path inside an ar member name can come
  #      back truncated, and the linker resolves symbols, not member names.
  stage="$work/ar-stage"
  rm -rf "$stage"; mkdir -p "$stage"
  : > "$work/ar-list.txt"
  # Defensive reset: the read below assigns these on every iteration, so this is belt and
  # braces rather than a fix for a real carry-over.
  mst=; mrel=; mo=;
  # The names are deliberately different from the crt loop's rel/base, so a crt path can
  # never be picked up as an archive member path.
  while IFS=$'\t' read -r mst mrel mo; do
    [ "$mst" = ok ] || continue
    flat="$(printf '%s' "${mrel%.o}" | tr '/' '+').o"
    ln -f "$mo" "$stage/$flat" 2>/dev/null || cp -f "$mo" "$stage/$flat"
    printf '%s\n' "$flat" >> "$work/ar-list.txt"
  done < "$manifest"
  rm -f "$OUT_LIB/libc.a"
  ( cd "$stage" && xargs -r ar rcs "$OUT_LIB/libc.a" < "$work/ar-list.txt" )
  echo "    libc.a: $(stat -c%s "$OUT_LIB/libc.a") bytes, $(ar t "$OUT_LIB/libc.a" | wc -l) members, sha256 $(sha256sum "$OUT_LIB/libc.a" | cut -c1-16)"
  # Key symbol check: x86_64's __set_thread_area must come from the .s, not from the
  # generic fallback
  echo "    member containing __set_thread_area: $(ar t "$OUT_LIB/libc.a" | grep -i set_thread_area | tr '\n' ' ')"
fi

# 5.3b Placeholder libm.a: **musl folds every math function into libc.a**, so the sysroot
# has no separate libm. GCC's build system writes `-lm` in many places (for example when
# linking build/genautomata) and xcc's ld fails the whole target with "m: library not
# found" when it cannot find one. So ship a **valid** archive here: xcc's ld rejects an
# 8-byte empty archive (one holding just "!<arch>\n" makes it report "Global header" and
# fail), hence a placeholder symbol that is never referenced. The math symbols themselves
# are resolved by the `-lc` that follows on the command line.
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

# ------------------------------------------------- 5.5 Land the "global sysroot"
# User convention: **the global sysroot is rootfs3/usr/{include,lib}**.
# The snapshot's top-level entries are symlinked into usr/include and usr/lib
# (idempotent: an entry that already exists is left alone).
# Links, not copies: third-party libraries (gmp/mpfr/...) install with --prefix=/usr into
# the same usr/ tree, so copying would scatter musl's headers and libraries over two
# places, while links keep a single copy of musl inside the very sysroot the third-party
# products install into.
# Gate: LAND_SYSROOT=0 skips this section (musl-1 snapshot only); default 1.
if [ "${LAND_SYSROOT:-1}" = 1 ]; then
  note "[5.5/7] Landing the global sysroot: $ROOTFS/usr/{include,lib} pointing at musl-1"
  mkdir -p "$ROOTFS/usr/include" "$ROOTFS/usr/lib"

  # ---- 5.5.0 The va_list bridge stays in the "xcc overlay" and must not pollute the
  #            shared sysroot ----
  # Background: xcc declares `__builtin_va_list` only in its own stdarg.h, while musl's
  # bits/alltypes.h defines va_list as `typedef __builtin_va_list va_list;`, so compiling
  # **with xcc** needs alltypes.h to start with `#include <stdarg.h>` and to replace those
  # two typedefs with `#define __DEFINED_*` (the va_list bridge).
  # **GCC needs no bridge and is broken by it**: GCC uses musl's own stdarg.h
  # (`#define __NEED_va_list` + `#include <bits/alltypes.h>`), so once the typedefs in
  # alltypes.h are reduced to `__DEFINED_*` markers, va_list/__isoc_va_list are undefined
  # types — measured: cc1 rejects any program that includes <stdio.h> with
  # `stdio.h:114:37: error: unknown type name '__isoc_va_list'`.
  # So the two are separated:
  #   * snapshot/sysroot (what GCC uses) -> musl's **raw generated** bits/alltypes.h
  #     (alltypes.h.raw), installed here when landing;
  #   * the xcc overlay (the wrapper puts `-I$SHIM` first, see 3-build-xcc-musl-cc.sh) ->
  #     the bridged version.
  # This is also what keeps RESTORE=1 of ./3-adjust-rootfs-current.sh (repointing the
  # sysroot back at musl-1) valid for GCC.
  raw="$M/obj/include/bits/alltypes.h.raw"
  if [ -f "$raw" ]; then
    cp -f "$raw" "$OUT_INC/bits/alltypes.h"
    mkdir -p "$COMPAT_INC/bits"
    { printf '/* xcc overlay: va_list/__isoc_va_list come from the <stdarg.h> in this directory */\n'
      printf '#include <stdarg.h>\n'
      cat "$raw"
    } > "$COMPAT_INC/bits/alltypes.h"
    sed -i \
      -e 's|^typedef __builtin_va_list va_list;$|#define __DEFINED_va_list 1|' \
      -e 's|^typedef __builtin_va_list __isoc_va_list;$|#define __DEFINED___isoc_va_list 1|' \
      "$COMPAT_INC/bits/alltypes.h"
    echo "    sysroot bits/alltypes.h -> musl's raw version (usable by GCC)"
    echo "    xcc overlay $COMPAT_INC/bits/alltypes.h -> va_list-bridged version"
  else
    warn "$raw not found, skipping the va_list bridge split (GCC may report __isoc_va_list as undefined)"
  fi

  n_inc=0; n_lib=0
  # All links are **relative**: rootfs3 has to work as a whole when it is used as / (bwrap,
  # chroot), and an absolute link points at a host path that no longer exists after the
  # root change (measured: a bare root reported `Cannot open file: <stdio.h>`).
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
  # usr/bin/{include,lib} are two convenience links into the same musl snapshot; repoint
  # them as well.
  ln -sfn ../musl-1/include "$ROOTFS/usr/bin/include" 2>/dev/null || true
  ln -sfn ../musl-1/lib     "$ROOTFS/usr/bin/lib"     2>/dev/null || true
fi

# ---------------------------------------------------------------- 6. Report
note "[6/7] Generating the report"
{
  echo "# musl $VERSION / xcc build report (3-build-musl-xcc.sh)"
  echo
  echo "generated : $(date -Iseconds)"
  echo "source    : musl-1.2.6.zip sha256=$(sha256sum "$SRC_ZIP" | cut -d' ' -f1)"
  echo "compiler  : xcc-xcclib $("$XCC" -v | tr '\n' ' ')"
  echo "  xcc sha256=$(sha256sum "$XCCDIR/bin/xcc" | cut -d' ' -f1)"
  echo "  cc1 sha256=$(sha256sum "$XCCDIR/bin/cc1" | cut -d' ' -f1)"
  echo "  as  sha256=$(sha256sum "$XCCDIR/bin/as"  | cut -d' ' -f1)"
  echo "  ld  sha256=$(sha256sum "$XCCDIR/bin/ld"  | cut -d' ' -f1)"
  echo "  cpp sha256=$(sha256sum "$XCCDIR/bin/cpp" | cut -d' ' -f1)"
  echo
  echo "## Compile statistics"
  echo
  echo "| item | count |"
  echo "|---|---|"
  echo "| libc objects (excluding crt/ldso) | $total |"
  echo "| of which excluded because xcc has no _Complex (src/complex) | $excluded_complex |"
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
  note "[7/7] Self-test: link and run a program with xcc + the musl just installed"
  st="$work/selftest"; mkdir -p "$st"
  cat > "$st/t.c" <<'EOF'
/* Covers the three paths that break most easily: TLS initialisation, malloc/calloc and
   floating-point printf */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(void) {
  char *p = malloc(80000);            /* below mallocng's 131052-byte mmap threshold: goes through the size-class path */
  void *q = calloc(10000, 8);
  if (!p || !q) return 1;
  memset(p, 0, 80000);
  strcpy(p, "musl-1");
  printf("%s %zu %.3f %d\n", p, strlen(p), 1.0/3.0, (int)sizeof(void*));
  free(p); free(q);
  return 0;
}
EOF
  incs=(-I"$COMPAT_INC" -I"$OUT_INC")
  "$XCC" "${incs[@]}" -c -o "$st/t.o" "$st/t.c" || die "self-test compile failed"
  if "$XCC" "${incs[@]}" -nostdlib -o "$st/t" "$st/t.o" \
       "$OUT_LIB/crt1.o" "$OUT_LIB/crti.o" "$OUT_LIB/crtn.o" -L"$OUT_LIB" -lc; then
    out="$("$st/t")" || die "self-test program run failed (exit code $?)"
    echo "    $out"
    echo "$out" | grep -q '^musl-1 6 0.333 8$' || die "unexpected self-test output (TLS/malloc/floating-point printf)"
    echo "    $(file -b "$st/t")"
  else
    die "self-test link failed"
  fi
fi

note "Done"
echo "  headers : $OUT_INC"
echo "  library : $OUT_LIB/libc.a + crt1.o crti.o crtn.o"
echo "  report  : $work/SUMMARY.txt"
echo "  log     : $LOG"
