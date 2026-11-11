#!/usr/bin/env python3
"""Patch the musl tree under rootfs/ so the bootstrapped tcc can build it.

This is the patching half of tcc-musl-by-pnut-on-stage0-x86/prepare-rootfs.sh,
kept in its own file so this project's prepare-rootfs.sh only needs a small
hook.  It expects rootfs/musl-1.2.5 to have been extracted already.

The remaining patches work around constructs the bootstrapped tcc cannot
handle at all:
  * _Complex is not supported, so musl's complex math is skipped by the
    build script,
  * i386 math using x87 register constraints ("+t") cannot be assembled,
    so those files are removed and musl's generic C versions are used,
  * a long double LDBL_MAX/LDBL_MIN, an INFINITY, and a handful of float
    literals the boot libc's strtod/ldexp stubs cannot parse,
  * stmxcsr/ldmxcsr/jecxz, which tcc's assembler does not know,
  * __builtin_va_list for tcc.
"""

import glob
import os
import re
import sys

ROOT = os.path.join('rootfs', 'musl-1.2.5')
if not os.path.isdir(ROOT):
    sys.exit('prepare-musl.py: %s not found' % ROOT)


def rd(p):
    return open(os.path.join(ROOT, p)).read()


def wr(p, s):
    open(os.path.join(ROOT, p), 'w').write(s)


def sub(p, old, new, count=0):
    s = rd(p)
    if old not in s:
        sys.exit('prepare-musl.py: musl patch pattern not found in %s: %r' % (p, old[:70]))
    wr(p, s.replace(old, new) if not count else s.replace(old, new, count))


def re_sub(p, pat, rep):
    s = rd(p)
    m = re.sub(pat, rep, s)
    if m != s:
        wr(p, m)


BIG = '*'.join(['4294967296.0'] * 64)


def pow2(e, suffix=''):
    """2**e as an expression tcc can constant fold (its boot libc's strtod
    only understands a handful of literals)."""
    n, parts = abs(e), []
    while n >= 32:
        parts.append('4294967296.0' + suffix)
        n -= 32
    if n:
        parts.append('(1.0%s*%d)' % (suffix, 1 << n))
    expr = '*'.join(parts)
    return '1.0%s/(%s)' % (suffix, expr) if e < 0 else expr


# 2. hex floats are parsed with ldexp(), a stub in the boot libc -----------
for dirpath, _, files in os.walk(os.path.join(ROOT, 'src')):
    for f in files:
        if f.endswith('.c'):
            p = os.path.join(dirpath, f)
            s = open(p).read()
            m = s.replace('0x1p120f', pow2(120, 'f')).replace('0x1p-120f', pow2(-120, 'f'))
            if m != s:
                open(p, 'w').write(m)

# 3. vfprintf / floatscan: literals the boot libc cannot parse -------------
sub('src/stdio/vfprintf.c', 'small=0x0.8p0;', 'small=1.0/2;')
sub('src/stdio/vfprintf.c', 'small=0x1.0p0;', 'small=1.0;')
sub('src/stdio/vfprintf.c', 'small=0x1.8p0;', 'small=1.0+1.0/2;')
sub('src/stdio/vfprintf.c', 'long double round = 8.0;', 'long double round = 8;')
sub('src/stdio/vfprintf.c', '0x1p28', '(4294967296.0/16)')
sub('arch/i386/bits/float.h',
    '#define LDBL_EPSILON 1.0842021724855044340e-19L',
    '#define LDBL_EPSILON (1.0/4294967296.0/4294967296.0*2)')

p = 'src/internal/floatscan.c'
s = rd(p)
s = s.replace('return sign * LDBL_MAX * LDBL_MAX;',
              'return sign * (long double)(%s);' % BIG)
s = s.replace('return sign * LDBL_MIN * LDBL_MIN;', 'return sign * 0.0;')
s = s.replace('return sign * INFINITY;', 'return sign * (long double)(%s);' % BIG)
s = re.sub(r'(?<![\w.])1000000000\.0L(?![\w.])', '(long double)1000000000', s)
for old, new in (('0.25', '(1.0/4)'), ('0.75', '(1.0-1.0/4)'), ('0.5', '(1.0/2)')):
    s = re.sub(r'(?<![\w.])%s(?![\w.])' % re.escape(old), new, s)
wr(p, s)

# 4. va_list for tcc ------------------------------------------------------
p = 'include/alltypes.h.in'
s = rd(p)
if '#ifdef __TINYC__' not in s:
    block = ('#ifdef __TINYC__\n'
             'typedef char *__builtin_va_list;\n'
             '#define __builtin_va_start(ap,last) ap = ((char *)&(last)) + ((sizeof(last)+3)&~3)\n'
             '#define __builtin_va_arg(ap,type) (ap += (sizeof(type)+3)&~3, *(type *)(ap - ((sizeof(type)+3)&~3)))\n'
             '#define __builtin_va_copy(dest, src) (dest) = (src)\n'
             '#define __builtin_va_end(ap)\n'
             '#endif\n\n')
    wr(p, s.replace('TYPEDEF __builtin_va_list va_list;',
                    block + 'TYPEDEF __builtin_va_list va_list;', 1))

# 5. tcc's i386 assembler has no stmxcsr/ldmxcsr and no jecxz -------------
p = 'src/fenv/i386/fenv.s'
s = rd(p)
m = '\n'.join(l for l in s.split('\n') if not re.match(r'\s*(stmxcsr|ldmxcsr)\b', l))
if m != s:
    wr(p, m)
p = 'src/signal/i386/sigsetjmp.s'
s = rd(p)
if '\tjecxz 1f' in s:
    wr(p, s.replace('\tjecxz 1f', '\tcmp $0,%ecx\n\tje 1f'))

# 6. drop the i386 C implementations that use x87 register constraints ----
for p in sorted(glob.glob(os.path.join(ROOT, 'src/math/i386/*.c'))):
    t = open(p).read()
    if re.search(r'"\+t"|"=t"|"t\(|"u"\(', t):
        os.remove(p)
# The lrint family spells the same x87 operand as `"t"(x)` with an `"st"`
# clobber, which the pattern above does not catch; drop them explicitly so
# musl's generic C versions are built instead.
for _f in ('lrint.c', 'llrint.c', 'lrintf.c', 'llrintf.c',
           'lrintl.c', 'llrintl.c'):
    _p = os.path.join(ROOT, 'src/math/i386', _f)
    if os.path.exists(_p):
        os.remove(_p)
sub('src/math/frexpl.c', '0x1p120', pow2(120))

# 7. avoid TLS / clone (the boot tcc produces code without a working %gs) --
sub('arch/i386/pthread_arch.h',
    'static inline uintptr_t __get_tp()\n{\n\tuintptr_t tp;\n'
    '\t__asm__ ("movl %%gs:0,%0" : "=r" (tp) );\n\treturn tp;\n}',
    'extern uintptr_t g_pthread;\nstatic inline uintptr_t __get_tp()\n{\n\treturn g_pthread;\n}')
sub('arch/i386/syscall_arch.h', '#define __SYSCALL_LL_E(x)',
    '#define SYSCALL_NO_TLS 1\n#define __SYSCALL_LL_E(x)')
sub('src/env/__init_tls.c', 'volatile int __thread_list_lock;\n',
    'volatile int __thread_list_lock;\nuintptr_t g_pthread;\n')
sub('src/env/__init_tls.c',
    '\tint r = __set_thread_area(TP_ADJ(p));\n\tif (r < 0) return -1;\n\tif (!r) libc.can_do_threads = 1;\n', '')
sub('src/env/__init_tls.c', '\ttd->next = td->prev = td;\n\treturn 0;',
    '\ttd->next = td->prev = td;\n\tg_pthread = (uintptr_t) td;\n\treturn 0;')
re_sub('src/process/posix_spawn.c',
       r'\tpid = __clone\(child, stack\+sizeof stack,\n\t\tCLONE_VM\|CLONE_VFORK\|SIGCHLD, &args\);',
       '\tpid = fork();\n\tif (pid == 0) {\n\t\t_exit(child(&args));\n\t}')

# 8. generated headers and the tcc runtime library ------------------------
for d in ('obj/include/bits', 'obj/src/internal', 'tcc-bootstrap'):
    if not os.path.isdir(os.path.join(ROOT, d)):
        os.makedirs(os.path.join(ROOT, d))
if os.system('cd %s && sed -f tools/mkalltypes.sed arch/i386/bits/alltypes.h.in '
             'include/alltypes.h.in > obj/include/bits/alltypes.h' % ROOT) != 0:
    sys.exit('prepare-musl.py: mkalltypes failed')
if os.system('cd %s && cp arch/i386/bits/syscall.h.in obj/include/bits/syscall.h && '
             "sed -n -e 's/__NR_/SYS_/p' < arch/i386/bits/syscall.h.in "
             '>> obj/include/bits/syscall.h' % ROOT) != 0:
    sys.exit('prepare-musl.py: syscall header generation failed')
open(os.path.join(ROOT, 'obj/src/internal/version.h'), 'w').write(
    '#define VERSION "%s"\n' % open(os.path.join(ROOT, 'VERSION')).read().strip())

# the list of sources to build, in musl's Makefile order: src/*, the i386
# replacements for files that have them, mallocng, crt and compat/time32.
# _Complex cannot be compiled by tcc, so src/complex is left out.
def _rel(p):
    return os.path.relpath(p, ROOT)


_base, _arch = [], []
for _d in sorted(glob.glob(os.path.join(ROOT, 'src/*'))):
    if os.path.isdir(_d):
        _base += glob.glob(_d + '/*.c')
        _arch += (glob.glob(_d + '/i386/*.c') + glob.glob(_d + '/i386/*.s'))
_base += glob.glob(os.path.join(ROOT, 'src/malloc/mallocng/*.c'))
_base += glob.glob(os.path.join(ROOT, 'crt/*.c'))
_base += glob.glob(os.path.join(ROOT, 'compat/time32/*.c'))
_arch += glob.glob(os.path.join(ROOT, 'crt/i386/*.s'))
_repl = set(os.path.splitext(_q)[0].replace('/i386/', '/') + '.o' for _q in _arch)
_files = [_q for _q in _base if os.path.splitext(_q)[0] + '.o' not in _repl] + _arch
_files = sorted(set(_rel(_q) for _q in _files if '/src/complex/' not in _q))
open(os.path.join(ROOT, 'tcc-files'), 'w').write('\n'.join(_files) + '\n')
print('prepare-musl.py: %d musl sources to build' % len(_files))

# tcc expands @file into arguments; kaem passes a ${var} as one argument, so
# the long flag list is kept in this response file.
open(os.path.join(ROOT, 'tcc-cflags'), 'w').write(
    '-D_XOPEN_SOURCE=700 -I%(r)s/arch/i386 -I%(r)s/arch/generic -I%(r)s/obj/src/internal'
    ' -I%(r)s/src/include -I%(r)s/src/internal -I%(r)s/obj/include -I%(r)s/include'
    ' -std=c99 -ffreestanding -DCRT -nostdinc\n' % {'r': '/musl-1.2.5'})

print('prepare-musl.py: musl patched for the bootstrapped tcc')
