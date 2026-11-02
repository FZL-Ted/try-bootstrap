#!/usr/bin/env python3
"""Give inline functions in EDG-generated C Itanium/COMDAT linkonce semantics.

EDG's IA64-ABI C output declares inline functions as `extern __inline__`.
With GCC's C99 inline rules that produces a *strong* out-of-line copy in every
TU (`multiple definition` at link time, and duplicated function-local
statics).  GCC 4.6 emits a weak out-of-line definition only if the function is
not `inline`; a weak out-of-line copy is the linkonce semantics the Itanium
ABI requires, so this pass drops `__inline__` and adds
`__attribute__((__weak__))` (keeping other attributes such as
`__always_inline__` untouched).  `static __inline__` (internal linkage) just
loses the `inline` keyword.

A few entities have internal linkage (anonymous namespaces / lambdas) and are
also declared `static`; gcc rejects a weak declaration for them ("weak
declaration of ... must be public").  Those are handled by the C++ driver,
which strips the weak attribute for exactly the symbols gcc complains about
and retries the compile; a line-level heuristic here cannot distinguish them
reliably (one EDG line may mix several declarations).
"""
import sys
WEAK = '__attribute__((__weak__))'
for path in sys.argv[1:]:
    out = []
    for line in open(path, encoding='utf-8', errors='surrogateescape'):
        if 'static __inline__' in line:
            line = line.replace('static __inline__', 'static')
        if '__inline__' in line:
            if WEAK not in line:
                line = line.replace('__inline__', WEAK)
            else:
                line = line.replace('__inline__', '')
        out.append(line)
    open(path, 'w', encoding='utf-8', errors='surrogateescape').writelines(out)
