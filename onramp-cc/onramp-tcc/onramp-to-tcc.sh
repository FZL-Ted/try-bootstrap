#!/bin/sh
#
# Build Onramp, then use that Onramp toolchain to build TinyCC.
#
# TinyCC is built from a COPY of ./tinycc (or its symlink target) so this
# script never modifies the TinyCC checkout.
#
# Host gcc and binutils are *not* used to build TinyCC.  The only native
# programs involved are the Onramp VM (the x86_64-linux stage-0 VM produced by
# the Onramp build), a POSIX shell, host `make` and coreutils.  A directory of
# failing shims is placed first on PATH so an accidental call to
# gcc/cc/as/ld/ar/ranlib/... fails loudly instead of silently using the host
# toolchain.  CC and AR are forced to onrampcc and onrampar.
#
# Why the short-path work directory?
# ----------------------------------
# At the Onramp commit currently checked out, the Onramp libc's vasprintf()
# first formats into a 128-byte stack buffer and then calls
# __fatal("Internal error: Invalid format output.") when a longer string
# overflows it.  Onramp's cpp joins include paths with asprintf(), so any
# include path (or quoted-include path derived from the source path) longer
# than roughly 146 bytes kills cpp before it even calls fopen().  This is not
# specific to TinyCC, but it does mean a TinyCC checkout in a deep directory
# cannot be compiled by Onramp.  To work around it without modifying Onramp,
# the TinyCC copy is built through a short /tmp symlink to the persistent
# ./build/work tree, and the Onramp install tree is reached through a short
# symlink too.  The final install prefix can still be the long, persistent
# path because it is not used as an include path.
#
# Usage:
#   ./onramp-to-tcc.sh [options]
#
# Options:
#   --clean             Remove ./build before doing anything.
#   --skip-onramp       Do not rebuild Onramp; use the existing build.
#   --reuse-work        Reuse the TinyCC work tree (for iterating on failures).
#   -j N, --jobs N      Pass -jN to the TinyCC build (default: 1).
#   -h, --help          Show this help.
#
# Exit status is 0 only if Onramp built and the TinyCC make/install finished.
# A nonzero status is a legitimate result of this experiment.

set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ONRAMP_DIR=$HERE/onramp
TINYCC_SRC=$HERE/tinycc
BUILD_ROOT=${BUILD_ROOT:-$HERE/build}
INSTALL_ROOT=$BUILD_ROOT/tinycc/install-stage0
LOG_ROOT=$BUILD_ROOT/logs
PATCH_FILE=$HERE/tinycc-onramp.patch

JOBS=1
DO_CLEAN=0
SKIP_ONRAMP=0
REUSE_WORK=0

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

die() {
    echo "onramp-to-tcc: $*" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case $1 in
        --clean) DO_CLEAN=1; shift ;;
        --skip-onramp) SKIP_ONRAMP=1; shift ;;
        --reuse-work) REUSE_WORK=1; shift ;;
        -j|--jobs)
            [ $# -ge 2 ] || die "missing argument to $1"
            JOBS=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1 (try --help)"
            ;;
    esac
done

case $JOBS in
    ''|*[!0-9]*) die "invalid job count: $JOBS" ;;
esac

[ -d "$ONRAMP_DIR" ] || die "Onramp not found at $ONRAMP_DIR"
[ -d "$TINYCC_SRC" ] || die "TinyCC not found at $TINYCC_SRC"
[ -f "$PATCH_FILE" ] || die "patch not found: $PATCH_FILE"

if [ "$DO_CLEAN" -eq 1 ]; then
    echo "==> Removing $BUILD_ROOT"
    rm -rf "$BUILD_ROOT"
fi
mkdir -p "$BUILD_ROOT" "$LOG_ROOT"

# The build tree lives in the persistent build directory, but all commands run
# through a short symlink to it.  This keeps the absolute paths passed to
# Onramp's cpp short enough for its present vasprintf() implementation.
WORK_ROOT=$BUILD_ROOT/work
SHORT_PARENT=${TMPDIR:-/tmp}
SHORT_ROOT=$SHORT_PARENT/onramp-to-tcc-work
SHORT_ONRAMP=$SHORT_ROOT/onramp
TINYCC_WORK=$SHORT_ROOT/tinycc
TINYCC_WORK_REAL=$WORK_ROOT/tinycc
SHIM_DIR=$SHORT_ROOT/host-tool-shims
ONRAMP_LOG=$LOG_ROOT/onramp-build.log

mkdir -p "$WORK_ROOT" "$SHORT_PARENT"
if [ -e "$SHORT_ROOT" ] && [ ! -L "$SHORT_ROOT" ]; then
    die "$SHORT_ROOT exists and is not a symlink; remove it or set TMPDIR"
fi
rm -f "$SHORT_ROOT"
ln -s "$WORK_ROOT" "$SHORT_ROOT" ||
    die "could not create short work symlink at $SHORT_ROOT"

cleanup() {
    rm -f "$SHORT_ROOT"
}
trap cleanup EXIT HUP INT TERM

# ---------------------------------------------------------------------------
# 1. Build Onramp
# ---------------------------------------------------------------------------

if [ "$SKIP_ONRAMP" -eq 0 ]; then
    echo "==> Configuring Onramp"
    (
        cd "$ONRAMP_DIR" &&
        ./configure.sh
    ) > "$LOG_ROOT/onramp-configure.log" 2>&1 || {
        echo "Onramp configure failed; last lines:" >&2
        tail -40 "$LOG_ROOT/onramp-configure.log" >&2
        die "Onramp configure failed (see $LOG_ROOT/onramp-configure.log)"
    }

    echo "==> Building Onramp (this is slow; log: $ONRAMP_LOG)"
    (
        cd "$ONRAMP_DIR" &&
        ./build.sh
    ) > "$ONRAMP_LOG" 2>&1 &
    ONRAMP_PID=$!

    # Report a little progress while the build runs.
    while kill -0 "$ONRAMP_PID" 2>/dev/null; do
        sleep 30
        if [ -f "$ONRAMP_LOG" ]; then
            printf '    ... %s\n' "$(tail -n 1 "$ONRAMP_LOG")"
        fi
    done
    wait "$ONRAMP_PID"
    ONRAMP_STATUS=$?
    if [ "$ONRAMP_STATUS" -ne 0 ]; then
        echo "Onramp build failed; last lines:" >&2
        tail -60 "$ONRAMP_LOG" >&2
        die "Onramp build failed (see $ONRAMP_LOG)"
    fi
else
    echo "==> Skipping Onramp build (--skip-onramp)"
fi

[ -x "$ONRAMP_DIR/output/posix/bin/onrampcc" ] ||
    die "Onramp build did not produce output/posix/bin/onrampcc"
[ -x "$ONRAMP_DIR/output/posix/bin/onrampvm" ] ||
    die "Onramp build did not produce output/posix/bin/onrampvm"

# Reach the Onramp install tree through a short path so that the absolute
# include paths the onrampcc wrapper builds stay below the broken vasprintf
# length limit.
ln -s "$ONRAMP_DIR" "$SHORT_ONRAMP"
ONRAMP_BIN=$SHORT_ONRAMP/output/posix/bin
[ -x "$ONRAMP_BIN/onrampcc" ] || die "onrampcc is not executable"

# ---------------------------------------------------------------------------
# 2. Prepare a short-path TinyCC build tree and Onramp-only toolchain PATH
# ---------------------------------------------------------------------------

# Create fail-closed shims for every host toolchain command we must not use.
rm -rf "$SHIM_DIR"
mkdir -p "$SHIM_DIR"
for tool in \
    gcc g++ cc c++ c89 c99 c11 clang clang++ tcc \
    as ld ld.bfd ld.gold ld.lld gold \
    ar ranlib nm objcopy objdump strip readelf elfedit addr2line \
    size strings
do
    cat > "$SHIM_DIR/$tool" <<EOF
#!/bin/sh
echo "onramp-to-tcc: refusing to run host tool '$tool' (must use Onramp)" >&2
exit 127
EOF
    chmod +x "$SHIM_DIR/$tool"
done

if [ "$REUSE_WORK" -eq 1 ] && [ -f "$TINYCC_WORK/tcc.c" ]; then
    echo "==> Reusing existing TinyCC work tree at $TINYCC_WORK_REAL"
else
    echo "==> Copying TinyCC sources to $TINYCC_WORK_REAL"
    rm -rf "$TINYCC_WORK_REAL"
    mkdir -p "$TINYCC_WORK_REAL"
    cp -a "$TINYCC_SRC/." "$TINYCC_WORK_REAL/"
    rm -f "$TINYCC_WORK_REAL"/config.mak "$TINYCC_WORK_REAL"/config.h

    echo "==> Applying Onramp compatibility patch"
    (
        cd "$TINYCC_WORK" &&
        patch -p1 --forward --batch < "$PATCH_FILE"
    ) || die "failed to apply $PATCH_FILE (the TinyCC checkout probably changed)"
fi

# Force only Onramp tools; also clear variables that could smuggle in a host
# compiler through the environment.
unset CC CXX CPP AS LD AR RANLIB NM STRIP OBJCOPY OBJDUMP CFLAGS LDFLAGS LIBS
export CC=onrampcc
export AR=onrampar
export PATH=$ONRAMP_BIN:$SHIM_DIR:$PATH

echo "==> Tool sanity check"
echo "    CC  = $(command -v onrampcc)"
echo "    AR  = $(command -v onrampar)"
# The first hit for every compiler/binutils name must be our failing shim.
for tool in gcc cc as ld ar ranlib strip; do
    found=$(command -v "$tool" 2>/dev/null || true)
    [ "$found" = "$SHIM_DIR/$tool" ] ||
        die "internal error: '$tool' resolves to '$found' instead of the shim"
    "$found" >/dev/null 2>&1 &&
        die "internal error: shim for '$tool' did not fail"
done

# Sanity-compile, link and run a trivial program with Onramp before involving
# make.  This catches include-path length problems immediately.
echo "==> Sanity-compiling, linking and running a trivial program with onrampcc"
SANITY_DIR=$SHORT_ROOT/sanity
mkdir -p "$SANITY_DIR"
cat > "$SANITY_DIR/hello.c" <<'EOF'
int main(void) { return 0; }
EOF
(
    cd "$SANITY_DIR" &&
    onrampcc -c hello.c -o hello.o &&
    onrampcc hello.o -o hello &&
    ./hello
) || {
    echo "onrampcc could not compile/link/run a trivial program." >&2
    die "Onramp C compiler is not usable for this TinyCC checkout"
}

# ---------------------------------------------------------------------------
# 3. Configure and build TinyCC
# ---------------------------------------------------------------------------

CONFIGURE_LOG=$LOG_ROOT/tinycc-configure.log
echo "==> Configuring TinyCC with CC=onrampcc AR=onrampar"
(
    cd "$TINYCC_WORK" &&
    ./configure \
        --prefix="$INSTALL_ROOT" \
        --enable-static \
        --config-ldl=no \
        --config-pthread=no
) > "$CONFIGURE_LOG" 2>&1 || {
    echo "TinyCC configure failed; last lines:" >&2
    tail -60 "$CONFIGURE_LOG" >&2
    die "TinyCC configure failed (see $CONFIGURE_LOG)"
}

# Show the compiler configure settled on.
grep -E "^(CC|AR)[[:space:]]*=" "$TINYCC_WORK/config.mak" || true

MAKE_LOG=$LOG_ROOT/tinycc-make.log
echo "==> Building TinyCC (log: $MAKE_LOG)"
(
    cd "$TINYCC_WORK" &&
    make -j"$JOBS"
) > "$MAKE_LOG" 2>&1
MAKE_STATUS=$?
if [ "$MAKE_STATUS" -ne 0 ]; then
    echo "TinyCC build failed; last lines:" >&2
    tail -80 "$MAKE_LOG" >&2
    die "TinyCC build failed (see $MAKE_LOG)"
fi

INSTALL_LOG=$LOG_ROOT/tinycc-install.log
echo "==> Installing TinyCC into $INSTALL_ROOT"
(
    cd "$TINYCC_WORK" &&
    make install
) > "$INSTALL_LOG" 2>&1 || {
    echo "TinyCC install failed; last lines:" >&2
    tail -60 "$INSTALL_LOG" >&2
    die "TinyCC install failed (see $INSTALL_LOG)"
}

echo
echo "Success! TinyCC was built by Onramp without host gcc/binutils."
echo "  stage-0 tcc: $INSTALL_ROOT/bin/tcc"
echo "  build log:   $MAKE_LOG"
echo
echo "The stage-0 tcc is a wrapped Onramp program: put onrampvm on PATH before"
echo "running it, for example by sourcing $ONRAMP_DIR/env.sh."
echo
echo "Next stage (optional).  Note that the short-path workaround applies"
echo "again, so build in a short work dir if you continue:"
echo "  cd <short-work-dir>/tinycc"
echo "  make clean && rm -f config.*"
echo "  CC=$INSTALL_ROOT/bin/tcc AR=\"$INSTALL_ROOT/bin/tcc -ar\" \\"
echo "      ./configure --prefix=$BUILD_ROOT/tinycc/install-stage1 \\"
echo "      --enable-static --config-ldl=no --config-pthread=no && make && make install"

# A minimal smoke test.  The stage-0 tcc is an Onramp VM executable that emits
# native binaries, so -v should print a version without needing host tools.
if [ -x "$INSTALL_ROOT/bin/tcc" ]; then
    echo
    echo "==> Running the newly built tcc -v"
    "$INSTALL_ROOT/bin/tcc" -v || echo "    (tcc -v failed; see note above)"
fi

exit 0
