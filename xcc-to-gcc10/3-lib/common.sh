#!/bin/bash
#
# 3-lib/common.sh — shared path constants and helper functions for the `3-` scripts.
#
# This build line bootstraps the toolchain generation by generation into rootfs3/,
# driven by the xcc source tree in xcc/ and the patch set in patches-3/.
# It reads and writes rootfs3/, xcc/ (the patches are applied there) and results/
# (its own logs); patches-3/ is read-only.
#
# This file is sourced by the 3-*.sh scripts. It does three things:
#   1) define the path constants (ROOT/ROOTFS3/XCC_SRC/...);
#   2) provide helper functions such as die/log/apply_patches/record;
#   3) declare the host tools the `3-` scripts are allowed to use (so each script can
#      disclose them in its documentation and logs).
#
# Design notes:
#   * The xcc source tree is **xcc/** itself (a git checkout). The scripts reset it
#     to HEAD and apply patches-3/ on top; keep uncommitted changes out of that tree
#     or commit them before running RESET=1.
#   * Toolchains are kept one directory per "generation": usr/xcc-boot,
#     usr/xcc-xcclib, usr/xcc-musl. Inside each directory the executables are still
#     named **xcc/cc1/cpp/as/ld** — xcc finds its sibling programs, include/ and lib/
#     via dirname(argv[0]), so renaming them would break it outright; the generation
#     is distinguished by the directory name, and usr/bin holds the entry links that
#     point at the "current generation".
#   * All logs go to results/3-*.log (tee), and results/3-STATE.env is maintained so
#     the next step can verify the state.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---- Sources and patches ----
XCC_SRC="$ROOT/xcc"                     # source tree (git checkout)
SRC="$XCC_SRC"                          # xcc source tree (git repo; HEAD = clean baseline)
PATCHES="$ROOT/patches-3"               # the xcc patch set
PATCH_NOTES="$ROOT/patches-notes-3"     # optional per-patch notes (not read by the build)
PATCHES_EXP="$PATCHES/experimental"     # experimental patches (not part of the build)

# ---- Products ----
ROOTFS="$ROOT/rootfs3"
BOOTDIR="$ROOTFS/usr/xcc-boot"
XCCLIBDIR="$ROOTFS/usr/xcc-xcclib"
MUSLDIR="$ROOTFS/usr/xcc-musl"          # private prefix of the third-generation (musl) xcc
ENTRYDIR="$ROOTFS/usr/bin"
MUSL1="$ROOTFS/usr/musl-1"              # standalone snapshot of the first musl build (include/ + lib/)
LOGDIR="$ROOT/results"
STATE="$LOGDIR/3-STATE.env"

JOBS="${JOBS:-$(nproc)}"
CLEAN="${CLEAN:-0}"

# ---- Host tool allowlist (disclosure only) ----
# Allowed: bash make git sed gawk grep sort uniq comm tar xz unzip ar nm ranlib file
#          readelf install cp mv rm mkdir ln cat head tail wc tr cut xargs stat cmp
#          sha256sum tee timeout bwrap (optional, for atomic smoke tests)
# Forbidden (except the host gcc bootstrap in 3-build-xcc-boot.sh): the host
#          gcc/cc/clang/c++/ld/as/cpp, and any header or library from /usr/include, /usr/lib.
HOST_TOOLS_OK="bash make git sed gawk grep sort uniq comm tar xz unzip ar nm ranlib file readelf install cp mv rm mkdir ln cat head tail wc tr cut xargs stat cmp sha256sum tee timeout bwrap"

die() { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }
info() { echo "==> $*"; }

# Record/read cross-script state (used by each step's precondition checks)
record() { # record <key> <value>
  mkdir -p "$LOGDIR"
  touch "$STATE"
  grep -v "^$1=" "$STATE" > "$STATE.tmp" 2>/dev/null || true
  mv "$STATE.tmp" "$STATE"
  echo "$1=$2" >> "$STATE"
}
recall() { # recall <key> [default]
  [ -f "$STATE" ] || { echo "${2:-}"; return; }
  local v; v="$(sed -n "s/^$1=//p" "$STATE" | tail -1)"
  echo "${v:-${2:-}}"
}

# Set up a log with tee: exec > >(tee ...) conflicts with set -e, so wrap it explicitly.
# Each script calls log_start <name> first; afterwards all stdout/stderr also go to the log.
log_start() { # log_start <logfile-name>
  mkdir -p "$LOGDIR"
  LOG="$LOGDIR/$1"
  # Keep the console output while writing the log (process substitution + exec)
  exec > >(tee "$LOG") 2>&1
  echo "### log: $LOG"
  echo "### time: $(date -Is)"
  echo "### host: $(uname -srm)"
  echo "### command: $0 $*"
}

# Verify that the 5 executables in a toolchain directory are static, with no PT_INTERP
check_static() { # check_static <bindir>
  local bindir="$1" f n
  for f in xcc cc1 cpp as ld; do
    [ -x "$bindir/$f" ] || die "missing executable: $bindir/$f"
    file -b "$bindir/$f" | grep -q 'statically linked' ||
      die "$bindir/$f is not statically linked: $(file -b "$bindir/$f")"
    n=$(readelf -l "$bindir/$f" | grep -c INTERP || true)
    [ "$n" = 0 ] || die "$bindir/$f contains PT_INTERP and still depends on the dynamic loader"
  done
}

# Whole-chain check: export HEAD to a temporary directory, apply **all** patches in
# alphabetical order, then compare file by file with the current working tree (only
# the files the patches touch).
# Why it is needed: patches edit the same regions as each other (for example a later
# patch lands in a region rewritten by xcc-inline-asm.patch), so for any intermediate
# patch
#   * `git apply --reverse --check` fails (the post-image was changed by later patches),
#   * `git apply --check` fails (the pre-image no longer exists),
# so per-patch checks all break down and the script would wrongly report a corrupted
# working tree and die (observed in practice).
# The whole-chain check does not rely on per-patch checks, and it matches the rule that
# "the patch chain is the source of truth".
patches_chain_matches_src() {
  local tmp rel p ok=1
  tmp="$(mktemp -d)" || return 1
  if ! { (cd "$SRC" && git archive HEAD) | tar -x -C "$tmp"; } 2>/dev/null; then
    rm -rf "$tmp"; return 1
  fi
  for p in "$@"; do
    if ! (cd "$tmp" && git apply "$p") >/dev/null 2>&1; then
      rm -rf "$tmp"; return 1
    fi
  done
  for rel in $(for p in "$@"; do
                 awk '/^\+\+\+ /{f=$2; sub(/^b\//,"",f); if (f != "/dev/null") print f}' "$p"
               done | sort -u); do
    if [ ! -e "$tmp/$rel" ] && [ ! -e "$SRC/$rel" ]; then continue; fi
    if ! cmp -s "$tmp/$rel" "$SRC/$rel"; then
      echo "      ✗ differs from the whole-chain result: $rel"
      ok=0; break
    fi
  done
  rm -rf "$tmp"
  [ "$ok" = 1 ]
}

# Idempotently apply patches-3/*.patch to $SRC (order = filename alphabetical order = dependency order)
#   * applies in reverse, or "all added lines already exist" -> already applied, skip;
#   * applies forward                                        -> apply it;
#   * neither works                                          -> the working tree is corrupted; die.
apply_patches_3() {
  [ -d "$SRC/.git" ] || die "the xcc source tree is not a git repository: $SRC (needed to tell whether the patches are applied)"
  info "applying patches ($PATCHES/*.patch)"
  shopt -s nullglob
  local -a ps=("$PATCHES"/*.patch)
  shopt -u nullglob
  [ "${#ps[@]}" -gt 0 ] || die "no patches found: $PATCHES/*.patch"

  # Do the whole-chain check first: if the working tree already equals "HEAD + all
  # patches", skip everything (the most common case).
  if patches_chain_matches_src "${ps[@]}"; then
    echo "    all ${#ps[@]} patches already applied (whole-chain check passed), skipping"
    return 0
  fi

  # Otherwise handle them one by one: forward apply = apply it, reverse apply = already applied.
  local p name
  for p in "${ps[@]}"; do
    name="$(basename "$p")"
    if (cd "$SRC" && git apply "$p") >/dev/null 2>&1; then
      echo "    applied: $name"
    elif (cd "$SRC" && git apply --reverse --check "$p") >/dev/null 2>&1; then
      echo "    skipped (already applied): $name"
    else
      die "patch does not apply, and the working tree matches neither the clean baseline nor the whole-chain result: $p"
    fi
  done
}

# Restore the xcc source tree to the clean baseline (HEAD), discarding all uncommitted changes and build products
reset_src() {
  [ -d "$SRC/.git" ] || die "the xcc source tree is not a git repository: $SRC"
  (cd "$SRC" && git checkout -q -- . && git clean -qfdx -e '*.log' >/dev/null 2>&1 || true)
  echo "    restored to baseline: $(cd "$SRC" && git log --oneline -1)"
}

# Before generating the per-generation entry links, clear the old ones (only our own names)
clean_entry() {
  rm -f "$ENTRYDIR"/xcc "$ENTRYDIR"/cc1 "$ENTRYDIR"/cpp "$ENTRYDIR"/as "$ENTRYDIR"/ld
  rm -f "$ENTRYDIR"/include "$ENTRYDIR"/lib
}

# Install one generation of the toolchain: install_toolchain <source prefix name gen2|''> <destination prefix dir> <entry name tag>
# Example: install_toolchain gen2 "$BOOTDIR" boot   → $BOOTDIR/bin/{xcc,cc1,cpp,as,ld}
install_toolchain() { # install_toolchain <src-prefix> <destdir> <generation-tag>
  local pfx="$1" dest="$2" tag="$3" f
  mkdir -p "$dest/bin" "$dest/lib"
  for f in xcc cc1 cpp as ld; do
    [ -x "$SRC/$pfx$f" ] || die "missing build product: $SRC/$pfx$f"
    install -m 755 "$SRC/$pfx$f" "$dest/bin/$f"
  done
  # crt0/libc of the bundled libc (used by bootstrap links and the "xcc with its own libc" stage)
  install -m 644 "$SRC/lib/crt0.a" "$SRC/lib/libc.a" "$dest/lib/" 2>/dev/null || true
  ln -sfn ../lib "$dest/bin/lib"
  echo "    installed [$tag] -> $dest/bin/{xcc,cc1,cpp,as,ld}"
}

# Print a directory listing (for reports)
tree_report() { # tree_report <dir> <indent>
  local d="$1" ind="${2:-  }"
  [ -d "$d" ] || return 0
  find "$d" -maxdepth 3 \( -type f -o -type l \) -printf '%y %-58p %s\n' 2>/dev/null |
    sort -k2 | sed "s|$ROOT/||" | sed "s/^/$ind/"
}

# Install/copy a directory tree to the target (keeping symlinks and permissions), idempotent
copy_tree() { # copy_tree <src> <dst>
  local s="$1" d="$2"
  mkdir -p "$d"
  (cd "$s" && tar cf - .) | (cd "$d" && tar xf -)
}

# Compare two musl build directories (<dir>/{include,lib}): report include differences,
# libc.a hashes, and per-member differences of crt*.o and libc.a.
# Arguments: compare_musl <name1> <dir1> <name2> <dir2>
compare_musl() {
  local n1="$1" d1="$2" n2="$3" d2="$4"
  local h1 h2 diff_inc diff_crt n_diff n_same tmp
  echo "  libc.a:"
  for x in "$n1 $d1" "$n2 $d2"; do
    set -- $x
    if [ -f "$2/lib/libc.a" ]; then
      printf '    %-8s %10s bytes / %5s members / sha256 %s\n' "$1" \
        "$(stat -c%s "$2/lib/libc.a")" "$(ar t "$2/lib/libc.a" | wc -l)" \
        "$(sha256sum "$2/lib/libc.a" | cut -c1-16)"
    else
      printf '    %-8s (missing)\n' "$1"
    fi
  done
  h1=$(sha256sum "$d1/lib/libc.a" 2>/dev/null | cut -c1-16)
  h2=$(sha256sum "$d2/lib/libc.a" 2>/dev/null | cut -c1-16)
  if [ -n "$h1" ] && [ "$h1" = "$h2" ]; then
    echo "    ✅ the libc.a of $n1 and $n2 are byte-identical"
  else
    echo "    ⚠️  libc.a differ ($h1 vs $h2); per-member comparison:"
    tmp=$(mktemp -d)
    mkdir -p "$tmp/a" "$tmp/b"
    d1abs="$(cd "$d1" && pwd)"; d2abs="$(cd "$d2" && pwd)"
    (cd "$tmp/a" && ar x "$d1abs/lib/libc.a") 2>/dev/null || true
    (cd "$tmp/b" && ar x "$d2abs/lib/libc.a") 2>/dev/null || true
    n_same=0; n_diff=0
    for o in "$tmp/a"/*; do
      b=$(basename "$o")
      if [ -f "$tmp/b/$b" ]; then
        if cmp -s "$o" "$tmp/b/$b"; then n_same=$((n_same+1)); else n_diff=$((n_diff+1)); echo "      different: $b"; fi
      else
        echo "      only in $n1: $b"
      fi
    done
    echo "    same $n_same / different $n_diff"
    rm -rf "$tmp"
  fi
  echo "  crt*.o:"
  for f in crt1.o crti.o crtn.o rcrt1.o Scrt1.o; do
    [ -f "$d1/lib/$f" ] && [ -f "$d2/lib/$f" ] || continue
    printf '    %-8s ' "$f"
    cmp -s "$d1/lib/$f" "$d2/lib/$f" && echo IDENTICAL || echo DIFFER
  done
  echo "  include/ header differences ($n1 vs $n2):"
  # Note: the caller (3-build-musl-gcc.sh) runs with `set -e`, and `diff` returns 1 when
  # there are differences, so a direct `diff | wc -l` would abort the whole script through
  # the non-zero pipeline status (observed: only the heading was printed before it exited).
  # Ignore diff's exit code explicitly here.
  diff_inc=$( { diff -rq "$d1/include" "$d2/include" 2>&1 || true; } | wc -l)
  if [ "$diff_inc" = 0 ]; then
    echo "    identical"
  else
    echo "    $diff_inc differences:"
    { diff -rq "$d1/include" "$d2/include" 2>&1 || true; } | sed 's/^/      /' | head -20
  fi
}
