#!/bin/bash
# onramp-to-pnut-exe.sh -- Build pnut-exe (the native-code backend) with Onramp.
#
# This mirrors the (commented-out) M2-Planet build of pnut in pnut's
# .github/workflows/main.yml: a small C compiler compiles pnut.c with the
# exe backend selected, resulting compiler emits native ELF executables, and it
# then recompiles pnut.c to a fixed point (identical binaries).
#
# The Onramp toolchain compiles pnut.c with:
#     -Dtarget_i386_linux    (or -Dtarget_x86_64_linux)
#     -DONE_PASS_GENERATOR
#
# ONE_PASS_GENERATOR is required under Onramp: without it pnut-exe allocates a
# 20 MB code buffer (5,000,000 ints) which exceeds the Onramp VM's 16 MiB free
# memory region, and the VM aborts with "A memory access is invalid."
#
# Usage:
#   ./onramp-to-pnut-exe.sh [--force] [--target x86_64|i386]
#
#   --force          Rebuild the Onramp-built compiler.
#   --target TARGET  ELF target emitted by the compiler (default: x86_64).
#                    Use i386 for the exact M2-Planet-style 32-bit workflow.
#
# Artifacts (under build-onramp-exe/):
#   pnut-exe                  pnut compiler built directly by Onramp,
#                             emitting native ELF (run via onrampvm)
#   pnut-exe-by-pnut-exe      native pnut produced by pnut-exe
#   pnut-exe-by-pnut-exe-2    native pnut produced by the previous binary
#                             (must be byte-identical: fixed point)
#   tiny.c / tiny / tiny-native   exit-code smoke tests (expect exit 42)

set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")

onramp="$root/base-onramp/onramp"
src="$here/pnut"
build="$here/build-onramp-exe"

vm="$onramp/output/posix/bin/onrampvm"
cc="$onramp/output/final/bin/cc.oe"

force=0
target=x86_64

usage() {
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
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
    x86_64|i386) ;;
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

wrap=$(realpath "$onramp/output/posix/share/onramp/platform/wrap-header")
[ -f "$wrap" ] || die "missing Onramp wrap-header: $wrap"

# pnut-exe is an Onramp wrapped executable; onrampvm must be on PATH when it
# runs.  The native binaries it emits do not need onrampvm.
export PATH="$onramp/output/posix/bin:$PATH"

defs="-Dtarget_${target}_linux -DONE_PASS_GENERATOR"

# i386 uses pnut's emulated 64-bit arithmetic runtime (arith64.c); the compiler
# must be built with SUPPORT_EMULATED_INT64 and link arith64.c so that it works
# with 32-bit targets (same approach as onramp-pnut-tcc-.sh).
verify_defs=$defs
self_runtime=()
if [ "$target" = i386 ]; then
    verify_defs="$verify_defs -DSUPPORT_EMULATED_INT64"
    self_runtime=( -rt arith64.c )
fi

# ---------------------------------------------------------------------------
# Build the Onramp-compiled pnut-exe
# ---------------------------------------------------------------------------
build_pnut_exe() {
    echo "== Building pnut-exe with Onramp (target: $target) =="
    echo "compiler: $cc"

    rm -rf "$build"
    mkdir -p "$build/src"
    cp -a "$src/." "$build/src/"
    cd "$build/src" || die "cannot enter $build/src"

    # ISO C fix, same as for pnut-sh: `return void_expression;` is rejected by
    # Onramp but accepted by GCC as an extension.
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
# Verify
# ---------------------------------------------------------------------------
cd "$build" || die "cannot enter $build"

echo "== Verifying pnut-exe ($target) =="

cat > tiny.c <<'EOF'
int main(void) { return 42; }
EOF

# 1. Compile a trivial program to a native executable, run it.
if ! ./pnut-exe tiny.c -o tiny; then
    die "pnut-exe failed to compile tiny.c"
fi
./tiny
rc=$?
[ "$rc" -eq 42 ] || die "tiny exited $rc, expected 42"
echo "ok: pnut-exe emitted a runnable native executable (exit 42)"
echo "    $(file tiny 2>/dev/null | sed 's/^tiny: //')"

# 2. Compile pnut.c with pnut-exe to a native compiler.  pnut resolves its
#    quoted includes (#include "debug.c" ...) relative to the input file, so
#    run from the source directory.
echo "-- self-compiling pnut.c with pnut-exe (about 10 s)"
cd "$build/src" || die "cannot enter $build/src"
if ! "$build/pnut-exe" pnut.c $verify_defs "${self_runtime[@]}" -o "$build/pnut-exe-by-pnut-exe"; then
    die "pnut-exe failed to compile pnut.c"
fi
[ -x "$build/pnut-exe-by-pnut-exe" ] || die "pnut-exe-by-pnut-exe was not produced"
echo "ok: native pnut compiler: $(wc -c < "$build/pnut-exe-by-pnut-exe") bytes"
echo "    $(file "$build/pnut-exe-by-pnut-exe" 2>/dev/null | sed "s|^$build/pnut-exe-by-pnut-exe: ||")"

# 3. The native compiler must work and recompile pnut.c to an identical binary.
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

echo
echo "SUCCESS"
echo "  Onramp-built pnut-exe: $build/pnut-exe"
echo "  native pnut compiler:  $build/pnut-exe-by-pnut-exe"
echo "Note: $build/pnut-exe runs under onrampvm; the native compiler does not."
