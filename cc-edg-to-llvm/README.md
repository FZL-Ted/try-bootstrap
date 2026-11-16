# edgcpp-try: LLVM/clang 5 self-hosting with host gcc/clang + musl + EDG

This directory builds a compiler toolchain in which the host C compiler is used
**only as a C compiler**, the C++ front end is **EDG 7.0** (which translates
C++ to C), and the C library is **musl**, built from source here.  The final
goal is LLVM/clang 5.0.2 and a self-hosted rebuild of clang.

Rules used throughout:

- Host `gcc` or `clang` is never asked to compile C++: no `g++`, no `clang++`
  in C++ mode, no `-x c++`.  Every C++ translation unit goes through EDG,
  which emits C.
- All builds happen inside a `rootfs-*` directory.  LLVM stages run in a
  bubblewrap sandbox with an explicit read-only whitelist of host binaries
  (`--ro-bind /usr/bin/ld /usr/bin/ld`, etc.).
- The C library and the produced binaries are musl-based and static; no host
  glibc headers or libraries are used for the result.
- The bootstrap stage (stage 3b) runs in a sandbox with **no host compiler**;
  only host binutils and build tools are visible.
- No git operations are used; input tarballs are looked up next to the scripts
  or one level up.

## Contents

| Path | Description |
|---|---|
| `refhost-musl.sh` | Stage 0: build musl 1.2.6 with the host C compiler; create the rootfs and `bin/cc` wrapper |
| `refhost-edg5.1.sh` | Stage 1: build EDG 5.1 with host C compiler + musl (the 5.1 front end is plain C) |
| `refhost-edg7.0.sh` | Stage 2: build EDG 7.0 using EDG 5.1 + musl (the 7.0 front end is C++, translated by 5.1) |
| `refhost-llvm5.x.sh` | Stage 3a (baseline): build LLVM/clang 5.0.2 with host gcc (C-only) + EDG 7.0 + musl |
| `refhost-llvm-5.x-bootstrap.sh` | Stage 3b: rebuild LLVM/clang 5.0.2 with the stage-3a clang, in a sandbox without any host compiler |
| `try-gcc-refhost-llvm5.x.sh` | Experimental stage 3a: same as above plus **big-TU-first scheduling**; separate tree `build/llvm5-try`, prefix `/opt/llvm5-try` |
| `try-clang-refhost-llvm5.x.sh` | Experimental stage 3a using **host clang** as the C compiler; accepts `ROOTFS=rootfs-hostgcc` or `rootfs-hostclang`; separate tree `build/llvm5-clang-try`, prefix `/opt/llvm5-clang-try` |
| `edg-support/predefined/edg5.1/predefined_macros.txt` | EDG 5.1 predefined macro table (the release tarball does not ship `lib/`) |
| `rootfs-hostgcc/` | Rootfs produced by the host-gcc chain (musl, EDG, LLVM artifacts) |
| `rootfs-hostclang/` | Rootfs produced by the host-clang chain (same refhost scripts with `HOSTCC=clang`) |
| `llvm5-*.log`, `try-*.log`, `*-start.ts` | Build logs and timing records from earlier runs |

Input tarballs (place in this directory or one level up):

```text
musl-v1.2.6.tar.gz
edgcpp-compiler-5.1.tar.gz
edgcpp-compiler-7.0.tar.gz
llvm-project-5.x.tar.gz          # LLVM 5.0.2 monorepo (clang, libcxx, compiler-rt)
```

## Quick start

### Option A: host gcc

Build the prerequisite chain once:

```bash
./refhost-musl.sh                 # -> rootfs-hostgcc
./refhost-edg5.1.sh
./refhost-edg7.0.sh
```

Then build LLVM/clang.  **Both scripts can be used with host gcc**:

```bash
# baseline (no reordering)
./refhost-llvm5.x.sh              # -> rootfs-hostgcc/opt/llvm5

# experimental, big-TU-first scheduling
./try-gcc-refhost-llvm5.x.sh      # -> rootfs-hostgcc/opt/llvm5-try
```

Finally, the self-hosted rebuild:

```bash
./refhost-llvm-5.x-bootstrap.sh   # -> rootfs-hostgcc/opt/llvm5-bootstrap
```

### Option B: host clang

Build the prerequisite chain into a clang-based rootfs:

```bash
HOSTCC=clang ROOTFS=rootfs-hostclang ./refhost-musl.sh
HOSTCC=clang ROOTFS=rootfs-hostclang ./refhost-edg5.1.sh
HOSTCC=clang ROOTFS=rootfs-hostclang ./refhost-edg7.0.sh
```

Build LLVM/clang with host clang as the C-only compiler (the rootfs may be
either the gcc-built or the clang-built one):

```bash
ROOTFS=rootfs-hostclang ./try-clang-refhost-llvm5.x.sh
# or
ROOTFS=rootfs-hostgcc   ./try-clang-refhost-llvm5.x.sh
```

`refhost-llvm5.x.sh` itself is the gcc wrapper path; use the `try-clang-*`
script for host clang, since it adds the clang-specific link setup
(`--gcc-toolchain`, non-PIE, compiler-rt atomics, host `libatomic`).

Then self-host that clang.  Stage 3b accepts the `try-clang-*` trees directly,
so no symlinks or copies are needed:

```bash
ROOTFS=rootfs-hostgcc \
STAGE1_PREFIX=/opt/llvm5-clang-try \
STAGE1_BUILD=build/llvm5-clang-try \
BUILD_DIR=build/llvm5-clang-bootstrap \
PREFIX=/opt/llvm5-clang-bootstrap \
  ./refhost-llvm-5.x-bootstrap.sh
```

### Stage 3b directory selection

`refhost-llvm-5.x-bootstrap.sh` defaults to the baseline stage-3a layout:

```text
<rootfs>/build/llvm5/src                   source tree
<rootfs>/opt/llvm5/bin/clang               stage-1 clang
```

To bootstrap a stage 3a built by a `try-*` script, or any other directory
layout, point the script at that tree instead of creating symlinks.  The
directories are selected with `STAGE1_PREFIX`, `STAGE1_BUILD`, `SRC_DIR`,
`BUILD_DIR` and `PREFIX` (see [Environment variables](#environment-variables));
all of them are interpreted inside the rootfs and a leading `/` is optional.
`ROOTFS` selects the rootfs as before, so the same script works on another
rootfs that contains a stage-3a toolchain.

## Environment variables

| Variable | Scripts | Default | Meaning |
|---|---|---|---|
| `ROOTFS` | all | `rootfs-hostgcc` | Rootfs directory, resolved against the current directory and required to be inside the script directory |
| `HOSTCC` | musl/EDG/LLVM stages | `gcc` (`clang` in `try-clang-*`) | Host C compiler |
| `JOBS` | all | `nproc --ignore=1` (19 here) | Parallel jobs; the build deliberately does not use every core |
| `OPT` | LLVM stages | `-O0` | Optimization for EDG-generated C; `-O0` is much faster for this workload |
| `KEEP_SRC` | LLVM stages | unset | Reuse an already extracted source tree |
| `REUSE_BUILD` | `refhost-llvm5.x.sh` | unset | Reuse the existing CMake build tree |
| `SKIP_CONFIGURE` | `refhost-llvm5.x.sh` | unset | Skip the cmake configure step |
| `USE_PRELINK` | try scripts | `0` | `2` = experimental EDG automatic instantiation + parallel pre-link driver; measured to converge slowly, off by default |
| `LLVM_TARGET` | LLVM stages | `clang` | CMake target to build |
| `STAGE1_PREFIX` | stage 3b | `/opt/llvm5` | Stage-1 install prefix (inside the rootfs) |
| `STAGE1_BUILD` | stage 3b | `build/llvm5` | Stage-1 build tree; its `src/` is the source tree by default |
| `SRC_DIR` | stage 3b | `$STAGE1_BUILD/src` | LLVM source tree override |
| `BUILD_DIR` | stage 3b | `build/llvm5-bootstrap` | Stage-3b build tree |
| `PREFIX` | LLVM stages | per script (`/opt/llvm5`, `/opt/llvm5-try`, `/opt/llvm5-clang-try`, or `/opt/llvm5-bootstrap`) | Install prefix inside the rootfs |

## Artifacts (default `rootfs-hostgcc`)

```text
rootfs-hostgcc/
  bin/cc                          musl + C-only compiler wrapper
  usr/include, usr/lib            musl headers and static libraries
  build/edg5.1/edg-5.1/build/edgcpfe
  build/edg7.0/edgcpfe, base/     EDG 7.0 front end and base directory
  build/llvm5/
    src/                          LLVM 5.0.2 source (patched for CMake 4 and musl)
    libcxx/libc++.a               libc++ built through EDG -> C -> musl gcc
    crt/libclang_rt.builtins-x86_64.a
    build/stage1/                 LLVM/clang build tree
    log/                          per-stage logs
  opt/llvm5/bin/clang{,++}             stage-3a result (static, no GLIBC symbols)
  opt/llvm5-bootstrap/bin/clang        stage-3b self-hosted result (gcc-built stage 1)
  opt/llvm5-clang-bootstrap/bin/clang  stage-3b result (clang-built stage 1)
```

The `try-*` scripts use `build/llvm5-try`, `build/llvm5-clang-try` and
`/opt/llvm5-try`, `/opt/llvm5-clang-try` instead, so they do not overwrite the
baseline artifacts.  The corresponding stage-3b run uses
`build/llvm5-clang-bootstrap` and `/opt/llvm5-clang-bootstrap`.

## Timing (20-core machine, `JOBS=19`, `-O0`)

| Step | Approximate time |
|---|---|
| `refhost-musl.sh` | 1–2 min |
| `refhost-edg5.1.sh` | 1–2 min |
| `refhost-edg7.0.sh` | 4–5 min (measured ~259 s) |
| three prerequisite scripts together | **6–10 min** |
| stage 3a, `refhost-llvm5.x.sh` (incl. libc++, builtins, LLVM/clang) | **7–9 h** from a clean rootfs |
| stage 3a, `try-gcc-*` / `try-clang-*` (big-TU-first) | **~6.4 h** (measured 6.38 h / 6.40 h; with libc++/builtins reused; add ~6–8 min if they are rebuilt) |
| stage 3b, `refhost-llvm-5.x-bootstrap.sh` | **~19 min** (measured 1139 s from the gcc-built stage 1, 1115 s from the clang-built one) |

The bottleneck is EDG translating the large `clang/lib/{Sema,AST,CodeGen}`
TUs, not the C compiler: the host-gcc and host-clang stage-3a runs took almost
the same time (22963 s vs 23034 s).

## Optimizations that were tried/kept

Adopted in the `try-*` scripts (and usable via the baseline scripts where
noted):

- **Build only the `clang` target.**  No LLVM tools, lld, libclang, examples,
  tests, or loadable modules (`LLVMHello.so`); the install is done by hand
  (clang, `clang++`, resource headers, libc++, compiler-rt builtins, EDG
  `libC.a`).  `LLVM_INCLUDE_TOOLS` must stay ON because the clang project is
  added from `llvm/tools/CMakeLists.txt`.
- **Big-TU-first scheduling** (`try-gcc-*`, `try-clang-*`): after configure,
  the object prerequisite lists in all generated `build.make` files are sorted
  by source-file size (74 files changed), so the biggest translation units
  start earlier.  This reduces the per-library tail; cross-library ordering is
  still dependency-driven.  Measured total time about 6.4 h.
- **`OPT=-O0`** by default, plus `-fno-asynchronous-unwind-tables`,
  `-fno-unwind-tables`, `-fno-pie` and `-no-pie` on the generated C and links.
- **Only the clang target is installed**, not LLVM headers/CMake files/tools;
  this avoids the long `install` target and the `LLVMHello.so` failure on a
  static-only musl rootfs.
- **Host clang support** (`try-clang-*`): binds `/usr/lib/llvm-22`, derives
  `--gcc-toolchain` from `crtbegin.o`, links non-PIE against musl, and solves
  EDG's `__atomic_add_fetch_*` references with a clang-built compiler-rt
  `atomic.o` plus host `libatomic.a`.
- **Cache/reuse knobs**: `KEEP_SRC`, `REUSE_BUILD`, `SKIP_CONFIGURE`,
  `REBUILD_LIBCXX`, `REBUILD_CRT` allow resuming rather than restarting.

Explored but **not adopted by default**:

- **EDG automatic instantiation + parallel prelink driver**
  (`USE_PRELINK=2`).  `edg_prelink -n` assigns roughly one TU per pass, so
  convergence needs O(number of TUs) sequential passes; the parallel recompile
  never materializes.  The machinery is implemented and left behind the flag,
  default `0`.
- Direct per-object `make` targets for scheduling (invalid in CMake's generated
  Makefiles); replaced by the `build.make` reordering above.

## Implementation notes

- EDG runs in GNU mode (`--g++ --gnu_version=50000`).  Its predefined-macro
  table is generated for clang, so the clang-gated entries are merged into the
  gnu/gcc/gpp modes in a private copy of `base/`.
- LLVM 5 predates CMake 4: `cmake_policy(SET CMP0051 OLD)` is rewritten to
  `NEW` in the extracted source tree.
- libc++ 5 expects glibc's `strtoll_l`/`strtoull_l`; musl has neither, so the
  extracted copy uses `strtoll`/`strtoull` instead, and the build defines
  `_LIBCPP_HAS_MUSL_LIBC` and `_LIBCPP_NO_EXCEPTIONS`.
- LLVM uses `lseek64`; musl exposes it only with `_LARGEFILE64_SOURCE`, which
  the scripts define for both EDG and the C compiler.
- Stage 3b has no host gcc, hence no `crtbegin.o`: it links with
  `-nostartfiles`, musl `crt1.o/crti.o/crtn.o`, a small `dso_handle.o`,
  `-nodefaultlibs` and an explicit `--start-group` of libc++, EDG `libC.a`,
  musl libc/libm/libpthread and the compiler-rt builtins.
- With `ROOTFS=rootfs-hostclang`, `GCCINC` resolves to clang's resource
  include directory (the same behaviour as `refhost-edg7.0.sh` on a
  clang-built rootfs); it can be overridden through the environment.
- All results are static and are checked for the absence of an `INTERP`
  program header and of `GLIBC_` symbols.
