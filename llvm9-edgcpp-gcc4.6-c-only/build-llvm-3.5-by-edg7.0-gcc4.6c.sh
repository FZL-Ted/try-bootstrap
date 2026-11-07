#!/usr/bin/env bash
#
# Build LLVM/Clang 3.5.2 with the EDG 7.0 C++ front end, using the
# C-only GCC 4.6.4 from the reference rootfs as the C compiler and that same
# rootfs' musl as the target libc.
#
# Pipeline:
#
#   C++ source --(EDG 7.0)--> generated C --(GCC 4.6, C only)--> object
#                                                          static musl link
#
# GCC 4.6 has no __atomic_* builtins and no __builtin_assume_aligned, so a
# small compatibility library (libcompat.a, built from
# edg-support/compat) is compiled by the same GCC and linked into every
# program.  GCC 4.6 was configured with a hard-coded sysroot pointing at the
# reference rootfs, so no --sysroot option is needed anywhere.
#
# Because LLVM is C++ and GCC 4.6 is C-only, the C++ standard library is built
# from source: libc++ 9 (llvm-project-9.0) is translated by EDG, compiled by
# GCC 4.6 against musl and archived as libc++.a.  libc++ 3.5 (the one shipped
# with LLVM 3.5) has no musl support at all (its __config relies on glibc's
# __GLIBC_PREREQ), so it is not used.
#
# Prerequisites (all read-only inputs):
#
#   compiler-test/ref-rootfs-gcc4.6-c-only/usr/  C-only GCC 4.6.4, musl
#                                               headers/static libs, binutils
#   build/edg7.0-edg5.1/edgcpfe               EDG 7.0 front end
#   build/edg7.0-edg5.1/base/                 EDG 7.0 base (include dirs)
#   build/edg7.0-edg5.1/lib/libC.a            EDG 7.0 runtime library
#   edg-support/compat/                       atomic_decls.h, atomic_compat.c
#   edg-support/predefined/gnu/predefined_macros.txt
#                                             gnu-mode macro table (843 lines)
#   llvm-project-3.5/{llvm,clang}             LLVM 3.5.2 sources
#   llvm-project-9.0/libcxx                   libc++ 9 sources/headers
#
# Products live under build/llvm3.5-edg7.0-gcc4.6c/:
#
#   compat/libcompat.a  __atomic_* / __builtin_assume_aligned for GCC 4.6
#   lib/libc++.a        C++ standard library (EDG + GCC 4.6 + musl)
#   lib/libC_weak.a     EDG runtime, with symbols overlapping libc++ weakened
#   driver/edg-cxx      CMake/Ninja C++ driver (translation + compile + link)
#   driver/cc46         C compiler wrapper (GCC 4.6, flags filtered)
#   llvm-build/bin/     llvm-tblgen, llc, opt, llvm-* and (optionally) clang
#
# Usage:
#     ./build-llvm-3.5-by-edg7.0-gcc4.6c.sh
#
# Overridable environment variables:
#     REF            reference rootfs (default: compiler-test/ref-rootfs-gcc4.6-c-only)
#     EDG70          EDG 7.0 directory (default: <root>/build/edg7.0-edg5.1)
#     LLVM35_SRC     LLVM 3.5 sources        (default: <root>/llvm-project-3.5)
#     LIBCXX9_SRC    libc++ 9 sources        (default: <root>/llvm-project-9.0/libcxx)
#     MACRO_TABLE    gnu predefined macros   (default: <root>/edg-support/predefined/gnu/predefined_macros.txt)
#     COMPAT_SRC     GCC 4.6 compat sources  (default: <root>/edg-support/compat)
#     WORK           build directory         (default: <root>/build/llvm3.5-edg7.0-gcc4.6c)
#     JOBS           parallel jobs           (default: nproc --ignore=1)
#     STOP_AFTER     stop after a stage       (tblgen|llvm|clang, default: clang)
#     KEEP_WORK      1 = keep the existing work directory (incremental runs)
#     HOST_CC        C compiler               (default: <REF>/usr/gcc4.6/bin/gcc)
#
# Every potentially long operation is wrapped in `timeout`; the limits are
# configurable (seconds):
#     EDG_TIMEOUT (per translation unit, default 3600)
#     CC_TIMEOUT (per generated-C compile, default 1800)
#     LIBCXX_TIMEOUT (per libc++ TU, default 1200)
#     CONFIGURE_TIMEOUT (default 1800)
#     TBLGEN_TIMEOUT (default 10800)
#     LLVM_TIMEOUT (default 43200)
#     CLANG_TIMEOUT (default 28800)
#
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
REF=${REF:-$ROOT/compiler-test/ref-rootfs-gcc4.6-c-only}
EDG70=${EDG70:-$ROOT/build/edg7.0-edg5.1}
LLVM35_SRC=${LLVM35_SRC:-$ROOT/llvm-project-3.5}
LIBCXX9_SRC=${LIBCXX9_SRC:-$ROOT/llvm-project-9.0/libcxx}
MACRO_TABLE=${MACRO_TABLE:-$ROOT/edg-support/predefined/gnu/predefined_macros.txt}
COMPAT_SRC=${COMPAT_SRC:-$ROOT/edg-support/compat}
WORK=${WORK:-$ROOT/build/llvm3.5-edg7.0-gcc4.6c}
STOP_AFTER=${STOP_AFTER:-clang}
KEEP_WORK=${KEEP_WORK:-0}
CC46=$REF/usr/gcc4.6/bin/gcc
HOST_CC=${HOST_CC:-$CC46}
if [ -z "${JOBS:-}" ]; then
  # Do not consume every core; leave one for the interactive user.
  JOBS=$(nproc --ignore=1 2>/dev/null || echo 1)
  case "$JOBS" in ''|*[!0-9]*) JOBS=1 ;; esac
  [ "$JOBS" -ge 1 ] || JOBS=1
fi

# GCC 4.6 is considerably slower than a 2020s host compiler on EDG's huge
# generated C, so the build timeouts are raised accordingly.
EDG_TIMEOUT=${EDG_TIMEOUT:-3600}
CC_TIMEOUT=${CC_TIMEOUT:-1800}
LIBCXX_TIMEOUT=${LIBCXX_TIMEOUT:-1200}
CONFIGURE_TIMEOUT=${CONFIGURE_TIMEOUT:-1800}
TBLGEN_TIMEOUT=${TBLGEN_TIMEOUT:-10800}
LLVM_TIMEOUT=${LLVM_TIMEOUT:-43200}
CLANG_TIMEOUT=${CLANG_TIMEOUT:-28800}

EDG=$WORK/edgcpfe
EDG_BASE=$WORK/edg
SRC=$WORK/src
BUILD=$WORK/llvm-build
LOG=$WORK/log
LIBCXX_INC=$LIBCXX9_SRC/include
LIBS=$WORK/lib
DRIVER=$WORK/driver
TESTS=$WORK/tests
COMPAT=$WORK/compat

GCC_INC=$("$HOST_CC" -print-file-name=include 2>/dev/null || true)
REF_AR=$REF/usr/binutils/bin/ar
REF_NM=$REF/usr/binutils/bin/nm
REF_OBJCOPY=$REF/usr/binutils/bin/objcopy
REF_RANLIB=$REF/usr/binutils/bin/ranlib
AR=$([ -x "$REF_AR" ] && printf '%s' "$REF_AR" || command -v ar)
NM=$([ -x "$REF_NM" ] && printf '%s' "$REF_NM" || command -v nm)
OBJCOPY=$([ -x "$REF_OBJCOPY" ] && printf '%s' "$REF_OBJCOPY" || command -v objcopy)
RANLIB=$([ -x "$REF_RANLIB" ] && printf '%s' "$REF_RANLIB" || command -v ranlib)

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

# ================================================================ sanity ===

[ -d "$REF" ]                                   || die "reference rootfs not found: $REF"
[ -d "$REF/usr/include" ]                       || die "musl headers not found: $REF/usr/include"
[ -s "$REF/usr/lib/libc.a" ]                    || die "musl libc.a not found: $REF/usr/lib/libc.a"
[ -s "$REF/usr/lib/crt1.o" ]                    || die "musl crt1.o not found: $REF/usr/lib/crt1.o"
[ -x "$EDG70/edgcpfe" ]                         || die "EDG 7.0 front end not found: $EDG70/edgcpfe"
[ -d "$EDG70/base/include" ]                    || die "EDG 7.0 base not found: $EDG70/base"
[ -d "$EDG70/base/include_c99" ]                || die "EDG 7.0 include_c99 not found: $EDG70/base"
[ -s "$EDG70/lib/libC.a" ]                      || die "EDG 7.0 runtime not found: $EDG70/lib/libC.a"
[ -f "$MACRO_TABLE" ]                           || die "gnu predefined macro table not found: $MACRO_TABLE"
[ -s "$MACRO_TABLE" ]                           || die "gnu predefined macro table is empty: $MACRO_TABLE"
[ -d "$LLVM35_SRC/llvm" ]                       || die "LLVM 3.5 sources not found: $LLVM35_SRC/llvm"
[ -d "$LLVM35_SRC/clang" ]                      || die "clang 3.5 sources not found: $LLVM35_SRC/clang"
[ -d "$LIBCXX9_SRC/src" ]                       || die "libc++ 9 sources not found: $LIBCXX9_SRC/src"
[ -d "$LIBCXX9_SRC/include" ]                   || die "libc++ 9 headers not found: $LIBCXX9_SRC/include"
command -v python3 >/dev/null 2>&1              || die "python3 is required"
command -v cmake   >/dev/null 2>&1              || die "cmake is required"
command -v ninja   >/dev/null 2>&1              || die "ninja is required"
command -v "$HOST_CC" >/dev/null 2>&1           || die "C compiler not found: $HOST_CC"
[ -n "$GCC_INC" ] && [ -d "$GCC_INC" ]          || die "compiler include directory not found"
[ -n "$AR" ] && [ -n "$NM" ] && [ -n "$OBJCOPY" ] || die "ar/nm/objcopy not found"
[ -f "$COMPAT_SRC/atomic_decls.h" ]             || die "missing $COMPAT_SRC/atomic_decls.h"
[ -f "$COMPAT_SRC/atomic_compat.c" ]            || die "missing $COMPAT_SRC/atomic_compat.c"
[ -n "$RANLIB" ]                                || die "ranlib not found"

case "$STOP_AFTER" in
  tblgen|llvm|clang) ;;
  *) die "invalid STOP_AFTER '$STOP_AFTER' (tblgen|llvm|clang)" ;;
esac

case "$WORK" in
  "$ROOT"|"$ROOT/build"|"$ROOT/build/"|"/"|"$REF"|"$EDG70"|"$LLVM35_SRC"|"$LIBCXX9_SRC")
    die "refusing to use $WORK as the work directory" ;;
esac
case "$WORK" in
  "$ROOT/build"/*) ;;
  *) die "work directory must be inside $ROOT/build: $WORK" ;;
esac

# GCC 4.6 was configured with a hard-coded sysroot pointing at the reference
# rootfs, so its sysroot must match $REF (and no --sysroot option is needed
# anywhere in this script).
HOST_CC_VERSION=$("$HOST_CC" -dumpversion)
HOST_TRIPLE=$("$HOST_CC" -dumpmachine)
case "$HOST_CC_VERSION" in
  4.6*) ;;
  *) die "expected GCC 4.6.x, got '$HOST_CC_VERSION' ($HOST_CC)" ;;
esac
CC46_SYSROOT=$("$HOST_CC" -print-sysroot)
[ -n "$CC46_SYSROOT" ] || die "GCC 4.6 reports an empty sysroot"
[ "$CC46_SYSROOT" = "$(cd "$REF" && pwd -P)" ] || \
  die "unexpected GCC 4.6 sysroot '$CC46_SYSROOT' (expected $REF)"
command -v "$RANLIB" >/dev/null 2>&1 || die "ranlib not found: $RANLIB"

# The compiler must be able to build a static musl program.  This is a hard
# requirement of the whole build, so verify it up front instead of discovering
# it at the first link.  -Wl,-z,noexecstack silences the "crtn.o: missing
# .note.GNU-stack" warning that the rootfs' crt objects trigger.
mkdir -p "$WORK/tests"
cat > "$WORK/tests/sanity.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
int main(void) { char *p = malloc(8); snprintf(p, 8, "%s", "musl"); printf("%s %d\n", p, 42); free(p); return 0; }
EOF
if ! "$HOST_CC" -static -O2 -w -Wl,-z,noexecstack -o "$WORK/tests/sanity" \
       "$WORK/tests/sanity.c" >"$WORK/tests/sanity.log" 2>&1; then
  tail -n 10 "$WORK/tests/sanity.log" >&2 || true
  die "GCC 4.6 cannot build a static musl program (see $WORK/tests/sanity.log)"
fi
SANITY_OUT=$("$WORK/tests/sanity") || die "the static musl sanity program failed at run time"
[ "$SANITY_OUT" = "musl 42" ] || die "unexpected static musl sanity output: '$SANITY_OUT'"

EDG_VERSION=$("$EDG70/edgcpfe" --version 2>&1 | head -n 1) || \
  die "the EDG front end failed to run"
case "$EDG_VERSION" in
  *"version 7.0"*) ;;
  *) die "unexpected EDG version: $EDG_VERSION" ;;
esac

info "C compiler      : $HOST_CC ($HOST_CC_VERSION, $HOST_TRIPLE)"
info "GCC 4.6 sysroot : $CC46_SYSROOT"
info "target libc     : $REF (musl, static)"
info "EDG front end   : $EDG70/edgcpfe"
info "EDG base        : $EDG70/base"
info "LLVM 3.5 source : $LLVM35_SRC"
info "libc++ 9 source : $LIBCXX9_SRC"
info "work directory  : $WORK"
info "parallel jobs   : $JOBS"
info "stop after      : $STOP_AFTER"

# Record the read-only source trees' git state, so the final check compares
# against the state at start rather than assuming a pristine checkout.
GIT_LLVM_BEFORE=
GIT_CXX_BEFORE=
if command -v git >/dev/null 2>&1; then
  if git -C "$LLVM35_SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    GIT_LLVM_BEFORE=$(git -C "$LLVM35_SRC" status --porcelain 2>/dev/null || true)
  fi
  if git -C "$LIBCXX9_SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    GIT_CXX_BEFORE=$(git -C "$LIBCXX9_SRC" status --porcelain 2>/dev/null || true)
  fi
fi

# ------------------------------------------------------------ work dir ---

if [ "$KEEP_WORK" = "1" ] && [ -d "$WORK" ]; then
  info "KEEP_WORK=1: reusing the existing work directory"
else
  rm -rf "$WORK"
fi
mkdir -p "$WORK"/{edg/lib,compat/obj,lcx,lcxobj,lib,driver,log,tests,src}
touch "$WORK/.start"
START=$(date +%s)
START_UTC=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

# ======================================================================
# Stage 1: stage the EDG 7.0 front end and its base directory
# ======================================================================
#
# The front end reads lib/predefined_macros.txt relative to its base
# directory.  The stage-1 base ships a 463-line table; libc++ 9 needs the
# 843-line gnu-mode table from edg-support/predefined/gnu.

info "stage 1: staging the EDG 7.0 front end and base"
cp "$EDG70/edgcpfe" "$EDG"
chmod +x "$EDG"
mkdir -p "$EDG_BASE/include" "$EDG_BASE/include_c99"
cp -a "$EDG70/base/include/."     "$EDG_BASE/include/"
cp -a "$EDG70/base/include_c99/." "$EDG_BASE/include_c99/"
cp "$MACRO_TABLE" "$EDG_BASE/lib/predefined_macros.txt"
[ -s "$EDG_BASE/lib/predefined_macros.txt" ] || die "predefined macro table was not installed"
"$EDG" --version 2>&1 | grep -q 'version 7.0' || die "unexpected EDG version output"
info "EDG 7.0: $(printf '%s\n' "$EDG_VERSION")"

# ======================================================================
# Stage 1b: GCC 4.6 compatibility layer
# ======================================================================
#
# EDG's C output calls the GCC __atomic_* entry points and
# __builtin_assume_aligned.  GCC 4.7+ knows them as builtins; GCC 4.6 does
# not, so the compat layer provides them on top of GCC 4.6's __sync_* builtins
# (x86-64: every access up to 8 bytes is lock-free; orderings are approximated
# with full barriers: correct, merely slower).  atomic_decls.h declares them
# for the generated C (the driver passes it with -include).

info "stage 1b: building the GCC 4.6 compatibility layer"
cp "$COMPAT_SRC/atomic_decls.h" "$COMPAT_SRC/atomic_compat.c" "$COMPAT/"
"$HOST_CC" -std=gnu99 -O2 -w -c "$COMPAT/atomic_compat.c" \
  -o "$COMPAT/obj/atomic_compat.o" >"$LOG/compat.log" 2>&1 || \
  die "compiling atomic_compat.c with GCC 4.6 failed (see $LOG/compat.log)"
"$AR" rcs "$COMPAT/libcompat.a" "$COMPAT/obj/atomic_compat.o" >>"$LOG/compat.log" 2>&1 || \
  die "creating libcompat.a failed (see $LOG/compat.log)"
[ -s "$COMPAT/libcompat.a" ] || die "libcompat.a was not produced"
"$RANLIB" "$COMPAT/libcompat.a" >/dev/null 2>&1 || true
info "libcompat.a: $(stat -c %s "$COMPAT/libcompat.a") bytes"

# ======================================================================
# Stage 2: libc++ 9 built by EDG + GCC 4.6 + musl
# ======================================================================
#
# Every libc++ source is translated by EDG to C and compiled by GCC 4.6 (and
# linked against musl).  -O0 for the C library: EDG output is huge and this is
# a stage-1 toolchain; correctness first.  -include atomic_decls.h supplies the
# __atomic_* / __builtin_assume_aligned declarations that GCC 4.6 lacks.
#
# The weaken pass gives EDG's `extern __inline__` output linkonce semantics:
# it drops __always_inline__ (GCC refuses to inline a weak function) and
# adds __attribute__((__weak__)) only to functions with external linkage
# (`static` declarations only lose the inline keyword).

cat > "$WORK/weaken_inline.py" <<'PY'
#!/usr/bin/env python3
"""Give inline functions in EDG-generated C Itanium/COMDAT linkonce semantics.

EDG's C output declares inline functions `extern __inline__`.  Under GCC's
C99 inline rules that produces a strong out-of-line copy in every TU
(multiple definitions at link time).  GCC emits a weak out-of-line definition
only if the function is not `inline`, so this pass drops `__inline__` and adds
`__attribute__((__weak__))` to external-linkage functions.

Two corrections are needed for GCC's C inline rules:

  * __attribute__((__always_inline__)) must go as well: GCC refuses to inline
    a weak function and turns that into a hard error ("inlining failed in call
    to 'always_inline' ... function body can be overwritten at link time").
  * internal-linkage functions (static / anonymous namespace) must NOT get a
    weak attribute: GCC rejects it ("weak declaration of ... must be public").
    EDG splits one declaration over several lines interleaved with `# line`
    directives, and one line may contain several declarations, so track the
    declaration state token by token and decide at each `__inline__` from the
    text that precedes it (never from a later `static` inside the body).
"""
import re
import sys

WEAK = '__attribute__((__weak__))'
INLINE = re.compile(r'__inline__')
# Tokens that change the state of the declaration currently being emitted.
STATE = re.compile(r'\bstatic\b|' + re.escape(WEAK) + r'|[;{}]')


def process(path):
    pending_static = False
    decl_has_weak = False

    def scan(text):
        nonlocal pending_static, decl_has_weak
        for match in STATE.finditer(text):
            token = match.group(0)
            if token in (';', '{', '}'):
                pending_static = False
                decl_has_weak = False
            elif token == WEAK:
                decl_has_weak = True
            else:
                pending_static = True

    out = []
    with open(path, encoding='utf-8', errors='surrogateescape') as f:
        for line in f:
            if line.lstrip().startswith('#'):
                out.append(line)
                continue
            if '__always_inline__' in line:
                line = line.replace('__attribute__((__always_inline__)) ', '')
                line = line.replace('__attribute__((always_inline)) ', '')
            if '__inline__' not in line:
                scan(line)
                out.append(line)
                continue
            pieces = []
            pos = 0
            for match in INLINE.finditer(line):
                scan(line[pos:match.start()])
                pieces.append(line[pos:match.start()])
                if pending_static:
                    pass  # internal linkage: just drop __inline__
                elif decl_has_weak:
                    pass  # this declaration is already weak
                else:
                    pieces.append(WEAK)
                    decl_has_weak = True
                pos = match.end()
            pieces.append(line[pos:])
            scan(line[pos:])
            out.append(''.join(pieces))
    with open(path, 'w', encoding='utf-8', errors='surrogateescape') as f:
        f.writelines(out)


if __name__ == '__main__':
    for p in sys.argv[1:]:
        process(p)
PY
chmod +x "$WORK/weaken_inline.py"

LIBCXX_SRCS=("$LIBCXX9_SRC"/src/*.cpp)
[ -e "${LIBCXX_SRCS[0]}" ] || die "no libc++ sources found in $LIBCXX9_SRC/src"
info "stage 2: building libc++ 9 (${#LIBCXX_SRCS[@]} TUs) with EDG 7.0"

libcxx_fail=0
libcxx_count=0
for src in "${LIBCXX_SRCS[@]}"; do
  base=$(basename "$src" .cpp)
  libcxx_count=$((libcxx_count + 1))
  elog=$LOG/lcx-$base.edg.log
  glog=$LOG/lcx-$base.gcc.log
  # Run EDG inside $WORK: it writes <basename>.ti next to the current
  # directory, which must not be the repository root.
  if ! ( cd "$WORK" && timeout "$LIBCXX_TIMEOUT" "$EDG" --edg_base_dir="$EDG_BASE" \
         --c++14 --g++ --gnu_version=50000 -tused -w \
         -D__ELF__ -D_GNU_SOURCE -D_LIBCPP_BUILDING_LIBRARY -D_LIBCPP_HAS_MUSL_LIBC \
         -I "$LIBCXX_INC" \
         --sys_include="$REF/usr/include" --sys_include="$GCC_INC" \
         --gen_c_file_name="$WORK/lcx/$base.int.c" "$src" ) >"$elog" 2>&1; then
    printf 'FAIL libc++ translate %s (see %s)\n' "$base" "$elog" >&2
    tail -n 6 "$elog" >&2 || true
    libcxx_fail=$((libcxx_fail + 1))
    continue
  fi
  python3 "$WORK/weaken_inline.py" "$WORK/lcx/$base.int.c"
  if ! timeout "$CC_TIMEOUT" "$HOST_CC" -std=gnu99 -O0 -w -D_GNU_SOURCE \
         -falign-functions=16 -include "$COMPAT/atomic_decls.h" \
         -c "$WORK/lcx/$base.int.c" -o "$WORK/lcxobj/$base.o" >"$glog" 2>&1; then
    printf 'FAIL libc++ compile %s (see %s)\n' "$base" "$glog" >&2
    tail -n 6 "$glog" >&2 || true
    libcxx_fail=$((libcxx_fail + 1))
  fi
done
[ "$libcxx_fail" -eq 0 ] || die "$libcxx_fail of $libcxx_count libc++ TUs failed (see $LOG)"
"$AR" rcs "$LIBS/libc++.a" "$WORK"/lcxobj/*.o >>"$LOG/libcxx-ar.log" 2>&1 || \
  die "creating libc++.a failed (see $LOG/libcxx-ar.log)"
[ -s "$LIBS/libc++.a" ] || die "libc++.a was not produced"
LIBCXX_OBJS=$("$AR" t "$LIBS/libc++.a" | wc -l | tr -d ' ')
[ "$LIBCXX_OBJS" -eq "$libcxx_count" ] || \
  die "libc++.a contains $LIBCXX_OBJS objects, expected $libcxx_count"
info "libc++.a: $LIBCXX_OBJS objects, $(stat -c %s "$LIBS/libc++.a") bytes"

# ======================================================================
# Stage 3: weaken the EDG 7.0 runtime where it overlaps libc++
# ======================================================================
#
# libc++ defines the same standard-library entities (operator new/delete,
# typeinfo, std::terminate, ...) as EDG's runtime library.  Both are C ABIs,
# so the linker sees duplicate strong definitions.  Make the runtime copies
# weak, exactly as the earlier llvm-9-edg-7 route did: the libc++ definitions win,
# the remaining runtime definitions (EDG exception handling, static init)
# still resolve.

info "stage 3: weakening the EDG 7.0 runtime overlap with libc++"
cp "$EDG70/lib/libC.a" "$LIBS/libC_full.a"
"$NM" --defined-only "$LIBS/libc++.a"   | awk '{print $3}' | grep -v '^$' | sort -u > "$WORK/lx-syms.txt"
"$NM" --defined-only "$LIBS/libC_full.a" | awk '{print $3}' | grep -v '^$' | sort -u > "$WORK/rt-syms.txt"
comm -12 "$WORK/lx-syms.txt" "$WORK/rt-syms.txt" > "$WORK/overlap-syms.txt"
OVERLAP=$(wc -l < "$WORK/overlap-syms.txt" | tr -d ' ')
info "runtime/libc++ symbol overlap: $OVERLAP (weakening runtime copies)"
rm -rf "$WORK/rtextract" "$WORK/rtweak"
mkdir -p "$WORK/rtextract" "$WORK/rtweak"
(cd "$WORK/rtextract" && "$AR" x "$LIBS/libC_full.a")
for o in "$WORK"/rtextract/*.o; do
  b=$(basename "$o")
  common=$("$NM" --defined-only "$o" | awk '{print $3}' | grep -v '^$' | sort -u | \
           comm -12 - "$WORK/overlap-syms.txt" || true)
  if [ -n "$common" ]; then
    # shellcheck disable=SC2086
    "$OBJCOPY" $(printf -- '-W %s ' $common) "$o" "$WORK/rtweak/$b" || cp "$o" "$WORK/rtweak/$b"
  else
    cp "$o" "$WORK/rtweak/$b"
  fi
done
"$AR" rcs "$LIBS/libC_weak.a" "$WORK"/rtweak/*.o >>"$LOG/libC-weak-ar.log" 2>&1 || \
  die "creating libC_weak.a failed (see $LOG/libC-weak-ar.log)"
[ -s "$LIBS/libC_weak.a" ] || die "libC_weak.a was not produced"
info "libC_weak.a: $( "$AR" t "$LIBS/libC_weak.a" | wc -l | tr -d ' ') objects, $(stat -c %s "$LIBS/libC_weak.a") bytes"

# ======================================================================
# Stage 4: CMake C++ driver and C compiler wrapper
# ======================================================================
#
# The driver is GCC-compatible enough for CMake/Ninja:
#   * C++ source  -> EDG translation -> weaken -> GCC 4.6 compile
#   * C source    -> GCC 4.6 (musl sysroot is built in)
#   * link        -> GCC 4.6, -static, musl + libc++ + libcompat + libC_weak
#
# Several details are load-bearing and explained inline in the driver:
#   * EDG must see its -I options before --sys_include, otherwise stddef.h
#     from the compiler's include directory is not found.
#   * No _LARGEFILE64_SOURCE: musl turns fopen64/stat64/... into macros and
#     LLVM 3.5's TargetLibraryInfo.h uses those as enum names.
#   * LC_ALL=C and dual quote styles: GCC may put the reported symbol in
#     Unicode quotes; both forms are accepted.
#   * weak declarations on internal-linkage functions are stripped by the
#     compile driver, walking back over EDG's interleaved # line directives.

cat > "$DRIVER/edg-cxx" <<'DRIVER'
#!/usr/bin/env python3
"""EDG 7.0 C++ driver for CMake/Ninja (GCC 4.6 C-only + musl)."""
import os
import re
import shlex
import subprocess
import sys

os.environ["LC_ALL"] = "C"

HERE = os.path.dirname(os.path.realpath(__file__))
WORK = os.path.dirname(HERE)
REF = os.environ["EDG_REF"]
LIBCXX = os.environ["EDG_LIBCXX"]
LLVM_SRC = os.environ.get("EDG_LLVM_SRC", "")
GCC = os.environ.get("EDG_CC", "gcc")
EDG = os.path.join(WORK, "edgcpfe")
EDGDIR = os.path.join(WORK, "edg")
GCC_INC = subprocess.check_output([GCC, "-print-file-name=include"]).decode().strip()
WEAKEN = os.path.join(WORK, "weaken_inline.py")
LIB = os.path.join(WORK, "lib")
COMPAT = os.path.join(WORK, "compat")
ATOMIC_DECL = os.path.join(COMPAT, "atomic_decls.h")
# GCC 4.6 has no __atomic_* builtins; libcompat supplies them.
LIBS = ["-L" + LIB, "-lc++", "-L" + COMPAT, "-lcompat",
        "-L" + LIB, "-lC_weak", "-lm"]
DROPLIB = {"dl", "rt", "crypt", "util", "resolv", "nsl", "c",
           "supc++", "stdc++", "gcc", "gcc_s"}
try:
    EDG_TIMEOUT = int(os.environ.get("EDG_TIMEOUT", "3600"))
except ValueError:
    EDG_TIMEOUT = 3600
WEAK = '__attribute__((__weak__))'
WEAK_RE = re.compile(r"weak declaration of [\u2018']([^\u2019']+)[\u2019'] must be public")


def expand(args):
    out = []
    for a in args:
        if a.startswith("@"):
            try:
                out += expand(shlex.split(open(a[1:]).read()))
            except OSError:
                out.append(a)
        else:
            out.append(a)
    return out


def info_mode(args):
    if "--version" in args:
        sys.stdout.write(
            "gcc (GCC) 4.6.4\n"
            "Copyright (C) 2011 Free Software Foundation, Inc.\n"
            "EDG 7.0 C/C++ front end (GCC 4.6 C-only + musl) driver\n")
        return True
    for a in args:
        if a == "-dumpversion":
            print("4.6.4")
            return True
        if a == "-dumpmachine":
            print("x86_64-pc-linux-gnu")
            return True
        if a in ("-v", "-###") and not [x for x in args if not x.startswith("-")]:
            sys.stderr.write("gcc version 4.6.4 (EDG 7.0 front end)\n")
            return True
        if (a.startswith("-print-file-name=") or a.startswith("-print-prog-name=")
                or a == "-print-libgcc-file-name"):
            sys.stdout.write(subprocess.check_output([GCC, a]).decode())
            return True
    return False


def locate_weak(lines, sym):
    """Return the line index of the weak attribute belonging to `sym`, or None.

    EDG emits one declaration over several lines interleaved with `# line`
    directives, and the attribute may be on either side of the name (e.g. a
    split declaration, then `__attribute__((__weak__)) void <name>(...)`).
    Prefer the occurrence where the weak attribute is on the same line, then
    look backwards and finally forwards, never crossing a declaration
    boundary (`;` or `}`).
    """
    occ = [i for i, line in enumerate(lines) if sym in line]
    if not occ:
        return None
    for i in occ:
        if WEAK in lines[i]:
            return i
    for i in occ:
        j = i - 1
        steps = 0
        while j >= 0 and steps < 60:
            line = lines[j]
            if line.lstrip().startswith('#'):
                j -= 1
                steps += 1
                continue
            if ';' in line or '}' in line:
                break
            if WEAK in line:
                return j
            j -= 1
            steps += 1
    for i in occ:
        j = i + 1
        steps = 0
        while j < len(lines) and steps < 60:
            line = lines[j]
            if line.lstrip().startswith('#'):
                j += 1
                steps += 1
                continue
            if WEAK in line:
                return j
            if ';' in line or '}' in line:
                break
            j += 1
            steps += 1
    return None


def strip_weak(gen, syms):
    """Remove weak attributes attached to internal-linkage functions."""
    lines = open(gen, encoding='utf-8', errors='surrogateescape').read().split('\n')
    changed = 0
    for sym in syms:
        j = locate_weak(lines, sym)
        if j is None:
            continue
        new = lines[j].replace(WEAK + ' ', '').replace(' ' + WEAK, '')
        if new != lines[j]:
            lines[j] = new
            changed += 1
    if changed:
        open(gen, 'w', encoding='utf-8', errors='surrogateescape').write('\n'.join(lines))
    return changed


def compile_generated(gen, cmd):
    """Compile EDG-generated C; retry after stripping weak attributes that the
    GCC rejects for internal-linkage symbols."""
    r = subprocess.run(cmd, capture_output=True)
    if r.returncode == 0:
        return True
    err = r.stderr.decode(errors='replace')
    syms = sorted(set(WEAK_RE.findall(err)))
    if not syms:
        sys.stderr.write(err)
        return False
    # Cheap convergence loop: -fsyntax-only parses the (huge) generated file
    # much faster than code generation.
    i = cmd.index("-c") if "-c" in cmd else None
    if i is not None:
        syn = cmd[:i] + ["-fsyntax-only", gen]
        for _ in range(300):
            rs = subprocess.run(syn, capture_output=True)
            if rs.returncode == 0:
                break
            serr = rs.stderr.decode(errors='replace')
            ssyms = sorted(set(WEAK_RE.findall(serr)))
            if not ssyms:
                sys.stderr.write(serr)
                return False
            if strip_weak(gen, ssyms) == 0:
                sys.stderr.write(serr)
                return False
        else:
            sys.stderr.write("edg: could not eliminate weak internal-linkage declarations\n")
            return False
    r = subprocess.run(cmd, capture_output=True)
    if r.returncode == 0:
        return True
    sys.stderr.write(r.stderr.decode(errors='replace'))
    return False


args = expand(sys.argv[1:])
if info_mode(args):
    sys.exit(0)

inc, defs, undefs, preincludes = [], [], [], []
cxx_std = "c++14"
exceptions = True
rtti = True
opt = "0"
pic = []
sources, objects, linkflags = [], [], []
mode_c = mode_E = False
out = depfile = dep_target = lang = None
i = 0
while i < len(args):
    a = args[i]
    nxt = args[i + 1] if i + 1 < len(args) else None
    if a == "-c":
        mode_c = True
    elif a == "-E":
        mode_E = True
    elif a == "-shared":
        linkflags.append(a)
    elif a == "-o":
        out = nxt
        i += 1
    elif a.startswith("-o") and len(a) > 2:
        out = a[2:]
    elif a == "-I":
        inc.append(nxt)
        i += 1
    elif a.startswith("-I"):
        inc.append(a[2:])
    elif a in ("-isystem", "-iquote", "-idirafter"):
        inc.append(nxt)
        i += 1
    elif a.startswith("-isystem"):
        inc.append(a[len("-isystem"):])
    elif a == "-D":
        defs.append(nxt)
        i += 1
    elif a.startswith("-D"):
        defs.append(a[2:])
    elif a == "-U":
        undefs.append(nxt)
        i += 1
    elif a.startswith("-U"):
        undefs.append(a[2:])
    elif a == "-include":
        preincludes.append(nxt)
        i += 1
    elif a.startswith("-include"):
        preincludes.append(a[len("-include"):])
    elif a in ("-MF", "-MT", "-MQ"):
        v = nxt
        i += 1
        if a == "-MF":
            depfile = v
        else:
            dep_target = v
    elif a.startswith("-MF"):
        depfile = a[3:]
    elif a.startswith("-MT"):
        dep_target = a[3:]
    elif a.startswith("-MQ"):
        dep_target = a[3:]
    elif a in ("-MD", "-MMD", "-MP", "-M", "-MM"):
        pass
    elif a == "-x":
        lang = nxt
        i += 1
    elif a.startswith("-std="):
        m = re.match(r"(gnu|c)\+\+(\w+)", a[5:])
        if m:
            v = {"0x": "11", "1y": "14", "1z": "17", "2a": "20", "2b": "23"}.get(m.group(2), m.group(2))
            cxx_std = "c++" + v
    elif a == "-fno-exceptions":
        exceptions = False
    elif a == "-fexceptions":
        exceptions = True
    elif a == "-fno-rtti":
        rtti = False
    elif a == "-frtti":
        rtti = True
    elif a.startswith("-O"):
        lvl = a[2:] or "1"
        # EDG output is huge; cap the generated-C optimisation at -O1.
        opt = "0" if lvl == "0" else "1"
    elif a in ("-fPIC", "-fpic", "-fPIE", "-fpie"):
        pic.append(a)
    elif a in ("-g", "-g0", "-g1", "-g2", "-g3", "-ggdb", "-w", "-pipe", "-s",
               "-pthread", "-Qunused-arguments", "-nostdinc++", "-rdynamic",
               "-fno-strict-aliasing", "-fstrict-aliasing"):
        if a == "-pthread":
            linkflags.append(a)
    elif a.startswith("-f") or a.startswith("-W") or a.startswith("-m") \
            or a.startswith("-g") or a.startswith("-pedantic") or a.startswith("-ansi"):
        pass
    elif a in ("-L", "-l"):
        v = nxt
        i += 1
        if a == "-L":
            linkflags.append("-L" + v)
        elif v not in DROPLIB:
            linkflags.append("-l" + v)
    elif a.startswith("-L"):
        linkflags.append(a)
    elif a.startswith("-l"):
        if a[2:] not in DROPLIB:
            linkflags.append(a)
    elif a.startswith("-Wl,"):
        linkflags.append(a)
    elif a in ("-static", "-nostdlib", "-nostartfiles", "-nodefaultlibs"):
        linkflags.append(a)
    elif a.startswith("-"):
        pass
    else:
        ext = os.path.splitext(a)[1]
        if ext in (".cpp", ".cc", ".cxx", ".c++", ".C", ".CPP"):
            sources.append(a)
        elif ext == ".c" and lang != "c++":
            sources.append(a)
        elif ext in (".o", ".a", ".so", ".obj"):
            objects.append(a)
        else:
            sources.append(a)
    i += 1


def edg_args(src):
    a = [EDG, "--edg_base_dir=" + EDGDIR, "--" + cxx_std, "--g++",
         "--gnu_version=50000", "-tused", "-w",
         "-D__ELF__", "-D_GNU_SOURCE", "-D_LIBCPP_HAS_MUSL_LIBC"]
    if not exceptions:
        a.append("--no_exceptions")
    if not rtti:
        a.append("--no_rtti")
    # -I options must come before --sys_include (EDG lookup order).
    a.append("-I" + LIBCXX)
    for d in inc:
        a.append("-I" + os.path.abspath(d))
    for d in defs:
        a.append("-D" + d)
    for d in undefs:
        a.append("-U" + d)
    # EDG 7.0 lookup bug: after llvm/lib/Support/Unix/Unix.h's MakeErrMsg is
    # parsed, unqualified lookup of llvm::detail becomes ambiguous.  Parsing
    # StringExtras.h first avoids the broken state.  Needed for LLVM's own
    # sources only, and only resolvable when the LLVM include dir is on -I.
    if LLVM_SRC and os.path.abspath(src).startswith(LLVM_SRC + os.sep):
        a.append("--preinclude=" + os.path.join(LLVM_SRC, "llvm", "include",
                                                "llvm", "ADT", "StringExtras.h"))
    for p in preincludes:
        a.append("--preinclude=" + os.path.abspath(p))
    a.append("--sys_include=" + REF + "/usr/include")
    a.append("--sys_include=" + GCC_INC)
    return a


if mode_E:
    if not sources:
        sys.exit(0)
    sys.exit(subprocess.run(edg_args(sources[0]) + ["-E", os.path.abspath(sources[0])],
                            cwd=EDGDIR).returncode)

objs = []
for src in sources:
    src = os.path.abspath(src)
    base = os.path.splitext(os.path.basename(src))[0]
    if os.path.splitext(src)[1] == ".c":
        # CMake compiles the handful of C sources with the same driver; honour
        # the requested -o path (otherwise objects land in the build root).
        if mode_c and len(sources) == 1 and out:
            obj = out
        elif out:
            obj = os.path.join(os.path.dirname(os.path.abspath(out)), base + ".o")
        else:
            obj = os.path.join(os.getcwd(), base + ".o")
        obj = os.path.abspath(obj)
        cmd = [GCC, "-std=gnu99", "-c", "-o", obj]
        cmd += ["-I" + d for d in inc] + ["-D" + d for d in defs]
        cmd += pic + ["-O" + opt, "-w", "-D_GNU_SOURCE", src]
        if subprocess.run(cmd).returncode:
            sys.exit(1)
        objs.append(obj)
        if depfile:
            with open(depfile, "w") as f:
                f.write("%s: %s\n" % (dep_target or obj, src))
        continue
    if mode_c and len(sources) == 1 and out:
        obj = out
    elif out:
        obj = os.path.join(os.path.dirname(os.path.abspath(out)), base + ".o")
    else:
        obj = os.path.join(os.getcwd(), base + ".o")
    obj = os.path.abspath(obj)
    gen = obj + ".edg.c"
    a = edg_args(src) + ["--gen_c_file_name=" + gen, src]
    try:
        rc = subprocess.run(a, cwd=EDGDIR, timeout=EDG_TIMEOUT).returncode
    except subprocess.TimeoutExpired:
        sys.stderr.write("edg: translation timed out after %ds: %s\n" % (EDG_TIMEOUT, src))
        sys.exit(124)
    if rc:
        sys.stderr.write("edg: translation failed: %s\n" % src)
        sys.exit(rc)
    subprocess.run([sys.executable, WEAKEN, gen])
    # Function alignment is load-bearing: EDG encodes a pointer-to-member
    # function's virtual bit in the low bit of its function pointer and tests
    # it at run time.  At -O1 GCC aligns functions to 1 byte, so a function at
    # an odd address is mistaken for a virtual member and crashes.
    #
    # atomic_decls.h declares the __atomic_* entry points that EDG emits and
    # GCC 4.6 does not know; the definitions come from libcompat.a.
    cmd = [GCC, "-std=gnu99", "-O" + opt, "-w",
           "-D_GNU_SOURCE", "-falign-functions=16",
           "-include", ATOMIC_DECL] + pic
    cmd += ["-c", gen, "-o", obj]
    if not compile_generated(gen, cmd):
        sys.stderr.write("edg: gcc failed on generated C for %s\n" % src)
        sys.exit(1)
    objs.append(obj)
    if depfile:
        with open(depfile, "w") as f:
            f.write("%s: %s\n" % (dep_target or obj, src))

if mode_c:
    sys.exit(0)
if not objs and not objects:
    sys.exit(0)
exe = out or "a.out"
cmd = [GCC, "-static", "-o", exe] + objs + objects + linkflags
cmd += LIBS + ["-Wl,-z,noexecstack"]
sys.exit(subprocess.run(cmd).returncode)
DRIVER
chmod +x "$DRIVER/edg-cxx"

cat > "$DRIVER/cc46" <<EOF
#!/usr/bin/env bash
# C compiler wrapper: C-only GCC 4.6.4 from the reference rootfs.  Its musl
# sysroot is hard-coded at configure time, so no --sysroot is passed here.
# Flags introduced by newer GCC versions are filtered out: CMake probes the
# C++ driver (which ignores unknown flags) and may then pass them to C too.
set -e
args=()
for a in "\$@"; do
  case "\$a" in
    -fdiagnostics-color*|-fno-diagnostics-color*|-fmacro-prefix-map=*|-fdebug-prefix-map=*)
      ;;
    *)
      args+=("\$a")
      ;;
  esac
done
exec "$HOST_CC" -std=gnu99 "\${args[@]}"
EOF
chmod +x "$DRIVER/cc46"

# The driver reads its configuration from the environment; export it before
# any invocation (the self-check below included).
export EDG_REF="$REF" EDG_LIBCXX="$LIBCXX_INC" EDG_LLVM_SRC="$SRC" EDG_TIMEOUT EDG_CC="$HOST_CC"
"$DRIVER/edg-cxx" --version | grep -q '4.6.4' || die "driver --version self-check failed"
"$DRIVER/cc46" --version >/dev/null 2>&1 || die "cc46 self-check failed"
info "driver: $DRIVER/edg-cxx (EDG 7.0 -> GCC $HOST_CC_VERSION C-only -> musl)"

# ======================================================================
# Stage 5: source copy and compatibility patches
# ======================================================================
#
# Sources are copied so patches never touch the read-only checkouts.  Only
# patches that are strictly required are applied; each one is documented.

info "stage 5: copying LLVM 3.5 sources and applying compatibility patches"
# Re-copy from pristine sources each run (also when KEEP_WORK=1): cp -a into an
# existing directory would otherwise nest llvm/llvm.  Timestamps are preserved,
# so a preserved build tree only rebuilds what the patch really changed.
rm -rf "$SRC/llvm" "$SRC/clang"
cp -a "$LLVM35_SRC/llvm"  "$SRC/llvm"
cp -a "$LLVM35_SRC/clang" "$SRC/clang"

python3 - "$SRC/llvm/lib/Support/DynamicLibrary.cpp" <<'PY' || die "DynamicLibrary.cpp patch failed"
import sys
p = sys.argv[1]
s = open(p).read()
old = "#define EXPLICIT_SYMBOL(SYM) \\\n   if (!strcmp(symbolName, #SYM)) return &SYM"
new = "#define EXPLICIT_SYMBOL(SYM) \\\n   if (!strcmp(symbolName, #SYM)) return (void *)&SYM"
if new in s:
    sys.exit(0)
if old not in s:
    raise SystemExit("EXPLICIT_SYMBOL definition not found in %s" % p)
open(p, "w").write(s.replace(old, new))
PY
grep -q 'return (void \*)&SYM' "$SRC/llvm/lib/Support/DynamicLibrary.cpp" || \
  die "DynamicLibrary.cpp patch was not applied"
# Patch #1: musl declares stdin/stdout/stderr as `FILE *const`, so &SYM has
# type FILE *const * and does not convert to void *.  A C-style cast fixes it.

python3 - "$SRC/llvm/include/llvm/ADT/IntrusiveRefCntPtr.h" <<'PY' || die "IntrusiveRefCntPtr.h patch failed"
import sys
p = sys.argv[1]
s = open(p).read()
friend = "    template <typename X> friend class IntrusiveRefCntPtr;\n"
if friend in s:
    sys.exit(0)
old = "    T* Obj;\n\n  public:"
new = "    T* Obj;\n" + friend + "\n  public:"
if old not in s:
    raise SystemExit("IntrusiveRefCntPtr layout not found in %s" % p)
open(p, "w").write(s.replace(old, new))
PY
grep -q 'friend class IntrusiveRefCntPtr' "$SRC/llvm/include/llvm/ADT/IntrusiveRefCntPtr.h" || \
  die "IntrusiveRefCntPtr.h patch was not applied"
# Patch #2: C++11 allows a member of a class template to access private members
# of any specialization of the same template (GCC and clang accept it), but
# EDG 7.0 rejects `S.Obj` in the templated move constructor.  An explicit
# friend declaration makes the intended access control unambiguous.

# ======================================================================
# Stage 6: driver smoke tests (libc++ + EDG runtime + musl, static)
# ======================================================================

info "stage 6: driver smoke tests"
cat > "$TESTS/vector_string.cpp" <<'EOF'
#include <algorithm>
#include <string>
#include <vector>
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
#include <stdexcept>
#include <string>
#include <vector>
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
#include <iostream>
#include <string>
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

run_driver_test() {
  local name=$1
  shift
  local log=$LOG/smoke-$name.log
  if ! timeout "$CC_TIMEOUT" "$DRIVER/edg-cxx" "$@" >"$log" 2>&1; then
    tail -n 10 "$log" >&2 || true
    die "smoke test '$name' did not compile/link (see $log)"
  fi
}

run_driver_test vector_string "$TESTS/vector_string.cpp" -o "$TESTS/vector_string"
"$TESTS/vector_string" || die "smoke test vector_string failed at run time"

run_driver_test iostream_eh "$TESTS/iostream_eh.cpp" -o "$TESTS/iostream_eh"
IOUT=$("$TESTS/iostream_eh") || die "smoke test iostream_eh failed at run time"
printf '%s\n' "$IOUT"
printf '%s\n' "$IOUT" | grep -q 'hello 3'        || die "unexpected iostream output"
printf '%s\n' "$IOUT" | grep -q 'stoi=42'        || die "unexpected stoi output"
printf '%s\n' "$IOUT" | grep -q 'caught: vector' || die "out_of_range was not caught"

run_driver_test multi_tu "$TESTS/multi_tu_a.cpp" "$TESTS/multi_tu_b.cpp" -o "$TESTS/multi_tu"
MTOUT=$("$TESTS/multi_tu") || die "smoke test multi_tu failed at run time"
[ "$MTOUT" = "multi-tu 2" ] || die "unexpected multi_tu output: '$MTOUT'"
info "smoke tests passed (libc++/STL, iostream + exceptions, multi-TU)"

# ======================================================================
# Stage 7: CMake configuration
# ======================================================================

info "stage 7: configuring LLVM 3.5 (CMake + Ninja)"
cmake_common=(
  -G Ninja
  -DCMAKE_C_COMPILER="$DRIVER/cc46"
  -DCMAKE_CXX_COMPILER="$DRIVER/edg-cxx"
  -DCMAKE_ASM_COMPILER="$HOST_CC"
  -DCMAKE_AR="$AR"
  -DCMAKE_RANLIB="$RANLIB"
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  -DLLVM_TARGETS_TO_BUILD=X86
  -DLLVM_EXTERNAL_CLANG_SOURCE_DIR="$SRC/clang"
  -DLLVM_INCLUDE_TESTS=OFF
  -DLLVM_INCLUDE_DOCS=OFF
  -DLLVM_INCLUDE_EXAMPLES=OFF
  -DLLVM_ENABLE_ASSERTIONS=OFF
  -DLLVM_ENABLE_TERMINFO=OFF
  -DLLVM_ENABLE_ZLIB=OFF
  -DCLANG_ENABLE_ARCMT=OFF
  -DCLANG_ENABLE_STATIC_ANALYZER=OFF
  -DCMAKE_C_FLAGS="-O2 -w"
  -DCMAKE_CXX_FLAGS="-O2 -w"
  -DCMAKE_EXE_LINKER_FLAGS="-static"
)
if ! timeout "$CONFIGURE_TIMEOUT" cmake -S "$SRC/llvm" -B "$BUILD" "${cmake_common[@]}" \
       >"$LOG/cmake-configure.log" 2>&1; then
  tail -n 30 "$LOG/cmake-configure.log" >&2 || true
  die "LLVM CMake configuration failed (see $LOG/cmake-configure.log)"
fi
info "CMake configured: $BUILD"

# ======================================================================
# Stage 8: build milestones
# ======================================================================

# ---------------------------------------------------------- llvm-tblgen ---
info "stage 8a: building llvm-tblgen (-j $JOBS)"
if ! timeout "$TBLGEN_TIMEOUT" ninja -C "$BUILD" -j "$JOBS" llvm-tblgen \
       >"$LOG/tblgen-build.log" 2>&1; then
  grep -E '^FAILED:' "$LOG/tblgen-build.log" | sed 's/^ *//' | sort -u > "$LOG/failures-tblgen.txt" || true
  printf 'error: llvm-tblgen build failed\n' >&2
  cat "$LOG/failures-tblgen.txt" >&2 2>/dev/null || true
  die "llvm-tblgen build failed (see $LOG/tblgen-build.log)"
fi
TBLGEN=$BUILD/bin/llvm-tblgen
[ -x "$TBLGEN" ] || die "llvm-tblgen was not produced"
"$TBLGEN" --version 2>&1 | grep -q 'LLVM version 3.5' || die "unexpected llvm-tblgen version"
info "llvm-tblgen: $("$TBLGEN" --version 2>&1 | sed -n '2p')"
if ! timeout 900 "$TBLGEN" --print-records "$SRC/llvm/lib/Target/X86/X86.td" \
       -I "$SRC/llvm/include" -I "$SRC/llvm/lib/Target/X86" \
       >"$LOG/tblgen-x86-records.txt" 2>"$LOG/tblgen-x86.log"; then
  tail -n 10 "$LOG/tblgen-x86.log" >&2 || true
  die "llvm-tblgen failed on X86.td (see $LOG/tblgen-x86.log)"
fi
info "llvm-tblgen X86.td records: $(wc -l < "$LOG/tblgen-x86-records.txt") lines"

if [ "$STOP_AFTER" = "tblgen" ]; then
  info "stopping after llvm-tblgen (STOP_AFTER=tblgen)"
  STOPPED_AT=tblgen
fi

# ------------------------------------------------- LLVM libraries/tools ---
if [ "${STOPPED_AT:-}" != "tblgen" ]; then
  info "stage 8b: building LLVM 3.5 libraries and core tools (-j $JOBS)"
  set +e
  timeout "$LLVM_TIMEOUT" ninja -C "$BUILD" -j "$JOBS" \
    llc opt llvm-config llvm-ar llvm-nm llvm-size llvm-objdump \
    llvm-readobj llvm-link llvm-as llvm-dis \
    >"$LOG/llvm-build.log" 2>&1
  llvm_rc=$?
  set -e
  if [ "$llvm_rc" -ne 0 ]; then
    grep -E '^FAILED:' "$LOG/llvm-build.log" | sed 's/^ *//' | sort -u > "$LOG/failures-llvm.txt" || true
    printf 'warning: LLVM build finished with failures (see %s)\n' "$LOG/failures-llvm.txt" >&2
    cat "$LOG/failures-llvm.txt" >&2 2>/dev/null || true
    die "LLVM libraries/tools build failed (rc=$llvm_rc, see $LOG/llvm-build.log)"
  fi
  for tool in llc opt llvm-config; do
    [ -x "$BUILD/bin/$tool" ] || die "bin/$tool was not produced"
  done
  info "LLVM tools: $(ls "$BUILD"/bin/llvm-* "$BUILD"/bin/llc "$BUILD"/bin/opt 2>/dev/null | wc -l | tr -d ' ') binaries"
  if [ "$STOP_AFTER" = "llvm" ]; then
    info "stopping after the LLVM libraries (STOP_AFTER=llvm)"
    STOPPED_AT=llvm
  fi
fi

# ----------------------------------------------------------------- clang ---
if [ "${STOPPED_AT:-}" = "" ]; then
  info "stage 8c: building clang 3.5 (-j $JOBS)"
  set +e
  timeout "$CLANG_TIMEOUT" ninja -C "$BUILD" -j "$JOBS" clang \
    >"$LOG/clang-build.log" 2>&1
  clang_rc=$?
  set -e
  if [ "$clang_rc" -ne 0 ]; then
    grep -E '^FAILED:' "$LOG/clang-build.log" | sed 's/^ *//' | sort -u > "$LOG/failures-clang.txt" || true
    printf 'warning: clang build finished with failures (see %s)\n' "$LOG/failures-clang.txt" >&2
    cat "$LOG/failures-clang.txt" >&2 2>/dev/null || true
    die "clang build failed (rc=$clang_rc, see $LOG/clang-build.log)"
  fi
  [ -x "$BUILD/bin/clang" ] || die "clang was not produced"
  "$BUILD/bin/clang" --version 2>&1 | grep -q 'clang version 3.5' || \
    die "unexpected clang version"
  info "clang: $("$BUILD/bin/clang" --version 2>&1 | head -n 1)"
  STOPPED_AT=clang
fi

# ======================================================================
# Stage 9: verification and summary
# ======================================================================

info "stage 9: verification"
VERIFY_ROWS=()
verify_static() {
  local file=$1
  local desc=$2
  local real
  real=$(readlink -f "$file" 2>/dev/null || printf '%s' "$file")
  [ -x "$real" ] || { VERIFY_ROWS+=("$desc|MISSING"); return 1; }
  local kind
  kind=$(file -b "$real")
  if ! printf '%s' "$kind" | grep -q 'statically linked'; then
    VERIFY_ROWS+=("$desc|NOT STATIC: $kind")
    return 1
  fi
  if readelf -d "$real" 2>/dev/null | grep -q 'NEEDED'; then
    VERIFY_ROWS+=("$desc|HAS NEEDED ENTRIES")
    return 1
  fi
  VERIFY_ROWS+=("$desc|ok ($(stat -c %s "$real") bytes, static)")
  return 0
}

verify_static "$BUILD/bin/llvm-tblgen" "llvm-tblgen" || true
if [ -x "$BUILD/bin/llc" ]; then verify_static "$BUILD/bin/llc" "llc" || true; fi
if [ -x "$BUILD/bin/clang" ]; then verify_static "$BUILD/bin/clang" "clang" || true; fi

# C program through the freshly built clang, static musl.
CLANG_C_OK=no
if [ -x "$BUILD/bin/clang" ]; then
  cat > "$TESTS/clang_c.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(void) {
  char *p = malloc(16);
  strcpy(p, "clang-musl");
  printf("%s %d\n", p, (int)strlen(p));
  free(p);
  return 0;
}
EOF
  # clang 3.5's driver looks for crtbeginT.o/-lgcc inside the --sysroot, and
  # the musl rootfs does not contain a GCC installation.  Compile with clang
  # and link the object with GCC 4.6 (which knows its own libgcc); the
  # resulting program is still a static musl binary.
  if timeout 600 "$BUILD/bin/clang" --sysroot="$REF" -static -O2 -w -c \
       -o "$TESTS/clang_c.o" "$TESTS/clang_c.c" >"$LOG/clang-c.log" 2>&1 && \
     timeout 600 "$HOST_CC" -static -Wl,-z,noexecstack -o "$TESTS/clang_c" \
       "$TESTS/clang_c.o" >>"$LOG/clang-c.log" 2>&1 && \
     [ "$("$TESTS/clang_c")" = "clang-musl 10" ]; then
    CLANG_C_OK=yes
  else
    warn "clang could not compile a static musl C program (see $LOG/clang-c.log)"
  fi
fi

# clang++ compile-only (libc++ headers built for musl); linking/running C++
# with the EDG-built libc++ is a known limitation of the EDG exception model,
# so this is reported, not required.
CLANG_CXX_OK=no
if [ -x "$BUILD/bin/clang" ]; then
  cat > "$TESTS/clang_cxx.cpp" <<'EOF'
#include <string>
#include <vector>
int main() { std::vector<std::string> v{"a", "b"}; return (int)v.size() - 2; }
EOF
  if timeout 600 "$BUILD/bin/clang" -x c++ -std=c++11 -fsyntax-only \
       -nostdinc++ -isystem "$LIBCXX_INC" -D_LIBCPP_HAS_MUSL_LIBC \
       --sysroot="$REF" "$TESTS/clang_cxx.cpp" >"$LOG/clang-cxx.log" 2>&1; then
    CLANG_CXX_OK=yes
  else
    warn "clang++ syntax check of libc++ headers failed (see $LOG/clang-cxx.log)"
  fi
fi

# bwrap: only the build tree (and the musl sysroot) visible.
BWRAP_OK=skipped
if [ -x "$BUILD/bin/clang" ] && command -v bwrap >/dev/null 2>&1 && [ "$CLANG_C_OK" = yes ]; then
  # Compile inside bwrap with only the build tree and the musl rootfs visible,
  # then run the already-linked static binary in an empty namespace.
  if bwrap --unshare-pid --die-with-parent --tmpfs / \
       --ro-bind "$BUILD" /tool --ro-bind "$REF" /ref \
       --bind "$TESTS" /work --dev /dev --proc /proc --tmpfs /tmp \
       /tool/bin/clang --sysroot=/ref -O2 -w -c /work/clang_c.c -o /work/clang_c_bwrap.o \
       >"$LOG/bwrap.log" 2>&1 && \
     [ -s "$TESTS/clang_c_bwrap.o" ] && \
     [ "$(bwrap --unshare-pid --die-with-parent --tmpfs / \
          --ro-bind "$TESTS/clang_c" /hello --dev /dev --proc /proc /hello)" = "clang-musl 10" ]; then
    BWRAP_OK=yes
  else
    BWRAP_OK=no
    warn "bwrap verification failed (see $LOG/bwrap.log)"
  fi
fi

END=$(date +%s)
ELAPSED=$((END - START))

{
  printf 'LLVM/Clang 3.5.2 built by EDG 7.0 + GCC 4.6 (C only) + musl\n'
  printf 'date (UTC)     : %s\n' "$START_UTC"
  printf 'stopped after  : %s\n' "${STOPPED_AT:-tblgen}"
  printf 'EDG front end  : %s\n' "$EDG_VERSION"
  printf 'C compiler     : %s %s (%s)\n' "$HOST_CC" "$HOST_CC_VERSION" "$HOST_TRIPLE"
  printf 'target libc    : %s (musl, static)\n' "$REF"
  printf 'compat layer   : %s (%s bytes)\n' "$COMPAT/libcompat.a" "$(stat -c %s "$COMPAT/libcompat.a")"
  printf 'libc++         : %s (%s objects, %s bytes)\n' "$LIBS/libc++.a" "$LIBCXX_OBJS" "$(stat -c %s "$LIBS/libc++.a")"
  printf 'EDG runtime    : %s (%s bytes, %s libc++ symbols weakened)\n' "$LIBS/libC_weak.a" "$(stat -c %s "$LIBS/libC_weak.a")" "$OVERLAP"
  printf 'CMake driver   : %s\n' "$DRIVER/edg-cxx"
  printf 'build tree     : %s\n' "$BUILD"
  printf 'jobs           : %s\n' "$JOBS"
  printf 'elapsed        : %s s\n' "$ELAPSED"
  printf '\n'
  printf 'verification:\n'
  for row in "${VERIFY_ROWS[@]}"; do
    printf '  %-14s %s\n' "${row%%|*}" "${row#*|}"
  done
  printf '  %-14s %s\n' 'clang C' "$CLANG_C_OK"
  printf '  %-14s %s\n' 'clang C++ hdr' "$CLANG_CXX_OK"
  printf '  %-14s %s\n' 'bwrap' "$BWRAP_OK"
  printf '\n'
  printf 'artifacts:\n'
  for f in "$BUILD/bin/llvm-tblgen" "$BUILD/bin/llc" "$BUILD/bin/opt" "$BUILD/bin/clang"; do
    [ -e "$f" ] && printf '  %-44s %s bytes\n' "$f" "$(stat -Lc %s "$f")"
  done
  printf '\n'
  printf 'patches:\n'
  printf '  llvm/lib/Support/DynamicLibrary.cpp: (void *)&SYM for musl FILE *const\n'
  printf '  llvm/include/llvm/ADT/IntrusiveRefCntPtr.h: friend declaration for EDG\n'
  printf '  generated C: -falign-functions=16 (Itanium member-pointer low bit)\n'
  printf '\n'
  printf 'known limitations:\n'
  printf '  - libc++ is built by EDG, so it uses EDG setjmp-based exceptions; C++\n'
  printf '    binaries built by this clang++ with the EDG-built libc++ do not\n'
  printf '    interoperate with Itanium EH.  A libc++ built by clang is\n'
  printf '    future work.\n'
  printf '  - clang 3.5 driver searches crtbeginT.o/-lgcc inside --sysroot; the musl\n'
  printf '    rootfs has no GCC installation, so clang -static links are done by\n'
  printf '    compiling with clang and linking with GCC 4.6.\n'
  printf '  - GCC 4.6 is C-only and has no __atomic_* builtins; EDG-generated C is\n'
  printf '    compiled with libcompat.a, and generated C is optimized at most -O1.\n'
} > "$WORK/build-info.txt"

# ---------------------------------------------------------- read-only ---

if command -v git >/dev/null 2>&1; then
  GIT_LLVM_AFTER=$(git -C "$LLVM35_SRC" status --porcelain 2>/dev/null || true)
  GIT_CXX_AFTER=$(git -C "$LIBCXX9_SRC" status --porcelain 2>/dev/null || true)
  [ "$GIT_LLVM_AFTER" = "$GIT_LLVM_BEFORE" ] || \
    die "read-only source tree was modified: $LLVM35_SRC"
  [ "$GIT_CXX_AFTER" = "$GIT_CXX_BEFORE" ] || \
    die "read-only source tree was modified: $LIBCXX9_SRC"
fi
REF_WRITES=$(find -L "$REF" -newer "$WORK/.start" -print -quit 2>/dev/null || true)
[ -z "$REF_WRITES" ] || die "the reference rootfs was modified during the build: $REF_WRITES"

info "done"
printf '\n'
printf 'stopped after : %s\n' "${STOPPED_AT:-tblgen}"
printf 'build tree    : %s\n' "$BUILD"
printf 'tools         : %s\n' "$(ls "$BUILD"/bin/llvm-tblgen "$BUILD"/bin/llc "$BUILD"/bin/opt "$BUILD"/bin/clang 2>/dev/null | tr '\n' ' ')"
printf 'libc++        : %s (%s objects)\n' "$LIBS/libc++.a" "$LIBCXX_OBJS"
printf 'runtime       : %s (%s symbols weakened)\n' "$LIBS/libC_weak.a" "$OVERLAP"
printf 'build info    : %s\n' "$WORK/build-info.txt"
printf 'logs          : %s\n' "$LOG"
printf 'elapsed       : %s s\n' "$ELAPSED"
