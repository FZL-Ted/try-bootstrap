# EDG bootstrap on host cc + musl

Build EDG C/C++ 5.1 and 7.0 with a **host C compiler** (gcc or clang) reduced
to a C-only compiler and pinned to a **musl** rootfs built in this directory.

The compiler is never used to compile C++: EDG's front end translates every
C++ file to C, and the host compiler only ever sees C.  No `g++`, no
`clang++`, no `-x c++`, no C++ compiler of any kind is invoked.  From the musl
build onwards the host glibc is not used for any header or library either.

## Build order

```bash
# host gcc -> rootfs-hostgcc
./build-all.sh

# host clang -> rootfs-hostclang
HOSTCC=clang ROOTFS=rootfs-hostclang ./build-all.sh

# the same in explicit stages, with any compiler / rootfs
HOSTCC=clang ROOTFS=rootfs-hostclang ./refhost-musl.sh
HOSTCC=clang ROOTFS=rootfs-hostclang ./refhost-edg5.1.sh
HOSTCC=clang ROOTFS=rootfs-hostclang ./refhost-edg7.0.sh

# this also works: the glob expands in sorted order, so build-all.sh runs and
# the sibling script names are ignored as arguments
HOSTCC=clang ROOTFS=rootfs-hostclang ./*.sh
```

`ROOTFS` is resolved against the current directory.  It must be a directory
inside this tree; the default is `rootfs-hostgcc`.  `HOSTCC` may be a name
found in `PATH` or a path.

All build activity happens inside the rootfs:

```text
<rootfs>/
  usr/include/                 musl headers
  usr/lib/                     musl libc.a, libm.a, crt1.o, crti.o, crtn.o, ...
  bin/cc                       host cc --sysroot=<rootfs> -static (the only CC)
  src/musl-1.2.6/              musl source + build tree
  build/
    musl-build.log
    musl-build-info.txt
    edg5.1/
      edg-5.1/build/edgcpfe    EDG 5.1 front end (static musl)
      edg-5.1/lib/libC.a       EDG 5.1 runtime library
      build.log / build-info.txt
    edg7.0/
      edgcpfe                  EDG 7.0 front end (static musl)
      lib/libC.a               EDG 7.0 runtime library
      base/                    EDG_BASE for the 7.0 front end
      log/                     per-translation and per-test logs
      build-info.txt
```

## Inputs

Read-only files, searched next to the scripts, one level up, then in the
reference `../edgcpp-try` tree:

- `musl-v1.2.6.tar.gz`
- `edgcpp-compiler-5.1.tar.gz`
- `edgcpp-compiler-7.0.tar.gz`
- `edg-support/predefined/edg5.1/predefined_macros.txt` (copied here)

## How the glibc flashpoint is avoided

`refhost-musl.sh` installs musl to `usr/` in the rootfs and writes
`<rootfs>/bin/cc`:

```sh
exec <host cc> [--gcc-toolchain=<prefix>] --sysroot=<rootfs> -static "$@"
```

Every later compiler invocation goes through that wrapper, so the C headers
resolve to `<rootfs>/usr/include` (musl), the startup files and `libc.a`
resolve to `<rootfs>/usr/lib` (musl), and the output is statically linked.
Only the compiler's own runtime (`libgcc`/`libgcc_eh`, and its resource or
internal include directory) still comes from the host; those are compiler
runtime, not the C library.  Each script verifies that the produced binaries
are static and carry no `GLIBC_` symbol versions.

`--gcc-toolchain` is added only for clang: with `--sysroot` pointing away from
the host, clang otherwise looks for `crtbegin.o`/`libgcc` under the rootfs.
The prefix is derived from `<cc> -print-file-name=crtbegin.o`.

## Host compiler specifics

The host gcc is 16.x and the host clang is 22.x, so the EDG sources and
EDG-generated C are compiled with `-std=gnu89`/`-std=gnu99` and `-fcommon` to
match the semantics the 2019/2020 release sources expect.  Link lines add
`-lm` because musl keeps `__fpclassifyl` and friends in `libm.a`.

`bin/cc` also rejects C++ inputs (`-x c++`, `*.cpp`, `*.cc`, ...), so the
C-only rule is enforced rather than merely assumed.

Clang does not provide gcc's x87 `__float80` type name, which EDG 7.0 emits
for its C99 complex runtime.  When the rootfs was built by clang,
`refhost-edg7.0.sh` therefore compiles the generated C with
`-D__float80="long double"`; on x86-64 the representation and ABI of the two
spellings are identical.

## Notes

- EDG 5.1 is the last release whose front end is plain C; later releases need
  a C++ compiler for the front end itself.
- EDG 5.1 has no prelinker in this pipeline; `-tused` duplicates template
  instantiations, so the 7.0 front end links with
  `-Wl,--allow-multiple-definition`.
- `__float128`/`_Float128` target support is disabled because EDG 5.1 cannot
  compile host `__float128`.

## LLVM/clang 5.0.2 (stages 3a + 3b)

Two further stages sit on top of the EDG chain.  Both run inside a
bubblewrap sandbox rooted at the musl rootfs, with an explicit read-only
whitelist of host binaries; the build always happens under
`<rootfs>/build/`.

```bash
# stage 3a: host gcc (C only) + EDG 7.0 + musl -> LLVM/clang 5.0.2
./refhost-llvm5.x.sh

# stage 3b: the stage-3a clang + musl -> a second, self-hosted LLVM/clang,
# in a sandbox that contains no host gcc/clang at all
./refhost-llvm-5.x-bootstrap.sh
```

`refhost-llvm5.x.sh` first builds libc++ 5.0.2 with EDG (every C++ source is
translated to C, then compiled by the musl gcc), since LLVM needs a C++
standard library.  It also builds the compiler-rt builtins.  LLVM 5.0.2 is
then configured with CMake through `bin/edg-cxx`, a driver that turns each
C++ compile command into `edgcpfe` + `cc`; `cc` itself is the sandbox-bound
host gcc restricted to the musl rootfs.  The installed toolchain is
`<rootfs>/opt/llvm5` (clang, clang++, llvm-ar, ... plus libc++, compiler-rt
and the EDG C++ runtime).

`refhost-llvm-5.x-bootstrap.sh` uses `<rootfs>/opt/llvm5/bin/clang++` for
both C and C++, rebuilds libc++ with clang, and rebuilds LLVM/clang into
`<rootfs>/opt/llvm5-bootstrap`.  Its sandbox does not contain gcc, g++, cc1,
libgcc or any host header/library used by the build; only `ld` and the build
tools are mounted from the host.  Both scripts reject a dynamically linked
or GLIBC-symbol-carrying result.

Relevant knobs: `ROOTFS`, `JOBS` (default `nproc --ignore=1`), `TARBALL`,
`PREFIX`, and `KEEP_SRC=1` to reuse an already extracted source tree.

### Resuming an interrupted LLVM build

The LLVM stages are long.  The intermediate trees under
`<rootfs>/build/llvm5` are kept, and the following environment variables let
a rerun continue instead of starting over:

```bash
KEEP_SRC=1 REUSE_BUILD=1 SKIP_CONFIGURE=1 ./refhost-llvm5.x.sh
REBUILD_LIBCXX=1 ./refhost-llvm5.x.sh      # force only the libc++ step
REBUILD_CRT=1    ./refhost-llvm5.x.sh      # force only the builtins step
```

Notes on the C++ toolchain used by `refhost-llvm5.x.sh`:

- EDG is driven in its GNU mode (`--g++ --gnu_version=50000`), so libc++
  takes its GCC code paths and the emitted C is plain GNU C for gcc.  EDG's
  predefined-macro table is generated for clang, so the clang-gated entries
  are copied into the gnu/gcc/gpp modes in a private copy of `base/`.
- libc++ 5 is built with EDG -> C -> gcc, `_LIBCPP_NO_EXCEPTIONS` and
  `_LIBCPP_HAS_MUSL_LIBC`; `locale` uses `strtoll`/`strtoull` because musl has
  no `*_l` variants.
- `_LARGEFILE64_SOURCE` is defined for LLVM's use of `lseek64` (musl exposes
  `lseek64` only under that feature macro).
- CMake 4 requires the `CMP0051` policy to be NEW; the extracted copy of
  `llvm/CMakeLists.txt` is patched accordingly.

### Throughput note

Building clang 5 with EDG is slow: the EDG front end needs minutes for the
large `clang/lib/{Sema,AST,Serialization}` translation units, while the
earlier LLVM `Support`/`IR` files are fast.  `OPT` defaults to `-O0` for the
EDG-generated C for that reason; set `OPT=-O1`/`-O2` only if build time does
not matter.  Expect a full LLVM+clang pass to take many hours, and use the
resume variables above rather than restarting.

### LLVM build scope and the EDG prelinker

Stage 3a builds **only the `clang` CMake target** (plus its build-time
`llvm-tblgen`/`clang-tblgen` dependencies). No LLVM tools, examples,
`LLVMHello.so`, libclang, lld, compiler-rt runtimes other than builtins, or
LLVM headers/CMake packages are built or installed. The install step is done
by hand: `clang`, `clang++`, the clang resource headers, libc++, the
compiler-rt builtins and EDG's `libC.a`. This removes the failure mode where
`LLVMHello.so` was linked with `-static` (the musl rootfs has no shared libc)
and avoids the long `install` target.

EDG's automatic template instantiation + prelinker is implemented
(`util/edg_prelink` is built from the EDG sources and the driver emits the
`cmd:`/`dir:`/`fnm:` records in the `.ti` files), but it is **off by default**
(`USE_PRELINK=1` enables it).  Measured on this machine, the prelinker has to
recompile assigned translation units *serially*, and for a cold LLVM build
that serial tail is much slower than the time saved by not emitting template
bodies per TU.  The default path therefore keeps `-tused`; the prelinker
machinery remains available for incremental or smaller programs.

Other speed-ups: `OPT=-O0` by default for EDG-generated C,
`-fno-asynchronous-unwind-tables -fno-unwind-tables -fno-pie` on that C,
`-no-pie` at link time, and the build target/source reduction above.

### Result

Both stages build and pass their checks on this machine (Debian, x86-64,
musl 1.2.6, host gcc 16.2.0):

```text
<rootfs>/opt/llvm5/bin/clang            137 MB, static, no GLIBC symbols
<rootfs>/opt/llvm5-bootstrap/bin/clang   48 MB, static, no GLIBC symbols
```

- Stage 3a (host gcc + EDG 7.0 -> clang): the clang target is built from a
  `-tused` EDG pipeline; libc++ 5.0.2 and the compiler-rt builtins are built
  first; self-hosted-style link checks (clang alone, no host gcc) pass.
- Stage 3b (stage-1 clang -> clang, no host compiler in the sandbox): takes
  about 19 minutes with `JOBS=19`; libc++ is rebuilt with clang, the clang
  target is rebuilt from the same source, and the resulting compiler builds
  and links C and C++ programs by itself.

Two details that matter for a clang-only bootstrap:

- `LLVM_INCLUDE_TOOLS` must stay ON: the clang project is added from
  `llvm/tools/CMakeLists.txt`.  Only the `clang` target is built
  (`LLVM_BUILD_TOOLS=OFF` merely keeps the other tools out of `all`).
- There is no `crtbegin.o` without a host gcc.  The toolchain links with
  `-nostartfiles`, musl's `crt1.o/crti.o/crtn.o`, a small `dso_handle.o`, and
  `-nodefaultlibs` with an explicit `--start-group` of `libc++.a`, EDG's
  `libC.a`, musl's `libc.a/libm.a/libpthread.a` and compiler-rt builtins.
  This is what the "stage-2 style" check in `refhost-llvm5.x.sh` exercises.
