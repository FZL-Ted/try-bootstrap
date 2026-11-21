# base-pnut: building pnut and TCC with Onramp

This directory verifies the self-bootstrapped [Onramp](../base-onramp/onramp)
C toolchain by building, in order:

1. `pnut-exe`, the native-code backend of [pnut](https://github.com/udem-dlteam/pnut);
2. TCC 0.9.27 (the copy shipped inside pnut's `kit/`);
3. tinycc commit `fc1fc50f` (version 0.9.28rc), the checkout at `./tinycc`
   (a symlink to `../tcc/tinycc`).

There are three scripts:

| Script | Purpose |
|---|---|
| `onramp-to-pnut-exe.sh` | Compile `pnut.c` with Onramp, verify native ELF output and the pnut fixed point |
| `onramp-pnut-tcc-0.9.27.sh` | Use the pnut from step 1 to build TCC 0.9.27 from `pnut/kit/tcc-0.9.27.tar.gz`, verify `hello` and TCC self-compilation |
| `onramp-pnut-tcc-fc1fc50f-20261120.sh` | Use the pnut from step 1 to build tinycc `fc1fc50f` (0.9.28rc) from `./tinycc`; requires the patches in `patches/` |

## Which script should I use?

- **Only want pnut?** Run `./onramp-to-pnut-exe.sh`.
- **Want the TCC version bundled with pnut?** Run
  `./onramp-to-pnut-exe.sh` once, then `./onramp-pnut-tcc-0.9.27.sh`.
- **Want the newer tinycc (0.9.28rc, "tinycc (lnk)")?** Run
  `./onramp-to-pnut-exe.sh` once, then
  `./onramp-pnut-tcc-fc1fc50f-20261120.sh`. This script assumes
  `build-onramp-exe/pnut-exe-by-pnut-exe` already exists and does **not**
  rebuild pnut-exe.

All three scripts use the Onramp toolchain built in
`../base-onramp/onramp` (see
[report-onramp.md](../base-onramp/report-onramp.md)).  The original `pnut/`
and `tinycc/` source trees are never modified: each script works on a copy
under its build directory.

Host requirements: x86_64 Linux, `bash`, `tar`, `realpath`, and `patch` or
`git` for the unified source patches.  No host C compiler (`gcc`) or binutils
is required.

---

## 1. `onramp-to-pnut-exe.sh`

Compiles `pnut.c` with the Onramp compiler, selecting the native ELF backend,
and verifies:

1. a trivial program compiled by `pnut-exe` runs natively (exit code 42);
2. `pnut-exe` compiles `pnut.c` into a native pnut;
3. that native pnut recompiles `pnut.c` to a byte-identical binary.

```sh
./onramp-to-pnut-exe.sh                    # x86_64 (default)
./onramp-to-pnut-exe.sh --target i386      # 32-bit, M2-Planet style
./onramp-to-pnut-exe.sh --force            # rebuild
```

Key flags:

```sh
-Dtarget_x86_64_linux   # or -Dtarget_i386_linux
-DONE_PASS_GENERATOR
```

`ONE_PASS_GENERATOR` is required under Onramp.  Without it `exe.c` allocates
`CODE_SIZE = 5,000,000` ints (20 MB), more than the Onramp VM's 16 MiB free
memory region, and running `pnut-exe` aborts with
`ERROR: A memory access is invalid.`.  With it, `CODE_SIZE` is 200,000 ints
(800 KB).

Artifacts (`build-onramp-exe/`):

| File | Description |
|---|---|
| `pnut-exe` | pnut built by Onramp (runs on the Onramp VM, needs `onrampvm` on `PATH`) |
| `pnut-exe-by-pnut-exe` | native pnut produced by `pnut-exe` |
| `pnut-exe-by-pnut-exe-2` | native pnut recompiled by the previous binary; must be identical |
| `tiny.c`, `tiny`, `tiny-native` | exit-code smoke tests |

Measured results:

| Target | Onramp `pnut-exe` | native pnut | fixed-point SHA-256 |
|---|---:|---:|---|
| x86_64 | 436,952 B | 237,279 B | `ad17e277…b36e13a8` |
| i386 | 459,120 B | 214,805 B | `31186a4b…a76a06a` |

The i386 build uses pnut's emulated 64-bit arithmetic
(`-DSUPPORT_EMULATED_INT64` plus `arith64.c`), so its binary differs from the
x86_64 one.

---

## 2. `onramp-pnut-tcc-0.9.27.sh`

Builds TCC 0.9.27 from `pnut/kit/tcc-0.9.27.tar.gz` with the pnut produced by
script 1, following `pnut/kit/bootstrap.sh`:

1. compile `pnut.c` again with `-DNO_BUILTIN_LIBC -DSAFE_MODE` plus
   `portable_libc/libc.c` to get `pnut-exe-for-tcc`;
2. unpack TCC 0.9.27, install `kit/config.h`, and apply the unified patches
   `patches/tcc-0.9.27-pnut.patch` (plus
   `patches/tcc-0.9.27-pnut-x86_64.patch` for x86_64);
3. compile `tcc.c` + `portable_libc/libc.c` into `tcc-pnut`;
4. build the boot0 runtime (`crt1.o`, `libc.a`, `libtcc1.a`), compile and run
   a `hello` program with `tcc-pnut`;
5. recompile TCC with itself into `tcc-boot0` and run it.

```sh
./onramp-pnut-tcc-0.9.27.sh                    # x86_64
./onramp-pnut-tcc-0.9.27.sh --target i386      # i386
./onramp-pnut-tcc-0.9.27.sh --force            # rebuild pnut-exe first
```

Artifacts (`build-pnut-tcc/`): `pnut-exe-for-tcc`, patched `tcc-0.9.27/`,
`build/tcc-pnut`, `build/tcc-boot0`, `build/boot0-lib/`, `build/hello`.

Measured results:

| Target | `tcc-pnut` | `tcc-boot0` | version output |
|---|---:|---:|---|
| x86_64 | 1,280,725 B | 304,040 B | `tcc version 0.9.27 (x86_64 Linux)` |
| i386 | 978,221 B | 238,912 B | `tcc version 0.9.27 (i386 Linux)` |

`tcc-pnut` compiles and runs `hello`; `tcc-boot0` is TCC compiled by TCC and
also runs.  With pnut-exe already built the script takes about 12 s;
`--force` (which also rebuilds pnut-exe) takes about 52 s.  The log is in
[pnut-tcc-self-test.log](pnut-tcc-self-test.log).

---

## 3. `onramp-pnut-tcc-fc1fc50f-20261120.sh`

Builds the newer tinycc checkout in `./tinycc` (commit `fc1fc50f`, version
0.9.28rc) using the pnut from script 1.  It supports the x86_64 pnut-exe only.
**This script assumes
`./onramp-to-pnut-exe.sh` has already been run** and uses
`build-onramp-exe/pnut-exe-by-pnut-exe` as the seed; it does not rebuild
pnut-exe.

```sh
./onramp-to-pnut-exe.sh                       # once
./onramp-pnut-tcc-fc1fc50f-20261120.sh        # build tinycc
```

Artifacts (`build-pnut-tinycc/`):

| Path | Description |
|---|---|
| `C1`, `pnut-exe-for-tcc` | two-stage pnut bootstrap compilers |
| `tcc-src/` | patched tinycc source |
| `bin/tcc-pnut` | tinycc 0.9.28rc compiled by pnut (1,691,884 B) |
| `bin/crt1.o`, `bin/libc.o`, `bin/libtcc1.o`, `bin/va_list.o` | runtime objects built by `tcc-pnut` |
| `bin/tiny`, `bin/hello` | executables linked by `tcc-pnut` itself |

Measured results (x86_64):

```
tcc version 0.9.28rc (x86_64 Linux)
tcc-pnut compiled tiny.c to 1134 bytes
tcc-pnut compiled and linked tiny (exit 42)
tcc-pnut compiled and linked hello:
  Hello from tinycc 0.9.28rc built by pnut!
```

The whole script runs in about 4 seconds after pnut-exe exists.  The log is in
[pnut-tinycc-self-test.log](pnut-tinycc-self-test.log).

### Why the extra patches?

tinycc 0.9.28rc is newer than what pnut's `kit/` targets, so
`patches/` contains the port:

- `patches/tinycc-fc1fc50f-pnut.patch` — tinycc changes:
  - `LDOUBLE_WORDS` fixed for `PNUT_CC` (pnut cannot parse a `sizeof` in an
    array size);
  - bitfields in `SymAttr`, `FuncAttr`, `sym_attr` replaced by plain fields
    when `HAVE_BITFIELD` is not defined (pnut rejects bitfield declarations);
  - `NORETURN`, `ALIGNED`, `PRINTF_LIKE` empty under `PNUT_CC`;
  - `ldexpl` mapped to `ldexp` (portable libc has no `ldexpl`);
  - a no-op `TCCSem` for `CONFIG_TCC_SEMLOCK` (portable libc has no
    `<semaphore.h>`);
  - the `TCC_STATE_VAR` state aliases defined directly per branch instead of
    through self-referential macros (pnut does not expand a macro name that
    appears inside its own expansion);
  - `tcc_internal_error` without `__FUNCTION__`;
  - float-literal code in `tccpp.c` and `tccgen.c` guarded with
    `HAVE_FLOAT` (pnut has no floating-point literals);
  - `N_DEFAULT_DEBUG` fixed to 29/27 entries (pnut cannot evaluate
    `sizeof` of a variable);
  - no `environ` and no `freopen` in `tccrun.c`;
  - the `jmp_buf` parameter name in `libtcc.h` renamed because pnut's
    portable libc defines `jmp_buf` as a macro;
  - the x86-64 local-enum `va_arg` patch from pnut's `kit/tcc-patches/0.9.27`.
- `patches/tcc-0.9.27-pnut.patch` and
  `patches/tcc-0.9.27-pnut-x86_64.patch` — unified diffs replacing the
  `kit/tcc-patches/0.9.27/*.before/.after` files; used by script 2 so that
  `python3` is not required.
- `patches/pnut-portable-libc.patch` — guard pnut's own
  `strlen`/`memcpy`/`strrchr` definitions with `!PNUT_PORTABLE_LIBC` so that
  they do not clash with `portable_libc`.
- `patches/pnut-tcc-compat.c` — `strpbrk`, `strerror`, and an exiting
  `longjmp`, which tinycc uses but pnut's portable libc does not provide.

### Two-stage pnut bootstrap

The seed pnut (`pnut-exe-by-pnut-exe`) still emits pnut's built-in runtime
(including the `printf` stub).  Building `pnut-exe-for-tcc` directly with
`-DNO_BUILTIN_LIBC` would therefore mix the built-in runtime with the
portable libc (duplicate `strlen`, stub `printf`).  The script therefore:

- builds **C1** from pnut.c with `-DNO_BUILTIN_LIBC` and **without** the
  portable libc (C1's own runtime comes from the seed);
- builds **C2** = `pnut-exe-for-tcc` with C1, `-DNO_BUILTIN_LIBC
  -DPNUT_PORTABLE_LIBC` and `portable_libc/libc.c`.

C2 has working diagnostics and emits no built-in runtime; it is used to
compile tinycc.

### Verification and limitations

`tcc-pnut` compiles C to x86-64 ELF object files.  The script builds the
runtime objects (`crt1.o`, `libc.o`, `libtcc1.o`, `va_list.o`) with
`tcc-pnut`, then links them and the test program with:

```sh
tcc-pnut -nostdlib -static -o tiny \
    crt1.o libc.o libtcc1.o va_list.o tiny.o
```

No host C compiler or binutils is involved in the whole tinycc build and
verification.

Archive (`-l`) linking is still unsupported: pnut's portable libc lacks
several `stdio` / archive behaviours TCC's archive reader relies on, so TCC
reports `invalid archive`.  TCC's own `-ar` output is accepted by host `ar`
but rejected by TCC's own linker.  This is a pnut portability limitation, not
a tinycc build failure.  For the same reason the script builds everything with
`CONFIG_TCC_BACKTRACE=0` (no `ucontext`/backtrace) and TCC's `-run` mode is
not exercised.

---

## Technical notes common to all scripts

1. **`onrampcc` is not used.**  The in-tree `onrampcc` wrapper passes include
   paths containing several `..` components and symlinks, which makes Onramp's
   cpp fail with `Internal error: Invalid format output.`.  The scripts call
   `output/final/bin/cc.oe` directly and canonicalise the wrap-header path.
2. **The Onramp linker limits `#line` filenames to 128 bytes.**  Absolute
   paths to Onramp's headers are longer, so the scripts rewrite them to
   basenames after preprocessing (`Name is too long.` otherwise).
3. **ISO C strictness.**  `return void_expression;` in pnut's
   `set_car()`/`set_cdr()` is a GCC extension that Onramp rejects; the build
   copies use plain calls.

## Reproducing

```sh
# 1. Build Onramp (once)
cd ../base-onramp/onramp && ./configure.sh && ./build.sh
cd ../../base-pnut

# 2. pnut
./onramp-to-pnut-exe.sh

# 3. TCC from pnut's kit
./onramp-pnut-tcc-0.9.27.sh

# 4. tinycc fc1fc50f (needs step 2)
./onramp-pnut-tcc-fc1fc50f-20261120.sh
```

All build output goes to `build-onramp-exe/`, `build-pnut-tcc/` and
`build-pnut-tinycc/`; the source trees `pnut/` and `tinycc/` stay clean.
