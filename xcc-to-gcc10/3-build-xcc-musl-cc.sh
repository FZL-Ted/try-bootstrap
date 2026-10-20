#!/bin/bash
#
# xcc-musl-cc — the CC wrapper for the third-party libraries and GCC: the compiler
# is xcc-musl, and the target libc is the **global sysroot** `rootfs3/usr/{include,lib}`
# (landed as musl-1 by [5.5] of `3-build-musl-xcc.sh`; `./3-adjust-rootfs-current.sh`
# later repoints those links at musl-gcc). Third-party libraries install there too.
#
# It does four things:
#   1) Drop GCC flags that xcc does not understand or that get in the way
#      (-MD/-MF/-Werror/-pipe/-ansi/-fPIC/-print-* and friends);
#   2) Inject `-I<shim>` for compiling/preprocessing: the shim holds only
#      stdarg.h (xcc's va_list support plus the `__isoc_va_list` alias) and a copy
#      of bits/alltypes.h that takes va_list/__isoc_va_list from that stdarg.h. It
#      must come first, because musl's bits/alltypes.h does `#include <stdarg.h>`
#      and xcc has to see the shim's version. **Do not** mirror musl headers in the
#      shim (they would shadow headers a package ships itself).
#   3) Add the sysroot's musl headers with `-idirafter` (**lowest priority**): a
#      package can still `#include <stdio.h>`, but the sysroot never wins over the
#      package's own `-I`. Using `-I<sysroot>/include` instead would shadow musl's
#      own tree headers (the kernel-header macro `hidden` from musl's
#      src/include/features.h) and a package's same-named header (for example
#      GCC's include/getopt.h, which musl's getopt.h would hide).
#   4) At link time inject the sysroot's crt1.o/crti.o/crtn.o + `-L<lib>` + `-lc`
#      and add `-nostdlib` (otherwise xcc links its own lib/crt0.a and its bundled
#      libc.a).
#
# Path resolution: everything is relative to this script, so it works both on the
# host and under chroot/bwrap.
#   DIR    = <rootfs3>/usr/xcc-musl
#   ROOTFS = <rootfs3> (rootfs root)
#   XCC    = <rootfs3>/usr/xcc-musl/bin/xcc           ← the xcc-musl compiler
#   SYSINC = <rootfs3>/usr/include  SYSLIB = <rootfs3>/usr/lib   ← global sysroot
#     (override with XCC_SYSINC / XCC_SYSLIB, e.g. to compile against musl-1's own
#      headers and libraries)
#
set -uo pipefail
DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"   # -> <rootfs3>/usr/xcc-musl
ROOTFS="$(cd "$DIR/../.." && pwd)"                         # -> <rootfs3> (rootfs root)
XCC="$DIR/bin/xcc"
# Bootstrap fallback: while xcc-musl itself is being built, $DIR/bin/xcc does not
# exist yet; the wrapper is then used to compile the third generation with the
# already-installed xcc-xcclib (the parent compiler).
[ -x "$XCC" ] || XCC="$DIR/../xcc-xcclib/bin/xcc"
SHIM="$DIR/shim"
# The target sysroot's include/lib; override with XCC_SYSINC / XCC_SYSLIB (the
# wrapper itself knows only these two paths).
SYSINC="${XCC_SYSINC:-$ROOTFS/usr/include}"
SYSLIB="${XCC_SYSLIB:-$ROOTFS/usr/lib}"

[ -x "$XCC" ] || { echo "xcc-musl-cc: compiler not found: $XCC" >&2; exit 1; }
[ -d "$SYSINC" ] || { echo "xcc-musl-cc: sysroot include directory not found: $SYSINC" >&2; exit 1; }
[ -f "$SYSLIB/libc.a" ] || { echo "xcc-musl-cc: $SYSLIB/libc.a not found" >&2; exit 1; }

args=(); skip=0; link=1
for a in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in
    -c|-E|-S) link=0; args+=("$a"); continue ;;
    -MD|-MMD|-MP|-MG) continue ;;
    -MF|-MT|-MQ|-aux-info) skip=1; continue ;;
    -Werror|-Werror=*) continue ;;
    -pipe|-frandom-seed=*|-fworking-directory|-fno-working-directory) continue ;;
    -ansi) continue ;;
    -print-file-name=*|-print-prog-name=*|-print-search-dirs) continue ;;
    -Wl,*) args+=("-Xlinker" "${a#-Wl,}"); continue ;;
    -fPIC|-fpic|-DPIC|-fno-omit-frame-pointer|-fomit-frame-pointer) continue ;;
    *) args+=("$a") ;;
  esac
done

extra=()
if [ "$link" = 1 ]; then
  extra=("-nostdlib" "$SYSLIB/crt1.o" "$SYSLIB/crti.o" "$SYSLIB/crtn.o" "-L$SYSLIB" "-lc")
fi
exec "$XCC" "-I$SHIM" "${args[@]}" "-idirafter" "$SYSINC" "${extra[@]}"
