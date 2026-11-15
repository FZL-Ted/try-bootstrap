# try-bootstrap

## Introduction

This is a project focus on trying different paths to bootstrap many things from source.
It is not intended to be used, at least for now.


Some relevant projects are listed as follows:

builder-hex0
builder-hex0-arch
stage0-posix
live-bootstrap
stagex
nixpkgs
guix
gentoo
onramp

[TODO] Datailed introduction of projects above.


## Content

### tcc-musl-by-pnut-on-stage0

For both x86 and amd64:

stage0-posix => pnut => tcc => musl + tcc-musl 

`./prepare-rootfs.sh --arch {x86,amd64}`


### xcc-to-gcc10

We can now use xcc (with patches) to build musl, binutils, gcc-4.6, and use them to build gcc-10.

(host gcc) => xcc-boot => xcc-xcclib => musl-1.2.6-xcc =>
xcc-musl => gmp-6.2.1/mpfr-4.1.0/mpc-1.2.1/zlib-1.3.2 =>
gcc-4.6.4.1 (ekaitz-zarraga fork) stage1 => musl-gcc =>
gcc-4.6.4.1 stage2 => gcc-10.4.0

### cc-edg-to-llvm: From host gcc/clang (w/o C++) to llvm5.

This directory builds a compiler toolchain in which the host C compiler is used
**only as a C compiler**, the C++ front end is **EDG 7.0** (which translates
C++ to C), and the C library is **musl**, built from source here.  The final
goal is LLVM/clang 5.0.2 and a self-hosted rebuild of clang.

host gcc/clang + host binutils => musl
host gcc/clang + host binutils + musl => edg5.1 => edg7.0
host gcc/clang + host binutils + musl + edg7.0 => llvm5 (~7 hours w/ 19 cores)
host binutils + musl + llvm5 => llvm5 (bootstrap)

Note: Both host gcc and host clang in my PC can run through the process, but it takes time (perhaps 7 hours).

### gcc4.6-c-only-edgcpp-llvm9

gcc-4.6 (disable C++ support) (or host gcc) + musl => edgcpp-5.1 => edgcpp-7.0 => 
llvm-3.5 => llvm-9.0

It is possible to go to llvm-3.5 from a gcc-4.6 (diable C++).

## Acknownledgement

LLM is used in this project.

