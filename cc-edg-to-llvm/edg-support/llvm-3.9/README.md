# LLVM 3.9 compatibility patches

Used by `refhost-llvm3.9.x-1.sh`, `-2.sh`, and `-bootstrap.sh`.

Apply with:

```bash
./apply.sh <source-root>
```

The source root is the directory produced by extracting
`llvm-project-3.9.x.tar.gz` with `--strip-components=1`, so it contains
`llvm/`, `clang/`, `libcxx/`, `compiler-rt/`, and `lld/`.

Patches:

- `libcxx-locale-strtoll.patch` — musl has no `strtoll_l`/`strtoull_l`;
  libc++ 3.9 calls them directly in its non-glibc path.
- `libcxx-stddef-max-align.patch` — musl defines `max_align_t` and sets
  `__DEFINED_max_align_t`; libc++ 3.9 only checks the clang/gcc guards.
- `libcxx-system-error-strerror-r.patch` — musl's `strerror_r` can return a
  non-`ERANGE` failure; do not assert/abort while formatting clang diagnostics.
- `llvm-dynamiclibrary-const-stdio.patch` — musl declares `FILE *const
  stdin/stdout/stderr`; take the address through an explicit `void*` cast.
- `llvm-cmake-cmp0051-new.patch` — 3.9 sets CMP0051 to OLD, which CMake 4
  rejects; use the required NEW behavior.

`apply.sh` skips a patch when its marker is already present, so the three
scripts can call it repeatedly.

LLVM 3.9's lld already handles `R_X86_64_GOTPCRELX`/`REX_GOTPCRELX` and TLS;
no lld source patch is needed.

Host-clang C adaptation:

- `edg-clang-atomic.h` — included for EDG-generated `.int.c` files.  EDG emits
  GCC-style `__sync_*_N` / `__atomic_*_N` calls with `volatile void *`
  arguments; these macros give clang a correctly typed integer pointer and
  map to clang's generic atomic builtins.

SSE2 fallback patches:

- `clang-lexer-no-sse2.patch` — guard `Lexer.cpp`'s SSE2 block with
  `EDG_BOOTSTRAP_NO_SSE2`; EDG uses the existing scalar fallback.
- `clang-sourcemanager-no-sse2.patch` — same for `SourceManager.cpp`.
