#!/bin/bash
#
# 3-adjust-rootfs-current.sh — point the "current generation" of rootfs3 at the **newest gcc / musl / libraries**
#
# What it does (only symlinks and small wrappers inside rootfs3; reversible and re-runnable):
#
#   [1] **Switch the global sysroot to musl-gcc**: the symlinks in `rootfs3/usr/{include,lib}`
#       that point at **musl-1** (99 + 7 = 106 of them, all at the top level) are repointed to
#       **musl-gcc** (the musl rebuilt completely by gcc46).
#       (musl-1 is the product of `3-build-musl-xcc.sh` and the target libc of the xcc chain.)
#       The headers and libraries of the four libraries are **real files** (gmp.h, mpfr.h,
#       mpc.h, zlib.h, zconf.h plus the four .a files), so they are unaffected;
#       ./3-build-deps-gcc46.sh rebuilds them with gcc46 later in the chain.
#
#   [2] **Point the commands in `rootfs3/usr/bin/` at the newest generation**:
#         * `gcc` `g++` `cc` `c++` `cpp` `gcov` → **small wrappers** that exec
#           `rootfs3<GCC_PREFIX>/bin/*` (default `GCC_PREFIX=/usr/gcc46`; after installing
#           GCC 10, switch over with `GCC_PREFIX=/usr/gcc10 ./3-adjust-rootfs-current.sh`).
#           **Why wrappers instead of symlinks**: GCC derives `gcc_exec_prefix` from
#           `argv[0]` (the configured prefix is `/usr/gcc46` while it really lives in
#           `rootfs3/usr/gcc46`, and this derivation bridges the two); once a symlink is
#           resolved the derivation lands nowhere, whereas a wrapper execs an **absolute
#           path**, so the bare command name works from an absolute path, a relative path
#           or through PATH.
#         * `as` `ld` `ar` `ranlib` `nm` → symlinks to the **self-built binutils**
#           (`usr/binutils/bin/`).
#         * `xcc` `cc1` `xcc-musl-cc` are left alone (the xcc generation's entries; older
#           scripts still use them by explicit path).
#
#   [3] Acceptance: compile and run C and C++ with the **bare command names**; print gcc's
#       sysroot / search directories / four-library locations; verify that **all** musl
#       links in `usr/{include,lib}` point at musl-gcc.
#
# Usage:
#   ./3-adjust-rootfs-current.sh            # switch to the "newest" generation (default)
#   RESTORE=1 ./3-adjust-rootfs-current.sh  # roll back: musl links point at musl-1 again, usr/bin returns to the xcc entries
#
# ⚠️ Impact (informed choice):
#   * After the switch, the xcc generation's `xcc-musl-cc` (default sysroot = `rootfs3/usr`)
#     sees the **musl-gcc headers** (including the true 80-bit `long double`) — xcc cannot
#     handle an 80-bit `long double`. So **when re-running the older xcc stages, point the
#     sysroot back at musl-1 explicitly** (`XCC_SYSINC/XCC_SYSLIB`, or
#     `-I/-L rootfs3/usr/musl-1/...`). The gcc path is unaffected (that is exactly what this
#     switch is for).
#   * Only symlinks are changed and small wrappers added; `musl-1/` and the four libraries
#     are **never deleted**, and `usr/binutils/` is untouched.
#     Rollback: `RESTORE=1 ./3-adjust-rootfs-current.sh`.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
ROOTFS="$ROOT/rootfs3"
USR="$ROOTFS/usr"
INC="$USR/include"
LIB="$USR/lib"
BIN="$USR/bin"
GCC46="$USR/gcc46"                          # historical default generation (kept for reference)
# Which gcc generation to point at: gcc-4.6 (/usr/gcc46) by default; `GCC_PREFIX=/usr/gcc10` switches to GCC 10.4.0
GCC_PREFIX="${GCC_PREFIX:-/usr/gcc46}"
GCC_SUBDIR="${GCC_PREFIX#/usr/}"          # gcc46 / gcc10
GCC_DIR="$USR/$GCC_SUBDIR"
BINUTILS="$USR/binutils/bin"
OLD_MUSL="musl-1"
NEW_MUSL="musl-gcc"
LOGDIR="$ROOT/results"
LOG="$LOGDIR/3-adjust-rootfs-current.log"

RESTORE="${RESTORE:-0}"

die()  { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }
note() { printf '\n==> %s\n' "$*"; }

mkdir -p "$LOGDIR"
exec > >(tee "$LOG") 2>&1

# ---------------------------------------------------------------- 0. Precondition checks
if [ "$RESTORE" = 1 ]; then
  note "[0/4] RESTORE=1: preparing to roll back to musl-1 + xcc entries"
else
  note "[0/4] checking inputs and host tools"
fi
[ -d "$USR" ] || die "cannot find $USR"
[ -f "$USR/$NEW_MUSL/lib/libc.a" ] || die "missing $USR/$NEW_MUSL/lib/libc.a (run SELFTEST=1 ./3-build-musl-gcc.sh first)"
[ -f "$USR/$NEW_MUSL/lib/crt1.o" ] || die "missing $USR/$NEW_MUSL/lib/crt1.o"
[ -f "$USR/$NEW_MUSL/include/stdio.h" ] || die "missing $USR/$NEW_MUSL/include/stdio.h"
[ -d "$USR/$OLD_MUSL/lib" ] || warn "cannot find $USR/$OLD_MUSL (needed by rollback mode)"
[ -x "$GCC_DIR/bin/gcc" ] || die "missing $GCC_DIR/bin/gcc (run ./3-build-gcc46-stage2.sh or ./3-build-gcc10.sh first)"
[ -x "$GCC_DIR/bin/g++" ] || die "missing $GCC_DIR/bin/g++"
for t in as ld ar ranlib nm; do
  [ -x "$BINUTILS/$t" ] || die "missing the self-built binutils: $BINUTILS/$t (run ./3-build-binutils.sh first)"
done
for t in bash find readlink ln rm mkdir cat head tail sed; do
  command -v "$t" >/dev/null 2>&1 || die "missing host tool: $t"
done
echo "    current gcc/g++ : $GCC_DIR/bin/{gcc,g++}  ($("$GCC_DIR/bin/gcc" --version 2>/dev/null | head -1))"
echo "    newest musl     : $USR/$NEW_MUSL  (libc.a $(stat -Lc%s "$USR/$NEW_MUSL/lib/libc.a") bytes)"
echo "    old musl (kept) : $USR/$OLD_MUSL"
echo "    self-built binutils: $BINUTILS"

# Note: print the current state before switching (so it can be checked or rolled back by hand)
echo "    symlink targets at the top level of usr/include before the switch:"
find "$INC" -maxdepth 1 -type l -exec readlink {} \; | sed 's|.*\.\./||; s|/.*||' | sort | uniq -c | sed 's/^/      /'
echo "    symlink targets at the top level of usr/lib before the switch:"
find "$LIB" -maxdepth 1 -type l -exec readlink {} \; | sed 's|.*\.\./||; s|/.*||' | sort | uniq -c | sed 's/^/      /'

# ---------------------------------------------------------------- 1. Global sysroot
repoint_dir() {   # $1=dir $2=old name $3=new name   → prints how many entries were changed
  local d="$1" old="$2" new="$3" n=0 l tgt
  while IFS= read -r l; do
    tgt="$(readlink "$l")"
    case "$tgt" in
      *"$old"*) ln -sfn "${tgt//$old/$new}" "$l"; n=$((n+1)) ;;
    esac
  done < <(find "$d" -maxdepth 1 -type l -print)
  echo "$n"
}

if [ "$RESTORE" = 1 ]; then
  note "[1/4] rolling back the global sysroot: $NEW_MUSL → $OLD_MUSL"
  n1=$(repoint_dir "$INC" "$NEW_MUSL" "$OLD_MUSL")
  n2=$(repoint_dir "$LIB" "$NEW_MUSL" "$OLD_MUSL")
  echo "    usr/include repointed back: $n1, usr/lib: $n2"
else
  note "[1/4] switching the global sysroot to the newest musl: $OLD_MUSL → $NEW_MUSL"
  n1=$(repoint_dir "$INC" "$OLD_MUSL" "$NEW_MUSL")
  n2=$(repoint_dir "$LIB" "$OLD_MUSL" "$NEW_MUSL")
  echo "    usr/include repointed: $n1, usr/lib: $n2"
  # Idempotency/sanity check: no top-level link should still point at $OLD_MUSL afterwards (unless it was mixed to begin with)
  left=$( { find "$INC" -maxdepth 1 -type l -exec readlink {} \; ; find "$LIB" -maxdepth 1 -type l -exec readlink {} \; ; } | grep -c "\.\./$OLD_MUSL/" || true)
  echo "    top-level links still pointing at $OLD_MUSL: $left"
  [ "$left" = 0 ] || warn "$left links still point at $OLD_MUSL (fine if they belong to the four libraries or something else; please check by hand)"
fi

# Also: `usr/bin/{include,lib}` are two stray musl links under bin/ (the real sysroot is
# `usr/{include,lib}`, handled above). They are not deleted here, only made to follow the
# current generation.
CUR_MUSL="$NEW_MUSL"; [ "$RESTORE" = 1 ] && CUR_MUSL="$OLD_MUSL"
for n in include lib; do
  if [ -L "$BIN/$n" ]; then
    ln -sfn "../$CUR_MUSL/$n" "$BIN/$n"
    echo "    also: usr/bin/$n -> $(readlink "$BIN/$n")"
  fi
done

# ---------------------------------------------------------------- 2. usr/bin commands
note "[2/4] usr/bin commands → current generation"
if [ "$RESTORE" = 1 ]; then
  # Rollback: remove the compiler wrappers/binutils links added by this script and restore cpp/as/ld to xcc-musl
  for c in gcc g++ cc c++ cpp gcov ar ranlib nm; do rm -f "$BIN/$c"; done
  for pair in "as:as" "ld:ld" "cpp:cpp"; do
    ln -sfn "../xcc-musl/bin/${pair##*:}" "$BIN/${pair%%:*}"
  done
  ln -sfn ../xcc-musl/bin/cc1  "$BIN/cc1"
  echo "    restored: usr/bin/{cpp,as,ld,cc1} -> ../xcc-musl/bin/* (and removed gcc/g++/cc/c++/gcov/ar/ranlib/nm)"
else
  # Compiler commands: small wrappers (exec an absolute path so GCC can derive gcc_exec_prefix from argv[0])
  mk_wrapper() {   # $1=command name $2=real file inside $GCC_SUBDIR
    # ★ rm -f first: `$BIN/<command>` may be a **symlink** from an earlier layout (for
    #   example `cpp -> ../xcc-musl/bin/cpp`), and `cat > symlink` follows the link and
    #   writes into the **target file**, overwriting the real binary of the previous
    #   toolchain (this actually happened once: xcc-musl's `cpp` was overwritten with a
    #   507-byte wrapper and had to be restored afterwards).
    rm -f "$BIN/$1"
    cat > "$BIN/$1" <<WRAP_EOF
#!/bin/sh
# Generated by 3-adjust-rootfs-current.sh: point the bare command "$1" at the "current generation" gcc ($GCC_PREFIX).
# Exec an absolute path (rather than using a symlink) so GCC can derive gcc_exec_prefix
# from argv[0] — the configured prefix is $GCC_PREFIX while it really lives in <rootfs>$GCC_PREFIX.
d=\$(cd -- "\$(dirname -- "\$0")/.." 2>/dev/null && pwd) || d=
[ -n "\$d" ] && [ -x "\$d/$GCC_SUBDIR/bin/$2" ] || d=$USR
exec "\$d/$GCC_SUBDIR/bin/$2" "\$@"
WRAP_EOF
    chmod 755 "$BIN/$1"
  }
  mk_wrapper gcc  gcc
  mk_wrapper cc   gcc
  mk_wrapper g++  g++
  mk_wrapper c++  g++
  mk_wrapper cpp  cpp
  mk_wrapper gcov gcov
  echo "    wrappers: usr/bin/{gcc,cc} → $GCC_PREFIX/bin/gcc; {g++,c++} → g++; cpp/gcov → their own"
  # Assembler/linker/archiver: symlink directly to the self-built binutils
  for t in as ld ar ranlib nm; do ln -sfn "../binutils/bin/$t" "$BIN/$t"; done
  echo "    symlinks: usr/bin/{as,ld,ar,ranlib,nm} → ../binutils/bin/*"
  echo "    left alone: usr/bin/{xcc,cc1,xcc-musl-cc} (the xcc generation's entries)"
fi

# ---------------------------------------------------------------- 3. Acceptance
note "[3/4] acceptance: bare commands + sysroot/library lookup"
echo "    --- usr/bin now ---"
ls -l "$BIN" | awk 'NR>1 {printf "      %-12s %s\n", $9, $10" "$11}' | sort

if [ "$RESTORE" = 1 ]; then
  echo "    (rollback mode: no compile acceptance)"
else
  T="$ROOTFS/tests"; mkdir -p "$T"
  cat > "$T/3-adjust-current.c" <<'C_EOF'
#include <stdio.h>
#include <gmp.h>
int main(void) { mpz_t z; mpz_init_set_ui(z, 6); mpz_mul_ui(z, z, 7);
  printf("current-c %ld gmp_ok\n", mpz_get_ui(z)); mpz_clear(z); return 0; }
C_EOF
  cat > "$T/3-adjust-current.cc" <<'CXX_EOF'
#include <iostream>
#include <string>
#include <vector>
#include <mpfr.h>
int main() { std::vector<std::string> v; v.push_back("current-cxx"); mpfr_t x; mpfr_init2(x, 53);
  mpfr_set_d(x, 2.0, MPFR_RNDN); mpfr_sqrt(x, x, MPFR_RNDN);
  std::cout << v[0] << " mpfr_sqrt2=" << mpfr_get_d(x, MPFR_RNDN) << std::endl; mpfr_clear(x); return 0; }
CXX_EOF
  # Compile with the **bare command names** (found through PATH) to simulate real use
  export PATH="$BIN:$PATH"
  W="$ROOTFS/build/adjust-rootfs"; mkdir -p "$W"
  echo "    gcc --version : $(gcc --version | head -1)"
  echo "    gcc -print-sysroot : $(gcc -print-sysroot)"
  echo "    gcc -print-file-name=libc.a    : $(gcc -print-file-name=libc.a)"
  echo "    gcc -print-file-name=libgmp.a  : $(gcc -print-file-name=libgmp.a)"
  echo "    gcc -print-file-name=libstdc++.a (via g++): $(g++ -print-file-name=libstdc++.a)"
  if gcc -o "$W/c" "$T/3-adjust-current.c" -lgmp 2>"$W/c.err"; then
    out="$("$W/c")"; echo "    C   : \"$out\"  $(file -b "$W/c" | cut -d, -f1-2)"
    [ "$out" = "current-c 42 gmp_ok" ] || warn "unexpected C output (expected current-c 42 gmp_ok)"
  else
    sed -n '1,10p' "$W/c.err" | sed 's/^/      /'; warn "bare gcc failed to compile C (with -lgmp)"
  fi
  if g++ -o "$W/cc" "$T/3-adjust-current.cc" -lmpfr -lgmp 2>"$W/cc.err"; then
    out="$("$W/cc")"; echo "    C++ : \"$out\"  $(file -b "$W/cc" | cut -d, -f1-2)"
    case "$out" in current-cxx*1.41421*) ;; *) warn "unexpected C++ output (expected current-cxx mpfr_sqrt2=1.41421…)" ;; esac
  else
    sed -n '1,10p' "$W/cc.err" | sed 's/^/      /'; warn "bare g++ failed to compile C++ (with -lmpfr)"
  fi
  # Look directly at where the musl links point
  echo "    --- where the musl links in usr/{include,lib} point now ---"
  find "$INC" -maxdepth 1 -type l -exec readlink {} \; | sed 's|.*\.\./||; s|/.*||' | sort | uniq -c | sed 's/^/      /'
  find "$LIB" -maxdepth 1 -type l -exec readlink {} \; | sed 's|.*\.\./||; s|/.*||' | sort | uniq -c | sed 's/^/      /'
fi

# ---------------------------------------------------------------- 4. Record
source "$ROOT/3-lib/common.sh" 2>/dev/null || true
if command -v record >/dev/null 2>&1; then
  record ROOTFS_CURRENT_MUSL "$USR/$NEW_MUSL"
  record ROOTFS_CURRENT_GCC "$GCC_DIR/bin/gcc"
  record ROOTFS_CURRENT_GXX "$GCC_DIR/bin/g++"
  record ROOTFS_CURRENT_GCC_PREFIX "$GCC_PREFIX"
  record ROOTFS_CURRENT_AS "$BINUTILS/as"
  record ROOTFS_CURRENT_LD "$BINUTILS/ld"
  record ROOTFS_CURRENT_MODE "$([ "$RESTORE" = 1 ] && echo restored-to-xcc-musl1 || echo "newest-$GCC_SUBDIR-muslgcc")"
  record ROOTFS_CURRENT_INC_MUSL_LINKS "$(find "$INC" -maxdepth 1 -type l -exec readlink {} \; | grep -c "$NEW_MUSL" || true)"
  record ROOTFS_CURRENT_LIB_MUSL_LINKS "$(find "$LIB" -maxdepth 1 -type l -exec readlink {} \; | grep -c "$NEW_MUSL" || true)"
fi

note "[4/4] done (log: $LOG)"
cat <<EOF
  Current generation (rootfs3/usr):
  gcc/g++/cc/c++/cpp/gcov  →  small wrappers in usr/bin → $GCC_PREFIX/bin/* (current gcc)
    as/ld/ar/ranlib/nm       →  usr/binutils/bin/* (self-built binutils)
    libc/headers             →  usr/musl-gcc (newest musl)
    four libraries (headers + .a) → usr/{include,lib} (the copy rebuilt with gcc46)
  Rollback: RESTORE=1 ./3-adjust-rootfs-current.sh
EOF
