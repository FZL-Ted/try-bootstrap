# compiler-test: a from-scratch, self-hosting C/C++ toolchain

This repository contains the build scripts for a complete, static C/C++ toolchain
for x86_64 Linux, built from source inside a private root filesystem. The build is
driven by the `3-*.sh` scripts in the repository root, and all products land under
`rootfs3/`.

The host `gcc` is used exactly once: to compile the very first `xcc` compiler.
After that, every compiler, assembler, linker, C library and support library is
produced by tools that were built in this tree. The finished tree contains:

| Component | Version | Installed at |
| --- | --- | --- |
| GCC (C, C++) | 10.4.0 | `rootfs3/usr/gcc10` |
| GCC (C, C++) | 4.6.4.1 | `rootfs3/usr/gcc46` |
| GNU binutils (`as`, `ld`, `ar`, `nm`, ...) | 2.44 | `rootfs3/usr/binutils` |
| musl libc, built by GCC 4.6 | 1.2.6 | `rootfs3/usr/musl-gcc` |
| musl libc, built by xcc | 1.2.6 | `rootfs3/usr/musl-1` |
| xcc (C compiler, static, musl) | 0.1.13 | `rootfs3/usr/xcc-musl` |
| xcc (C compiler, static, bundled libc) | 0.1.13 | `rootfs3/usr/xcc-xcclib` |
| xcc (bootstrap seed, host glibc) | 0.1.13 | `rootfs3/usr/xcc-boot` |
| GNU make | 4.4 | `rootfs3/usr/bin/make` |
| GMP / MPFR / MPC / zlib | 6.2.1 / 4.1.0 / 1.2.1 / 1.3.2 | `rootfs3/usr/{include,lib}` |

All final toolchain executables are statically linked. There is one deliberate
exception: `xcc-boot`, the seed built by the host compiler, is dynamically linked
against the host glibc. `xcc-xcclib` is static but links xcc's own bundled libc;
everything after it uses musl. The `rootfs3/` tree is self-contained enough to be
used as a chroot or with `bwrap`; the scripts exercise that in their smoke tests
when `bwrap` is available.

The current tree has been built through GCC 10.4.0 and GNU make 4.4. GCC 10 is the
default compiler at `rootfs3/usr/bin/gcc`; GCC 4.6 remains installed beside it.
The complete sequence has also been re-run from an empty `rootfs3/` with
`./3-build-all.sh` (clean `xcc` checkout, host GCC 16.2.0 as the seed). It built
GCC 10.4.0 with `Comparison successful`, and the resulting compiler compiled and
ran both C and C++ programs. GNU make 4.4 is not part of this driver.

All build scripts (comments and runtime messages) and this README are in English.

---

## 1. What the build does

The chain is a sequence of small, auditable generations:

```
host gcc
  |
  v
xcc-boot (dynamic, host glibc; seed only)
  |
  v
xcc-xcclib (static, xcc's own libc)
  |
  +--> musl-1 (musl built by xcc-xcclib; sysroot for the xcc chain)
  |
  +--> xcc-musl (static, linked against musl-1)
           |
           +--> GMP, MPFR, MPC, zlib
           +--> GNU binutils 2.44
           +--> GCC 4.6.4.1 stage 1 (built by xcc-musl)
                    |
                    +--> musl-gcc (complete musl built by GCC 4.6 stage 1)
                    +--> target libgcc
                    +--> GCC 4.6.4.1 stage 2 (own libgcc + static libstdc++)
                             |
                             +--> GCC 10.4.0 (three-stage bootstrap)
                             +--> GNU make 4.4 (optional; via xcc-musl + musl-gcc + binutils)
```

The two musl builds have different jobs:

* `musl-1` is built by `xcc-xcclib`. It deliberately omits features xcc cannot
  compile, so it is only the target libc for the xcc-based stages.
* `musl-gcc` is built by GCC 4.6 and is complete. It includes complex arithmetic,
  true 80-bit `long double`, `posix_spawn`, and all architecture assembly. It is
  the target libc for the GCC stages.

Likewise, the GCC 4.6 build has two phases: the first compiler (`stage 1`) proves
that xcc can compile GCC's own sources; the second (`stage 2`) is built by that
first compiler, with its own `libgcc` and static `libstdc++`. The four support
libraries are rebuilt once by GCC 4.6 before the final `stage 2` rebuild so that
the final compiler does not depend on xcc-generated library code.

---

## 2. Requirements

### Host

* Linux on x86_64. The target triple used throughout is `x86_64-pc-linux-gnu`.
* `bash`, GNU `make`, `git`, and the usual POSIX/userland tools: `sed`, `gawk`,
  `grep`, `find`, `sort`, `uniq`, `comm`, `tar`, `xz`, `unzip`, `bzip2`, `ar`,
  `nm`, `ranlib`, `file`, `readelf`, `install`, `cp`, `mv`, `rm`, `mkdir`, `ln`,
  `cat`, `head`, `tail`, `wc`, `tr`, `cut`, `xargs`, `stat`, `cmp`, `sha256sum`,
  `tee`, `timeout`, `nproc`, plus `m4` (GMP's configure) and `perl`/`diff` (GCC).
* A host C compiler (`gcc`) for `3-build-xcc-boot.sh` only. Apart from that seed
  step, no host C++ compiler, assembler, linker, or host `/usr/include` /
  `/usr/lib` is used by the build.
* `bwrap` is optional; when present it is used for an extra "bare root" smoke test.

### Building resources

* About 10 GB of free disk space. A built `rootfs3/` is roughly 6 GB, with the
  GCC 10 build tree and source trees being the largest items.
* Time: the full chain takes hours on a typical machine. GCC 10 is the longest
  single step (the scripts allow a CPU-time limit; see section 8).
* No network access is required if all source archives are already in the
  repository root.

### Source archives

Place these exact files in the repository root. The scripts fail early with a
clear message if one is missing.

| Archive | Used for |
| --- | --- |
| `binutils-2.44.tar.gz` | GNU binutils |
| `gcc-4.6.4.1.tar.gz` | GCC 4.6 (RISC-V fork; the archive's top directory is `gcc/`) |
| `gcc-10.4.0.tar.gz` | GCC 10 |
| `gmp-6.2.1.tar.xz` | GMP |
| `mpfr-4.1.0.tar.xz` | MPFR |
| `mpc-1.2.1.tar.gz` | MPC |
| `zlib-1.3.2.tar.gz` | zlib |
| `musl-1.2.6.zip` | musl |
| `make-4.4.tar.gz` | GNU make |

`fetch-source.sh` in the repository root is a reference list of the upstream
URLs. It is not run by any build step.

### xcc source tree

The xcc sources live in `xcc`, which must be a git checkout. The patches in
`patches-3/` target xcc 0.1.13 (upstream commit `9eea241`). If `xcc` is missing
or empty, populate it from upstream:

```sh
# If xcc exists but is empty, remove the placeholder first.
rm -rf xcc
git clone https://github.com/tyfkda/xcc.git xcc
git -C xcc checkout 9eea241
```

`RESET=1` on the first build restores `xcc` to its checked-out HEAD
and discards local changes there; do not keep uncommitted work in that tree.

The build scripts apply `patches-3/*.patch` to this tree and expect it to be a
git repository. Patches are applied only inside `xcc`.

---

## 3. Build order

Run the steps in the order below. Every script is idempotent: it can be re-run,
and it skips work that is already done. The full sequence has been validated
from an empty `rootfs3/`: host GCC seeds `xcc-boot`, and the chain builds through
GCC 10.4.0. GNU make 4.4 is a separate optional step. Each step checks its inputs
and stops with the name of any missing artifact; if a step fails, fix the cause
and re-run it.

One command builds the whole chain through GCC 10.4.0:

```sh
./3-build-all.sh
```

The driver accepts `JOBS`, `CPU_LIMIT`, and `RESET` and writes
`results/3-build-all.log`. GNU make 4.4 is not part of it; run
`./3-build-make.sh` separately if you need make.

The equivalent manual sequence is:

```sh
# Phase 1: seed the compiler and the xcc-compatible libc
RESET=1 ./3-build-xcc-boot.sh
./3-build-musl-xcc.sh
./3-build-xcc-musl.sh

# Phase 2: support libraries, binutils, GCC 4.6 stage 1
./3-build-gmp.sh
./3-build-mpfr.sh
./3-build-mpc.sh
./3-build-zlib.sh
./3-build-binutils.sh
./3-build-gcc46-xcc.sh
./3-build-musl-gcc.sh
GOAL=all-target-libgcc ./3-build-gcc46-xcc.sh

# Phase 3: GCC 4.6 stage 2, rebuilt libraries, final stage 2
SYSROOT="$PWD/rootfs3/usr/musl-gcc-sysroot" ./3-build-gcc46-stage2.sh
./3-adjust-rootfs-current.sh
./3-build-deps-gcc46.sh
CLEAN=1 ./3-build-gcc46-stage2.sh

# Phase 4: GCC 10 and current-generation switch
./3-build-gcc10.sh
GCC_PREFIX=/usr/gcc10 ./3-adjust-rootfs-current.sh

# Optional, not part of ./3-build-all.sh
./3-build-make.sh
```

### Phase 1: seed and xcc chain

* `3-build-xcc-boot.sh` builds `xcc-boot` with the host compiler. `xcc-boot` then
  builds `xcc-xcclib`, a static compiler linked against xcc's own bundled libc.
  `xcc-boot` is only a seed and is not part of the final toolchain. `RESET=1`
  restores `xcc` to its clean baseline before applying the patches; use it
  on the first run or whenever the patch set changes.
* `3-build-musl-xcc.sh` uses `xcc-xcclib` to build musl 1.2.6. It installs the
  result in `rootfs3/usr/musl-1` and, by default (`LAND_SYSROOT=1`), also makes
  `rootfs3/usr/{include,lib}` point at it. That global sysroot is what the next
  xcc and library builds use.
* `3-build-xcc-musl.sh` uses `xcc-xcclib` plus musl-1 to build `xcc-musl`, the
  final static xcc linked against musl. It also installs the `xcc-musl-cc` wrapper
  used by the support-library, binutils and GCC builds.

### Phase 2: libraries, binutils, GCC 4.6 stage 1

* The four library steps (`gmp`, `mpfr`, `mpc`, `zlib`) compile with
  `xcc-musl-cc` and install headers/libraries into the global sysroot. GMP and
  MPFR are prerequisites of MPC; zlib is required by binutils and GCC.
* `3-build-binutils.sh` builds GNU binutils 2.44 with `xcc-musl`, restricted to
  the C-only components. It installs to `rootfs3/usr/binutils` and deliberately
  does not overwrite the entry points in `rootfs3/usr/bin`.
* `3-build-gcc46-xcc.sh` (default `GOAL=all-gcc`) builds GCC 4.6.4.1 stage 1 with
  `xcc-musl`: the `cc1` and `cc1plus` front ends, but no target-side runtimes.
  Its `--with-as/--with-ld` point at the self-built binutils.
* `3-build-musl-gcc.sh` uses that stage-1 GCC to build a complete musl. This is
  `musl-gcc`; unlike `musl-1`, it includes complex arithmetic, true 80-bit
  `long double`, and all architecture assembly.
* `GOAL=all-target-libgcc ./3-build-gcc46-xcc.sh` reuses the stage-1 build tree to
  build the target `libgcc` and `crtbegin`/`crtend` objects.

### Phase 3: GCC 4.6 stage 2

The first `3-build-gcc46-stage2.sh` run uses a small sysroot view
(`rootfs3/usr/musl-gcc-sysroot`) because the global sysroot still points at
`musl-1`. It installs GCC 4.6 with its own `libgcc` and static `libstdc++` into
`rootfs3/usr/gcc46`.

`3-adjust-rootfs-current.sh` then switches the global sysroot from `musl-1` to
`musl-gcc` and writes the `rootfs3/usr/bin` entry points for the current GCC
(default: `/usr/gcc46`).

`3-build-deps-gcc46.sh` rebuilds GMP, MPFR, MPC and zlib with the stage-1 GCC
4.6 so they no longer contain xcc-generated code. Finally,
`CLEAN=1 ./3-build-gcc46-stage2.sh` rebuilds GCC 4.6 against those libraries and
the normal (non-view) sysroot.

### Phase 4: GCC 10 and current generation

* `3-build-gcc10.sh` builds GCC 10.4.0 with the installed GCC 4.6 and the
  self-built binutils. It enables a three-stage bootstrap; the installed compiler
  is the stage-3 result.
* `GCC_PREFIX=/usr/gcc10 ./3-adjust-rootfs-current.sh` makes GCC 10 the current
  compiler: `gcc`, `g++`, `cc`, `c++`, `cpp` and `gcov` in `rootfs3/usr/bin` now
  exec the GCC 10 binaries, and `as`, `ld`, `ar`, `ranlib`, `nm` point at the
  self-built binutils.

### Optional: GNU make 4.4

`./3-build-make.sh` builds GNU make 4.4 with `xcc-musl`, the self-built GNU `ld`,
and `musl-gcc`, and installs it as `rootfs3/usr/bin/make`. It is not part of
`3-build-all.sh`.

---

## 4. Using the finished toolchain

The installed binaries are static and can be run directly from the host:

```sh
rootfs3/usr/bin/gcc --version
rootfs3/usr/bin/g++ --version
rootfs3/usr/bin/as --version
rootfs3/usr/bin/make --version
```

Compile and run a small C program:

```sh
cat > /tmp/hello.c <<'EOF'
#include <stdio.h>
int main(void) {
    puts("hello from the self-hosted toolchain");
    return 0;
}
EOF

rootfs3/usr/bin/gcc /tmp/hello.c -o /tmp/hello
/tmp/hello
```

The same works for C++:

```sh
rootfs3/usr/bin/g++ -std=c++17 /tmp/hello.cc -o /tmp/hello
```

`rootfs3/usr/bin/include` and `rootfs3/usr/bin/lib` are symlinks into the current
sysroot. They exist so that running the toolchain with `rootfs3/usr/bin` on
`PATH` (for example inside a chroot) finds headers and libraries consistently.

> **Moving the tree:** the compiled GCC records the absolute path of the sysroot
> at configure time. If you move the repository to a different path, rebuild the
> affected GCC steps (or reconfigure) rather than copying the binaries.

---

## 5. Script reference

| Script | What it does | Main outputs |
| --- | --- | --- |
| `3-build-all.sh` | Runs the complete chain from host GCC to GCC 10.4.0 (does not build make) | `usr/gcc10` |
| `3-build-xcc-boot.sh` | Host GCC builds `xcc-boot`; `xcc-boot` builds `xcc-xcclib` | `usr/xcc-boot`, `usr/xcc-xcclib` |
| `3-build-musl-xcc.sh` | Builds musl 1.2.6 with `xcc-xcclib`; lands it as the global sysroot | `usr/musl-1`, `usr/{include,lib}` |
| `3-build-xcc-musl.sh` | Builds `xcc-musl` from `xcc-xcclib` + `musl-1`; installs the CC wrapper | `usr/xcc-musl`, `xcc-musl-cc` |
| `3-build-xcc-musl-cc.sh` | Source of the `xcc-musl-cc` wrapper (not a build step itself) | installed as `usr/xcc-musl/bin/xcc-musl-cc` |
| `3-build-gmp.sh` | Builds GMP 6.2.1 with `xcc-musl-cc` | `usr/include/gmp.h`, `usr/lib/libgmp.a` |
| `3-build-mpfr.sh` | Builds MPFR 4.1.0 with `xcc-musl-cc` | `usr/include/mpfr.h`, `usr/lib/libmpfr.a` |
| `3-build-mpc.sh` | Builds MPC 1.2.1 with `xcc-musl-cc` | `usr/include/mpc.h`, `usr/lib/libmpc.a` |
| `3-build-zlib.sh` | Builds zlib 1.3.2 with `xcc-musl-cc` | `usr/include/zlib.h`, `usr/lib/libz.a` |
| `3-build-binutils.sh` | Builds GNU binutils 2.44 with `xcc-musl` | `usr/binutils/{bin,lib,...}` |
| `3-build-gcc46-xcc.sh` | Builds GCC 4.6.4.1 stage 1 (`all-gcc` by default, `all-target-libgcc` with `GOAL`) | `build/gcc-4.6.4.1` |
| `3-build-musl-gcc.sh` | Builds complete musl 1.2.6 with GCC 4.6 stage 1 | `usr/musl-gcc` |
| `3-build-gcc46-stage2.sh` | Rebuilds GCC 4.6 with the stage-1 gcc46; produces `libgcc` and static `libstdc++` | `usr/gcc46` |
| `3-build-deps-gcc46.sh` | Rebuilds GMP/MPFR/MPC/zlib with GCC 4.6 stage 1 | global sysroot |
| `3-build-gcc10.sh` | Builds GCC 10.4.0 with GCC 4.6, three-stage bootstrap | `usr/gcc10` |
| `3-build-make.sh` | Builds GNU make 4.4 with `xcc-musl` + GNU `ld` + `musl-gcc` (optional) | `usr/bin/make` |
| `3-adjust-rootfs-current.sh` | Switches the current GCC and the global sysroot; rewrites `usr/bin` entries | symlinks/wrappers in `usr/bin` |
| `3-lib/common.sh` | Shared paths and helpers: logging, patch application, static checks, state | sourced by the scripts |

Useful switches are documented at the top of each script. The most common ones
are:

| Variable | Used by | Effect |
| --- | --- | --- |
| `JOBS=n` | most scripts | Parallel make jobs (default: `nproc`) |
| `CLEAN=1` | most scripts | Delete the build tree before rebuilding |
| `FORCE_SRC=1` | most scripts | Re-extract the source archive, discarding source edits |
| `NO_SMOKE=1` | most scripts | Skip the end-to-end smoke test |
| `RESET=1` | `3-build-xcc-boot.sh` | Restore `xcc` to HEAD before patching |
| `CONF_ONLY=1` | GCC/binutils scripts | Stop after `configure` |
| `MAKE_ONLY=1` | `3-build-binutils.sh` | Skip `configure`, run `make` only |
| `GOAL=...` | GCC/binutils scripts | Override the make target |
| `CPU_LIMIT=n` | GCC 4.6, binutils, GCC 4.6 stage-2 | Set `ulimit -t n` for `make` (CPU seconds) |
| `LAND_SYSROOT=0` | `3-build-musl-xcc.sh` | Do not land musl-1 as the global sysroot |
| `SELFTEST=1` | `3-build-musl-gcc.sh` | Run the extra end-to-end self-test |
| `MATERIALIZE_SYSROOT=1` | `3-build-musl-gcc.sh` | Add missing entries to the global sysroot (repoint existing ones with `3-adjust-rootfs-current.sh`) |
| `ASLD=binutils\|xcc\|host` | `3-build-musl-gcc.sh` | Choose the assembler/linker source; `host` is diagnostic, and the recorded `--with-as/--with-ld` may still take precedence |
| `CHECK=1` | library/make scripts | Run the upstream test suite where available |
| `NO_BOOTSTRAP=1` | `3-build-gcc10.sh` | Build a single-stage GCC 10 instead of a bootstrap |
| `GCC_PREFIX=/usr/gcc10` | `3-adjust-rootfs-current.sh` | Select the GCC generation to make current |
| `RESTORE=1` | `3-adjust-rootfs-current.sh` | Roll the entry points back to the xcc-era layout |

`XCC_TIME=1` enables xcc's internal code-generation timing (the
`xcc-time-report` patch); it is useful only when debugging the compiler itself.

---

## 6. Directory layout

| Path | Contents |
| --- | --- |
| `3-build-*.sh` | The build steps |
| `3-build-all.sh` | Driver that runs the chain from host GCC to GCC 10.4.0 |
| `3-adjust-rootfs-current.sh` | Switch the current GCC and global sysroot |
| `3-lib/common.sh` | Shared constants and helper functions |
| `patches-3/*.patch` | Patches applied to `xcc` |
| `patches-3/experimental/` | Experimental/probe material; not applied by the build |
| `xcc` | xcc source checkout (baseline + applied patches) |
| `rootfs3/usr/` | Installed toolchains and the global sysroot |
| `rootfs3/build/` | Out-of-tree build directories and detailed logs |
| `rootfs3/src/` | Extracted source trees |
| `rootfs3/tests/` | Smoke-test sources and artifacts |
| `results/` | Per-script logs and `3-STATE.env` |
| `*.tar.gz`, `*.zip`, `*.tar.xz` | Source archives expected in the repository root |

`rootfs3/` contains build products and is not tracked by git. The source archives
are part of the repository; the scripts unpack them into `rootfs3/src/` and build
in `rootfs3/build/`.

Each build step writes its full log to `results/3-build-<name>.log`. Small
key/value facts (paths, versions, sizes, hashes, success flags) are appended to
`results/3-STATE.env` through `record`/`recall`, and later steps use them for
precondition checks.

---

## 7. Patches

All patches in `patches-3/*.patch` are applied to `xcc` in alphabetical
order by `apply_patches_3` in `3-lib/common.sh`. Application is idempotent: a
patch that is already present is skipped, and a whole-chain check first compares
the tree with "clean HEAD + every patch" so that overlapping patches do not cause
false failures. `experimental/` is not part of the chain.

| Patch | Purpose |
| --- | --- |
| `xcc-builtin-alloca.patch` | Makes `__builtin_alloca` a real builtin. |
| `xcc-cmp-const-fold.patch` | Folds comparisons with constant operands. |
| `xcc-comma-string-literal.patch` | Handles a string literal as the right operand of a comma expression. |
| `xcc-declit-signed.patch` | Preserves the signedness of decimal integer literals. |
| `xcc-extern-with-initializer.patch` | Accepts `extern T x[];` after a definition that has an initializer. |
| `xcc-gcc-syntax-extensions.patch` | Adds GCC range designators (`[lo ... hi]`), `case lo ... hi:`, and `__extension__`. |
| `xcc-inline-asm.patch` | Adds GNU inline assembly (templates, operands, clobbers, x86 opcodes); required by musl. |
| `xcc-mov-const-flonum-cast.patch` | Fixes moves and casts of floating-point constants. |
| `xcc-regalloc-pinned.patch` | Respects fixed-register constraints in register allocation. |
| `xcc-regalloc-reserve-frame-pointer.patch` | Reserves the frame pointer instead of allocating `%rbp` as a general register. |
| `xcc-stdarg-va-arg-hygiene.patch` | Fixes macro hygiene in `va_arg`. |
| `xcc-stdio-seek-macros.patch` | Defines `SEEK_SET`/`SEEK_CUR`/`SEEK_END` as macros rather than an enum. |
| `xcc-strtod-correct-rounding.patch` | Corrects rounding in `strtod`. |
| `xcc-ternary-qualified-struct.patch` | Fixes the result type of `?:` with qualified struct operands. |
| `xcc-time-report.patch` | Adds optional `XCC_TIME=1` code-generation/register-allocation timing. |

Patch files are the source of truth. To change xcc behaviour, change the patch
(and re-run `RESET=1 ./3-build-xcc-boot.sh`), not the generated tree.

---

## 8. Logs, state, and verification

Every build step logs to `results/3-build-<name>.log` (and `results/3-adjust-rootfs-current.log`
for the switch script). The log contains the exact command line, host
information, configure output, make output, and the final report. `3-STATE.env`
holds the machine-readable summary.

The scripts do not treat "the output file exists" as success. Depending on the
step, they check:

* the exit status of `configure`, `make` and `install`;
* expected output files, their sizes, and archive membership;
* that produced executables are statically linked and have no `PT_INTERP`
  (`file` and `readelf -l`);
* end-to-end smoke tests that compile, link and run a small program (and, for
  GCC, C++ exceptions, threads, the four support libraries, and a few standard
  headers);
* upstream test suites where practical: GMP (175 pass), MPFR (179 pass), MPC
  (69 pass), zlib's own test, and GNU make's test suite (1185 pass, one known
  musl-specific failure);
* for GCC 10, the bootstrap comparison: the build log should contain
  `Comparing stages 2 and 3` followed by `Comparison successful`.

One xcc-specific trap is handled explicitly. The xcc driver is a
`cpp | cc1 | as` pipeline. If the upstream process is killed (for example by
`ulimit -t`), the downstream `as` can still exit 0 after writing a 384-byte
object file with no symbols. A build could therefore look successful while
producing an empty object. The GCC and binutils scripts scan for exactly
384-byte `.o` files, skip a small whitelist of legitimately empty objects, and
delete/report suspicious ones.

Wall-clock time is not a reliable measure when the host machine may sleep or be
loaded. Compare CPU time (`user` + `sys`) instead. `CPU_LIMIT=n` wraps `make` in
`ulimit -t n`, which bounds CPU seconds (not elapsed time) and is useful for
unattended runs; when the limit is hit, the build stops and the log is kept.

---

## 9. Switching the current generation

`3-adjust-rootfs-current.sh` is the script that switches the current GCC
generation and the global sysroot. It:

1. repoints the `rootfs3/usr/include` and `rootfs3/usr/lib` symlinks from
   `musl-1` to `musl-gcc` (and the convenience links `usr/bin/{include,lib}`);
2. writes small POSIX-sh wrappers for `gcc`, `g++`, `cc`, `c++`, `cpp` and `gcov`
   that `exec` the selected GCC with an absolute path (this matters because GCC
   derives its `gcc_exec_prefix` from `argv[0]`);
3. symlinks `as`, `ld`, `ar`, `ranlib` and `nm` to the self-built binutils.

The default GCC is `/usr/gcc46`. To make GCC 10 current:

```sh
GCC_PREFIX=/usr/gcc10 ./3-adjust-rootfs-current.sh
```

To roll back to the xcc-era layout:

```sh
RESTORE=1 ./3-adjust-rootfs-current.sh
```

Re-running `3-build-musl-xcc.sh` lands `musl-1` as the global sysroot again
(unless `LAND_SYSROOT=0`). If you re-run it after switching to `musl-gcc`, run
`3-adjust-rootfs-current.sh` again to restore the `musl-gcc` sysroot.

---

## 10. Design notes

* **One host compiler, then none.** `3-build-xcc-boot.sh` is the only step that
  calls the host `gcc`. The host `make`, shell and text utilities are used as
  drivers, but no host compiler, assembler, linker, `/usr/include` or `/usr/lib`
  participates after the seed.
* **Static by construction.** The target trees contain only `libc.a` and static
  archives, so produced programs do not need a dynamic loader.
* **Every generation is built by the previous one.** There is no opaque binary
  seed beyond the one host-GCC step, and the build records what was used.
* **Patches are explicit.** Compiler fixes are files in `patches-3/`, applied
  idempotently; the generated source tree is never the source of truth.
* **The steps are resumable.** Each script checks its inputs, reuses existing
  build trees, and can be re-run. `CLEAN=1` forces a clean rebuild of its own
  step; `FORCE_SRC=1` re-extracts the archive.
* **Observable results.** Logs, `3-STATE.env`, output sizes, static-link checks
  and smoke tests make failures visible.

---

## 11. Known limitations

* **x86_64 only.** There is no cross-compilation and no multilib support in the
  current scripts; the GCC 4.6 source includes a RISC-V backend, but the build
  targets `x86_64-pc-linux-gnu`.
* **Static only.** No shared libraries are built. GCC 4.6 and GCC 10 produce
  static executables against musl.
* **xcc is not GCC.** It lacks `_Complex`, has an 8-byte `long double`, and its
  assembler does not understand x87/SSE syntax. The xcc-built `musl-1`
  compensates by skipping `src/complex/*` and `posix_spawn.c`, narrowing
  `long double` to `double`, and using C fallbacks or hand-written assembly for
  some architecture files. Use `musl-gcc` when you need the complete libc.
* **Two compiler generations are retained.** `usr/gcc46` and `usr/gcc10` coexist
  so that either can be selected. The `3-adjust-rootfs-current.sh` wrapper only
  changes the entry points; it does not delete anything.
* **GCC 10 is intentionally reduced.** The build disables LTO, plugins,
  `libgomp`, `libatomic`, `libvtv`, `libsanitizer`, multilib and shared
  libraries to keep the bootstrap tractable. `<coroutine>` requires C++20 and
  `-fcoroutines`; `<filesystem>` is available.
* **GNU make check has one known failure.** `misc/close_stdout` triggers musl's
  recursive-`exit` protection; this is a musl/make semantic difference, not an
  xcc bug. The other 1185 tests pass.
* **binutils is C-only.** `gold` and `gprofng` (C++) are disabled; `gdb` and
  `sim` are separate upstream packages and are not part of this build.
* **Absolute paths are embedded.** GCC's sysroot and the `rootfs3/usr/bin`
  wrappers use the build-time absolute path. Moving the tree requires
  reconfiguring the affected steps.
* **Host-driver tools are still needed.** `make`, the shell, `sed`, `awk`, `tar`
  and friends are host tools. The scripts document the exact list they use; the
  policy is "no host compilers, assemblers, linkers, headers or libraries after
  the seed".

---

## 12. Troubleshooting

* **Check syntax first.** `bash -n 3-build-*.sh` catches accidental edits.
* **A patch does not apply.** Ensure `xcc` is a clean git checkout at the
  baseline the patches target. `RESET=1 ./3-build-xcc-boot.sh` restores and
  reapplies; `git -C xcc status` shows what is dirty.
* **A step fails after changing the compiler or a library.** Re-run that step
  with `CLEAN=1`; make will not rebuild objects when only the compiler changed.
  Use `FORCE_SRC=1` if you also changed a source patch.
* **Re-running an xcc-based step after the switch.** `xcc-musl-cc` defaults to
  the global sysroot, which `3-adjust-rootfs-current.sh` points at `musl-gcc`.
  xcc cannot handle musl-gcc's true 80-bit `long double`. Before rerunning an
  xcc-based step (`musl-1`, `xcc-musl`, the four libraries, binutils, or GCC
  stage 1), point `XCC_SYSINC` / `XCC_SYSLIB` at
  `rootfs3/usr/musl-1/{include,lib}`, or re-land musl-1 and re-run the
  adjustment afterwards.
* **The wrong libc is being picked up.** Check where
  `rootfs3/usr/include` and `rootfs3/usr/lib` point. Run
  `3-adjust-rootfs-current.sh` to restore the `musl-gcc` sysroot, or use
  `XCC_SYSINC` / `XCC_SYSLIB` to override the wrapper paths for a single build.
* **GCC 10 bootstrap directories.** GCC's bootstrap keeps `stage1-gcc`, moves
  stage 2 to `prev-gcc`, and leaves the final compiler in `gcc`; `stage2-gcc` /
  `stage3-gcc` are not kept. The authoritative result is
  `Comparing stages 2 and 3` + `Comparison successful` in
  `rootfs3/build/gcc10/make-gcc10.log`; the script now checks that line.
* **The build looks slow but the logs show little progress.** The host may be
  sleeping or oversubscribed. Compare `user`/`sys` time from the logs, not
  wall-clock time, and reduce `JOBS` if memory pressure causes swapping.
* **A source archive was modified or extracted badly.** Use `FORCE_SRC=1` to
  re-extract that step's archive.
* **The tree was moved.** Rebuild the GCC steps so their configured sysroot
  paths match the new location.

---

## 13. Upstream sources and licensing

| Project | Version | Upstream |
| --- | --- | --- |
| xcc | 0.1.13 | <https://github.com/tyfkda/xcc> |
| musl | 1.2.6 | <https://github.com/kraj/musl/tree/v1.2.6> |
| GCC 4.6 (RISC-V fork) | 4.6.4.1 | <https://codeberg.org/ekaitz-zarraga/gcc> |
| GCC | 10.4.0 | <https://ftp.gnu.org/gnu/gcc/gcc-10.4.0/> |
| GNU binutils | 2.44 | <https://ftp.gnu.org/gnu/binutils/> |
| GNU make | 4.4 | <https://ftp.gnu.org/gnu/make/> |
| GMP | 6.2.1 | <https://gmplib.org/> |
| MPFR | 4.1.0 | <https://www.mpfr.org/> |
| MPC | 1.2.1 | <https://www.multiprecision.org/mpc/> |
| zlib | 1.3.2 | <https://zlib.net/> |

The source archives remain under their upstream licenses. This repository adds
build scripts and compiler patches; it does not relicense the upstream projects.
Consult each source archive's `COPYING`/`LICENSE` file before redistributing
binaries.
