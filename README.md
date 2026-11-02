# try-bootstrap

## Introduction

This is a project focus on different paths to bootstrap many things from source.

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

### tcc-pnutlib-by-pnut-on-stage0-x86

Tcc (against pnut's lib) can be built through pnut on stage0-posix.

[TODO] Building tcc against musl can be done too, will be upload later.

### xcc-to-gcc10

We can now use xcc (with patches) to build musl, binutils, gcc-4.6, and use them to build gcc-10.

(host gcc) => xcc-boot => xcc-xcclib => musl-1.2.6-xcc =>
xcc-musl => gmp-6.2.1/mpfr-4.1.0/mpc-1.2.1/zlib-1.3.2 =>
gcc-4.6.4.1 (ekaitz-zarraga fork) stage1 => musl-gcc =>
gcc-4.6.4.1 stage2 => gcc-10.4.0

### [WIP] gcc4.6-c-only-edgcpp-llvm9

gcc-4.6 (disable C++ support) => edgcpp-5.1 => edgcpp-7.0 =>
[WIP] llvm-9


## Acknownledgement

LLM is used in this project.

