#!/usr/bin/env bash
#
# Apply the LLVM/Clang 3.9 compatibility patches used by
# refhost-llvm3.9.x-{1,2,bootstrap}.sh.
#
# Usage: apply.sh <source-root>
#   <source-root> must contain llvm/, clang/, libcxx/, compiler-rt/, lld/.
#
# The script is idempotent: each patch is skipped if its marker is already
# present.  It is intentionally host-side and uses the host `patch` utility.
set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
SRC=${1:?usage: apply.sh <source-root>}

die() { printf 'apply.sh: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

[ -d "$SRC/llvm" ] || die "not a 3.9 source root: $SRC"
[ -d "$SRC/libcxx" ] || die "missing libcxx under $SRC"

apply() {
  local patch=$1 marker=$2 file=$3
  [ -f "$DIR/$patch" ] || die "missing patch: $DIR/$patch"
  if grep -q -- "$marker" "$SRC/$file"; then
    info "patch already applied: $patch"
    return 0
  fi
  info "applying $patch"
  patch -p1 --forward --batch -d "$SRC" < "$DIR/$patch" || \
    die "failed to apply $patch"
}

apply libcxx-locale-strtoll.patch \
  'long long __ll = strtoll(__a' libcxx/include/locale
apply libcxx-stddef-max-align.patch \
  '__DEFINED_max_align_t' libcxx/include/stddef.h
apply libcxx-system-error-strerror-r.patch \
  '(void)new_errno;' libcxx/src/system_error.cpp
apply llvm-dynamiclibrary-const-stdio.patch \
  'return (void\*)&SYM' llvm/lib/Support/DynamicLibrary.cpp
apply llvm-cmake-cmp0051-new.patch \
  'cmake_policy(SET CMP0051 NEW)' llvm/CMakeLists.txt
apply clang-lexer-no-sse2.patch \
  'EDG_BOOTSTRAP_NO_SSE2' clang/lib/Lex/Lexer.cpp
apply clang-sourcemanager-no-sse2.patch \
  'EDG_BOOTSTRAP_NO_SSE2' clang/lib/Basic/SourceManager.cpp

info "all 3.9 patches applied (or already present)"
