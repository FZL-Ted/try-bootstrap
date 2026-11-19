
llvm-3.5 's lld does not support aarch64, lld/ELF/Target.cpp AArch64TargetInfo +aarch64 in 3.8.

llvm-3.5 does not have musl support (libcxx), adds musl after 3.8.

So I switch to llvm-3.9.x.
