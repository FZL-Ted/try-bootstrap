#!/bin/bash
# onramp-pnut-tcc-0.9.27.sh -- Bootstrap pnut-exe and TCC 0.9.27 with Onramp.
#
# Phase 1 (same as onramp-to-pnut-exe.sh): compile pnut.c directly with the
# Onramp C toolchain using the native-code backend, verify that pnut-exe emits
# runnable ELF and that it recompiles pnut.c to an identical binary.
#
# Phase 2: use the resulting pnut to build TinyCC 0.9.27 (the copy shipped in
# pnut/kit/tcc-0.9.27.tar.gz), following pnut's kit/bootstrap.sh:
#   - compile pnut.c again with the portable libc and safe mode to get
#     pnut-exe-for-tcc (the compiler used for TCC);
#   - unpack TCC 0.9.27, install kit/config.h and apply the unified patches
#     patches/tcc-0.9.27-pnut.patch (+ ...-x86_64.patch for x86_64);
#   - compile TCC with pnut-exe-for-tcc + portable_libc/libc.c -> tcc-pnut;
#   - build the boot0 runtime (crt1.o, libc.a, libtcc1.a), compile and run a
#     hello program with tcc-pnut;
#   - recompile TCC with tcc-pnut -> tcc-boot0 and check that it runs.
#
# The complete kit bootstrap continues with boot1/boot2/boot3 from there; this
# script stops after tcc-boot0 (see README.md).
#
# Usage:
#   ./onramp-pnut-tcc-0.9.27.sh [--force] [--target x86_64|i386]
#
#   --force          Rebuild the Onramp-built pnut-exe.
#   --target TARGET  ELF target emitted by pnut-exe and TCC (default: x86_64).
#                    Use i386 for the 32-bit M2-Planet-style workflow.
#
# Artifacts:
#   build-onramp-exe/   pnut-exe, native pnut, fixed-point binaries
#   build-pnut-tcc/     pnut-exe-for-tcc, tcc-0.9.27/, portable_libc/,
#                       build/tcc-pnut, build/tcc-boot0, build/hello,
#                       build/boot0-lib/

set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")

onramp="$root/base-onramp/onramp"
src="$here/pnut"
build="$here/build-onramp-exe"
tccbuild="$here/build-pnut-tcc"
patches="$here/patches"

vm="$onramp/output/posix/bin/onrampvm"
cc="$onramp/output/final/bin/cc.oe"

force=0
target=x86_64

usage() {
    sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --force)       force=1 ;;
        --target)      shift; [ $# -gt 0 ] || { echo "ERROR: --target needs an argument" >&2; exit 2; }; target=$1 ;;
        --target=*)    target=${1#--target=} ;;
        --help|-h)     usage ;;
        *) echo "ERROR: unknown option: $1" >&2; usage ;;
    esac
    shift
done

case "$target" in
    x86_64) tcc_target=X86_64 ;;
    i386)   tcc_target=I386 ;;
    *) echo "ERROR: unsupported target '$target' (use x86_64 or i386)" >&2; exit 2 ;;
esac

die() { echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Check the Onramp toolchain and sources
# ---------------------------------------------------------------------------
for f in "$vm" "$cc"; do
    if [ ! -e "$f" ]; then
        die "Onramp is not built: missing $f
Build it first:
    cd $onramp && ./configure.sh && ./build.sh"
    fi
done
[ -d "$src" ] || die "pnut sources not found: $src (expected a checkout at base-pnut/pnut)"
[ -e "$src/kit/tcc-0.9.27.tar.gz" ] || die "missing $src/kit/tcc-0.9.27.tar.gz"
[ -d "$patches" ] || die "patches directory not found: $patches"

# Apply unified patches without python3: use patch(1) when available, and fall
# back to git apply.
if command -v patch > /dev/null 2>&1; then
    apply_patch() { patch -p1 -d "$1" < "$2"; }
elif command -v git > /dev/null 2>&1; then
    apply_patch() { git -C "$1" apply "$2"; }
else
    die "neither 'patch' nor 'git' is available to apply the TCC patches"
fi

wrap=$(realpath "$onramp/output/posix/share/onramp/platform/wrap-header")
[ -f "$wrap" ] || die "missing Onramp wrap-header: $wrap"

# pnut-exe is an Onramp wrapped executable; onrampvm must be on PATH when it
# runs.  The native binaries it emits do not need onrampvm.
export PATH="$onramp/output/posix/bin:$PATH"

defs="-Dtarget_${target}_linux -DONE_PASS_GENERATOR"

# i386 uses pnut's emulated 64-bit arithmetic runtime (arith64.c); the compiler
# itself must be built with SUPPORT_EMULATED_INT64 so that it understands the
# -rt option used by kit/bootstrap.sh.
verify_defs=$defs
self_runtime=()
if [ "$target" = i386 ]; then
    verify_defs="$verify_defs -DSUPPORT_EMULATED_INT64"
    self_runtime=( -rt arith64.c )
fi

# ---------------------------------------------------------------------------
# Phase 1: build the Onramp-compiled pnut-exe
# ---------------------------------------------------------------------------
build_pnut_exe() {
    echo "== Building pnut-exe with Onramp (target: $target) =="
    echo "compiler: $cc"

    rm -rf "$build"
    mkdir -p "$build/src"
    cp -a "$src/." "$build/src/"
    cd "$build/src" || die "cannot enter $build/src"

    # ISO C fix: `return void_expression;` is rejected by Onramp but accepted
    # by GCC as an extension.
    if grep -q 'return set_child(pair, 0, value);' pnut.c &&
       grep -q 'return set_child(pair, 1, value);' pnut.c; then
        sed -i 's/void set_car(const int pair, const int value)   { return set_child(pair, 0, value); }/void set_car(const int pair, const int value)   { set_child(pair, 0, value); }/' pnut.c
        sed -i 's/void set_cdr(const int pair, const int value)   { return set_child(pair, 1, value); }/void set_cdr(const int pair, const int value)   { set_child(pair, 1, value); }/' pnut.c
    else
        echo "WARNING: set_car()/set_cdr() return-void pattern not found." >&2
        echo "         The pnut sources may have changed; check the patch." >&2
    fi
    grep -q 'return set_child(pair, [01], value);' pnut.c &&
        die "failed to apply the set_car()/set_cdr() portability patch"

    echo "-- preprocessing pnut.c ($verify_defs)"
    "$vm" "$cc" -E $verify_defs pnut.c -o pnut-exe.i ||
        die "Onramp preprocessor failed"

    # Onramp's linker limits #line filenames to 128 bytes; rewrite the long
    # absolute header paths to their basenames (diagnostic info only).
    sed -E 's|^#line ([0-9]+) "/[^"]*/([^/"]+)"$|#line \1 "\2"|' pnut-exe.i > pnut-exe-pre.i
    if grep -Eq '^#line [0-9]+ "/' pnut-exe-pre.i; then
        die "long absolute #line filename still present in pnut-exe-pre.i"
    fi

    echo "-- compiling pnut.c (this takes about half a minute)"
    exe_srcs=( pnut-exe-pre.i )
    [ "$target" = i386 ] && exe_srcs+=( arith64.c )
    "$vm" "$cc" -wrap-header="$wrap" "${exe_srcs[@]}" -o pnut-exe ||
        die "Onramp compilation failed"

    chmod +x pnut-exe
    cp pnut-exe "$build/pnut-exe"
    echo "$target" > "$build/.target"
    rm -f .tmp.* pnut-exe.i pnut-exe-pre.i
    echo "built: $build/pnut-exe"
}

if [ "$force" -eq 0 ] && [ -x "$build/pnut-exe" ] &&
   [ "$(cat "$build/.target" 2>/dev/null)" = "$target" ] &&
   [ "$build/pnut-exe" -nt "$src/pnut.c" ]; then
    echo "pnut-exe already built for $target: $build/pnut-exe"
    echo "(use --force to rebuild)"
else
    build_pnut_exe
fi

# ---------------------------------------------------------------------------
# Verify pnut-exe: native ELF, native self-host, fixed point
# ---------------------------------------------------------------------------
cd "$build" || die "cannot enter $build"

echo "== Verifying pnut-exe ($target) =="

cat > tiny.c <<'EOF'
int main(void) { return 42; }
EOF

if ! ./pnut-exe tiny.c -o tiny; then
    die "pnut-exe failed to compile tiny.c"
fi
./tiny
rc=$?
[ "$rc" -eq 42 ] || die "tiny exited $rc, expected 42"
echo "ok: pnut-exe emitted a runnable native executable (exit 42)"
echo "    $(file tiny 2>/dev/null | sed 's/^tiny: //')"

echo "-- self-compiling pnut.c with pnut-exe (about 10 s)"
cd "$build/src" || die "cannot enter $build/src"
if ! "$build/pnut-exe" pnut.c $verify_defs "${self_runtime[@]}" -o "$build/pnut-exe-by-pnut-exe"; then
    die "pnut-exe failed to compile pnut.c"
fi
[ -x "$build/pnut-exe-by-pnut-exe" ] || die "pnut-exe-by-pnut-exe was not produced"
echo "ok: native pnut compiler: $(wc -c < "$build/pnut-exe-by-pnut-exe") bytes"

cd "$build" || die "cannot enter $build"
if ! ./pnut-exe-by-pnut-exe tiny.c -o tiny-native; then
    die "the native pnut compiler failed to compile tiny.c"
fi
./tiny-native
rc=$?
[ "$rc" -eq 42 ] || die "tiny-native exited $rc, expected 42"

cd "$build/src" || die "cannot enter $build/src"
if ! "$build/pnut-exe-by-pnut-exe" pnut.c $verify_defs "${self_runtime[@]}" -o "$build/pnut-exe-by-pnut-exe-2"; then
    die "the native pnut compiler failed to compile pnut.c"
fi
if ! diff -q "$build/pnut-exe-by-pnut-exe" "$build/pnut-exe-by-pnut-exe-2" > /dev/null; then
    die "binaries differ after recompilation (self-hosting fixed point not reached)"
fi
echo "ok: native pnut recompiled pnut.c to an identical binary (fixed point)"
echo "    sha256: $(sha256sum "$build/pnut-exe-by-pnut-exe" | cut -d' ' -f1)"

# ---------------------------------------------------------------------------
# Phase 2: build TCC 0.9.27 with pnut
# ---------------------------------------------------------------------------
echo
echo "== Building TCC 0.9.27 with pnut ($target) =="

# pnut options used to compile pnut-exe-for-tcc (see kit/bootstrap.sh).
pnut_tcc_defs=(
    -D "target_${target}_linux"
    -D "ONE_PASS_GENERATOR"
    -D "UNDEFINED_LABELS_ARE_RUNTIME_ERRORS"
    -D "ENABLE_PNUT_INLINE_INTERRUPT"
    -D "NO_BUILTIN_LIBC"
)
arith=()
if [ "$target" = i386 ]; then
    pnut_tcc_defs+=( -D "SUPPORT_EMULATED_INT64" )
    arith=( -rt arith64.c )
else
    pnut_tcc_defs+=(
        -D "HEAP_SIZE=2048000"
        -D "MAX_CODE_SIZE=2048000"
        -D "PROGRAM_SIZE=2048000"
    )
fi

# Build pnut-exe-for-tcc (portable libc, safe mode): the compiler used for TCC.
echo "-- building pnut-exe-for-tcc"
rm -rf "$tccbuild"
mkdir -p "$tccbuild/build"
if ! ( cd "$build/src" && "$build/pnut-exe-by-pnut-exe" pnut.c \
        "${pnut_tcc_defs[@]}" -D "SAFE_MODE" "${arith[@]}" \
        -I portable_libc/include/ portable_libc/libc.c \
        -o "$tccbuild/pnut-exe-for-tcc" ); then
    die "failed to build pnut-exe-for-tcc"
fi
echo "ok: pnut-exe-for-tcc: $(wc -c < "$tccbuild/pnut-exe-for-tcc") bytes"

# Prepare the TCC source tree (extract + config.h + kit patches).
echo "-- unpacking and patching TCC 0.9.27"
cp -a "$src/portable_libc" "$tccbuild/"
cp "$src/arith64.c" "$src/kit/libtcc1.c" "$src/kit/tcc-0.9.27.tar.gz" "$tccbuild/"
cd "$tccbuild" || die "cannot enter $tccbuild"
tar xzf tcc-0.9.27.tar.gz || die "failed to extract TCC"
cp "$src/kit/config.h" tcc-0.9.27/config.h || die "failed to install kit/config.h"

apply_patch "$tccbuild" "$patches/tcc-0.9.27-pnut.patch" ||
    die "failed to apply tcc-0.9.27-pnut.patch"
if [ "$tcc_target" = X86_64 ]; then
    apply_patch "$tccbuild" "$patches/tcc-0.9.27-pnut-x86_64.patch" ||
        die "failed to apply tcc-0.9.27-pnut-x86_64.patch"
fi

# Compile TCC with pnut-exe-for-tcc.  The CONFIG_* values follow
# kit/bootstrap.sh; they are relative to this directory.
tcc_defs=(
    -D "BOOTSTRAP=1"
    -D "PNUT_CC=1"
    -D "HAVE_LONG_LONG=1"
    -D "TCC_TARGET_${tcc_target}=1"
    -D 'CONFIG_SYSROOT="/"'
    -D 'CONFIG_TCC_CRTPREFIX="build/boot0-lib"'
    -D 'CONFIG_TCC_ELFINTERP="/mes/loader"'
    -D 'CONFIG_TCC_SYSINCLUDEPATHS="portable_libc/include"'
    -D 'TCC_LIBGCC="build/boot0-lib/libc.a"'
    -D "CONFIG_TCC_LIBTCC1_MES=0"
    -D "CONFIG_TCCBOOT=1"
    -D "CONFIG_TCC_STATIC=1"
    -D "CONFIG_USE_LIBGCC=1"
    -D 'TCC_VERSION="0.9.27"'
    -D "ONE_SOURCE=1"
    -D 'CONFIG_TCCDIR="build/boot0-lib/tcc"'
)

echo "-- compiling TCC 0.9.27 (tcc.c + portable libc)"
if ! "$tccbuild/pnut-exe-for-tcc" "${tcc_defs[@]}" \
        -I portable_libc/include/ \
        tcc-0.9.27/tcc.c portable_libc/libc.c \
        -D "__intptr_t_defined=1" "${arith[@]}" \
        -o build/tcc-pnut; then
    die "failed to compile TCC with pnut"
fi
chmod +x build/tcc-pnut
echo "ok: tcc-pnut: $(wc -c < build/tcc-pnut) bytes"
echo "    $(build/tcc-pnut -v 2>&1 | head -1)"

# ---------------------------------------------------------------------------
# Verify tcc-pnut: boot0 runtime, hello program, self-compiled tcc-boot0
# ---------------------------------------------------------------------------
echo "== Verifying tcc-pnut =="

mkdir -p build/boot0-lib/tcc
if ! ./build/tcc-pnut -c portable_libc/src/crt1.c -o build/boot0-lib/crt1.o ||
   ! ./build/tcc-pnut -c -D ADD_LIBC_STUB -I portable_libc/include \
        -o build/boot0-lib/libc.o portable_libc/libc.c ||
   ! ./build/tcc-pnut -ar cr build/boot0-lib/libc.a build/boot0-lib/libc.o ||
   ! ./build/tcc-pnut -c -o build/boot0-lib/libtcc1.o libtcc1.c; then
    die "failed to build the boot0 runtime"
fi
if [ "$tcc_target" = X86_64 ]; then
    ./build/tcc-pnut -c -o build/boot0-lib/va_list.o tcc-0.9.27/lib/va_list.c ||
        die "failed to compile lib/va_list.c"
    ./build/tcc-pnut -ar cr build/boot0-lib/tcc/libtcc1.a \
        build/boot0-lib/libtcc1.o build/boot0-lib/va_list.o ||
        die "failed to create libtcc1.a"
else
    ./build/tcc-pnut -ar cr build/boot0-lib/tcc/libtcc1.a build/boot0-lib/libtcc1.o ||
        die "failed to create libtcc1.a"
fi
cp build/boot0-lib/tcc/libtcc1.a build/boot0-lib/libtcc1.a
printf "" > build/boot0-lib/crti.o
printf "" > build/boot0-lib/crtn.o
echo "ok: boot0 runtime built (crt1.o, libc.a, libtcc1.a)"

cat > hello.c <<'EOF'
#include <stdio.h>

int main(void) {
    printf("Hello from TCC compiled by pnut (Onramp bootstrap)!\n");
    return 0;
}
EOF

if ! ./build/tcc-pnut -static -I portable_libc/include -B build/boot0-lib \
        -L build/boot0-lib -L build/boot0-lib/tcc \
        -o build/hello hello.c; then
    die "tcc-pnut failed to compile hello.c"
fi
hello_out=$(./build/hello) || die "the hello program exited nonzero"
[ "$hello_out" = "Hello from TCC compiled by pnut (Onramp bootstrap)!" ] ||
    die "unexpected hello output: $hello_out"
echo "ok: tcc-pnut compiled and ran hello.c"

# Recompile TCC with TCC itself (kit/bootstrap.sh "go" step for boot0).
self_defs=(
    -D "BOOTSTRAP=1"
    -D "__SIZEOF_LONG_LONG__=8"
    -D "HAVE_FLOAT=1"
    -D "HAVE_BITFIELD=1"
    -D "HAVE_LONG_LONG=1"
    -D "HAVE_SETJMP=1"
    -I portable_libc/include
    -D "TCC_TARGET_${tcc_target}=1"
    -D 'CONFIG_TCCDIR="build/boot0-lib/tcc"'
    -D 'CONFIG_TCC_CRTPREFIX="build/boot0-lib"'
    -D 'CONFIG_TCC_LIBPATHS="build/boot0-lib:build/boot0-lib/tcc"'
    -D 'CONFIG_TCC_SYSINCLUDEPATHS="portable_libc/include"'
    -D 'TCC_LIBGCC="build/boot0-lib/libc.a"'
    -D 'TCC_LIBTCC1="libtcc1.a"'
    -D 'CONFIG_TCC_ELFINTERP="/mes/loader"'
    -D "CONFIG_TCCBOOT=1"
    -D "CONFIG_TCC_STATIC=1"
    -D "CONFIG_USE_LIBGCC=1"
    -D 'TCC_VERSION="0.9.27"'
    -D "ONE_SOURCE=1"
)

echo "-- recompiling TCC with tcc-pnut (boot0)"
if ! ./build/tcc-pnut -static -o build/tcc-boot0 \
        "${self_defs[@]}" -L build/boot0-lib tcc-0.9.27/tcc.c; then
    die "tcc-pnut failed to compile TCC"
fi
boot0_version=$(./build/tcc-boot0 -v 2>&1 | head -1) ||
    die "tcc-boot0 failed to run"
echo "ok: tcc-boot0: $boot0_version"

echo
echo "SUCCESS"
echo "  Onramp-built pnut-exe: $build/pnut-exe"
echo "  native pnut compiler:  $build/pnut-exe-by-pnut-exe"
echo "  pnut-built TCC:        $tccbuild/build/tcc-pnut"
echo "  TCC built by TCC:      $tccbuild/build/tcc-boot0"
echo "  tcc-pnut version:      $(./build/tcc-pnut -v 2>&1 | head -1)"
echo "Note: $build/pnut-exe runs under onrampvm; the native binaries do not."
