#!/usr/bin/env bash
# Build LLVM/Clang 3.5.2 (clang + libc++/libc++abi + core LLVM tools) from
# ./llvm-project-3.5 with the host GCC.  Source copy, build trees and the
# install tree all live under ./build/llvm3.5-host/.
#
# The compiler, its libraries and all installed tools are static.  LLVM 3.5
# contains no C library (and its lld cannot link against -L/-l), so linking a
# user program still uses the host C headers/static libs and the host ld; the
# resulting program has no runtime dependency on them when built with -static.
set -euo pipefail

root=$(cd "$(dirname "$0")" && pwd)
src=$root/llvm-project-3.5
out=$root/build/llvm3.5-host
tree=$out/src
tc=$out/toolchain
jobs=${JOBS:-$(nproc)}
cc=${CC:-gcc}
cxx=${CXX:-g++}

rm -rf "$out"
mkdir -p "$out"
cp -a "$src" "$tree"

# ---- compatibility fixes for a 2020s host toolchain -------------------------
# Modern libstdc++ requires std::set comparators to be const-callable.
sed -i 's/^  bool operator()(const ValueType &LHS, const ValueType &RHS) {$/  bool operator()(const ValueType \&LHS, const ValueType \&RHS) const {/' \
    "$tree/llvm/utils/TableGen/AsmWriterEmitter.cpp"
sed -i 's/    operator()(const PoolEntry\* a, const CostKeyT &b) {/    operator()(const PoolEntry* a, const CostKeyT \&b) const {/; s/    bool operator()(const PoolEntry\* a, const PoolEntry\* b) {/    bool operator()(const PoolEntry* a, const PoolEntry* b) const {/' \
    "$tree/llvm/include/llvm/CodeGen/PBQP/CostAllocator.h"
sed -i 's/  bool operator()(const Vector &A, const Vector &B) {/  bool operator()(const Vector \&A, const Vector \&B) const {/; s/  bool operator()(const Matrix &A, const Matrix &B) {/  bool operator()(const Matrix \&A, const Matrix \&B) const {/' \
    "$tree/llvm/include/llvm/CodeGen/PBQP/Math.h"
sed -i 's/        bool operator()(NodeId N1Id, NodeId N2Id) {/        bool operator()(NodeId N1Id, NodeId N2Id) const {/' \
    "$tree/llvm/include/llvm/CodeGen/PBQP/RegAllocSolver.h"
perl -0pi -e 's/(bool operator\(\)\(const MCWriteProcResEntry &LHS,\s*const MCWriteProcResEntry &RHS\)) \{/$1 const {/' \
    "$tree/llvm/utils/TableGen/SubtargetEmitter.cpp"
# clang 3.5 only parsed "4.8"-style GCC versions; accept "16" as well.
perl -0pi -e 's/  if \(Second\.first\.getAsInteger\(10, GoodVersion\.Minor\) \|\|\n      GoodVersion\.Minor < 0\)\n    return BadVersion;/  if (Second.first.empty())\n    GoodVersion.Minor = 0;\n  else if (Second.first.getAsInteger(10, GoodVersion.Minor) ||\n           GoodVersion.Minor < 0)\n    return BadVersion;/' \
    "$tree/clang/lib/Driver/ToolChains.cpp"
# glibc >= 2.26 folded <xlocale.h> into <locale.h>.
sed -i 's/#elif (defined(__GLIBC__) || defined(__APPLE__)      || defined(__FreeBSD__) \\/#elif (defined(__APPLE__)      || defined(__FreeBSD__) \\/' \
    "$tree/libcxx/include/__locale"

common=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5)

# ---- stage 1: static clang and LLVM tools ----------------------------------
cmake -S "$tree/llvm" -B "$out/llvm" "${common[@]}" \
    -DCMAKE_C_COMPILER="$cc" -DCMAKE_CXX_COMPILER="$cxx" \
    -DLLVM_TARGETS_TO_BUILD=X86 -DLLVM_EXTERNAL_CLANG_SOURCE_DIR="$tree/clang" \
    -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_DOCS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_ZLIB=OFF \
    -DCLANG_ENABLE_ARCMT=OFF -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
    -DCMAKE_C_FLAGS="-O2 -w" \
    -DCMAKE_CXX_FLAGS="-O2 -w -include cstdint -fno-access-control" \
    -DCMAKE_EXE_LINKER_FLAGS=-static -DCMAKE_INSTALL_PREFIX="$tc"
ninja -C "$out/llvm" -j"$jobs" clang llvm-config llvm-ar llvm-nm llvm-size \
    llvm-objdump llvm-readobj llvm-link llvm-as llvm-dis opt llc

mkdir -p "$tc/bin" "$tc/lib" "$tc/share/llvm"
cp -a "$out/llvm/bin"/{clang-3.5,llvm-config,llvm-ar,llvm-nm,llvm-ranlib,llvm-size,\
llvm-objdump,llvm-readobj,llvm-link,llvm-as,llvm-dis,opt,llc} "$tc/bin/"
ln -sf clang-3.5 "$tc/bin/clang"
ln -sf clang-3.5 "$tc/bin/clang++"
cp -a "$out/llvm/lib/clang" "$tc/lib/"
cp -a "$out/llvm/share/llvm/cmake" "$tc/share/llvm/"

# ---- static libc++ and libc++abi ------------------------------------------
cmake -S "$tree/libcxx" -B "$out/libcxx" "${common[@]}" \
    -DCMAKE_C_COMPILER="$tc/bin/clang" -DCMAKE_CXX_COMPILER="$tc/bin/clang++" \
    -DCMAKE_C_FLAGS="-O2 -w" -DCMAKE_CXX_FLAGS="-O2 -w" \
    -DCMAKE_INSTALL_PREFIX="$tc" -DLIBCXX_ENABLE_SHARED=OFF \
    -DLIBCXX_ENABLE_ASSERTIONS=OFF -DLIBCXX_CXX_ABI=libcxxabi \
    -DLIBCXX_LIBCXXABI_INCLUDE_PATHS="$tree/libcxxabi/include"
ninja -C "$out/libcxx" -j"$jobs" cxx
cmake --install "$out/libcxx"

cmake -S "$tree/libcxxabi" -B "$out/libcxxabi" "${common[@]}" \
    -DCMAKE_C_COMPILER="$tc/bin/clang" -DCMAKE_CXX_COMPILER="$tc/bin/clang++" \
    -DCMAKE_C_FLAGS="-O2 -w" -DCMAKE_CXX_FLAGS="-O2 -w" \
    -DCMAKE_INSTALL_PREFIX="$tc" -DLLVM_CONFIG="$tc/bin/llvm-config" \
    -DLLVM_NO_OLD_LIBSTDCXX=1 -DLIBCXXABI_ENABLE_SHARED=OFF \
    -DLIBCXXABI_ENABLE_ASSERTIONS=OFF \
    -DLIBCXXABI_LIBCXX_INCLUDES="$tree/libcxx/include" \
    -DLIBCXXABI_USE_LLVM_UNWINDER=OFF
ninja -C "$out/libcxxabi" -j"$jobs" cxxabi
cmake --install "$out/libcxxabi"

# ---- stage 2: make clang default to the bundled libc++ ---------------------
perl -0pi -e 's/(ToolChain::CXXStdlibType ToolChain::GetCXXStdlibType\(const ArgList &Args\) const\{.*?\n  return ToolChain::CST_)Libstdcxx;/$1Libcxx;/s' \
    "$tree/clang/lib/Driver/ToolChain.cpp"
perl -0pi -e 's/(  case ToolChain::CST_Libcxx:\n    CmdArgs\.push_back\("-lc\+\+"\);\n)/$1    CmdArgs.push_back("-lc++abi");\n/' \
    "$tree/clang/lib/Driver/ToolChain.cpp"
ninja -C "$out/llvm" -j"$jobs" clang
cp -a "$out/llvm/bin/clang-3.5" "$tc/bin/"

# ---- verification: static compiler, static C++ program in bwrap ------------
mkdir -p "$out/smoke"
cat > "$out/smoke/hello.cc" <<'EOF'
#include <iostream>
#include <string>
#include <vector>
int main() {
  std::vector<std::string> v{"hello", "static", "c++"};
  for (const auto &s : v) std::cout << s << ' ';
  std::cout << std::endl;
}
EOF
if command -v bwrap >/dev/null; then
  bwrap --unshare-pid --die-with-parent --tmpfs / \
      --ro-bind "$tc" /tc --dev /dev --proc /proc /tc/bin/clang --version
  bwrap --unshare-pid --die-with-parent --ro-bind /usr /usr --ro-bind /lib /lib \
      --ro-bind /lib64 /lib64 --ro-bind "$tc" /tc --bind "$out/smoke" /work \
      --dev /dev --proc /proc --tmpfs /tmp --setenv PATH /tc/bin:/usr/bin \
      /tc/bin/clang++ -std=c++11 -static /work/hello.cc -o /work/hello
  bwrap --unshare-pid --die-with-parent --tmpfs / \
      --ro-bind "$out/smoke/hello" /hello --dev /dev --proc /proc /hello
fi
echo "toolchain: $tc"
