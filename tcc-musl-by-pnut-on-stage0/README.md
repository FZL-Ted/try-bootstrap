# tcc-musl-by-pnut-on-stage0

A reproducible bootstrap of a **musl-linked TinyCC 0.9.27** on top of the
[stage0-posix](https://github.com/oriansj/stage0-posix) seed, for **x86 (i386)**
and **amd64 (x86_64)**.

Starting from the stage0-posix binary seeds, the project builds
[M2-Planet](https://github.com/oriansj/M2-Planet), [pnut](https://github.com/udem-dlteam/pnut)
and a chain of TinyCC compilers, uses the final boot compiler to build
[musl](https://musl.libc.org/) from source, and then builds a new `tcc` that is
compiled and linked against that musl.

Everything runs inside a `bubblewrap` sandbox, so the host only needs the
sources, Python 3 and `bwrap`; no host C compiler is involved.

## Build pipeline

```
stage0-posix seeds
  └─ M2-Planet, M1, hex2, blood-elf, kaem
       └─ pnut-exe-by-M2-Planet
            └─ pnut-exe (pnut compiles itself)
                 ├─ bintools (ar, tar, ...)
                 └─ tcc-pnut
                      └─ tcc-boot0 → tcc-boot1 → tcc-boot2 → tcc-boot3
                           └─ tcc-musl-x86.sh / tcc-musl-amd64.sh
                                ├─ pass 1: musl built by tcc-boot3
                                │    (math is skipped: the boot libc cannot
                                │     parse all of its floating-point literals)
                                ├─ tcc-musl linked against the pass 1 libc.a
                                ├─ pass 2: all of musl built by tcc-musl
                                └─ tcc-musl rebuilds itself on the full musl
```

The two-pass musl build is needed because the tcc that runs on top of pnut's
minimal libc understands only a few floating point literals. Pass 1 is just
complete enough to link `tcc-musl`; with tcc's full 64-bit/float runtime
available, pass 2 builds every musl source.

## Requirements

* A Linux x86_64 host. The x86 chain runs i386 binaries, so the kernel must
  support 32-bit execution (`CONFIG_IA32_EMULATION`).
* `bash`, `git`, `wget`, `python3`, `tar`, `sed`, `grep`.
* `bubblewrap` (`bwrap`) with unprivileged user namespaces enabled.
* Network access on the first run: `stage0-posix` and `pnut` are cloned if
  their directories are missing, and `musl-1.2.5.tar.gz` is downloaded if the
  tarball is absent. Later runs reuse the local checkouts and tarball.
* A few hundred MB of disk space: about 100 MB per rootfs plus the shared
  source checkouts (`pnut/`, `stage0-posix/`) and the musl tarball.

## Usage

```sh
# x86 (i386), rootfs in ./rootfs-x86
./prepare-rootfs.sh

# amd64 (x86_64), rootfs in ./rootfs-amd64
./prepare-rootfs.sh --arch amd64

# explicit rootfs directory (~a plain name starting with "rootfs")
./prepare-rootfs.sh --arch amd64 --rootfs rootfs-test
```

`prepare-rootfs.sh` accepts:

| Option | Description |
| --- | --- |
| `--arch x86\|amd64` | Target architecture (default: `x86`). |
| `--rootfs <dir>` | Rootfs directory to create. It must be a plain name starting with `rootfs` because the script deletes it before populating it. Defaults to `rootfs-x86` / `rootfs-amd64`. |
| `--help`, `-h` | Show usage. |

The build finishes inside the rootfs; the resulting compiler can be checked
with:

```sh
bwrap --bind ./rootfs-amd64 / --proc /proc --dev /dev /usr/bin/tcc-musl -v
```

To compile and run a program, put the source inside the rootfs (the compiler
has absolute include paths bound to `/musl-1.2.5`):

```sh
cat > rootfs-amd64/hello.c <<'EOF'
#include <stdio.h>
int main(void) { printf("hello %d\n", 42); return 0; }
EOF
bwrap --bind ./rootfs-amd64 / --proc /proc --dev /dev \
  /usr/bin/tcc-musl /hello.c -o /hello
bwrap --bind ./rootfs-amd64 / --proc /proc --dev /dev /hello
```

## Outputs

| Path | Description |
| --- | --- |
| `ROOTFS/usr/bin/tcc-musl` | Final x86 / x86_64 TinyCC linked against musl (static). |
| `ROOTFS/usr/lib/musl/libc.a` | Static musl libc built by tcc-musl. |
| `ROOTFS/usr/lib/musl/{crt1,crti,crtn}.o` | musl crt objects. |
| `ROOTFS/usr/lib/musl/tcc/libtcc1.a` | tcc runtime library used when linking programs. |
| `ROOTFS/build/tcc-boot0..3` | Boot-chain compilers (linked against pnut's libc). |
| `ROOTFS/tccbuild/p1`, `ROOTFS/tccbuild/p2` | Pass 1 / pass 2 musl objects. |

## Repository layout

| Path | Description |
| --- | --- |
| `prepare-rootfs.sh` | Main entry point: checks out and patches the sources, assembles the rootfs, and runs the bootstrap in `bwrap`. |
| `prepare-musl.py` | Applies the per-architecture musl patches, generates the musl headers, and writes `tcc-files` / `tcc-cflags`. |
| `tcc-by-pnut-on-stage0-x86.sh` | In-rootfs bootstrap script for i386: stage0 → pnut → tcc-boot0..3 → musl. |
| `tcc-by-pnut-on-stage0-amd64.sh` | Same for x86_64, with the extra x86-64 tcc patches. |
| `tcc-musl-x86.sh` | i386: two-pass musl build and `tcc-musl` self-hosting (copied to `/tcc-musl-x86.sh` in the rootfs). |
| `tcc-musl-amd64.sh` | Same for x86_64 (copied to `/tcc-musl-amd64.sh` in the rootfs). |
| `tcbuild.c` | Small build driver: kaem has no loops, so this runs the compiler once per source file and archives the objects. |
| `tcc-libgcc.c` | Complete 64-bit helper runtime; replaces pnut's deliberately incomplete `kit/libtcc1.c` for the i386 boot chain. |
| `tcc-boot-patches/` | tcc source patches applied by the bootstrap scripts (weak `ar` symbols, C99 array declarators, static linking, etc.). |
| `patches/` | stage0-posix / pnut patches, including the M2-Planet global `++`/`--` fix. |
| `docs/` | Notes on the upstream M2-Planet fixes. |

## Verified configurations

The following hashes were produced by full, from-scratch runs of
`./prepare-rootfs.sh` and are useful as a sanity check (they depend on the
exact upstream `pnut` / `stage0-posix` revisions and may change when those
projects move):

| Target | tcc-boot3 | tcc-musl | musl pass 1 | musl pass 2 |
| --- | --- | --- | --- | --- |
| x86 (i386) | `a51ec15c…` | `0474fddf…` | 1254 compiled / 92 skipped | 1346 / 0 |
| amd64 (x86_64) | `7ddfe133…` | `23862f5a…` | 1169 / 114 | 1283 / 0 |

For amd64, `tcc-boot2` and `tcc-boot3` reach a fixed point
(`7ddfe133…`), and the rebuilt `tcc-musl.new` is byte-identical to
`tcc-musl`.

Basic smoke tests performed with the resulting compiler: `printf` with
integer/float/double varargs, 64-bit division/modulo/shifts, `qsort`,
`malloc`, `strtod`/`strtol`, `sqrt`, `lrint`/`llrint`, `setjmp`/`longjmp`,
`pthread_create`/`pthread_join` and `stat`.

## Known limitations

* **Static linking only.** No shared libc or dynamic loader is built;
  `tcc-musl` links programs against `libc.a`.
* `_Complex` is not supported, so musl's complex math is not built.
* On x86_64, `fenv` uses musl's generic no-op C implementation and a few
  x86_64 assembly math overrides fall back to the generic C versions.
* On i386, TLS is stubbed out (`g_pthread`) and `posix_spawn` uses `fork`,
  because the boot compiler cannot produce working `%gs`-relative code.
* `tcc-musl` is built with `CONFIG_TCCBOOT=1` (required for the x86_64 static
  PLT/GOT fixes), so `tcc -run`/JIT and some libtcc features are unavailable.
* `compat/time32` is only built for i386, matching musl's `arch/i386/arch.mak`.
* The x86 chain needs a host that can execute i386 ELF binaries.

## Credits

This project stands on the work of the
[stage0-posix](https://github.com/oriansj/stage0-posix),
[M2-Planet](https://github.com/oriansj/M2-Planet),
[pnut](https://github.com/udem-dlteam/pnut),
[musl](https://musl.libc.org/) and
[TinyCC](https://bellard.org/tcc/) projects.
