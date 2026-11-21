# C Compiler Cross-Evaluation: Baseline, Mutual Builds, and EDG 5.1 (x86_64)

- Date: 2026-11-13 – 2026-11-16
- Working directory: `/home/tedm/CS/my-proj/my-bootstrap/personal-bootstrap/bootstrap-box/Compilers`
- Scope: `cproc-qbe/`, `pcc/`, `tcc/`, `widcc-slimcc/`, `xcc/`; plus the new `pairwise/` (four compilers building each other) and `edg5.1-try/` (EDG C++ front end 5.1)
- Detailed source reports:
  - Baseline evaluation:
    - [`cproc-qbe/cproc-report-1.md`](cproc-qbe/cproc-report-1.md), [`cproc-report-2.md`](cproc-qbe/cproc-report-2.md), [`cproc-report-3.md`](cproc-qbe/cproc-report-3.md)
    - [`pcc/pcc-testsuite.md`](pcc/pcc-testsuite.md)
    - [`tcc/tcc-testsuite.md`](tcc/tcc-testsuite.md)
    - [`widcc-slimcc/widcc-testsuite.md`](widcc-slimcc/widcc-testsuite.md), [`widcc-slimcc/slimcc-testsuite.md`](widcc-slimcc/slimcc-testsuite.md)
    - [`xcc/xcc-testsuite.md`](xcc/xcc-testsuite.md)
  - Mutual builds: [`pairwise/pairwise-build-report.md`](pairwise/pairwise-build-report.md)
  - EDG 5.1: [`edg5.1-try/edg5.1-build-report.md`](edg5.1-try/edg5.1-build-report.md)

> This document is a cross-cutting summary. The complete commands, log paths, and per-item analyses are in the detailed reports listed above.
>
> Chinese version: [`c-compiler-test-cn.md`](c-compiler-test-cn.md).
>
> Revision note: this document is an expansion of the original `c-compiler-test.md`, adding §6 (four-compiler mutual builds) and §7 (EDG C++ front end 5.1), and was renamed to `c-compiler-test-cn.md` (Chinese) / `c-compiler-test-en.md` (English).

## Table of Contents

0. Executive summary
1. Environment and evaluation criteria
2. Compiler overview: architecture, build, toolchain, standard library, code size
3. Baseline I: c-testsuite results and per-test errors
4. Baseline II: binutils 2.44 and toybox 0.8.15
5. Baseline III: musl 1.2.5 build attempts
6. Mutual builds: four compilers building each other
7. Application build: EDG C++ front end 5.1
8. Conclusions and recommendations
9. Artifacts, logs, and reproduction

**Reading guide**

- For conclusions only: §0. For architecture/toolchain/license/code size: §2.
- For baseline results and per-test failures: §3–§5. For mutual builds: §6. For EDG 5.1: §7.
- For overall judgement and fix priorities: §8. For reproduction commands: §9.

**Table conventions**: `—` means not applicable or not measured; "not tested" means no data was collected in this round.

---

## 0. Executive Summary

### 0.1 c-testsuite (single-exec, 220 tests, no skips)

| Rank | Compiler | Host PASS | Pass rate | Host failures |
|---:|---|---:|---:|---|
| 1 | **tcc** | **220 / 220** | **100%** | none |
| 2 | **slimcc** | **219 / 220** | **99.5%** | `00206` |
| 3 | **widcc** | **217 / 220** | **98.6%** | `00206`, `00216`, `00219` |
| 4 | **xcc** | **214 / 220** | **97.3%** | `00162`, `00178`, `00202`, `00206`, `00209`, `00216` |
| — | **xcc (host as/ld + glibc)** | **213 / 220** | **96.8%** | same 6 plus `00204` (long double/HFA) |
| 5 | **cproc + QBE** | **211 / 220** | **95.9%** | `00141`, `00144`, `00174`, `00204`, `00209`, `00210`, `00213`, `00214`, `00216` |
| 6 | **pcc** | **207 / 220** | **94.1%** | `00143`, `00162`, `00174`, `00200`, `00202`, `00204`, `00206`, `00210`, `00211`, `00212`, `00213`, `00216`, `00219` |

All reports used a GCC 16.2.0 baseline, which scored **220 / 220**.

> xcc's "host as/ld + glibc" mode is experimental and is not part of the default ranking; it scored 213/220.

### 0.2 riscv64 tests (only the four projects with riscv builds)

| Compiler | riscv64 result | Notes |
|---|---|---|
| **tcc** | **220 / 220** | tcc compile + riscv gcc link; tcc + tcc-built musl self-host also 220/220 |
| **xcc** | **213 / 220** | riscv64-hosted xcc under qemu; one more failure than on the host: `00204` |
| **cproc + QBE** | **193 / 220** | x86 host, riscv64 target cross-compiler; 27 compile errors |
| **pcc** | **0 / 220** | riscv binary starts, but the backend is an unfinished 32-bit backend; GNU as rejects its non-GNU assembly |
| widcc / slimcc | not provided | upstream supports x86-64 Linux only |
| **xcc (host as/ld + glibc)** | n/a | this variant was only tested on amd64 |

### 0.3 musl 1.2.5 build (unmodified sources)

| Compiler | Compiled | Success rate | `libc.a`/`libc.so` | Main blocker |
|---|---:|---:|---|---|
| **slimcc** | **1284 / 1352** | **95.0%** | no | `_Complex` only (68) |
| **tcc (x86_64)** | **2525 / 2697 targets** | **93.6%** | no | `_Complex` + x86_64 SSE/x87 inline assembly |
| **tcc (riscv64)** | **1281 / 1351 targets** | **94.8%** | no | `_Complex` + 2 assembly files |
| **pcc** | **745 / 1345** | **55.4%** | no | register-asm locals (534) |
| **widcc** | **722 / 1352** | **53.4%** | no | inline assembly/register variables (557) |
| **xcc (x86_64)** | **1117 / 2697 targets** | **41.4%** | no | `__builtin_va_list` + extended inline asm + `_Complex` |
| **xcc (riscv64)** | **566 / 1351 targets** | **41.9%** | no | same, plus `__attribute__` |
| **cproc + QBE** | **526 / 1345** | **39.1%** | no | inline asm (537) + `long double` (211) + `_Complex` (68) |
| **xcc (host as/ld + glibc)** | not tested | — | — | this mode was not used for musl |

### 0.4 binutils 2.44 / toybox 0.8.15

| Compiler | binutils 2.44 | toybox 0.8.15 |
|---|---|---|
| **tcc** | **complete success** (282 `.o` + 102 `.lo`, objdump/as/ld) | **success** (239 applets; requires dropping `--gc-sections`, which tcc does not support) |
| **slimcc** | **complete success** (282 `.o` + 102 `.lo`, objdump/as/ld) | **success** (239 applets) |
| **widcc** | failure (81/282 `.o`, glibc `_Generic`) | **success** (239 applets) |
| **xcc (default mini libc)** | configure failure (missing `ferror`) | failure (missing `regex.h`) |
| **xcc (host as/ld + glibc)** | configure passes, but make still fails (2 `.o`) | parallel build reaches 29 `.o`, then fails on GNU `?:` |
| **cproc + QBE** | failure (64/282 `.o`, zlib K&R definitions) | failure (driver probes `-xc -`/`--version`) |
| **pcc** | failure (73/282 `.o`, zlib K&R + `--print-prog-name`) | failure (`__has_include`) |

GCC 16.2.0 baseline: binutils succeeds (282 `.o` + 102 `.lo`, objdump 11,106,816 B); toybox succeeds (239 applets, 452,768 B).

### 0.5 Code size overview (physical lines, excluding test/ etc.)

| Project | Physical lines | Comment-stripped code lines |
|---|---:|---:|
| pcc | 163,215 | 120,944 |
| tcc | 114,480 | 96,420 |
| xcc | 55,408 | 48,165 |
| cproc + QBE | 27,818 | 24,345 |
| slimcc | 21,843 | 18,492 |

See §2.10 for the counting method and composition.

### 0.6 Exploration I: mutual builds (four compilers building each other)

| Target \ Source | tcc | slimcc | xcc | cproc |
|---|---|---|---|---|
| **tcc** | — (self-build control) | ✅ | ⚠️→✅ | ❌ |
| **slimcc** | ✅ | — | ❌ | ✅ (bootstrap options) |
| **xcc** | ✅ | ✅ | — | ❌ |
| **cproc + QBE** | ✅ | ✅ | ⚠️* (cproc ok / QBE fail) | — |

- Of the 12 cross combinations: **7 direct successes, 1 success after fallback, 1 partial success, 3 failures**.
- All successful products pass hello + stress and complete stage2/gen2 self-builds; except for the `BOOTSTRAP_NO_LDOUBLE` semantic difference in slimcc ← cproc, their c-testsuite results match the native compilers exactly.
- Failure causes: cproc lacks `long double` (2 combinations); xcc has a front-end bug (1 combination, plus the partial QBE case). See §6.

### 0.7 Exploration II: application build (EDG C++ front end 5.1)

| Compiler | Front end edgcpfe | C++ runtime libC.a | C/C++17/exception smoke tests | Verdict |
|---|---|---|---|---|
| **tcc** | ✅ 63/63 | ✅ 51/51 | ✅ | complete success |
| **slimcc** | ✅ 63/63 | ✅ 51/51 | ✅ | complete success |
| **xcc** | ❌ cc1 SIGSEGV | — | — | failure |
| **cproc** | ❌ no `long double` | — | — | failure |

- tcc/slimcc build the EDG 5.1 front end and C++ runtime completely; all smoke tests pass.
- xcc fails because of an incomplete-struct pointer typedef type-completion bug, reproducible with four lines of valid C.
- cproc fails because it does not implement `long double`; EDG's `float_pt.c` alone contains 86 occurrences. See §7.

### 0.8 One-sentence summary

- **tcc**: c-testsuite 220/220, riscv64 220/220; musl only misses C99 complex and a little assembly; all 12 mutual-build combinations as a source compiler succeed, and it fully builds EDG 5.1.
- **slimcc**: c-testsuite 219/220; the only musl gap is `_Complex`; usable as both source and target in the mutual-build matrix, and it fully builds EDG 5.1.
- **widcc**: c-testsuite 217/220, but musl is only 53.4%; it lacks inline assembly, register variables, file-scope asm, and `_Generic`.
- **xcc**: c-testsuite 214/220; a self-contained toolchain with a mini libc and its own as/ld; as a source compiler it is limited by header gaps and a front-end bug, and cannot build slimcc/QBE/EDG.
- **cproc + QBE**: c-testsuite 211/220 (baseline, without `-lm`; 212/220 with `-lm` in the uniform runner); it lacks `long double`, inline asm, and `_Complex`; the missing `long double` blocks both tcc/xcc mutual builds and EDG 5.1.
- **pcc**: c-testsuite 207/220; the riscv backend is unfinished; musl is 55.4%, with register-asm variables as the single largest blocker.

## 1. Environment and Evaluation Criteria

### 1.1 Environment

| Item | Value |
|---|---|
| Host | Linux x86_64, kernel `7.2.12+deb14-amd64`, 20 cores |
| Host gcc | gcc `16.2.0` (Debian 16.2.0-3) |
| riscv cross gcc | riscv64-unknown-linux-musl-gcc `16.1.0` |
| riscv sysroot | `/opt/riscv/sysroot` (musl, lp64d/rv64gc; mostly headers + libs, no full userland) |
| Emulator | qemu-riscv64 (11.0.0 in the cproc report, 11.1.2 in the others) |
| c-testsuite | commit `5c72756` (2020-03-09), 220 `tests/single-exec/*.c` |
| musl | 1.2.5 |

### 1.2 c-testsuite criteria

All reports follow the single-exec specification:

1. one `.c` file with `main` as the entry point;
2. stdout + stderr must match `.expected` byte for byte;
3. the exit code must be 0;
4. each test has a time limit (tightened in the reports to 60 s for compilation and 10–30 s for execution).

No report used a skip list: all 220 tests were actually attempted, and every GCC baseline scored 220/220.

Status definitions:

| Status | Meaning |
|---|---|
| `PASS` | compile/link succeeded, exit code 0, output matched byte for byte |
| `COMPILE_ERROR` | preprocessing, compiling, assembling, or linking failed |
| `RUN_FAIL` | the program exited non-zero (including signals) |
| `OUTPUT_MISMATCH` | exit code 0, but output differs from `.expected` |
| `TIMEOUT` | compile or run time limit exceeded |

Driver options differ slightly between compilers, determined by what each driver supports:

| Compiler | Driver/link options | Notes |
|---|---|---|
| cproc | `cproc src -o bin` (no `-lm`) | `00174` fails for this reason; it passes with `-lm` |
| pcc | `pcc src -o bin` (no `-lm`) | same as above |
| tcc | `-std=c11 -lm` | links the native glibc |
| widcc | `-std=c11 -lm` | links the native glibc |
| slimcc | `-std=c11 -lm` | links the native glibc |
| xcc | `-std=c11` (no `-lm`) | the xcc driver does not accept `-lm`; its mini libc already contains the math functions |

### 1.3 musl criteria

- cproc and pcc use **1345 libc objects** as the denominator (corresponding to the 1345 members of GCC's final `libc.a`).
- widcc and slimcc use the **1352 targets in musl's `ALL_OBJS`** (including static `.o` and shared `.lo`).
- tcc and xcc reports count by their own build configurations: with static + shared on x86_64 the denominator is **2697 compile targets**; with `--disable-shared` on riscv64 it is **1351 targets**.
- Therefore the absolute object counts cannot be added directly; **percentages and blocker causes** are the comparable quantities.
- "Compiled successfully" is not the same as "libc is usable": only producing `libc.a` (or `libc.so`) and linking/running a real program counts as usable.

### 1.4 Mutual-build criteria (new)

- Scope: x86_64 only; the four compilers tcc, slimcc, xcc, and cproc + QBE build each other, giving 12 cross combinations. Self-builds are not counted and serve only as controls.
- Source compilers are the native, gcc-built versions:
  - tcc: `tcc/build-native/tcc` (0.9.28rc)
  - slimcc: `widcc-slimcc/slimcc/slimcc`
  - xcc: `xcc/build-native/xcc` (0.1.13)
  - cproc: `cproc-qbe/cproc/cproc` + `cproc-qbe/qbe/qbe`
- Target build methods:
  - tcc: out-of-tree `configure --cc=<source compiler>` + `make` + `make install`;
  - slimcc: copy the source tree and run `make CC=<source compiler>`;
  - xcc: copy the source tree and run `make CC=<source compiler> exes`, keeping xcc's own `lib/libc.a` and `lib/crt0.a`;
  - cproc + QBE: build `qbe` and `cproc` separately; `cproc`'s `configure` points at the `qbe` produced by the same source compiler.
- Special rule for xcc: first use xcc's own `cpp/cc1/as/ld` and mini libc; if that fails, fall back to "system as/ld + system headers + glibc" (the `xcc-sys` variant).
- Verification levels:
  1. the product exists and reports its version;
  2. it compiles and runs hello and a stress program;
  3. stage2 self-build (tcc/slimcc/cproc) or gen2/gen3 (xcc);
  4. compare against the native compiler with a uniform c-testsuite runner.
- The stress program covers structs, unions, bit-fields, variadics, function pointers, long integers, floating point, and strings. The c-testsuite run uses `-std=c11 -lm` uniformly; xcc does not use `-lm` because its mini libc already contains the math functions.

### 1.5 EDG C++ front end 5.1 criteria (new)

- Input: `edgcpp-compiler-5.1.tar.gz`; the EDG 5.1 front end is 63 C sources (`-std=gnu89` style, relying on `-fcommon`), and the C++ runtime is 51 `lib_src/*.c` files.
- Reference script: `edgcpp-try/refhost-edg5.1.sh`.
- Steps:
  1. generate `src/err_codes.h` and `src/err_data.h` (`mk_errinfo`);
  2. compile the 63 front-end sources and link `edgcpfe`;
  3. check `--version`;
  4. translate a C program → compile the generated C → run it;
  5. translate the 51 C++ runtime sources to C with edgcpfe → compile → `ar libC.a`;
  6. translate a C++17 program and an exception program → link against `libC.a` → run.
- Adaptation: when EDG translates C++, it uses the musl rootfs `/usr/include` to avoid glibc `bits/floatn.h`'s `__float128`/`__attribute__((__mode__))` (the gcc baseline fails there as well). The generated C is compiled with each compiler's default glibc.
- Compiler options:
  - tcc / slimcc: `-O2 -w -std=gnu89 -fcommon`;
  - cproc: `-O2 -std=gnu89` (cproc rejects `-w` and `-fcommon`).
- For xcc, again try its own tools/libraries first and fall back to system as/ld + glibc.

## 2. Compiler Overview: Architecture, Build, Toolchain, and Code Size

### 2.1 Version, license, and architecture overview

| Compiler | Version/commit | License | Upstream architecture support |
|---|---|---|---|
| **cproc + QBE** | cproc `d1c53dd`; QBE `180d2eb` (v1.3-4) | **ISC** (cproc) + **MIT** (QBE) | x86_64, aarch64, riscv64 (determined by the QBE backend) |
| **pcc** | `8b92dab2`, `1.2.0.DEVEL 20231021` | **mixed BSD/ISC** (including a Caldera-advertising-clause variant; file headers govern) | amd64, i386, aarch64, arm, mips, mips64, powerpc, riscv, sparc64, vax, and more; **the riscv backend has not been converted to 64-bit** |
| **tcc** | `2be0218b`, `0.9.28rc` | **LGPL-2.1** (plus a `RELICENSING` file, see below) | i386, x86_64, arm, aarch64, riscv64 (the tree also has a c67 backend) |
| **widcc** | `3d8385c5` | **MIT** | x86-64 Linux (glibc 2.28+) |
| **slimcc** | `2388c399` | **MIT** | x86-64 Linux |
| **xcc** | `83c51319`, `0.1.13` | **MIT** | x86-64, aarch64, riscv64, wasm |

> License sources: each repository's `LICENSE`/`COPYING`. cproc is ISC, QBE is MIT, pcc is mixed BSD/ISC (`LICENSE.md` says file headers govern), tcc is LGPL-2.1 (with the `RELICENSING` caveat below), and widcc/slimcc/xcc are MIT. Build status is in §2.8.
>
> **tcc `RELICENSING` note**: the official README and `COPYING` still declare tcc under LGPL-2.1, and the source headers still say "LGPL version 2 or later". The repository also contains a `RELICENSING` file in which listed authors agree to relicense TinyCC (including historical contributions) under MIT-style terms. The list is not unanimous: Daniel Glöckner voted NO for `arm-gen.c` (YES for other files), and `tiny_libmaker.c` (Timo VJ Lähde) and `tcccoff.c`/`c67-gen.c` (TK) are still marked `?`. This document therefore still labels the whole of tcc as **LGPL-2.1**, not pure MIT; only the clearly approved parts may be handled under the `RELICENSING` terms.

### 2.2 cproc + QBE

**Architecture**: cproc is a front end for QBE; the target architecture is determined by QBE. The cproc README says all QBE-supported backends should work (currently x86_64, aarch64, riscv64), and its CI covers `x86_64-linux-musl/gnu`, `aarch64-linux-musl/gnu`, and `riscv64-linux-gnu`. This evaluation actually verified an x86_64 host and a riscv64 target.

**Host build**:

```sh
cd qbe && make -j20 && cd ..
cd cproc && ./configure --with-qbe="$PWD/../qbe/qbe" && make -j20
```

Products:

```text
qbe/qbe          669,384 B
cproc/cproc       50,624 B  (driver)
cproc/cproc-qbe  291,096 B  (front end)
```

**Two riscv64 builds**:

- **Option A**: compile the QBE/cproc binaries with riscv64-unknown-linux-musl-gcc, producing riscv64-musl executables. A manual pipeline (cross cpp → cproc-qbe under qemu → qbe under qemu → cross as/ld) verified that it generates correct riscv64 programs. The full driver, however, depends on native `cpp/as/ld/qbe` on the target; the current sysroot has no userland, and qemu-user resolves external tools to host x86 programs, so the full native driver cannot run under qemu.
- **Option B**: build an "x86_64 host, riscv64-unknown-linux-musl target" cross-compiler that compiles riscv64 programs directly on the host and runs them under qemu. The 193/220 c-testsuite result was obtained with this option.

### 2.3 pcc

**Architecture**: the source tree contains many backends (`arch/` has amd64, i386, aarch64, arm, m68k, mips, mips64, powerpc, riscv, sparc64, vax, pdp10, pdp11, etc.). This evaluation only verified amd64; the riscv backend is an unfinished 32-bit implementation (`SZLONG`/`SZPOINT` fixed at 32 bits, assembly output using `subi`, `assign`, `;` comments, and other non-GNU syntax).

**Host build**:

```sh
mkdir build-host install-host && cd build-host
../pcc/configure --prefix="$PWD/../install-host"
make -j20 && make install
```

Result: success, 29 warnings, 0 errors. Products:

```text
install-host/bin/pcc      36,784 B   (driver)
install-host/libexec/ccom 470,304 B  (C compiler proper)
install-host/libexec/cpp   64,792 B
```

To actually compile/link programs, the report also supplied the runtime pieces missing from pcc-libs (without changing test semantics):

- an empty `libpcc.a`;
- GCC's `crtbegin.o`/`crtend.o` and other startup objects;
- GCC's private headers (`stddef.h`, `stdarg.h`, `float.h`, etc.).

**riscv64 build**: after modifying 8 files (configure/cconfig/Makefile/arch/riscv etc.), it built successfully with riscv64 gcc and starts under qemu. However, it generates 32-bit-model code with non-GNU assembly syntax that GNU as rejects, so it is only "a riscv binary that starts", not a usable riscv64 compiler.

### 2.4 tcc

**Architecture**: the README explicitly states that it generates i386, x86_64, arm, aarch64, and riscv64 machine code; the tree also contains a c67 backend. This evaluation verified x86_64 and riscv64.

**Host build** (out-of-tree):

```sh
mkdir build-native && cd build-native
../tinycc/configure --cc=gcc --prefix="$PWD/../install-native" -q
make -j20 && make install
```

Product: `install-native/bin/tcc`, 381,600 B, 0 warnings.

**riscv64 build**:

```sh
../tinycc/configure --cross-prefix=riscv64-unknown-linux-musl- \
  --cpu=riscv64 --config-musl --prefix=... \
  --sysincludepaths='{B}/include:/opt/riscv/sysroot/include' \
  --libpaths='{B}:/opt/riscv/sysroot/lib:/opt/riscv/sysroot/usr/lib' \
  --crtprefix=/opt/riscv/sysroot/lib \
  --elfinterp=/lib/ld-musl-riscv64.so.1
make -j20 tcc
make -C lib TCC=work/riscv-tcc.sh XTCC=work/riscv-tcc.sh
```

Products: `install-riscv64/bin/tcc`, 481,528 B; `install-riscv64/lib/tcc/libtcc1.a`, 65,892 B.

Key point: `make` uses the freshly built tcc to generate `libtcc1.a` by default. Since there is no riscv binfmt, it must be run through `qemu-riscv64 -L /opt/riscv/sysroot`.

### 2.5 widcc

**Architecture**: the README explicitly states that it is for glibc 2.28+ on x86-64 Linux only, with no multi-architecture backends.

**Build**:

```sh
cd widcc
ln -s platform/linux-glibc-generic.c platform.c
make clean && make -j20 CC=gcc
```

Product: `widcc/widcc`, 219,768 B, x86-64 PIE; build with no warnings.

### 2.6 slimcc

**Architecture**: shares its origin with widcc; the README also targets x86-64 Linux, with no separate multi-architecture backend.

**Build**:

```sh
cd slimcc
ln -s platform/linux-glibc-generic.c platform.c
make clean && make -j20 CC=gcc
```

Product: `slimcc/slimcc`, 467,912 B; uses `-O3 -flto=auto` and links jemalloc; build with no errors and no warnings.

### 2.7 xcc

**Architecture**: the README explicitly supports x86-64, aarch64, riscv64, and wasm; this evaluation verified x86_64 and riscv64.

**Host build**:

```sh
rsync -a --exclude .git xcc/ build-native/
cd build-native && make -j20
```

Products: `xcc` 205,600 B, `cc1` 1,324,200 B, `cpp` 353,160 B, `as` 636,448 B, `ld` 343,376 B; `lib/libc.a` is built by xcc itself.

**Two riscv64 builds**:

- A riscv64 cross xcc that runs on the host: `make ARCHTYPE=riscv64 PLATFORM=posix -j20`, producing `build-riscv64-cross/xcc` (205,696 B), used to generate the riscv64 libc/crt0.
- A riscv64-hosted xcc: compile `exes` with riscv64 gcc, producing `.xcc.real` 169,824 B, `.cc1.real` 1,421,608 B, etc.; copy the libraries from the cross build.

Three compatibility issues were handled when building the riscv-hosted version:

1. add `-D_POSIX_C_SOURCE=200809L` so musl headers declare `getline`;
2. xcc originally assumed that the RISC-V toolchain "has no getline, only `__getline`", the opposite of musl; in the build copy the guard was changed to `__riscv && !__XCC && !__linux__`;
3. musl's `elf.h` lacks `EF_RISCV_RVC`, `EF_RISCV_FLOAT_ABI_DOUBLE`, and `SHT_RISCV_ATTRIBUTES`; these were supplied via compiler options.

In addition, xcc locates `cpp/cc1/as/ld` relative to the directory of `argv[0]`. The riscv version cannot execute these sub-tools directly, so a qemu wrapper was placed for each of the five executables, using `qemu-riscv64 -0` to pin the guest's `argv[0]` to the wrapper path so that xcc's path-prefix computation is correct.

### 2.8 Build comparison

| Compiler | Host build | riscv build | Extra build steps | Binary size (main driver) |
|---|---|---|---|---|
| cproc + QBE | success | native components + cross-compiler both succeed | build QBE separately | 50,624 B (+ QBE 669,384 B) |
| pcc | success (29 warnings) | builds, but backend unusable | supply pcc-libs runtime, 8 source patches | 36,784 B (ccom 470,304 B) |
| tcc | success (0 warnings) | success (usable) | qemu wrapper for libtcc1 | 381,600 B / 481,528 B |
| widcc | success (0 warnings) | unsupported | `platform.c` link | 219,768 B |
| slimcc | success (0 warnings) | unsupported | `platform.c` link | 467,912 B |
| xcc | success (0 warnings) | success (usable) | 3 compatibility fixes + qemu sub-tool wrappers | 205,600 B / 169,824 B |

> xcc's "host as/ld + glibc" is a usage-mode experiment, not another build of the compiler itself; it is not included in this table. See §4.5.

### 2.9 Toolchain and standard library quick reference

#### (1) Provided binary tools

| Compiler | Executables/libraries provided | Own as/ld? | Notes |
|---|---|---|---|
| cproc + QBE | `cproc` (driver), `cproc-qbe` (C front end), `qbe` (backend) | no | needs external `cpp`, `as`, `ld` at runtime; QBE only emits assembly |
| pcc | `pcc`, `pcpp`, `p++` (drivers), `ccom`, `cxxcom` (C/C++ compilers), `cpp` | no | uses host GNU `as`/`ld`; `pcc-libs` is not in this repository |
| tcc | a single `tcc` (preprocess+compile+assemble+link), `libtcc.a` (embeddable API), `libtcc1.a` (compiler runtime) | **yes** (built in) | ships `include/` (stddef/stdarg/float etc.); `-run` can JIT-execute directly |
| widcc | a single `widcc`, `widcc_headers/` | no | uses host GNU `as`/`ld` |
| slimcc | a single `slimcc`, `slimcc_headers/` | no | uses host GNU `as`/`ld` |
| xcc | `xcc` (driver), `cpp`, `cc1`, `as`, `ld`; `lib/crt0.a`, `lib/libc.a`, `include/` | **yes** (built in) | a complete self-contained toolchain; does not invoke host as/ld |

#### (2) Bundled standard library/headers

| Compiler | Complete C standard library? | libc actually used | Bundled headers/runtime |
|---|---|---|---|
| cproc + QBE | no | host glibc (or the target sysroot's musl) | no libc headers; depends on target system headers |
| pcc | no | host glibc | no full libc; `pcc-libs` provides `libpcc`/startup helpers (this run used an empty `libpcc.a`) |
| tcc | no | host glibc; the riscv build can be configured for `/opt/riscv/sysroot` musl | `include/` provides freestanding headers, `libtcc1.a` is the compiler runtime, not libc |
| widcc | no | host glibc | `widcc_headers/` (helper headers), no libc |
| slimcc | no | host glibc | `slimcc_headers/` (helper headers), no libc |
| xcc | no (incomplete mini libc) | by default xcc's own `lib/libc.a`, not host libc | bundled `include/` + `libc.a` + `crt0.a`; missing `regex.h`, `ferror`, etc. |

> Conclusion: only **xcc** is a closed toolchain with its own mini libc and as/ld. tcc has its own as/ld and runtime, but programs still link against the host/target libc. The other compilers depend on host GNU as/ld and the host libc. None of the projects ships a complete C standard library. xcc's "host as/ld + glibc" is only the experimental mode in §4.5, not its default toolchain.

### 2.10 Code size (LoC)

Counting method:

- count `.c`, `.h`, `.S`, `.s`, `.y`, `.l` files;
- exclude directories whose names start with `test` (`test/`, `tests/`, `*_test/` etc.), `examples/`, `doc/`, `.git`, `build*/`, `obj/`, `install*/`;
- "physical lines" are text lines (Python `splitlines()`; the only difference from `wc -l` is a file without a trailing newline, at most one line per file); "comment-stripped code lines" count non-empty lines after a simple regex removal of `/* ... */` and `// ...` (not exact cloc semantics, for cross-project comparison only);
- pcc counts the current workspace source (including the 8 riscv-experiment patches); cproc+qbe merges both repositories; tests, examples, docs, and third-party build products are excluded;
- counting script: [`work/count_loc.py`](work/count_loc.py).

| Project | Files | Physical lines (LoC) | Non-empty lines | Comment-stripped code lines | Main composition |
|---|---:|---:|---:|---:|---|
| **pcc** | 221 | **163,215** | 143,916 | 120,944 | `arch/` 85,873 (17 backends) + `cc/` 44,497 + `mip/` 11,987 + `f77/` 12,392 etc. |
| **tcc** | 166 | **114,480** | 103,562 | 96,420 | core `.c` 63,313 + `.h` 48,025; of which `win32/` headers are about 36,618 lines |
| **xcc** | 382 | **55,408** | 49,557 | 48,165 | `src/` 47,985 (cpp/cc1/as/ld/wcc) + `libsrc/` 5,814 (mini libc) + `include/` 1,609 |
| **cproc + QBE** | 69 | **27,818** | 25,602 | 24,345 | cproc 8,962 + QBE 18,856 (QBE includes `minic/` 2,635 and `tools/` 420) |
| ├ cproc | 26 | 8,962 | 8,262 | 8,011 | front end, driver, QBE IL generation |
| └ QBE | 43 | 18,856 | 17,340 | 16,334 | amd64/arm64/rv64 backends, parser, minic, tools |
| **slimcc** | 51 | **21,843** | 18,759 | 18,492 | compiler proper + `slimcc_headers/` + `platform/` |

Notes:

- pcc is the largest, mostly because `arch/` contains many historical backends; excluding `arch/`, it still has 77,342 physical lines.
- About 36,618 of tcc's 114,480 lines are Windows API headers under `win32/`; excluding them leaves about 77,862 lines.
- xcc's 55,408 lines include its own mini libc (`libsrc/`, 5,814 lines) and target headers (`include/`, 1,609 lines), part of its "bundled libc" approach.
- cproc + QBE's 27,818 lines are the two repositories combined; QBE's `minic/` is a small test C compiler and `tools/` are helper tools, so the QBE core alone is about 3,000 lines less.
- slimcc's 21,843 lines exclude `test/`; the sibling widcc is not included in this count.
- Sorted by physical lines: **pcc (163,215) > tcc (114,480) > xcc (55,408) > cproc+QBE (27,818) > slimcc (21,843)**.

## 3. Baseline I: c-testsuite Results and Per-test Errors

> **Key points**: tcc 220/220; slimcc 219/220; widcc 217/220; xcc 214/220 (host as/ld variant 213/220); cproc+QBE 211/220; pcc 207/220. Failures are mostly at compile time rather than wrong runtime output.

### 3.1 Summary table

| Compiler | PASS | COMPILE_ERROR | RUN_FAIL | OUTPUT_MISMATCH | Other | Total |
|---|---:|---:|---:|---:|---:|---:|
| tcc | 220 | 0 | 0 | 0 | 0 | 220 |
| slimcc | 219 | 0 | 0 | 1 | 0 | 220 |
| widcc | 217 | 1 | 1 (SIGSEGV) | 1 | 0 | 220 |
| xcc (x86_64) | 214 | 4 | 0 | 2 | 0 | 220 |
| xcc (host as/ld + glibc) | 213 | 4 | 0 | 3 | 0 | 220 |
| cproc + QBE | 211 | 9 | 0 | 0 | 0 | 220 |
| pcc | 207 | 8 | 4 | 1 | 0 | 220 |

### 3.2 cproc + QBE: 9 failures (all at compile/link time)

| # | Test | tags | Stage | Diagnostic/symptom | Root cause |
|---:|---|---|---|---|---|
| 1 | `00141` | portable c89 needs-cpp | QBE codegen | `slot %.1 is read but never stored to` | the test reads an uninitialized variable (UB); QBE's SSA verifier rejects it |
| 2 | `00144` | portable c89 | cproc compile | `assignment to pointer discards qualifiers` | discarding `const` is a constraint violation; cproc errors, GCC only warns |
| 3 | `00174` | portable c99 needs-libc needs-cpp | link | `undefined reference to 'sin'` | the driver does not link `-lm` by default; with `-lm` the output matches exactly |
| 4 | `00204` | portable c99 needs-libc needs-cpp | codegen | `long double is not yet supported` | cproc does not implement `long double` (size 16) |
| 5 | `00209` | portable c89 | cproc compile | `too many arguments for function call` | cproc follows C23 semantics: `()` means "no parameters" |
| 6 | `00210` | portable c89 needs-cpp | cproc compile | `GNU attribute 'packed' is not supported here` | GNU attribute at the end of a union definition/abstract declarator |
| 7 | `00213` | portable c89 | cproc compile | `expected primary expression` | GNU statement expressions `({ ... })` not implemented |
| 8 | `00214` | portable c89 | cproc compile | `expected primary expression` | same as above |
| 9 | `00216` | portable needs-libc needs-cpp | cproc compile | `no type in struct member declaration` | zero-member `struct {}` (GNU extension) not supported |

Classification: 4 known missing language features (`00204`, `00213`, `00214`, `00216`); 1 GNU attribute position (`00210`); 1 C23 semantic conflict (`00209`); 1 strict diagnostic (`00144`); 1 test relying on UB (`00141`); 1 missing `-lm` (`00174`).

> Conclusion: cproc has no runtime failures and no output mismatches; its 9 failures are not "compiled successfully but produced wrong results".

### 3.3 pcc: 13 failures

| # | Test | tags | Stage | Diagnostic/symptom | Root cause |
|---:|---|---|---|---|---|
| 1 | `00143` | portable c89 needs-cpp | compile | `invalid function definition` / `syntax error` | Duff's device: case labels nested inside do-while |
| 2 | `00162` | portable c99 needs-cpp | compile | `bad qualifier` | C99 array-parameter qualifiers `[const 5]`/`[static 5]`/`[restrict 5]` |
| 3 | `00174` | portable c99 needs-libc needs-cpp | link | `undefined reference to 'sin'` | driver does not link `-lm` by default; passes with `-lm` |
| 4 | `00200` | portable c89 needs-libc needs-cpp | run | `46 test(s) failed`, e.g. `((short)((1))) -4 4` | wrong type/sign of left-shift result: narrow signed types promoted then treated as unsigned |
| 5 | `00202` | portable c89 needs-libc needs-cpp | compile | `syntax error` | `##` with empty macro argument: wrong placemarker semantics |
| 6 | `00204` | portable c99 needs-libc needs-cpp | output | long double returns `0.0`; HFA varargs corrupted | long double return / HFA varargs ABI |
| 7 | `00206` | portable c89 needs-libc needs-cpp | run | prints `111/222/333/333/333`, exit code 12 | `#pragma push_macro/pop_macro` not implemented + implicit return from main not handled |
| 8 | `00210` | portable c89 needs-cpp | compile | `lvalue required` + ICE | GNU attribute in the abstract declarator `int(ATTR *)(void)` |
| 9 | `00211` | portable c99 needs-cpp | run | correct output `n+1 = 15`, exit code 9 | main without `return` does not return 0 per C99; returns printf's 9 |
| 10 | `00212` | portable c89 needs-libc needs-cpp | run | correct output `Ok`, exit code 3 | same as above; returns printf's 3 |
| 11 | `00213` | portable c89 | compile | `operands of : have incompatible types` | GNU statement expressions not implemented |
| 12 | `00216` | portable needs-libc needs-cpp | compile | `major internal compiler error` | empty struct + compound-literal global initializer (GNU extension) |
| 13 | `00219` | portable c89 needs-libc needs-cpp | compile | `duplicate type in _Generic` | `_Generic` qualifier removal for compatible types (`int`/`const int`) differs from GCC |

### 3.4 tcc: 0 failures

tcc's host build is **220/220**. It covers macros/preprocessing, initializers, bit-fields, floating point, variadics, TLS, `setjmp`, inline-assembly strings, compound literals, `_Generic`, `#pragma push_macro`, etc.; the tests that widcc fails (`00178`/`00206`/`00216`/`00219`) all pass under tcc.

### 3.5 widcc: 3 failures

| # | Test | Stage | Symptom | Root cause |
|---:|---|---|---|---|
| 1 | `00206` | output mismatch | expected `111,222,333,222,111`, got `111,222,333,333,333` | `#pragma push_macro/pop_macro` is dropped entirely |
| 2 | `00216` | runtime SIGSEGV | jumping to address 0 when calling a function pointer inside a global compound literal | `write_gvar_data()` does not handle `init->expr`; relocations in compound literals are lost |
| 3 | `00219` | compile error | `implicit declaration of a function` (`_Generic(...)`) | widcc's README explicitly removes `_Generic` (and other C11 features) |

Additional notes: `00216` was confirmed with a minimal reproducer to be a real code-generation bug, not a test problem; `00206` is a missing MSVC/GCC extension; `00219` is a standard feature removed by design.

### 3.6 slimcc: 1 failure

| # | Test | Stage | Symptom | Root cause |
|---:|---|---|---|---|
| 1 | `00206` | output mismatch | expected `111,222,333,222,111`, got `111,222,333,333,333` | same as widcc: `#pragma push_macro/pop_macro` not implemented |

Compared with widcc, slimcc fixes `00216` (global compound-literal relocations) and implements `_Generic` for `00219`.

### 3.7 xcc: 6 host failures + 1 extra riscv failure

| # | Test | tags | Stage | Diagnostic/symptom | Root cause |
|---:|---|---|---|---|---|
| 1 | `00162` | portable c99 needs-cpp | compile | `expression expected` / `cannot dereference raw type` | does not support the VLA `[*]` parameter form `int x[const *]` |
| 2 | `00178` | portable c89 needs-libc needs-cpp | output mismatch | `sizeof(!a)` prints 1, expected 4 | the result type of `!`/`==` is 1 byte, not the standard-mandated `int` |
| 3 | `00202` | portable c89 needs-libc needs-cpp | compile | `lvalue expected` (`60 ++ 3`) | token pasting produces `+ +`, but xcc emits no space and the lexer merges it into `++` |
| 4 | `00206` | portable c89 needs-libc needs-cpp | output mismatch | same `333/333` | `#pragma push_macro/pop_macro` not implemented |
| 5 | `00209` | portable c89 | compile | `')' expected` | does not support function-type parameters `int f2(int (int x), int)` |
| 6 | `00216` | portable needs-libc needs-cpp | compile | `']' expected` | does not support GNU range designators `[1 ... 5]` |
| +1 | `00204` | portable c99 needs-libc needs-cpp | riscv output mismatch | variadic struct/HFA data corrupted | wrong riscv64 variadic/HFA calling convention (passes on x86_64) |

Minimal reproducer for `00178`:

```c
char a = 0;
printf("%d %d\n", (int)sizeof(!a), (int)sizeof(a==1));
/* xcc: 1 1; gcc: 4 4 */
```

Minimal reproducer for `00202`:

```c
#define Q(A,B) A ## B+
jim = 60 Q(+,)3;   /* should be 60 + + 3 -> 63 */
/* xcc preprocesses this to 60 ++ 3 and reports lvalue expected; gcc outputs 63 */
```

> The host as/ld + glibc variant scored 213/220: the same 6 failures plus `00204` (glibc's long double/HFA ABI).

### 3.8 riscv64 results

#### cproc + QBE (Option B cross-compiler): 193 / 220

There are **27** failures, all COMPILE_ERROR, with no runtime failures and no output mismatches:

| Category | Count | Tests |
|---|---:|---|
| QBE rv64 backend `extern with offset` limitation | 18 | `00024`, `00047`, `00048`, `00049`, `00050`, `00090`, `00091`, `00092`, `00115`, `00146`, `00147`, `00148`, `00151`, `00163`, `00176`, `00195`, `00205`, `00217` |
| `long double` (triggered by musl headers) | 2 | `00174`, `00204` |
| failures shared with the host | 7 | `00141`, `00144`, `00209`, `00210`, `00213`, `00214`, `00216` |

Root cause: cproc HEAD emits a QBE `extern` marker for all externally linked globals, but the QBE rv64 backend does not support "external symbol + offset". A causal experiment that removed the `extern` markers returned **211/220**, exactly matching the host, proving that all 18 failures share this one interface problem.

#### pcc: 0 / 220

The riscv pcc binary starts but cannot generate riscv64 code that GNU as accepts:

| Category | Count | Symptom |
|---|---:|---|
| GNU as rejects pcc-generated assembly | 146 | `unrecognized opcode 'subi ...'`, `unrecognized opcode 'assign zero'`, `junk at end of line ... '4'` |
| pcc's own cpp crashes under qemu | 64 | `qemu: uncaught target signal 11 (Segmentation fault)` (tests with system headers) |
| front-end/codegen diagnostics | 10 | `Cannot generate code, node ... op OREG/SCONV/= `, plus similar errors in `00162`/`00210`/`00213` |

Root cause: the riscv backend assumes a fixed 32-bit type model and emits non-GNU assembly syntax, and its `cpp` crashes under qemu.

#### tcc: 220 / 220 (three variants)

| Method | Result | Notes |
|---|---|---|
| tcc compile (`-c`) + riscv gcc link | **220/220** | tests tcc's compile/codegen only; linking is left to GNU ld |
| tcc compile + static link with tcc-built musl | **220/220** | tcc's complete self-hosted environment |
| tcc links against the GCC-built musl in `/opt/riscv/sysroot` | **0/220** | all LINK_ERROR: `Unknown relocation type for got: 26/27/28` |

The third case is not a test failure: tcc's riscv64 linker does not support the absolute relocations (`R_RISCV_HI20`/`LO12_I`/`LO12_S`) that GCC emits; object files produced by tcc itself link fine.

#### xcc: 213 / 220

All 6 host failures also fail on riscv, plus one extra `00204`:

- The riscv `00204` output difference is concentrated in `va_arg` of structs/HFAs, for example:

```diff
 stdarg:
-ABCDEFGHI ABCDEFGHI ABCDEFGHI ABCDEFGHI ABCDEFGHI ABCDEFGHI
+ABCDEFGHI ABCDEFGHI ABCDEFGHI @ I2 I
```

This shows xcc's riscv64 variadic/HFA calling convention still has implementation defects.

#### riscv cross-comparison

| Compiler | PASS | Failure stage | Conclusion |
|---|---:|---|---|
| tcc | 220 | — (all link errors with pure tcc linking) | compiler usable; linker incompatible with GCC object files |
| xcc | 213 | 4 compile + 3 output mismatches | compiler basically usable; one extra riscv ABI bug |
| cproc + QBE | 193 | 27 compile errors | front/back end usable; QBE rv64 extern+offset gap |
| pcc | 0 | 146 assembly + 64 cpp crashes + 10 front end | riscv backend unfinished |

---

## 4. Baseline II: binutils 2.44 and toybox 0.8.15

> **Key points**: only tcc and slimcc fully build both binutils and toybox; widcc builds only toybox; xcc's host as/ld variant gets binutils configure to pass but still cannot complete the build.

### 4.1 Build criteria

Both packages were attempted only with **host x86_64** compilers; no riscv cross builds were done. binutils used a uniform configuration:

```sh
../work/binutils-2.44-src/configure \
  --disable-nls --disable-werror --disable-gdb --disable-sim \
  --disable-gprof --disable-gprofng --disable-gold --disable-shared \
  --build=x86_64-pc-linux-gnu --host=x86_64-pc-linux-gnu
CFLAGS=-O0 make -k -j4
```

toybox used the default `defconfig`:

```sh
make defconfig
make -j4 CC=<compiler>
```

Build directories are inside each compiler project (`<project>/binutils-2.44/`, `<project>/toybox-0.8.15/`; widcc/slimcc use a prefix).

### 4.2 binutils 2.44 results

| Compiler | configure | make | `.o` produced | objdump/as/ld | Failure cause |
|---|---|---|---|---|---|
| tcc | success | **0** | **282** (+102 `.lo`) | **all produced** | — |
| slimcc | success | **0** | **282** (+102 `.lo`) | **all produced** | — |
| widcc | success | 2 | 81 | not produced | glibc `sys/cdefs.h`'s `__glibc_const_generic` uses `_Generic`; widcc removed `_Generic`, so macros such as `strchr` fail to expand |
| pcc | success | 2 | 73 | not produced | bundled zlib's K&R definitions: `function doesn't match prototype`; also pcc's driver does not support `--print-prog-name` |
| cproc + QBE | success | 2 | 64 | not produced | bundled zlib's K&R definitions: `no type in parameter declaration` (C23 semantics) |
| xcc | **failure** | — | 0 | not produced | xcc's mini libc lacks `ferror`; configure's conftest cannot run: `cannot run C compiled programs` |
| xcc (host as/ld + glibc) | success | 2 | 2 | not produced | configure passes with glibc headers, but `libiberty/regex.c`'s `free` is undeclared and the `liblto_plugin.so` link probe fails |

Detailed errors:

- **tcc / slimcc (success)**: fully built `binutils/objdump`, `gas/as-new`, and `ld/ld-new`, all reporting `GNU Binutils 2.44`; `objdump -f /bin/ls` works, and their as/ld assembled, linked, and ran a bare assembly program that calls `exit(7)`. tcc products: objdump 3,546,394 B, as-new 2,918,178 B, ld-new 3,632,346 B; slimcc products: 3,553,456 / 2,782,896 / 3,496,904 B.
- **widcc (81 `.o`)**:

```text
/usr/include/x86_64-linux-gnu/sys/cdefs.h:837:
# define __glibc_const_generic(PTR, CTYPE, CALL) _Generic (...)
                                     ^ implicit declaration of a function
libiberty/argv.c:226 / vprintf-support.c:60 / simple-object-mach-o.c:1175
```

- **pcc (73 `.o`)**: configure repeatedly reports `error: unknown option '--print-prog-name'`; the build stops at bundled zlib:

```text
zlib/deflate.c, line 206: function doesn't match prototype
...cannot recover from earlier errors: goodbye!
```

- **cproc (64 `.o`)**: bundled zlib uses K&R definitions:

```c
uLong ZEXPORT adler32_z(adler, buf, len)
    uLong adler;
    const Bytef *buf;
    z_size_t len;
```

```text
zlib/adler32.c:63:17: error: no type in parameter declaration
```

15 errors of this kind in total.

- **xcc**: configure's conftest fails because `ferror` is undeclared (xcc's mini libc does not provide it), so `./conftest` is not produced.

### 4.3 toybox 0.8.15 results

| Compiler | defconfig | make | toybox | applets | Failure cause |
|---|---|---|---|---|---|
| tcc | success | **0** (after avoiding `--gc-sections`) | 734,840 B | **239** | first link: `unsupported linker option '--gc-sections'`; succeeds with `LDOPTIMIZE="-Wl,--as-needed"` |
| slimcc | success | **0** | 592,856 B | **239** | — |
| widcc | success | **0** | 2,502,008 B | **239** | — |
| cproc + QBE | success | 2 | not produced | 0 | toybox's build script probes `$CC --version`, `-xc -`, and `-E -`; cproc does not support `--version` and requires explicit `-x` for stdin |
| pcc | success | 2 | not produced | 0 | `lib/portability.h:234`'s `__has_include` is not supported by pcc's cpp (`junk after expression`) |
| xcc | success | 2 | not produced | 0 | missing `<regex.h>` (xcc's mini libc has no POSIX regex) |
| xcc (host as/ld + glibc) | success | 2 | not produced | 29 | GNU `a ? : b` in `lib/lib.c:23` is not supported by xcc |

Smoke tests on the successful products: all `toybox` builds list **239 applets** (same as the GCC baseline), and `echo`, `basename`, `wc -l`, `md5sum`, and `ls` work normally.

### 4.4 Interpretation

1. **binutils is the stronger discriminator**: it contains a large amount of real GNU code and bundled zlib. tcc and slimcc fully build it and produce usable objdump/as/ld; widcc is blocked by modern glibc's `_Generic` macro; pcc and cproc are blocked by zlib's K&R definitions; xcc's default mini libc cannot even get through configure (the host-glibc wrapper is covered in §4.5, and still does not complete the build).
2. **toybox depends more on build-script/driver compatibility**: tcc/slimcc/widcc build it; cproc fails at driver probing (not C itself); pcc fails on `__has_include`; xcc's default mini libc lacks headers (the host-glibc wrapper gets further; see §4.5).
3. **tcc's binutils success** is one of the most notable results: it not only passes c-testsuite and builds musl, but also fully builds binutils 2.44 (objdump/as/ld) and toybox.
4. **slimcc** also completes both packages; combined with the earlier "only `_Complex` missing" conclusion, slimcc is the closest to tcc in practical usefulness.
5. All results are **x86_64 host**; no riscv64 cross attempts were made for binutils/toybox.

### 4.5 Addendum: xcc + host GNU as/ld + host glibc

The xcc failures in §4.2/§4.3 use the default "bundled mini libc + bundled as/ld" path. To separate "missing libc interfaces" from "xcc compiler capability", a control experiment was run: xcc only preprocesses/compiles to assembly, host GNU `as` assembles, and host `gcc` (host ld + glibc) links.

- **Minimal validation**: `xcc -S` output is accepted by GNU as, and GNU ld/glibc links it into a working program; with `-I/usr/include -I/usr/include/x86_64-linux-gnu`, xcc can use glibc headers directly.
- **toybox**: `defconfig` succeeds; after supplying macros such as `__signed__`/`__BYTE_ORDER__` and replacing the `\e` escape, a parallel build produces **29 `.o`**; serial reproduction fails first at `lib/lib.c:23`, i.e. GNU's omitted-middle-operand ternary `a ? : b`. toybox is not produced.
- **binutils**: configure **passes** (compared with the immediate failure under the default mini libc), but `make` still fails: only 2 `.o` are produced; `libiberty/regex.c`'s `free` is parsed as undeclared (`cannot call except function`); some link probes report that `liblto_plugin.so` cannot be found. objdump/as/ld are not produced.
- **Verdict**: clear progress (configure passes, toybox parallel build reaches 29 objects), but the remaining blockers move to xcc language/driver capabilities (GNU header macros, `\e`, `?:`, glibc declaration compatibility, libtool link probes), so these two packages still cannot be built. Detailed logs are in `xcc/toybox-hostlibc-0.8.15/`, `xcc/binutils-hostlibc-2.44/`, and `xcc/binutils-hostlibc2-2.44/`.

---

## 5. Baseline III: musl 1.2.5 Build Attempts

> **Key points**: slimcc is only missing `_Complex`; tcc is next; pcc/widcc are around 50%; xcc/cproc are around 40% and both lack several infrastructure features.

### 5.1 Summary table

| Compiler | Denominator (report basis) | Success | Success rate | `libc.a` | `libc.so` | Primary blocker |
|---|---:|---:|---:|---|---|---|
| slimcc | 1352 ALL_OBJS | 1284 | **95.0%** | no | no | `_Complex` (68) |
| tcc (x86_64) | 2697 compile targets | 2525 | **93.6%** | no | no | `_Complex` in 68 sources + 17 x86_64 SSE/x87 asm + `sigsetjmp.s` |
| tcc (riscv64) | 1351 compile targets | 1281 | **94.8%** | no | no | `_Complex` 68 + `fenv.S`/`tlsdesc.s` |
| pcc | 1345 objects | 745 | **55.4%** | no | no | register-asm variables (534) |
| widcc | 1352 ALL_OBJS | 722 | **53.4%** | no | no | inline asm/register variables (557) |
| xcc (x86_64) | 2697 compile targets | 1117 | **41.4%** | no | no | `__builtin_va_list` (825) + extended asm (512) |
| xcc (riscv64) | 1351 compile targets | 566 | **41.9%** | no | no | same + `__attribute__` |
| cproc + QBE | 1345 objects | 526 | **39.1%** | no | no | inline asm (537) + `long double` (211) + `_Complex` (68) |
| xcc (host as/ld + glibc) | — | — | — | — | — | this mode was not tested for musl |

> Note: "success" above means an object file was compiled; unless stated otherwise, no complete usable `libc.a`/`libc.so` was produced. Denominator differences are explained in §1.3.
>
> As an environment control: the cproc and pcc reports first fully built musl 1.2.5 with GCC 16.2.0 (`libc.a`/`libc.so` complete; static and dynamic hello run), and the later tcc/slimcc experiments also confirmed that the same tarball produces a usable libc. The failures below are therefore not caused by the tarball or environment.

### 5.2 cproc + QBE: 526 / 1345 (39.1%)

- configure succeeds.
- The default `make` fails at the first step on `-fPIC`: `cproc: unknown option '-fPIC'`, and cproc explicitly does not support PIC, so it cannot build a shared `libc.so`.
- Building only the static library (`make -k -j1 lib/libc.a`): of 1345 objects, **526 succeed and 819 fail**; `libc.a` is not produced.

Failure attribution:

| Root cause | Count | Typical diagnostic |
|---|---:|---|
| inline assembly unsupported | **537** | `arch/x86_64/syscall_arch.h:6:2: error: inline assembly is not yet supported` |
| `long double` unsupported | **211** | `cproc-qbe: long double is not yet supported` |
| `_Complex` unsupported | **68** | `include/complex.h:16:8: error: _Complex is not yet supported` |
| `volatile` store unsupported | 1 | `src/thread/sem_init.c:10:23: error: volatile store is not yet supported` |
| GNU `packed` attribute position | 1 | `include/sys/epoll.h:53:27: error: GNU attribute 'packed' is not supported here` |
| C23 function-pointer semantics | 1 | `src/legacy/ftw.c:7:33: error: base types of pointer assignment must be compatible or void` |
| **Total** | **819** | |

Additional note: 534 of the 537 inline-asm failures are only indirectly included through `syscall_arch.h`/`atomic_arch.h`; 143 of the 211 `long double` failures come from unreferenced `static inline long double` helpers in headers that cproc still generates code for. In other words, **implementing inline asm + dropping unreferenced static inlines + long double** would unlock most objects.

### 5.3 pcc: 745 / 1345 (55.4%)

- configure succeeds; the default `make` ICEs on the very first object `obj/src/aio/aio.o`:

```c
register long r10 __asm__("r10") = a4;   /* syscall_arch.h:37 */
/* pcc: major internal compiler error */
```

- Full `make -k -j1` statistics: of 1345 objects, **745 succeed and 600 fail**; neither `libc.a` nor `libc.so` is produced.

Failure attribution:

| Root cause | Count | Typical diagnostic |
|---|---:|---|
| `register ... __asm__("reg")` register-variable ICE | **534** | `arch/x86_64/syscall_arch.h, line 37: major internal compiler error` |
| complex type handling | **60** | `src/complex/__cexp.c:72: operands of CAST/=` have incompatible types` |
| complex `long double` struct assignment | **5** | `assignment of different structures` (`ccoshl.c`, `cexpl.c`, etc.) |
| unsupported xasm option | **1** | `src/math/x86_64/remquol.c:32: unsupported xasm option string 'X'` |
| **Total** | **600** | |

A single feature, register-asm locals, blocks 534/600 failed objects (89%).

### 5.4 tcc: 93.6% on x86_64, 94.8% on riscv64

#### x86_64 (unmodified musl, fails)

- configure succeeds; `make -k -j1 AR=ar RANLIB=ranlib LIBCC=`.
- **Of 2697 compile targets (`.o` + `.lo`), 172 fail and 2525 succeed (93.6%)**; 86 unique source files fail; `libc.a`/`libc.so` are not produced.

| Root cause | Unique sources | Typical location/error |
|---|---:|---|
| `_Complex` | **68** | `include/complex.h:16: _Complex is not yet supported` |
| x86_64 SSE constraints `x`/`t`/`X` | **16** | `src/math/x86_64/fabs.c:6: unknown constraint 'x'` etc. |
| x87 clobber `st` | **2** | `src/math/x86_64/llrintl.c`/`lrintl.c`: `invalid clobber register 'st'` |
| `@PLT` assembly suffix | **1** | `src/signal/x86_64/sigsetjmp.s:14` |
| `expl.s` assembly syntax | **1** | `src/math/x86_64/expl.s:40` |

#### riscv64 (unmodified musl, fails)

- With `--disable-shared`: **of 1351 targets, 70 fail and 1281 succeed (94.8%)**; 70 unique sources fail.
- Failure composition: 68 `src/complex/*` + `fenv.S` (the `fscsr t1` pseudo-instruction) + `tlsdesc.s` (the `add sp,sp,-16` pseudo-instruction); `src/math/riscv64/*`'s `"f"` constraint compiles normally.

#### Results after minimal changes (experimental, explicitly labelled)

| Architecture | Changes | `libc.a` | Runtime validation |
|---|---|---|---|
| x86_64 | remove `src/complex`, remove `src/math/x86_64` (fall back to generic C math), remove `@PLT` from `sigsetjmp.s` | 2,653,670 B / 1277 members | static hello links with tcc; c-testsuite **220/220** |
| riscv64 | remove `src/complex` (and optionally `src/math/riscv64`), `fscsr`→`csrw`, `sll`→`slli`, `add sp,sp,±16`→`addi` | 2,996,466 B / 1278 members | hello runs under qemu; c-testsuite **220/220** |

> This is musl "with complex removed", not the complete musl. It does show that, apart from `_Complex` and a little assembly, tcc already has what it takes to build and use musl.

### 5.5 widcc: 722 / 1352 (53.4%)

- configure succeeds (requires `--target=x86_64-linux-musl`, `AR=ar RANLIB=ranlib`, `CFLAGS=-O0`).
- `make -k -j1`: **of 1352 targets, 722 succeed and 630 fail**; `libc.a`/`libc.so` are not produced.

| Root cause | Failed objects | Typical diagnostic |
|---|---:|---|
| GNU inline asm + explicit register variables (syscall wrappers) | **528** | `register long r10 __asm__("r10") = a4;` → `expected ','` |
| `_Complex` | **68** | `include/complex.h:16: expected ','` |
| vDSO/atomic inline asm with operands | **12** | `arch/x86_64/atomic_arch.h:56` |
| file-scope `__asm__` (CRT/ldso) | **4** | `arch/x86_64/crt_arch.h:1: variable name omitted` |
| x86_64 math inline asm | **16** | `src/math/x86_64/*.c: GNU inline assembly not implemented` |
| `explicit_bzero` memory barrier | **1** | `src/string/explicit_bzero.c:7` |
| `offsetof` is not a compile-time constant | **1** | `include/stddef.h:24` (`strptime.c` case label) |
| **Total** | **630** | |

### 5.6 slimcc: 1284 / 1352 (95.0%)

- configure succeeds; `make -k -j1`: **1284 succeed and 68 fail**; all 68 failures are `_Complex` in `src/complex/*`.
- The other 1284 objects—including syscall/atomic inline asm, `register ... __asm__`, file-scope asm, x86_64 math inline asm, and `offsetof` constant folding—all compile.
- Removing `src/complex` gives a complete build:

```text
lib/libc.a  2,673,522 B
lib/libc.so 1,110,496 B
```

Static/dynamic hello and a combined malloc/qsort/sqrt/strptime/pthread/setjmp test all run. **slimcc is missing only `_Complex`.**

### 5.7 xcc: 41.4% (x86_64) / 41.9% (riscv64)

- Original musl fails at configure:

```text
checking whether compiler's long double definition matches float.h... no
../musl-src/configure: error: unsupported long double type
```

xcc's `sizeof(long double) == 8`, while musl requires x86_64 to be 80-bit (16-byte storage) and riscv64 to be 128-bit (16-byte storage).

- The report ran an experiment that bypassed the long-double check (explicitly labelled experimental):

| Architecture | Compile targets | Successful objects | Success rate | `libc.a` |
|---|---:|---:|---:|---|
| x86_64 | 2697 | 1117 (558 `.o` + 559 `.lo`) | 41.4% | not produced |
| riscv64 | 1351 | 566 | 41.9% | not produced |

First-diagnostic distribution on x86_64 (about 1580 failed targets):

| First diagnostic location | Targets | Notes |
|---|---:|---|
| `obj/include/bits/alltypes.h:326` | **825** | `typedef __builtin_va_list va_list;`: xcc does not understand GCC's `__builtin_va_list` |
| `arch/x86_64/syscall_arch.h:7` | **512** | inline asm with operands `__asm__ __volatile__("syscall" : ...)` |
| `include/complex.h` | **136** | `_Complex` |
| `arch/x86_64/atomic_arch.h` | **24** | atomic inline asm |
| x86_64 `.s` files | 47 + 22 | `unknown directive` / `line end expected` |
| `#pragma STDC FENV_ACCESS` | 1 | not handled |

The riscv64 errors are essentially the same, plus `__attribute__((aligned(16)))` in riscv headers not being parsed.

### 5.8 musl gap matrix

| Feature | cproc | pcc | tcc | widcc | slimcc | xcc |
|---|---|---|---|---|---|---|
| GNU extended inline asm (with operands) | ✗ | partial (xasm) | ✓ | ✗ | ✓ | ✗ |
| `register T x __asm__("reg")` | ✗ | ✗ | ✓ | ✗ | ✓ | ✗ |
| file-scope `asm` | ✗ | partial | ✓ | ✗ | ✓ | ✗ |
| `_Complex` | ✗ | partial (many failures) | ✗ | ✗ | ✗ | ✗ |
| `long double` | ✗ | partial (ABI issues) | ✓ | ✓ | ✓ | ✗ (8 bytes) |
| `volatile` stores | partial (reads only) | ✓ | ✓ | ✓ | ✓ | ✓ |
| PIC / shared libc | ✗ (no `-fPIC`) | not tested | partial (native `libc.so` fails) | not tested | ✓ | not tested |
| GCC `__builtin_va_list` | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ |
| GNU `__attribute__` | partial (positions) | partial | ✓ | ✓ | ✓ | ✗ |
| C23 `()` = no parameters | yes (deliberate) | no | no | no | no | no |
| `#pragma push_macro/pop_macro` | ✓ | ✗ | ✓ | ✗ | ✗ | ✗ |

Notes:

- tcc's `long double` passes musl's configure check; the x86_64 musl build fails mainly because of `_Complex`/SSE assembly, not `long double`; the same applies to riscv64.
- pcc's basic `long double` type works, but the return/HFA ABI for `00204` is still wrong.
- cproc implements only `volatile` reads; `volatile` stores are not implemented.
- "partial" means only some syntax/positions are covered and cannot pass all musl code that uses the feature.

### 5.9 What counts as "building musl successfully with X"

This document only calls a build successful if:

1. a complete `libc.a` (or `libc.so`) is produced;
2. a real program can be linked against that libc and run;
3. the test suite is run against that libc as far as possible.

By this standard:

| Compiler | Unmodified musl | After minimal source changes |
|---|---|---|
| slimcc | failure (only `_Complex`) | **success** (remove `src/complex`; static/dynamic/multithreaded all verified) |
| tcc | failure | **success** (remove complex/arch math + small assembly patches; x86_64/riscv64 both verified) |
| others | failure | — |

---

## 6. Mutual Builds: Four Compilers Building Each Other

> **Key points**: among the 12 cross combinations, tcc, slimcc, and cproc can mostly build each other; xcc as a source compiler is limited by its mini libc and a front-end bug and can build only tcc/cproc; cproc cannot build tcc/xcc because it lacks `long double`; QBE cannot be built by xcc because xcc does not support function-type parameters.
>
> Complete commands, logs, and per-combination products are in [`pairwise/pairwise-build-report.md`](pairwise/pairwise-build-report.md).

### 6.1 Goal and criteria

- Scope: x86_64 only; host and target are both x86_64 Linux/glibc.
- Four compilers: **tcc**, **slimcc**, **xcc**, **cproc + QBE**.
- 12 cross combinations: each target compiler is built by the other three; self-builds are not counted and serve only as controls.
- `cproc-qbe/{cproc,qbe}` is treated as one pair: the target side requires both `cproc` and `qbe` to be produced by the same source compiler.
- For xcc, as requested, first try "bundled `cpp/cc1/as/ld` + mini libc"; if that fails, fall back to "system as/ld + glibc + system headers".
- Verification levels:
  1. the product exists and `--version` works;
  2. it compiles and runs hello and a stress program;
  3. stage2 self-build (tcc/slimcc/cproc) or gen2/gen3 (xcc) where possible;
  4. compare against the native compiler with a uniform c-testsuite runner.

Source compilers (native, built by gcc):

| Compiler | Native path | Version/commit |
|---|---|---|
| tcc | `tcc/install-native/bin/tcc` | 0.9.28rc, `2be0218b` |
| slimcc | `widcc-slimcc/slimcc/slimcc` | `2388c39` |
| xcc | `xcc/build-native/xcc` | 0.1.13, `83c51319` |
| cproc + QBE | `cproc-qbe/cproc/cproc` + `cproc-qbe/qbe/qbe` | cproc `d1c53dd` / QBE `180d2eb` |

### 6.2 Matrix of the 12 combinations

Legend: ✅ direct success; ⚠️ success after falling back to system tools/libraries; ⚠️* partial success; ❌ failure; — self-build (not counted).

| Target \ Source | tcc | slimcc | xcc | cproc |
|---|---|---|---|---|
| **tcc** | — (self-build control) | ✅ | ⚠️→✅ | ❌ |
| **slimcc** | ✅ | — | ❌ | ✅ (bootstrap options) |
| **xcc** | ✅ | ✅ | — | ❌ |
| **cproc + QBE** | ✅ | ✅ | ⚠️* (cproc ok / QBE fail) | — |

Counts (by target/source):

- direct successes: **7** (tcc←slimcc, slimcc←tcc, slimcc←cproc, xcc←tcc, xcc←slimcc, cproc+QBE←tcc, cproc+QBE←slimcc)
- success after fallback: **1** (tcc←xcc)
- partial success: **1** (cproc+QBE←xcc: cproc succeeds, QBE fails)
- failures: **3** (tcc←cproc, slimcc←xcc, xcc←cproc)

That is **9/12 successful or partially successful, 3/12 failed**.

### 6.3 Per-combination results

#### 6.3.1 tcc ← slimcc: ✅

- Out-of-tree `configure --cc=<slimcc>` + `make` + `make install` succeeds on the first try.
- The product `install/bin/tcc` compiles/runs hello and stress correctly.
- stage2: rebuilding tcc with that tcc succeeds, and the resulting tcc also compiles hello.
- c-testsuite: **220/220**, same as native tcc.

#### 6.3.2 tcc ← xcc: ⚠️ bundled tools fail → system tools succeed

1. Native xcc (bundled toolchain + mini libc) fails with `Cannot open file: <sys/time.h>`.
2. Fallback: build an xcc variant with gcc that uses system as/ld (`-DUSE_SYS_AS -DUSE_SYS_LD`, called `xcc-sys`), and give xcc:
   - system header paths: `-I/usr/include -I/usr/include/x86_64-linux-gnu`;
   - GCC predefined type macros: `__SIZE_TYPE__`, `__PTRDIFF_TYPE__`, `__WCHAR_TYPE__`, `__WINT_TYPE__`, `__INTMAX_TYPE__`, `__UINTMAX_TYPE__`;
   - `-Wl,-no-pie` when linking (xcc emits non-PIC objects, and glibc defaults to PIE).
3. Result: build succeeds; hello/stress correct; stage2 succeeds; c-testsuite **220/220**.
4. The product is dynamically linked against glibc and unstripped, 600,496 B (native 381,600 B).

#### 6.3.3 tcc ← cproc: ❌

```
cproc-qbe: long double is not yet supported
```

Triggered in `tccgen.c`. tcc's source uses `long double` extensively, and cproc/QBE fatals on 16-byte `long double`; no compiler option bypasses it.

#### 6.3.4 slimcc ← tcc: ✅

- Build succeeds; hello/stress correct; stage2 succeeds.
- c-testsuite: **219/220**, the only failure is `00206`, exactly matching native slimcc.

#### 6.3.5 slimcc ← xcc: ❌

1. Native xcc fails with `Cannot open file: <glob.h>`.
2. After falling back to `xcc-sys` + system headers, cc1 aborts while compiling `parse.c` and `type.c`:

```
cc1: src/cc/frontend/initializer.c:200: reserve_init_for_multi:
     Assertion `sinfo != NULL' failed.
```

3. Conclusion: xcc's front end hits an internal assertion on some aggregate initialization in slimcc's source; changing libc/toolchain does not help.

#### 6.3.6 slimcc ← cproc: ✅ (requires two explicit build options)

1. slimcc's README specifies that cproc needs:
   ```
   -DBOOTSTRAP_NO_LDOUBLE -U__has_builtin
   ```
2. cproc's driver uses `cpp -undef` but does not supply the GCC type macros that glibc needs; a wrapper must add:
   ```
   -D__SIZE_TYPE__=unsigned long  -D__PTRDIFF_TYPE__=long
   -D__WCHAR_TYPE__=int  -D__WINT_TYPE__=unsigned int
   -D__INTMAX_TYPE__=long int  -D__UINTMAX_TYPE__=long unsigned int
   ```
   Otherwise glibc's `glob.h` reports `declaration has no type specifier`.
3. Result: build succeeds; hello/stress correct; stage2 succeeds.
4. c-testsuite: **218/220**. It fails one more test than native slimcc: `00204` (HFA/`long double` struct varargs); this is a known cost of `BOOTSTRAP_NO_LDOUBLE` turning the internal `long_double_t` into `double`, not cproc miscompiling slimcc.

#### 6.3.7 xcc ← tcc: ✅

- `make exes` succeeds on the first try, producing `xcc/cpp/cc1/as/ld`.
- The resulting `./xcc` uses its bundled ld + mini libc to produce a static hello that runs correctly.
- Self-build: `make gen2` and `make gen3` both succeed; the five gen2/gen3 programs have byte-identical `.text/.rodata/.data`, and the raw binaries differ only in symbol/string-table ordering (cc1 8 B, cpp/ld 30 B, xcc 60 B, as identical).
- c-testsuite: **214/220**, with the same failure set as native xcc: `00162`, `00178`, `00202`, `00206`, `00209`, `00216`.

#### 6.3.8 xcc ← slimcc: ✅

- Same as 6.3.7: succeeds on the first try; gen2/gen3 succeed.
- c-testsuite: **214/220**, same failure set as native xcc.

#### 6.3.9 xcc ← cproc: ❌

- Failure: `cproc-qbe: long double is not yet supported`, triggered in `src/cc/frontend/initializer.c` and `expr.c`.
- xcc's source uses `long double`; cproc cannot compile it.

#### 6.3.10 cproc + QBE ← tcc: ✅

- QBE builds successfully and produces correct assembly for valid `.ssa` input.
- Both `cproc` and `cproc-qbe` build successfully; the configuration points at the QBE built by the same tcc.
- hello/stress correct; stage2 succeeds; the stage2 product also compiles hello.
- c-testsuite: **212/220**, with the same failure set as native cproc (`00141`, `00144`, `00204`, `00209`, `00210`, `00213`, `00214`, `00216`).

#### 6.3.11 cproc + QBE ← slimcc: ✅

- QBE, cproc, and cproc-qbe all build successfully; hello/stress correct; stage2 succeeds.
- c-testsuite: **212/220**, same failure set as native cproc.

#### 6.3.12 cproc + QBE ← xcc: ⚠️ partial success

1. Native xcc (bundled tools/libraries) fails to build the cproc driver:
   - `Cannot open file: <spawn.h>`;
   - `freopen`/`ferror` undeclared;
   - `uint_least32_t` undefined (the mini libc's `stdint.h` is incomplete).
2. After falling back to `xcc-sys`:
   - **The cproc driver and cproc-qbe proper build successfully**; hello/stress correct; stage2 succeeds; c-testsuite **212/220**, exactly matching native cproc.
   - **QBE still fails**, and it is not a libc issue:
     ```
     all.h(539): `)' expected
     void parse(FILE *, char *, void (char *), void (Dat *), void (Fn *));
     ```
     xcc does not support **function-type parameters without parameter names**. Native xcc also lacks `<getopt.h>` and the `PRIi64` macro from `inttypes.h`; even with system headers, the function-type parameter issue remains.
3. Conclusion: xcc can build the cproc compiler proper but cannot build QBE; the "cproc + QBE" pair is only half done.

### 6.4 Fidelity checks

#### 6.4.1 Stress program

Every successful product compiles a stress program covering structs/unions/bit-fields/variadic functions/function pointers/long integers/floating point/strings, and its output matches the gcc baseline byte for byte:

| Product | stress |
|---|---|
| tcc ← slimcc | ✅ |
| tcc ← xcc (fallback) | ✅ |
| slimcc ← tcc | ✅ |
| slimcc ← cproc | ✅ |
| xcc ← tcc | ✅ |
| xcc ← slimcc | ✅ |
| cproc ← tcc | ✅ |
| cproc ← slimcc | ✅ |
| cproc ← xcc (fallback) | ✅ |

#### 6.4.2 stage2 / self-build

| Product | Self-build result |
|---|---|
| tcc ← slimcc | rebuilds tcc successfully |
| tcc ← xcc (fallback) | rebuilds tcc successfully |
| slimcc ← tcc | `slimcc-stage2` succeeds |
| slimcc ← cproc | `slimcc-stage2` succeeds |
| xcc ← tcc | `gen2` and `gen3` succeed; code sections byte-identical |
| xcc ← slimcc | `gen2` and `gen3` succeed; code sections byte-identical |
| cproc ← tcc | `make stage2` succeeds |
| cproc ← slimcc | `make stage2` succeeds |
| cproc ← xcc (fallback) | `make stage2` succeeds |

#### 6.4.3 c-testsuite comparison with native compilers

Uniform runner and options; xcc omits `-lm` (its libc already contains math functions), the others use `-std=c11 -lm`.

| Compiler | Build source | PASS/total | Compared with native |
|---|---|---:|---|
| tcc native | gcc | 220/220 | — |
| tcc | slimcc | 220/220 | identical |
| tcc | xcc (fallback) | 220/220 | identical |
| slimcc native | gcc | 219/220 (`00206`) | — |
| slimcc | tcc | 219/220 (`00206`) | identical |
| slimcc | cproc (bootstrap) | 218/220 (`00204`,`00206`) | one extra `00204`, due to `BOOTSTRAP_NO_LDOUBLE` |
| xcc native | gcc | 214/220 | — |
| xcc | tcc | 214/220 | failure set identical |
| xcc | slimcc | 214/220 | failure set identical |
| cproc native | gcc | 212/220 | — |
| cproc | tcc | 212/220 | failure set identical |
| cproc | slimcc | 212/220 | failure set identical |
| cproc | xcc (fallback) | 212/220 | failure set identical |

> Note: this section's runner adds `-lm`, so cproc passes `00174` and scores 212 instead of the 211 baseline in §0.1/§3; xcc does not use `-lm`.

### 6.5 Key compatibility issues

1. **tcc / slimcc have the best mutual compatibility**: they build each other, and both can build xcc and cproc.
2. **cproc's `long double` gap** directly blocks tcc ← cproc and xcc ← cproc.
3. **cproc's external-cpp configuration gap**: `cpp -undef` plus missing GCC type macros prevents glibc headers from being preprocessed; a wrapper can add the macros, or musl headers can be used.
4. **xcc's mini libc is incomplete**: missing `sys/time.h`, `glob.h`, `spawn.h`, `getopt.h`, `locale.h`, `uint_least32_t`, `PRIi64`, etc.; as a source compiler it usually needs a fallback to system as/ld + glibc.
5. **xcc front-end bugs**: cc1 asserts at `initializer.c:200` when compiling slimcc; xcc does not support unnamed function-type parameters when compiling QBE.
6. **xcc linking constraint**: it emits non-PIC objects, so linking with glibc requires `-Wl,-no-pie`.

### 6.6 Summary

| Dimension | Conclusion |
|---|---|
| As a build target | tcc, slimcc, xcc, and cproc can each be built by at least two of the others; xcc is the easiest target (both tcc and slimcc succeed) |
| As a source compiler | tcc and slimcc are the most reliable; cproc is limited by `long double`; xcc is limited by its mini libc and front-end bugs |
| Build fidelity | except for the `BOOTSTRAP_NO_LDOUBLE` semantic difference in slimcc ← cproc, successful products' c-testsuite results match native exactly |
| Biggest obstacles | cproc lacks `long double` (2 of the 3 failures); xcc front-end bugs (1 failure + 1 partial success) |

## 7. Application Build: EDG C++ Front End 5.1

> **Key points**: tcc and slimcc fully build EDG 5.1 (front end + C++ runtime + C/C++17/exception smoke tests); xcc segfaults because of a front-end type-completion bug; cproc fails because it does not support `long double`.
>
> Complete logs, products, and minimal reproducers are in [`edg5.1-try/edg5.1-build-report.md`](edg5.1-try/edg5.1-build-report.md).

### 7.1 Input and reference flow

- Input: `edgcpp-compiler-5.1.tar.gz` (263 files; 63 C sources in the front end, 51 `.c` files in the C++ runtime).
- Reference script: `edgcpp-try/refhost-edg5.1.sh`.
- The EDG 5.1 front end is **plain C** (`-std=gnu89` style, relying on `-fcommon` tentative-definition merging); the C++ runtime is first translated to C by edgcpfe and then compiled by the C compiler.
- Flow:
  1. compile and run `util/mk_errinfo.c` to generate `src/err_codes.h` and `src/err_data.h`;
  2. compile the 63 front-end sources with `-std=gnu89 -fcommon` and link `edgcpfe`;
  3. check `--version`;
  4. translate a C program, compile the generated C, run it;
  5. use edgcpfe to translate the 51 `lib_src/*.c` (C++) files to C, compile them with the same C compiler, and `ar` them into `libC.a`;
  6. translate a C++17 program and an exception program, link against `libC.a`, and run them.
- Adaptation: when EDG translates C++, glibc's `bits/floatn.h` triggers `__float128`/`__attribute__((__mode__))` (the gcc baseline fails there too), so EDG's `--sys_include` points at the musl rootfs `/usr/include`; compiling the generated C still uses each compiler's default glibc.

### 7.2 Summary

| Compiler | Front end edgcpfe (63 C sources) | C++ runtime libC.a (51 C++→C) | C / C++17 / exception smoke tests | Verdict |
|---|---|---|---|---|
| **tcc** | ✅ 63/63 | ✅ 51/51 | ✅ all pass | **complete success** |
| **slimcc** | ✅ 63/63 | ✅ 51/51 | ✅ all pass | **complete success** |
| **xcc** | ❌ cc1 SIGSEGV | — | — | failure: front-end type-completion bug |
| **cproc** | ❌ no `long double` | — | — | failure: missing language feature |

### 7.3 tcc: complete success

- All 63 front-end sources compile, producing `build/edgcpfe` at 7,306,668 B; `--version` reports `version 5.1`.
- All 51 runtime sources are translated and compiled; `lib/libC.a` is 156,168 B with 51 objects.
- The C smoke test, C++17 smoke test, and C++ exception smoke test all pass.
- The build log contains no errors/warnings (using `-w`).

### 7.4 slimcc: complete success

- All 63 front-end sources compile, producing `build/edgcpfe` at 6,700,256 B; the version check passes.
- All 51 runtime sources are translated and compiled; `lib/libC.a` is 123,826 B with 51 objects.
- The C/C++17/exception smoke tests all pass.
- The only noise is a `_BSD_SOURCE and _SVID_SOURCE are deprecated` `#warning` from glibc headers (EDG's `defines_linux.h` defines `_BSD_SOURCE`); it does not affect the build.

### 7.5 xcc: failure (front-end cc1 SIGSEGV)

#### 7.5.1 First attempt: xcc's bundled tools/libraries

```
Cannot open file: <locale.h>
FATAL: mk_errinfo compile
```

xcc's mini libc headers do not include `locale.h`, so even `util/mk_errinfo.c` cannot be compiled. EDG's front end also uses `sys/time.h`, `sys/resource.h`, etc., none of which are in xcc's mini libc.

#### 7.5.2 Second attempt: fall back to system tools/libraries

Using an xcc variant with system as/ld/glibc (`-DUSE_SYS_AS -DUSE_SYS_LD`), plus system header paths, GCC type macros, and `-D_DEFAULT_SOURCE` to avoid glibc's `#warning`:

- `mk_errinfo` compiles and runs successfully;
- while compiling the front end, cc1 **segfaults at `src/class_decl.c`**.

Compiling files one by one confirms that `attribute.c`, `cfe.c`, and `c_gen_be.c` are fine, while `class_decl.c` crashes.

#### 7.5.3 Locating the crash

Debugging xcc's `cc1` with gdb (preprocess with `xcc -E`, then feed the result to `cc1 -O2 -fcommon -`):

```
Program received signal SIGSEGV
0x... in gen_assign_sub (lhs=..., rhs=...)
    at src/cc/backend/codegen_expr.c:859
859     if (lhs->type->struct_.info->size > 0) {
(gdb) p lhs->type->kind
$1 = TY_STRUCT
(gdb) p lhs->type->struct_.info
$2 = (StructInfo *) 0x0
(gdb) p lhs->token->line->lineno
$3 = 29032
(gdb) x/s lhs->token->line->filename
$4 = "src/class_decl.c"
```

The corresponding source line, `src/class_decl.c:29032`:

```c
if (decl_pos_block_ptr != NULL) {
  *decl_pos_block_ptr = decl_info.decl_pos_block;
}
```

`decl_pos_block_ptr` has type `a_decl_pos_block_ptr`, and `src/il.h` declares them in this order:

```c
typedef struct a_decl_pos_block *a_decl_pos_block_ptr;
typedef struct a_decl_pos_block {
  ...
} a_decl_pos_block;
```

That is, **a pointer typedef to an incomplete struct is declared first, and the struct itself is defined later by another typedef**. xcc's front end does not associate the later complete definition with the earlier pointer typedef, so `a_decl_pos_block_ptr` always points to an incomplete struct and its `StructInfo` is NULL; the backend dereferences NULL when doing a struct assignment.

#### 7.5.4 Minimal reproducer

The following valid C (gcc compiles and runs it) makes xcc segfault:

```c
typedef struct S *S_ptr;
typedef struct S { int x; } S;
int main(void) {
  S a, b;
  S_ptr p = &a;
  *p = b;           /* struct assignment through pointer typedef */
  return 0;
}
```

| Variant | gcc | xcc |
|---|---|---|
| the full case above | ok | **SIGSEGV (139)** |
| remove `*p = b;`, keep `p->x = 1` | ok | ok |
| direct `a = b;` (no pointer typedef) | ok | ok |
| `struct S; typedef struct S *S_ptr; struct S { int x; };` | ok | **SIGSEGV** |
| put `typedef struct S *S_ptr;` after the struct definition | ok | ok |

Trigger condition: **a pointer typedef to an incomplete struct appears first, the complete struct definition appears later, and a struct assignment is performed through that pointer**.

#### 7.5.5 Not an isolated EDG case

`il.h` is only the first hit; several EDG 5.1 headers use the same pattern, for example `src/error.h`:

```c
typedef struct a_diag_list *a_diag_list_ptr;
typedef struct a_diag_list {
  ...
} a_diag_list;
```

In a temporary copy, reordering the typedefs in `il.h` and supplying xcc's missing `LDBL_*` macros (xcc's own `float.h` lacks `LDBL_DIG`/`LDBL_MANT_DIG` etc.) let xcc continue to the 35th file, `src/interpret.c`, where it segfaulted again at the same `gen_assign_sub`, on this source line:

```
src/interpret.c:15413:  *diag_list = ips.diag_list;
```

and `diag_list`'s type `a_diag_list_ptr` comes from the same `error.h` pattern. In other words, **this xcc front-end defect recurs throughout EDG** and cannot be worked around by fixing one header.

### 7.6 cproc: failure (no `long double`)

#### 7.6.1 First attempt: default cproc configuration + glibc

cproc's driver rejects `-w` and `-fcommon`, so `-O2 -std=gnu89` is used. It fails on the very first source:

```
../../src/lexical.h:1872:13: error: undeclared identifier: __SCHAR_MAX__
cproc: compile: process 86 exited with status 1
```

Cause: cproc invokes the external `cpp` with `-undef`, and its `config.h` provides only a few GCC predefined macros; `__SCHAR_MAX__`, `__SIZE_TYPE__`, `__restrict`, etc. are missing, but glibc headers need them.

#### 7.6.2 Second attempt: musl headers + gcc preprocessing

cproc supports preprocessed `.i` input (`CPPOUT`). Using gcc as the external preprocessor with musl headers and GNU attributes stripped:

```sh
gcc -E -nostdinc -isystem <musl>/usr/include -isystem <gcc-include> \
    -std=gnu89 -D_DEFAULT_SOURCE -U__GNUC__ '-D__attribute__(x)=' \
    -D__extension__= -D__inline=inline -D__inline__=inline -I src src/X.c -o X.i
cproc -c X.i -o X.o
```

The header layer no longer errors, and cproc successfully compiles the first 22 files (`attribute.c` through `floating.c`); it fails on the 23rd file, `src/float_pt.c`:

```
cproc-qbe: long double is not yet supported
cproc: compile: process 210 exited with status 1
FATAL: cproc compile src/float_pt.c
```

#### 7.6.3 Root cause

- `src/float_pt.c` alone contains **86 occurrences** of `long double`; `c_gen_be.c`, `decl_spec.c`, `expr.c`, `fixed_pt.c`, `folding.c`, `il_to_str.c`, `lexical.c`, `literals.c`, `lower_c99.c`, `lower_name.c`, `overload.c`, `symbol_tbl.c`, `basics.h`, `floating.h`, and `float_pt.h` also use it.
- In the Linux x86_64 EDG configuration, `USE_LONG_DOUBLE_FOR_HOST_FP_VALUE=1`; the host floating-point value uses 80-bit `long double`, and the target `TARG_SIZEOF_LONG_DOUBLE=16`.
- cproc/QBE's `qbe.c:206` directly calls `fatal("long double is not yet supported")` for 16-byte `long double`.
- Trying `-DUSE_LONG_DOUBLE_FOR_HOST_FP_VALUE=0` triggers EDG's configuration consistency checks:
  ```
  #error -- TARG_SIZEOF_DOUBLE must equal TARG_SIZEOF_LONG_DOUBLE when
            LONG_DOUBLE_AS_DOUBLE_IN_GENERATED_C is TRUE
  ```
  The target `long double` would also have to become 8 bytes (like the Windows configuration), which changes the target ABI and is no longer "building the original EDG configuration with cproc".

### 7.7 Failure-cause comparison

| Compiler | Failure stage | Direct error | Root-cause type |
|---|---|---|---|
| **xcc** | front end, `src/class_decl.c` | cc1 SIGSEGV, `gen_assign_sub` dereferences NULL `StructInfo` | xcc front-end bug: pointer typedef to an incomplete struct is not completed by the later struct definition |
| **cproc** | front end, `src/float_pt.c` | `cproc-qbe: long double is not yet supported` | cproc/QBE language gap: 16-byte `long double` not implemented |
| cproc (earlier layer) | front end, `attribute.c` | `__SCHAR_MAX__` undefined | cproc's external cpp uses `-undef` without the GCC predefined macros glibc needs |
| xcc (earlier layer) | `mk_errinfo` | `Cannot open file: <locale.h>` | xcc's mini libc header set is incomplete |
| xcc (after fallback, earlier layer) | glibc `features.h` | `#warning` treated as an unknown directive by xcc | xcc's preprocessor does not understand glibc's `#warning`; `-D_DEFAULT_SOURCE` avoids it |

### 7.8 Summary

- **tcc and slimcc** handle EDG's K&R-style definitions, `-fcommon` tentative definitions, GNU-extension header usage, and EDG-generated C; both fully build the front end, the runtime, and the smoke tests.
- **xcc**'s failure is a front-end/backend implementation bug (incomplete-struct pointer typedef) and is unrelated to EDG's code portability.
- **cproc**'s failure is the missing `long double` language feature; the external-cpp predefined-macro configuration is an earlier, bypassable problem, but even after bypassing it the build still stops at `float_pt.c`.

## 8. Conclusions and Recommendations

> **Key points**: tcc is closest to "can be tested, can self-host, can build real projects"; slimcc is the easiest to complete; xcc/pcc/cproc each have structural gaps.

### 8.1 Overall ranking

1. **tcc**: the only perfect c-testsuite score; also perfect on riscv64; musl only misses complex and a little assembly. Its only notable limitation is that the riscv64 linker cannot consume GCC object files.
2. **slimcc**: 219/220; the only musl gap is `_Complex`, after which it is fully usable. The best candidate for "add one feature and build musl completely".
3. **widcc**: 217/220, but musl is only 53.4%; it lacks inline assembly, register variables, file-scope asm, `_Generic`, etc., and is far from musl.
4. **xcc**: 214/220 (riscv 213/220); high engineering completeness, but lacks GCC `va_list`, extended asm, `_Complex`, `__attribute__`, and 16-byte `long double`; musl is about 41%.
5. **cproc + QBE**: 211/220; c-testsuite failures are all missing features, not miscompiles; the riscv cross result is 193/220, and the extra failures were localized to QBE rv64's extern+offset limitation. musl is 39.1%, missing inline asm, long double, complex, etc.
6. **pcc**: 207/220, usable on the host; the riscv backend is unfinished; musl is 55.4%, with register-asm variables the single largest blocker.

### 8.2 Highest-priority fixes per compiler

| Compiler | Highest-priority fix | Expected benefit |
|---|---|---|
| tcc | `_Complex`; riscv64 linker relocations `R_RISCV_HI20/LO12_I/LO12_S` | complete musl; can link GCC object files directly |
| slimcc | `_Complex` | immediately gains complete musl build capability |
| widcc | inline assembly with operands + register variables + file-scope asm | unlocks 544/630 failed musl objects at once |
| xcc | **type completion for pointer typedefs to incomplete structs**; GCC-compatible `__builtin_va_list` + extended inline asm + `_Complex`; mini-libc `locale.h`/`glob.h`/`spawn.h` etc. | unlocks slimcc/EDG 5.1; raises musl from 41% to a discussable range |
| cproc | **`long double`**; inline asm + `_Complex`; GCC predefined macros for the external cpp; QBE rv64 extern+offset | unlocks EDG 5.1 and tcc/xcc mutual builds; raises musl objects above 95% |
| pcc | register-asm locals; `_Complex`/long double struct assignment | unlocks 534/600 failed musl objects |

> xcc's "pointer typedef before struct definition" is the newly discovered high-value fix: it should unlock slimcc (currently a cc1 assertion) and may give xcc the foundation to build EDG 5.1 (EDG's `il.h`, `error.h`, and several other headers use this pattern).

### 8.3 "Non-defect" failures worth noting

- cproc `00141`: the test itself reads an uninitialized variable (UB); cproc/QBE's rejection is not a standards violation.
- cproc `00144`: discarding `const` is a constraint violation; cproc errors while GCC only warns—a diagnostic-strictness difference.
- cproc `00174` / pcc `00174`: the driver does not link `-lm` by default; adding `-lm` makes them pass.
- cproc `00209`: cproc deliberately adopts C23 `()` semantics, which conflicts with a c89 test.
- cproc `00216` / xcc `00216` / pcc `00216` / widcc `00216`: all involve GNU extensions or empty struct/compound literals, which are not required by ISO C (though c-testsuite marks them portable).

### 8.4 Mutual builds and EDG 5.1

Putting "can it build others" and "can it build a real application" together gives this compatibility profile:

| Compiler | As a build target | As a source compiler | Builds EDG 5.1 | Main limitation |
|---|---|---|---|---|
| **tcc** | easy for slimcc/xcc to build | most reliable; builds slimcc/xcc/cproc | ✅ complete success | `long double` works; no new structural gap found |
| **slimcc** | easy for tcc/cproc to build | builds tcc/xcc/cproc | ✅ complete success | needs cproc's `BOOTSTRAP_NO_LDOUBLE`; `_Complex` is still the musl gap |
| **xcc** | easy for tcc/slimcc to build | only builds tcc/cproc (with system-library fallback) | ❌ | incomplete mini-libc headers; incomplete-struct pointer typedef bug; no `long double` |
| **cproc + QBE** | easy for tcc/slimcc to build | builds slimcc (and itself); cannot build tcc/xcc | ❌ | no `long double`, inline asm, or `_Complex`; external cpp predefined macros incomplete |

A few facts worth highlighting:

1. **tcc and slimcc have the best two-way compatibility**: they build each other, both build xcc and cproc, and both fully build EDG 5.1. tcc succeeds in all three of its source-compiler combinations (building slimcc/xcc/cproc+QBE).
2. **cproc's missing `long double` has the widest impact**: it blocks tcc ← cproc, xcc ← cproc, and EDG 5.1 at once; it is also responsible for 211 failed musl objects.
3. **xcc's "self-contained ecosystem" is a double-edged sword**: as a target it is easy to build (its source is compatible), but as a source compiler it is limited by mini-libc header gaps and front-end bugs; its c-testsuite 214/220 matches native, showing that the built xcc itself is reliable.
4. **EDG 5.1 is a heavier C-code compatibility test than c-testsuite**: it contains 63 gnu89/K&R-style sources, `-fcommon` tentative definitions, heavy host `long double`, and 51 C files generated by EDG itself. tcc/slimcc pass all of it; xcc/cproc are stopped by a front-end bug and `long double`, respectively.

### 8.5 Overall assessment

- If the goal is "a C compiler that passes all of c-testsuite and can self-host musl", **tcc** is currently the closest; **slimcc** is only one `_Complex` away and requires the least work.
- If the goal is "multi-architecture and cross-compilation", **cproc + QBE** has the clearest architecture (front end + multiple backends), but the QBE rv64 / cproc HEAD `extern` interface issue must be fixed; **xcc** also has a complete multi-architecture design, but more language-feature gaps than cproc.
- **pcc** is the oldest project with the most backends, but its riscv backend in this repository is unfinished; its host amd64 result is still solid (207/220), and musl 55.4% shows that register-asm support is the most valuable next step.
- **widcc** is a "stripped-down slimcc" with a high c-testsuite pass rate, but its musl failures concentrate on infrastructure such as inline assembly and register variables, making the fix cost clearly higher than slimcc's single `_Complex`.
- All six compilers were compared against **the same 220 tests, the same musl 1.2.5, and the same GCC 16.2.0 environment**, so the cross-comparison is fairly consistent; the one caveat is that the reports use different denominators for musl object counts (see §1.3).

## 9. Artifacts, Logs, and Reproduction

| Project | Report | Main results/logs |
|---|---|---|
| cproc + QBE | [cproc-report-1.md](cproc-qbe/cproc-report-1.md), [cproc-report-2.md](cproc-qbe/cproc-report-2.md) | `cproc-qbe/.ctest-work/results.tsv`, `riscv-build/ctest/results.tsv`, `musl-build/build-cproc/` |
| pcc | [pcc-testsuite.md](pcc/pcc-testsuite.md) | `pcc/ctest-work/host-final/results.tsv`, `pcc/ctest-work/se-root/report.tap`, `pcc/musl-work/` |
| tcc | [tcc-testsuite.md](tcc/tcc-testsuite.md) | `tcc/ctest-work/*.tap`, `tcc/musl-build-*/`, `tcc/musl-build-*/analysis.txt` |
| widcc | [widcc-testsuite.md](widcc-slimcc/widcc-testsuite.md) | `widcc-slimcc/ctest-work/widcc.tap`, `widcc-slimcc/musl-build/analysis.txt` |
| slimcc | [slimcc-testsuite.md](widcc-slimcc/slimcc-testsuite.md) | `widcc-slimcc/ctest-work/slimcc.tap`, `widcc-slimcc/musl-build-slimcc/analysis.txt` |
| xcc | [xcc-testsuite.md](xcc/xcc-testsuite.md) | `xcc/ctest-work/*.tap`, `xcc/musl-build-*/analysis.txt` |
| Additional packages | appendices in each compiler report; cproc in [cproc-report-3.md](cproc-qbe/cproc-report-3.md) | `*/binutils-2.44/build.log`, `*/toybox-0.8.15/build.log` |
| xcc host-toolchain experiment | §9 of [xcc-testsuite.md](xcc/xcc-testsuite.md) | `xcc/toybox-hostlibc-0.8.15/build*.log`, `xcc/binutils-hostlibc*-2.44/build.log` |
| Mutual builds | [pairwise/pairwise-build-report.md](pairwise/pairwise-build-report.md) | `pairwise/builds/*`, `pairwise/logs/*`, `pairwise/xcc-sys/`, `pairwise/wrappers/` |
| EDG 5.1 | [edg5.1-try/edg5.1-build-report.md](edg5.1-try/edg5.1-build-report.md) | `edg5.1-try/builds/*`, `edg5.1-try/repro/` |

### 9.1 Baseline reproduction entry points

```sh
# cproc host
(cd cproc-qbe/qbe && make -j20)
(cd cproc-qbe/cproc && ./configure --with-qbe="$PWD/../qbe/qbe" && make -j20)

# pcc host
(cd pcc && mkdir -p build-host && cd build-host && ../pcc/configure --prefix="$PWD/../install-host" && make -j20 && make install)

# tcc host
(cd tcc/build-native && ../tinycc/configure --cc=gcc --prefix="$PWD/../install-native" -q && make -j20 && make install)

# widcc / slimcc
(cd widcc-slimcc/widcc && ln -sfn platform/linux-glibc-generic.c platform.c && make -j20)
(cd widcc-slimcc/slimcc && ln -sfn platform/linux-glibc-generic.c platform.c && make -j20)

# xcc host
(cd xcc/build-native && make -j20)

# c-testsuite (tcc as an example)
cd c-testsuite
./single-exec ../../../tcc/ctest-work/runners/tcc-native > ../tcc/ctest-work/tcc-native.tap
```

### 9.2 Artifacts for the new experiments

| Project | Report | Main results/logs |
|---|---|---|
| Mutual builds | [pairwise/pairwise-build-report.md](pairwise/pairwise-build-report.md) | `pairwise/builds/*`, `pairwise/logs/*`, `pairwise/xcc-sys/`, `pairwise/wrappers/` |
| EDG 5.1 | [edg5.1-try/edg5.1-build-report.md](edg5.1-try/edg5.1-build-report.md) | `edg5.1-try/builds/*`, `edg5.1-try/repro/` |

### 9.3 Reproduction entry points for the new experiments

```sh
# Four-compiler mutual builds: tcc <- slimcc as an example
cd pairwise/builds/tcc-by-slimcc
../../src/tcc/configure --cc=.../widcc-slimcc/slimcc/slimcc \
  --prefix=$PWD/install --extra-cflags="-O2"
make -j8 && make install

# xcc fallback to system as/ld + glibc
cd pairwise/builds/tcc-by-xcc-sys
../../src/tcc/configure --cc=.../pairwise/wrappers/xcc-sys \
  --prefix=$PWD/install --extra-cflags="-O2"
make -j8 && make install

# EDG 5.1: tcc full pipeline (front end + runtime + smoke tests)
cd edg5.1-try
NAME=tcc CC=.../tcc/build-native/tcc \
  CFLAGS="-O2 -w -std=gnu89 -fcommon" ./run-edg5.1.sh

# EDG 5.1: cproc + musl preprocessing (to analyse the long double blocker)
cd edg5.1-try
./run-edg5.1-cproc-musl.sh
```

---
