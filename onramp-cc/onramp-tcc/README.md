# Building TinyCC with Onramp

`onramp-to-tcc.sh` builds Onramp from `./onramp`, then uses the resulting
Onramp toolchain to build TinyCC from a copy of `./tinycc`.  Host gcc and
binutils are masked with failing PATH shims and are not used for the TinyCC
build.

```sh
./onramp-to-tcc.sh              # build Onramp, then TinyCC
./onramp-to-tcc.sh --skip-onramp
./onramp-to-tcc.sh --clean -j 4
```

The work tree is `build/work`; logs are in `build/logs/`.  The built compiler
is installed to `build/tinycc/install-stage0/bin/tcc`.

## Result

At the commits currently checked out, the build succeeds:

```text
tcc version 0.9.28rc 2026-11-20 mob@fc1fc50f* (x86_64 Linux)
```

The stage-0 `tcc` is a wrapped Onramp program, so `onrampvm` must be on PATH
when running it.  It emits native x86-64 relocatable objects; linking native
executables still needs a native libc and crt objects, which this script does
not provide.

## Findings

The current Onramp checkout needs three workarounds for TinyCC.  They are
either in the script or in `tinycc-onramp.patch`, a forward-port of Onramp's
`ports/tinycc/0001-TinyCC-hacks-to-support-Onramp.patch`:

1. **Long include paths break Onramp's cpp.**
   Onramp's libc `vasprintf()` formats into a 128-byte stack buffer and calls
   `__fatal("Internal error: Invalid format output.")` if the output is
   longer.  Onramp's cpp builds include paths with `asprintf()`, so a deep
   source/build directory makes every include fail before `fopen()` is even
   called.  The script therefore builds through a short symlink rooted at
   `/tmp/onramp-to-tcc-work`.

2. **Onramp's cci rejects `L`-suffixed floating literals.**
   `tccpp.c` uses constants such as `79228162514264337593543950336.0L`; the
   patch drops the `L` suffixes.  This is safe here because Onramp has no long
   double support and the TinyCC build already enables
   `TCC_USING_DOUBLE_FOR_LDOUBLE`.

3. **Onramp's libc declares but does not implement `strtold()`/`ldexpl()`.**
   The link fails with `Symbol not found: strtold`.  The patch maps both to
   their double equivalents under `__onramp__`.

These are limitations of the current Onramp checkout, not of TinyCC itself.
