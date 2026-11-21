#!/bin/bash
# onramp-pnut-tcc-fc1fc50f-20261120.sh
#
# Build the tinycc/tinycc checkout at commit fc1fc50f (version 0.9.28rc,
# 2026-11-20, the "tinycc (lnk)" tree in ../tcc/tinycc) with the pnut compiler
# that was built by onramp-to-pnut-exe.sh.
#
# This script deliberately does NOT rebuild pnut-exe.  It assumes that
# onramp-to-pnut-exe.sh has already been run successfully, i.e. that
# build-onramp-exe/pnut-exe-by-pnut-exe exists.  Run it as:
#
#     ./onramp-to-pnut-exe.sh          # once, builds the Onramp pnut
#     ./onramp-pnut-tcc-0.9.27.sh      # optional: TCC 0.9.27 from pnut kit
#     ./onramp-pnut-tcc-fc1fc50f-20261120.sh   # this script: tinycc fc1fc50f
#
# Build steps:
#   1. copy pnut sources, apply ../patches/pnut-portable-libc.patch so that
#      pnut.c and the portable libc do not both define strlen/memcpy/strrchr;
#   2. two-stage pnut-exe-for-tcc:
#        C1 = seed pnut compiles pnut.c (NO_BUILTIN_LIBC, no libc)
#        C2 = C1 compiles pnut.c + portable libc (PNUT_PORTABLE_LIBC)
#      C2 has working diagnostics and does not emit pnut's builtin runtime;
#   3. copy the tinycc source, apply ../patches/tinycc-fc1fc50f-pnut.patch and
#      install a config.h (tinycc's configure normally generates it);
#   4. compile tcc.c + portable libc + ../patches/pnut-tcc-compat.c with C2;
#   5. verify tcc-pnut -v, then compile the runtime and test objects and link
#      them with tcc-pnut itself (no host gcc or binutils).
#
# The pnut-built TCC compiles and links the test programs itself.  Archive
# (-l) linking is still not supported because pnut's portable libc is missing
# behaviour TCC's archive reader relies on; this is documented in README.
#
# Artifacts (under build-pnut-tinycc/):
#   C1, pnut-exe-for-tcc       bootstrap compilers
#   tcc-src/                   patched tinycc source
#   bin/tcc-pnut               the TCC built by pnut
#   bin/tiny.o, bin/hello.o    objects produced by tcc-pnut

set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")

onramp="$root/base-onramp/onramp"
pnut="$here/pnut"
patches="$here/patches"
build="$here/build-pnut-tinycc"

vm="$onramp/output/posix/bin/onrampvm"
seed="$here/build-onramp-exe/pnut-exe-by-pnut-exe"

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
    sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h) usage ;;
        *) echo "ERROR: unknown option: $1" >&2; usage ;;
    esac
done

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
[ -e "$vm" ] || die "Onramp is not built; see ../base-onramp/report-onramp.md"
[ -x "$seed" ] || die "$seed is missing.
Run ./onramp-to-pnut-exe.sh first: this script builds on the pnut-exe it produces."
if [ -f "$here/build-onramp-exe/.target" ]; then
    target=$(cat "$here/build-onramp-exe/.target")
    [ "$target" = x86_64 ] || die "pnut-exe was built for '$target', but this
script only supports the x86_64 pnut-exe.  Rebuild it with:
    ./onramp-to-pnut-exe.sh --force"
fi
[ -d "$pnut" ] || die "pnut sources not found: $pnut"
[ -d "$patches" ] || die "patches directory not found: $patches"

# tinycc is normally a symlink to ../../tcc/tinycc; resolve it.
[ -e "$here/tinycc" ] || die "tinycc sources not found: $here/tinycc"
tcc_src_real=$(readlink -f "$here/tinycc")
[ -f "$tcc_src_real/tcc.c" ] || die "$tcc_src_real does not look like tinycc (no tcc.c)"
[ -f "$tcc_src_real/VERSION" ] || die "$tcc_src_real/VERSION not found"

tcc_version=$(cat "$tcc_src_real/VERSION")
tcc_version=${tcc_version%$'\n'}

if command -v git > /dev/null 2>&1 && [ -d "$tcc_src_real/.git" ]; then
    tcc_commit=$(git -C "$tcc_src_real" log -1 --format=%h 2>/dev/null || true)
    case "$tcc_commit" in
        fc1fc50f*) ;;
        "")        echo "WARNING: cannot read tinycc commit" >&2 ;;
        *)         echo "WARNING: tinycc commit is $tcc_commit, expected fc1fc50f" >&2 ;;
    esac
fi

if command -v patch > /dev/null 2>&1; then
    apply_patch() { patch -p1 -d "$1" < "$2"; }
elif command -v git > /dev/null 2>&1; then
    apply_patch() { git -C "$1" apply "$2"; }
else
    die "neither 'patch' nor 'git' is available to apply the source patches"
fi

# pnut-exe is an Onramp wrapped executable; onrampvm is needed when it runs.
export PATH="$onramp/output/posix/bin:$PATH"

rm -rf "$build"
mkdir -p "$build/bin"

# ---------------------------------------------------------------------------
# 1/2. Build pnut-exe-for-tcc (two stages)
# ---------------------------------------------------------------------------
echo "== Building pnut-exe-for-tcc =="

mkdir -p "$build/pnut-src"
cp -a "$pnut/." "$build/pnut-src/"
rm -rf "$build/pnut-src/.git"
cd "$build/pnut-src" || die "cannot enter $build/pnut-src"

# ISO C fix (same as onramp-to-pnut-exe.sh).
sed -i 's/void set_car(const int pair, const int value)   { return set_child(pair, 0, value); }/void set_car(const int pair, const int value)   { set_child(pair, 0, value); }/' pnut.c
sed -i 's/void set_cdr(const int pair, const int value)   { return set_child(pair, 1, value); }/void set_cdr(const int pair, const int value)   { set_child(pair, 1, value); }/' pnut.c
grep -q 'return set_child(pair, [01], value);' pnut.c &&
    die "failed to apply the set_car()/set_cdr() patch"

apply_patch . "$patches/pnut-portable-libc.patch" ||
    die "failed to apply pnut-portable-libc.patch"

pnut_exe_defs=(
    -D "target_x86_64_linux"
    -D "ONE_PASS_GENERATOR"
    -D "UNDEFINED_LABELS_ARE_RUNTIME_ERRORS"
    -D "ENABLE_PNUT_INLINE_INTERRUPT"
    -D "NO_BUILTIN_LIBC"
    -D "HEAP_SIZE=2048000"
    -D "MAX_CODE_SIZE=2048000"
    -D "PROGRAM_SIZE=2048000"
    -D "SAFE_MODE"
)

echo "-- C1: seed pnut compiles pnut.c (no portable libc)"
if ! "$seed" pnut.c "${pnut_exe_defs[@]}" -I portable_libc/include/ \
        -o "$build/C1"; then
    die "failed to build C1"
fi

echo "-- C2: C1 compiles pnut.c + portable libc"
if ! "$build/C1" pnut.c "${pnut_exe_defs[@]}" -D "PNUT_PORTABLE_LIBC" \
        -I portable_libc/include/ portable_libc/libc.c \
        -o "$build/pnut-exe-for-tcc"; then
    die "failed to build pnut-exe-for-tcc"
fi
echo "ok: pnut-exe-for-tcc: $(wc -c < "$build/pnut-exe-for-tcc") bytes"

# ---------------------------------------------------------------------------
# 3. Prepare the tinycc source
# ---------------------------------------------------------------------------
echo "== Preparing tinycc $tcc_version =="

cp -a "$tcc_src_real/." "$build/tcc-src/"
rm -rf "$build/tcc-src/.git"
apply_patch "$build/tcc-src" "$patches/tinycc-fc1fc50f-pnut.patch" ||
    die "failed to apply tinycc-fc1fc50f-pnut.patch"

# tinycc's configure normally generates an empty config.h; pnut's kit ships one.
cp "$pnut/kit/config.h" "$build/tcc-src/config.h"

# Portable libc and the small compatibility layer for TCC's missing functions.
cp -a "$pnut/portable_libc" "$build/portable_libc"
cp "$patches/pnut-tcc-compat.c" "$build/pnut-tcc-compat.c"

# ---------------------------------------------------------------------------
# 4. Compile TCC with pnut
# ---------------------------------------------------------------------------
echo "== Compiling tinycc $tcc_version with pnut =="

cd "$build" || die "cannot enter $build"

tcc_defs=(
    -D "BOOTSTRAP=1"
    -D "PNUT_CC=1"
    -D "HAVE_LONG_LONG=1"
    -D "TCC_TARGET_X86_64=1"
    -D "CONFIG_TCC_BACKTRACE=0"
    -D 'CONFIG_SYSROOT="/"'
    -D 'CONFIG_TCC_CRTPREFIX="build/boot0-lib"'
    -D 'CONFIG_TCC_ELFINTERP="/mes/loader"'
    -D 'CONFIG_TCC_SYSINCLUDEPATHS="portable_libc/include"'
    -D 'TCC_LIBGCC="build/boot0-lib/libc.a"'
    -D "CONFIG_TCC_LIBTCC1_MES=0"
    -D "CONFIG_TCCBOOT=1"
    -D "CONFIG_TCC_STATIC=1"
    -D "CONFIG_USE_LIBGCC=1"
    -D "TCC_VERSION=\"$tcc_version\""
    -D "ONE_SOURCE=1"
    -D 'CONFIG_TCCDIR="build/boot0-lib/tcc"'
)

if ! "$build/pnut-exe-for-tcc" "${tcc_defs[@]}" \
        -I portable_libc/include/ \
        tcc-src/tcc.c portable_libc/libc.c pnut-tcc-compat.c \
        -D "__intptr_t_defined=1" \
        -o "$build/bin/tcc-pnut"; then
    die "failed to compile tinycc with pnut"
fi
chmod +x "$build/bin/tcc-pnut"
echo "ok: tcc-pnut: $(wc -c < "$build/bin/tcc-pnut") bytes"

# ---------------------------------------------------------------------------
# 5. Verify
# ---------------------------------------------------------------------------
echo "== Verifying tcc-pnut =="

version_out=$("$build/bin/tcc-pnut" -v 2>&1 | head -1) ||
    die "tcc-pnut -v failed"
case "$version_out" in
    *"$tcc_version"*) ;;
    *) die "unexpected version output: $version_out" ;;
esac
echo "ok: $version_out"

cat > "$build/tiny.c" <<'EOF'
int main(void) { return 42; }
EOF

if ! "$build/bin/tcc-pnut" -I "$build/tcc-src/include" -c \
        "$build/tiny.c" -o "$build/bin/tiny.o"; then
    die "tcc-pnut failed to compile tiny.c"
fi
[ -s "$build/bin/tiny.o" ] || die "tcc-pnut produced an empty object file"
echo "ok: tcc-pnut compiled tiny.c to $(wc -c < "$build/bin/tiny.o") bytes"

# Compile the runtime objects with tcc-pnut, then let tcc-pnut link them and
# the test program itself.  This verifies the compiler and linker end to end
# without using a host C compiler or host binutils.  Archive linking is not
# exercised (see README); object-file linking is enough here.
echo "-- building the boot runtime with tcc-pnut"
tcc_includes=(-I "$build/tcc-src/include")

if ! "$build/bin/tcc-pnut" "${tcc_includes[@]}" -c \
        "$build/portable_libc/src/crt1.c" -o "$build/bin/crt1.o"; then
    die "tcc-pnut failed to compile portable_libc/src/crt1.c"
fi
if ! "$build/bin/tcc-pnut" "${tcc_includes[@]}" -c \
        -I "$build/portable_libc/include" \
        "$build/portable_libc/libc.c" -o "$build/bin/libc.o"; then
    die "tcc-pnut failed to compile portable_libc/libc.c"
fi
if ! "$build/bin/tcc-pnut" "${tcc_includes[@]}" -c \
        "$pnut/kit/libtcc1.c" -o "$build/bin/libtcc1.o"; then
    die "tcc-pnut failed to compile kit/libtcc1.c"
fi
if ! "$build/bin/tcc-pnut" "${tcc_includes[@]}" -c \
        "$build/tcc-src/lib/va_list.c" -o "$build/bin/va_list.o"; then
    die "tcc-pnut failed to compile lib/va_list.c"
fi

runtime_objs=(
    "$build/bin/crt1.o"
    "$build/bin/libc.o"
    "$build/bin/libtcc1.o"
    "$build/bin/va_list.o"
)

if ! "$build/bin/tcc-pnut" -nostdlib -static -o "$build/bin/tiny" \
        "${runtime_objs[@]}" "$build/bin/tiny.o"; then
    die "tcc-pnut failed to link tiny"
fi
"$build/bin/tiny"
rc=$?
[ "$rc" -eq 42 ] || die "tcc-pnut-linked tiny exited $rc, expected 42"
echo "ok: tcc-pnut compiled and linked tiny (exit 42)"

cat > "$build/hello.c" <<'EOF'
#include <stdio.h>
int main(void) {
    printf("Hello from tinycc 0.9.28rc built by pnut!\n");
    return 0;
}
EOF

if ! "$build/bin/tcc-pnut" "${tcc_includes[@]}" -c \
        "$build/hello.c" -o "$build/bin/hello.o"; then
    die "tcc-pnut failed to compile hello.c"
fi
if ! "$build/bin/tcc-pnut" -nostdlib -static -o "$build/bin/hello" \
        "${runtime_objs[@]}" "$build/bin/hello.o"; then
    die "tcc-pnut failed to link hello"
fi
hello_out=$("$build/bin/hello")
[ "$hello_out" = "Hello from tinycc 0.9.28rc built by pnut!" ] ||
    die "unexpected hello output: $hello_out"
echo "ok: tcc-pnut compiled and linked hello: $hello_out"

echo
echo "SUCCESS"
echo "  pnut-built tinycc: $build/bin/tcc-pnut"
echo "  pnut-exe-for-tcc:  $build/pnut-exe-for-tcc"
echo "  tinycc sources:    $build/tcc-src (patched)"
echo
echo "Note: tcc-pnut compiled and linked the runtime and tests itself; no host"
echo "      gcc or binutils is used.  Archive (-l) linking still needs a fix"
echo "      in pnut's portable libc archive handling (see README)."
