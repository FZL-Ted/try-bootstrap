# EDG bootstrap: EDG 5.1 to EDG 7.0 with a C-only GCC 4.6 toolchain

- Date: 2026-11-02 (CST)
- Workspace: `/home/tedm/CS/my-proj/my-bootstrap/personal-bootstrap/bootstrap-box/edgcpp-try`
- Source checkout: `edgcpp-compiler/` (`7.0-105-gee3b38ed5d`)
- Toolchain: C-only GCC 4.6.4 + musl in `compiler-test/ref-rootfs-gcc4.6-c-only`
- Build root: `./build/`
- Scripts:
  - [build-edg-5.1-by-gcc-4.6-c-only.sh](build-edg-5.1-by-gcc-4.6-c-only.sh)
  - [build-edgcpp-by-edg-5.1.sh](build-edgcpp-by-edg-5.1.sh)
  - [build-edgcpp-stage2.sh](build-edgcpp-stage2.sh)

This document replaces the three earlier stage reports. It covers the whole
chain: EDG 5.1 built by a C-only GCC 4.6, EDG 7.0 built by that EDG 5.1, and
a second EDG 7.0 built by EDG 7.0 itself, plus the test results.

## 1. Build chain

```
C-only GCC 4.6.4 + musl
        |
        |  build-edg-5.1-by-gcc-4.6-c-only.sh
        v
EDG 5.1 (edgcpfe + 5.1 runtime libC.a)
        |
        |  build-edgcpp-by-edg-5.1.sh
        v
EDG 7.0 stage 1 (edgcpfe + 7.0 runtime libC.a)
        |
        |  build-edgcpp-stage2.sh
        v
EDG 7.0 stage 2 (edgcpfe built by stage 1)
        |
        +-- smoke tests and the project's edgy test suites
```

EDG's front end translates C++ to C. The generated C is then compiled by the
C-only GCC 4.6.4 toolchain. No C++ compiler, CMake, Ninja, host g++, or
network access is required.

## 2. Build directory layout

All build output is under `./build/`, one directory per stage:

```
build/
  edg5.1-gcc4.6c/
    edg-5.1/                 extracted EDG 5.1 source tree
      build/edgcpfe          EDG 5.1 front end
      lib/libC.a             EDG 5.1 runtime library
    build.log                EDG 5.1 build log

  edg7.0-edg5.1/
    edgcpfe                  EDG 7.0 front end (stage 1)
    lib/libC.a               EDG 7.0 runtime library
    base/                    EDG_BASE for the 7.0 front end
    includes/                cmake_defines.h, err_codes.h, err_data.h
    gen/ obj/ rt/            generated C, objects, runtime objects
    tests/                   smoke tests
    log/                     per-translation and per-test logs
    sources.txt              the 75 cpfe source names
    build-info.txt           versions, sizes, flags, timings

  edg7.0-stage2/
    edgcpfe                  EDG 7.0 front end (stage 2)
    gen/ obj/                generated C and objects
    tests/                   stage-2 smoke tests
    test-base/               local EDG_BASE used by the test driver
    test-runs/               stage-1 and stage-2 edgy run outputs
    stage2-summary.txt       versions, sizes, suite result table
    log/
```

The input directories `edgcpp-compiler/`, `compiler-test/`, and
`build/edg5.1-gcc4.6c/edg-5.1/` are read-only during these builds.

## 3. Prerequisite: EDG 5.1 with C-only GCC 4.6

EDG 5.1 is the last EDG release whose front end source is plain C; release 6.0
and later require a C++ compiler for the front end. EDG 5.1 also supports
C++17, which is enough to compile the C++14 source of EDG 7.0.

Inputs:

- `edg-compiler-5.1.tar.gz` (GitHub archive of tag 5.1)
- `predefined_macros.txt` (predefined-macro table used by the front end)
- C-only GCC 4.6.4 + musl reference rootfs

Build:

```bash
./build-edg-5.1-by-gcc-4.6-c-only.sh
```

The script extracts the tarball to `build/edg5.1-gcc4.6c/edg-5.1`, builds
`mk_errinfo`, generates the error tables, compiles all 63 front-end C sources
with GCC 4.6, links `edgcpfe`, then translates the 51 C++ runtime sources in
`lib_src/` with the new front end and archives `lib/libC.a`.

Results:

| Item | Result |
| --- | --- |
| Front-end sources | 63 C files, 0 errors |
| Front end | `edgcpfe` 4,936,304 B, static musl ELF |
| Runtime sources | 51 C++ files translated by EDG 5.1 and compiled by GCC 4.6 |
| Runtime library | `libC.a` 132,810 B, 51 objects |
| Smoke tests | C, C++17, and exception programs run successfully |

The 5.1 front end emits cfront-ABI C. This is intentional: the 5.1 runtime
library matches that ABI.

## 4. Stage 1: EDG 7.0 built by EDG 5.1

Inputs:

- `build/edg5.1-gcc4.6c/edg-5.1/build/edgcpfe` and `lib/libC.a` from stage 1
- `edgcpp-compiler/` at commit `7.0-105-gee3b38ed5d`
- `predefined_macros.txt`

Build:

```bash
./build-edgcpp-by-edg-5.1.sh
```

The script does not run CMake. It:

1. Generates `cmake_defines.h` from
   `cmake/macro-conf/linux-gcc/base.cmakedef` with `dev_tools/bin/edg-cmakedef`.
2. Extracts the cpfe source list from `src/CMakeLists.txt` (75 files).
3. Builds `mk_errinfo` and generates `err_codes.h` and `err_data.h`.
4. Translates and compiles each of the 75 sources with EDG 5.1 and GCC 4.6.
5. Links `edgcpfe` against the EDG 5.1 runtime library.
6. Builds the EDG 7.0 runtime library from `lib_src/` with the new 7.0 front end.
7. Runs C++17 and exception smoke tests with the 7.0 front end and 7.0 runtime.

Key flags for the 75 front-end sources:

```text
--c++14 --g++ --gnu_version=50000
--no_exceptions --no_rtti
--edg_base_dir=<5.1 base>
-DUSE_CMAKE_DEFINES -D__CHAR_BIT__=8
-DUSE_FLOAT128_FOR_HOST_FP_VALUE=0
-DUSE_QUADMATH_LIBRARY=0
-DFLOAT128_ENABLING_POSSIBLE=0
-I<generated includes> -I<checkout>/src
--sys_include=<5.1 include_c++>
--sys_include=<musl include>
--sys_include=<gcc 4.6 builtin include>
-tused
```

Important configuration points:

- EDG 5.1 does not support `__float128` in host code. The three floating-point
  macros must be overridden, or `targ_def.h` stops with an `#error`. The
  resulting front end therefore does not enable target `__float128` or
  `_Float128` support.
- EDG 5.1 has no prelinker in this pipeline. `-tused` makes every translation
  unit instantiate the templates it uses, so identical strong definitions can
  appear more than once. The final link uses
  `-Wl,--allow-multiple-definition`; all translation units are compiled with
  identical flags.
- The EDG 7.0 Linux configuration sets `IA64_ABI=1`. The front end therefore
  emits Itanium-ABI code and needs the EDG 7.0 runtime library, not the 5.1
  runtime library.

Results:

| Item | Result |
| --- | --- |
| Front-end sources | 75 files, 75 translated and compiled |
| Generated C | 208,491,784 B |
| Front end | `edgcpfe` 24,274,288 B |
| `--version` | `Edison Design Group C/C++ Front End, version 7.0 ...` |
| Runtime library | `libC.a` 181,034 B, 51 objects |
| Smoke tests | C++17 (virtual functions, templates, lambda, range-for, `if constexpr`) and exceptions pass |
| Build time | about 236 s (sequential, `-O2`) |

## 5. Stage 2: EDG 7.0 built by EDG 7.0

Build:

```bash
./build-edgcpp-stage2.sh
```

Stage 2 uses the stage-1 7.0 front end to translate the same 75 sources. The
generated Itanium-ABI objects are compiled with GCC 4.6 and linked against the
EDG 7.0 runtime library. No `--allow-multiple-definition` is needed: the 7.0
Itanium-ABI backend emits weak definitions for template and inline code.

| Item | Result |
| --- | --- |
| Front-end sources | 75 of 75 translated and compiled |
| Stage-2 front end | `edgcpfe` 26,698,472 B |
| `--version` | `Edison Design Group C/C++ Front End, version 7.0 ...` |
| Link | plain link (no `--allow-multiple-definition`) |
| Runtime | EDG 7.0 `libC.a` (181,034 B) |
| Smoke tests | C++17 and exception tests pass |
| Full stage-2 script | 398 s (build, smoke tests, and two test rounds) |

The stage-2 binary is larger than the stage-1 binary because it is
Itanium-ABI code linked against the 7.0 runtime.

## 6. Tests

The project test framework (`edgy`) runs the front end through
`util/eccp.sh`. The stage-2 script installs a local `EDG_BASE` with an
`edg_eccp_config` that points at:

- the C-only GCC 4.6.4 compiler;
- the EDG 7.0 runtime library;
- the checkout's 7.0 `include_c++` headers.

The local test configuration also uses:

- `EDG_STD_LIBS=""`: the EDG C++ standard library (`libstd`) is not built;
- a no-op `edg_prelink`: the driver adds `-tused` for single-file compile and
  link tests, so no cross-translation-unit instantiation is needed;
- `EDG_SUPPRESS_PATCH_MUNCH=1`: Itanium `.init_array` initialization does not
  need the cfront `patch`/`munch` step;
- `PYTHONDONTWRITEBYTECODE=1`: no `__pycache__` is written into the source tree.

The script runs the same suites twice, once with the stage-1 front end
(control) and once with stage 2, and compares the sorted lists of executed
tests and output differences.

| Suite | Stage-2 executed | Stage-2 diffs | Stage-1 executed | Stage-1 diffs | Identical |
| --- | ---: | ---: | ---: | ---: | :---: |
| `regressions` | 51 | 2 | 51 | 2 | yes |
| `changes` | 1430 | 13 | 1430 | 13 | yes |
| `cwg` | 737 | 12 | 737 | 12 | yes |
| `edg` | 3002 | 399 | 3002 | 399 | yes |
| `modules` | 46 | 3 | 46 | 3 | yes |
| `stdlib` | 20 | 47 | 20 | 47 | yes |
| `reflections` | 1 | 1 | 1 | 1 | yes |
| **Total** | **5287** | **477** | **5287** | **477** | **yes** |

The 477 differences are differences against the recorded expectations in
`tests/expectations/edg_x86_64/`, not differences between stage 1 and stage 2.
They are present with both front ends and are caused by the build configuration
and local test environment:

- `__float128`/`_Float128` target support is disabled (EDG 5.1 limitation);
- reflection and Microsoft extension tests are not enabled by the
  `linux-gcc` macro configuration used here;
- the EDG C++ standard library (`libstd`) is not built, so `stdlib` tests and
  tests that use `std::` facilities are incomplete;
- a few tests differ in source positions or checking pragmas.

The `edg` suite has 399 differences in both runs; their sets are identical, but
the log order differs because `edgy` writes results in completion order. The
script compares sorted lists.

`edgy` returns exit code 5 when these known differences are present. The
stage-2 script therefore uses "stage 1 and stage 2 produced identical results"
as the test criterion, not exit code 0.

The 40,230-test `imported` suite is not run by default. Use
`TEST_SUITES=all` to include it (this takes substantially longer).

## 7. Reproduction

Full chain:

```bash
./build-edg-5.1-by-gcc-4.6-c-only.sh
./build-edgcpp-by-edg-5.1.sh
./build-edgcpp-stage2.sh
```

Useful environment variables:

| Variable | Script | Default | Meaning |
| --- | --- | --- | --- |
| `REF` | all | `compiler-test/ref-rootfs-gcc4.6-c-only` | C-only GCC 4.6.4 + musl rootfs |
| `PREDEF` | 5.1, 7.0 | `predefined_macros.txt` | predefined-macro table |
| `WORK` | 7.0 | `build/edg7.0-edg5.1` | stage-1 build directory |
| `WORK` | stage 2 | `build/edg7.0-stage2` | stage-2 build directory |
| `EDG51` / `EDG51_BASE` | 7.0 | `build/edg5.1-gcc4.6c/edg-5.1/...` | stage-1 translator |
| `STAGE1_DIR` | stage 2 | `build/edg7.0-edg5.1` | stage-1 build directory |
| `OPT` | 7.0, stage 2 | `-O2` | GCC optimization for generated C |
| `TEST_SUITES` | stage 2 | seven suites listed above | `all` includes `imported` |
| `TEST_COMPARE` | stage 2 | `1` | run the stage-1 control and compare |
| `TEST_TIMEOUT` | stage 2 | `120` | per-test timeout, seconds |
| `EDGY_TIMEOUT` | stage 2 | `1800` | per-suite timeout, seconds |

Build only, without the test rounds:

```bash
TEST_SUITES="" ./build-edgcpp-stage2.sh
```

## 8. Artifacts and checks

- EDG 5.1 front end: `build/edg5.1-gcc4.6c/edg-5.1/build/edgcpfe`
- EDG 5.1 runtime: `build/edg5.1-gcc4.6c/edg-5.1/lib/libC.a`
- Stage-1 front end: `build/edg7.0-edg5.1/edgcpfe`
- Stage-1 runtime: `build/edg7.0-edg5.1/lib/libC.a`
- Stage-2 front end: `build/edg7.0-stage2/edgcpfe`
- Stage-2 test summary: `build/edg7.0-stage2/stage2-summary.txt`

The scripts check that:

- `edgcpp-compiler/` has the same `git status` before and after a build;
- the reference rootfs has no files newer than the build start;
- all build output stays under `build/`;
- the produced front ends report the expected versions.

## 9. Limitations

- `__float128`/`_Float128` target support is disabled because EDG 5.1 cannot
  compile host `__float128`. Supporting it would need a different transitional
  front end or the SoftFloat configuration.
- The `linux-gcc` macro configuration used here does not enable reflection or
  Microsoft extensions. Other presets exist in the checkout but were not used.
- The EDG C++ standard library (`libstd`) is not built, so some `stdlib` and
  `std::`-using tests are incomplete.
- The test setup is local to this workspace. It does not use Docker or
  `edg-docker-test`.
- The 40,230-test `imported` suite is not part of the default test run.
- A third-stage fixed-point comparison was not performed; stage 2 already
  recompiles the full front end and matches stage 1 on the core test suites.

## 10. Script and document map

| Path | Purpose |
| --- | --- |
| `build-edg-5.1-by-gcc-4.6-c-only.sh` | Build EDG 5.1 and its runtime with C-only GCC 4.6 |
| `build-edgcpp-by-edg-5.1.sh` | Build EDG 7.0 (stage 1) and its runtime with EDG 5.1 |
| `build-edgcpp-stage2.sh` | Build EDG 7.0 (stage 2) with stage 1 and run the tests |
| `build/edg5.1-gcc4.6c/` | EDG 5.1 build output |
| `build/edg7.0-edg5.1/` | EDG 7.0 stage-1 build output |
| `build/edg7.0-stage2/` | EDG 7.0 stage-2 build and test output |
