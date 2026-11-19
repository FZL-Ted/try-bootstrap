#!/usr/bin/env python3
"""Give inline functions in EDG-generated C Itanium/COMDAT linkonce semantics.

EDG's C output declares inline functions `extern __inline__`.  Under GCC's
C99 inline rules that produces a strong out-of-line copy in every TU
(multiple definitions at link time).  GCC emits a weak out-of-line definition
only if the function is not `inline`, so this pass drops `__inline__` and adds
`__attribute__((__weak__))` to external-linkage functions.

Two corrections are needed for GCC's C inline rules:

  * __attribute__((__always_inline__)) must go as well: GCC refuses to inline
    a weak function and turns that into a hard error ("inlining failed in call
    to 'always_inline' ... function body can be overwritten at link time").
  * internal-linkage functions (static / anonymous namespace) must NOT get a
    weak attribute: GCC rejects it ("weak declaration of ... must be public").
    EDG splits one declaration over several lines interleaved with `# line`
    directives, and one line may contain several declarations, so track the
    declaration state token by token and decide at each `__inline__` from the
    text that precedes it (never from a later `static` inside the body).
"""
import re
import sys

WEAK = '__attribute__((__weak__))'
INLINE = re.compile(r'__inline__')
# Tokens that change the state of the declaration currently being emitted.
STATE = re.compile(r'\bstatic\b|' + re.escape(WEAK) + r'|[;{}]')


def process(path):
    pending_static = False
    decl_has_weak = False

    def scan(text):
        nonlocal pending_static, decl_has_weak
        for match in STATE.finditer(text):
            token = match.group(0)
            if token in (';', '{', '}'):
                pending_static = False
                decl_has_weak = False
            elif token == WEAK:
                decl_has_weak = True
            else:
                pending_static = True

    out = []
    with open(path, encoding='utf-8', errors='surrogateescape') as f:
        for line in f:
            if line.lstrip().startswith('#'):
                out.append(line)
                continue
            if '__always_inline__' in line:
                line = line.replace('__attribute__((__always_inline__)) ', '')
                line = line.replace('__attribute__((always_inline)) ', '')
            if '__inline__' not in line:
                scan(line)
                out.append(line)
                continue
            pieces = []
            pos = 0
            for match in INLINE.finditer(line):
                scan(line[pos:match.start()])
                pieces.append(line[pos:match.start()])
                if pending_static:
                    pass  # internal linkage: just drop __inline__
                elif decl_has_weak:
                    pass  # this declaration is already weak
                else:
                    pieces.append(WEAK)
                    decl_has_weak = True
                pos = match.end()
            pieces.append(line[pos:])
            scan(line[pos:])
            out.append(''.join(pieces))
    with open(path, 'w', encoding='utf-8', errors='surrogateescape') as f:
        f.writelines(out)


if __name__ == '__main__':
    for p in sys.argv[1:]:
        process(p)
