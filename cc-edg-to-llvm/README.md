# edgcpp-try: LLVM/clang 3.9 bootstrap with host gcc/clang + musl + EDG

This directory builds a compiler toolchain in which the host C compiler is used
**only as a C compiler**, the C++ front end is **EDG 7.0** (it translates C++
to C), and the C library is **musl**, built from source here.

**LLVM/clang 3.9 is the first-round LLVM target of this tree.**  The current
scripts are the three 3.9 stages plus the common musl/EDG prerequisites:

1. `refhost-musl.sh` — musl 1.2.6 with the host C compiler.
2. `refhost-edg5.1.sh` — EDG 5.1.
3. `refhost-edg7.0.sh` — EDG 7.0, built with EDG 5.1.
4. `refhost-llvm3.9.x-1.sh` — stage 1: LLVM/clang 3.9 libraries + clang,
   libc++ 3.9 and compiler-rt builtins, with host gcc or clang as the C-only
   compiler and EDG for every C++ translation unit.
5. `refhost-llvm3.9.x-2.sh` — stage 2: lld 3.9 and LLVM binutils
   (`llvm-ar`, `llvm-ranlib`, `llvm-nm`, `llvm-readobj`) built by the stage-1
   clang, with host binutils allowed for this stage only.
6. `refhost-llvm3.9.x-bootstrap.sh` — stage 3: self-hosted clang 3.9 + lld 3.9,
   built by the stage-1 clang + lld in a sandbox with **no host compiler and no
   host binutils**.

## Rules

- Host `gcc` or `clang` is never asked to compile C++: no `g++`, no `clang++`
  in C++ mode, no `-x c++`.  All C++ goes through EDG, which emits C.
- All builds happen under a `rootfs-*` directory inside this directory.
- LLVM stages run in bubblewrap with an explicit read-only host whitelist.
- The resulting C library and binaries are musl-based and static; no host
  glibc headers or libraries are used for the result.
- The stage-3 sandbox exposes no host compiler and no host binutils.

## Input tarballs

Place these next to the scripts, one level up, or in the reference tree:

```text
musl-v1.2.6.tar.gz
edgcpp-compiler-5.1.tar.gz
edgcpp-compiler-7.0.tar.gz
llvm-project-3.9.x.tar.gz
```

## Host gcc: complete command sequence

Run from this directory.  A clean host-gcc chain creates `rootfs-gcc`:

```bash
HOSTCC=gcc ROOTFS=rootfs-gcc ./refhost-musl.sh
HOSTCC=gcc ROOTFS=rootfs-gcc ./refhost-edg5.1.sh
HOSTCC=gcc ROOTFS=rootfs-gcc ./refhost-edg7.0.sh
HOSTCC=gcc ROOTFS=rootfs-gcc ./refhost-llvm3.9.x-1.sh
HOSTCC=gcc ROOTFS=rootfs-gcc ./refhost-llvm3.9.x-2.sh
HOSTCC=gcc ROOTFS=rootfs-gcc ./refhost-llvm3.9.x-bootstrap.sh
```

Results:

- stage-1/stage-2 prefix: `rootfs-gcc/opt/llvm3.9`
- self-hosted prefix: `rootfs-gcc/opt/llvm3.9-bootstrap`

## Host clang: complete command sequence

A clean host-clang chain creates `rootfs-clang`:

```bash
HOSTCC=clang ROOTFS=rootfs-clang ./refhost-musl.sh
HOSTCC=clang ROOTFS=rootfs-clang ./refhost-edg5.1.sh
HOSTCC=clang ROOTFS=rootfs-clang ./refhost-edg7.0.sh
HOSTCC=clang ROOTFS=rootfs-clang ./refhost-llvm3.9.x-1.sh
HOSTCC=clang ROOTFS=rootfs-clang ./refhost-llvm3.9.x-2.sh
HOSTCC=clang ROOTFS=rootfs-clang ./refhost-llvm3.9.x-bootstrap.sh
```

Results:

- stage-1/stage-2 prefix: `rootfs-clang/opt/llvm3.9`
- self-hosted prefix: `rootfs-clang/opt/llvm3.9-bootstrap`

In host-clang mode:

- host clang compiles every C file, including EDG-generated `.int.c`;
- links use host clang as the driver plus host `ld.lld`, with explicit musl
  `crt1/crti/crtn`, libc/libm/libpthread, stage-1 libc++/libC and compiler-rt
  builtins (`-nostdlib`, `-nodefaultlibs`, `-nostartfiles`, `-nostdlib++`);
- **no host gcc is invoked for compilation or linking**;
- EDG-generated C atomics with `volatile void *` are adapted by
  [`edg-support/llvm-3.9/edg-clang-atomic.h`](edg-support/llvm-3.9/edg-clang-atomic.h).

## Output layout

| Item | Host gcc | Host clang |
|---|---|---|
| rootfs | `rootfs-gcc/` | `rootfs-clang/` |
| stage-1 build | `rootfs-gcc/build/llvm3.9` | `rootfs-clang/build/llvm3.9` |
| stage-2 build | `rootfs-gcc/build/llvm3.9-tools` | `rootfs-clang/build/llvm3.9-tools` |
| stage-3 build | `rootfs-gcc/build/llvm3.9-bootstrap` | `rootfs-clang/build/llvm3.9-bootstrap` |
| stage-1/2 prefix | `rootfs-gcc/opt/llvm3.9` | `rootfs-clang/opt/llvm3.9` |
| stage-3 prefix | `rootfs-gcc/opt/llvm3.9-bootstrap` | `rootfs-clang/opt/llvm3.9-bootstrap` |

Stage 2 installs `lld`/`ld.lld` and the LLVM binutils replacements into the
stage-1 prefix.  Stage 3 installs the self-hosted clang and lld into its own
prefix and reports:

```text
host tools : no host compiler and no host binutils in the sandbox
```

## Deprecated LLVM targets

The old LLVM 3.5 and LLVM 5 build scripts are archived under:

```text
ref-deprecated/llvm3.5.x/
ref-deprecated/llvm5.x/
```

They are kept for history only and are **not** part of the current chain.  Do
not mix their scripts, rootfs names, or build trees with the 3.9 scripts.  See
the `Why-not-*.md` files in those directories for the reasons they were
replaced.

## Build times (16 jobs)

Measured on the local 20-core machine:

| Step | gcc chain | clang chain |
|---|---|---|
| `refhost-llvm3.9.x-1.sh` | 11904 s | 11527 s |
| `refhost-llvm3.9.x-2.sh` | 755 s | 687 s |
| `refhost-llvm3.9.x-bootstrap.sh` | 924 s | 843 s |

The prerequisite musl/EDG5.1/EDG7.0 steps together take only a few minutes.

## Source patches and EDG compatibility

All source patches are under [`edg-support/llvm-3.9/`](edg-support/llvm-3.9)
and are applied idempotently by:

```bash
edg-support/llvm-3.9/apply.sh <source-root>
```

The patches cover:

- musl differences in libc++ 3.9 (`strtoll_l`, `max_align_t`, `strerror_r`);
- musl's `FILE *const` stdio declarations in LLVM;
- CMake 4 compatibility (`CMP0051 NEW`);
- the two Clang 3.9 SSE2 fast paths (`Lexer.cpp`, `SourceManager.cpp`).

For EDG translation, `EDG_BOOTSTRAP_NO_SSE2` selects the existing scalar
fallbacks in those two files, so no `emmintrin.h` or GCC intrinsic header is
needed.  The normal stage-3 clang build does not define this macro and keeps
the SSE2 path.

LLVM 3.9's lld already handles `R_X86_64_GOTPCRELX`/`REX_GOTPCRELX` and TLS;
no lld source patch is required.

## Important stage-3 details

- `-fuse-init-array` is used when compiling and linking the self-hosted
  clang/lld and libc++ 3.9.  The stage-1 clang emits `.ctors` for some 3.9
  LLVM/Clang objects; lld 3.9 does not map `.ctors` into `.init_array`, so
  without this flag constructors (including `cl::opt` registration) would not
  run in the self-hosted binaries.
- Stage 3 uses the stage-1 `llvm-tblgen`/`clang-tblgen` as the native tablegen
  generators (`-DLLVM_TABLEGEN`, `-DCLANG_TABLEGEN`).  The generated clang is
  still compiled and linked by the stage-1 clang + lld; table generation does
  not depend on a self-hosted tablegen binary.

## Environment variables

| Variable | Scripts | Default | Meaning |
|---|---|---|---|
| `ROOTFS` | all | `rootfs-hostgcc` | Rootfs directory inside this directory; use `rootfs-gcc`/`rootfs-clang` as above |
| `HOSTCC` | musl/EDG/stage-1 | `gcc` | Host C compiler (`gcc` or `clang`) |
| `JOBS` | all | `16` | Parallel jobs |
| `OPT` | stage 1 | `-O0` | Optimization for EDG-generated C |
| `KEEP_SRC` | LLVM stages | unset | Reuse an extracted source tree |
| `REUSE_BUILD` | LLVM stages | unset | Reuse an existing CMake build tree |
| `SKIP_CONFIGURE` | LLVM stages | unset | Skip CMake configure |
| `CONFIGURE_ONLY` | stage 1 | unset | Stop after successful CMake configure |
| `REBUILD_LIBCXX` | stage 1 | unset | Force a libc++ rebuild |
| `REBUILD_CRT` | stage 1 | unset | Force a compiler-rt builtins rebuild |
| `LLVM_TARGET` | stage 1 | `clang` | CMake target to build |
| `STAGE1_PREFIX` | stage 3 | `/opt/llvm3.9` | Stage-1 prefix inside the rootfs |
| `STAGE1_BUILD` | stage 3 | `build/llvm3.9` | Stage-1 build tree |
| `SRC_DIR` | stage 3 | `$STAGE1_BUILD/src` | LLVM source tree override |
| `BUILD_DIR` | stage 3 | `build/llvm3.9-bootstrap` | Stage-3 build tree |
| `PREFIX` | stage 3 | `/opt/llvm3.9-bootstrap` | Stage-3 install prefix |

## Verified regression status

Both complete chains were built from clean rootfs directories and passed all
stage checks:

- host gcc: stage-1 11904 s, stage-2 755 s, stage-3 924 s;
- host clang: stage-1 11527 s, stage-2 687 s, stage-3 843 s.

In both cases the self-hosted stage reports no host compiler and no host
binutils, produces clang 3.9.1 + LLD 3.9, and the self-hosted clang compiles
and links C and C++ programs by itself.
