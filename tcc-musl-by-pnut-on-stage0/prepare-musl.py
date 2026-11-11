#!/usr/bin/env python3
"""Patch the musl tree under rootfs/ so the bootstrapped tcc can build it.

This is the patching half of tcc-musl-by-pnut-on-stage0-x86/prepare-rootfs.sh,
kept in its own file so this project's prepare-rootfs.sh only needs a small
hook.  It expects rootfs/musl-1.2.5 to have been extracted already.

The patches work around constructs the bootstrapped tcc cannot handle at all:
  * _Complex is not supported, so musl's complex math is skipped by the
    build script,
  * math overrides using x87/SSE register constraints cannot be assembled or
    compiled, so those files are removed and musl's generic C versions are
    used,
  * a long double LDBL_MAX/LDBL_MIN, an INFINITY, and a handful of float
    literals the boot libc's strtod/ldexp stubs cannot parse,
  * stmxcsr/ldmxcsr (i386) or the whole x86_64 fenv asm, which tcc's
    assembler does not know,
  * __builtin_va_list and tcc's x86_64 va_list ABI,
  * named register variables in musl's x86_64 syscall wrappers,
  * on i386: TLS/clone, which the boot tcc cannot support.
"""

import argparse
import glob
import os
import re
import sys


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--arch', choices=('x86', 'amd64'), default='x86',
                    help='target architecture (default: x86)')
    ap.add_argument('--root', default=None,
                    help='musl source tree (default: rootfs-<arch>/musl-1.2.5)')
    args = ap.parse_args()

    ARCH = 'i386' if args.arch == 'x86' else 'x86_64'
    ROOT = args.root
    if ROOT is None:
        ROOT = os.path.join('rootfs-x86' if args.arch == 'x86' else 'rootfs-amd64',
                            'musl-1.2.5')
    if not os.path.isdir(ROOT):
        sys.exit('prepare-musl.py: %s not found' % ROOT)

    def rd(p):
        return open(os.path.join(ROOT, p)).read()

    def wr(p, s):
        open(os.path.join(ROOT, p), 'w').write(s)

    def sub(p, old, new, count=0):
        s = rd(p)
        if old not in s:
            sys.exit('prepare-musl.py: musl patch pattern not found in %s: %r'
                     % (p, old[:70]))
        wr(p, s.replace(old, new) if not count else s.replace(old, new, count))

    def re_sub(p, pat, rep):
        s = rd(p)
        m = re.sub(pat, rep, s)
        if m != s:
            wr(p, m)

    def arch_path(*parts):
        return os.path.join('arch', ARCH, *parts)

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

    # 2. hex floats are parsed with ldexp(), a stub in the boot libc -------
    for dirpath, _, files in os.walk(os.path.join(ROOT, 'src')):
        for f in files:
            if f.endswith('.c'):
                p = os.path.join(dirpath, f)
                s = open(p).read()
                m = s.replace('0x1p120f', pow2(120, 'f')).replace('0x1p-120f', pow2(-120, 'f'))
                if m != s:
                    open(p, 'w').write(m)

    # 3. vfprintf / floatscan: literals the boot libc cannot parse ---------
    sub('src/stdio/vfprintf.c', 'small=0x0.8p0;', 'small=1.0/2;')
    sub('src/stdio/vfprintf.c', 'small=0x1.0p0;', 'small=1.0;')
    sub('src/stdio/vfprintf.c', 'small=0x1.8p0;', 'small=1.0+1.0/2;')
    sub('src/stdio/vfprintf.c', 'long double round = 8.0;', 'long double round = 8;')
    sub('src/stdio/vfprintf.c', '0x1p28', '(4294967296.0/16)')
    sub(arch_path('bits/float.h'),
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

    # tcc itself uses ldexp(), which musl implements with scalbn(), so the
    # scalbn/frexp family has to build even in pass 1; their hex floats are
    # parsed with the boot libc's stub ldexp() and are rewritten like above.
    sub('src/math/frexpl.c', '0x1p120', pow2(120))
    if ARCH == 'x86_64':
        sub('src/math/scalbn.c', '0x1p1023', pow2(1023))
        sub('src/math/scalbn.c', '0x1p-1022', pow2(-1022))
        sub('src/math/scalbn.c', '0x1p53', pow2(53))
        sub('src/math/scalbnl.c', '0x1p16383L', pow2(16383, 'L'))
        sub('src/math/scalbnl.c', '0x1p-16382L', pow2(-16382, 'L'))
        sub('src/math/scalbnl.c', '0x1p113L', pow2(113, 'L'))
        sub('src/math/frexp.c', '0x1p64', pow2(64))

    # 4. va_list for tcc --------------------------------------------------
    # musl's <stdarg.h> routes va_* to the GCC builtins; tcc has no
    # __builtin_va_list type, so give it the definition its own <stdarg.h>
    # uses (a char pointer on i386, the SysV register-save structure on
    # x86_64) and map the builtins to tcc's helpers.
    p = 'include/alltypes.h.in'
    s = rd(p)
    if '#ifdef __TINYC__' not in s:
        if ARCH == 'i386':
            block = (
                '#ifdef __TINYC__\n'
                'typedef char *__builtin_va_list;\n'
                '#define __builtin_va_start(ap,last) ap = ((char *)&(last)) + ((sizeof(last)+3)&~3)\n'
                '#define __builtin_va_arg(ap,type) (ap += (sizeof(type)+3)&~3, *(type *)(ap - ((sizeof(type)+3)&~3)))\n'
                '#define __builtin_va_copy(dest, src) (dest) = (src)\n'
                '#define __builtin_va_end(ap)\n'
                '#endif\n\n')
        else:
            # bits/alltypes.h is included repeatedly, so the typedef has to
            # be guarded (two anonymous struct typedefs are distinct types).
            block = (
                '#ifdef __TINYC__\n'
                '#ifndef __TCC_VA_LIST_DEFINED\n'
                '#define __TCC_VA_LIST_DEFINED\n'
                'typedef struct {\n'
                '    unsigned int gp_offset;\n'
                '    unsigned int fp_offset;\n'
                '    union {\n'
                '        unsigned int overflow_offset;\n'
                '        char *overflow_arg_area;\n'
                '    };\n'
                '    char *reg_save_area;\n'
                '} __va_list_struct;\n'
                'typedef __va_list_struct __builtin_va_list[1];\n'
                'void __va_start(__va_list_struct *ap, void *fp);\n'
                'void *__va_arg(__va_list_struct *ap, int arg_type, int size, int align);\n'
                '#define __builtin_va_start(ap,last) __va_start(ap, __builtin_frame_address(0))\n'
                '#define __builtin_va_arg(ap,type) (*(type *)(__va_arg(ap, __builtin_va_arg_types(type), sizeof(type), __alignof__(type))))\n'
                '#define __builtin_va_copy(dest,src) (*(dest) = *(src))\n'
                '#define __builtin_va_end(ap)\n'
                '#endif\n'
                '#endif\n\n')
        wr(p, s.replace('TYPEDEF __builtin_va_list va_list;',
                        block + 'TYPEDEF __builtin_va_list va_list;', 1))

    # 5. tcc's assembler cannot handle some arch asm ----------------------
    if ARCH == 'i386':
        # no stmxcsr/ldmxcsr and no jecxz
        p = 'src/fenv/i386/fenv.s'
        s = rd(p)
        m = '\n'.join(l for l in s.split('\n')
                      if not re.match(r'\s*(stmxcsr|ldmxcsr)\b', l))
        if m != s:
            wr(p, m)
        p = 'src/signal/i386/sigsetjmp.s'
        s = rd(p)
        if '\tjecxz 1f' in s:
            wr(p, s.replace('\tjecxz 1f', '\tcmp $0,%ecx\n\tje 1f'))
    else:
        # x86_64: drop the fenv asm entirely; musl's generic C fenv.c is
        # built instead (a no-op fenv is enough for the bootstrap).
        _p = os.path.join(ROOT, 'src/fenv/x86_64/fenv.s')
        if os.path.exists(_p):
            os.remove(_p)
        # pushq/popq and @PLT are not understood by tcc's assembler.
        for p in ('src/signal/x86_64/sigsetjmp.s',
                  'src/math/x86_64/expl.s'):
            s = rd(p)
            m = re.sub(r'\b(pushq|popq)\b', lambda mo: mo.group(1)[:-1], s)
            m = m.replace('@PLT', '')
            if m != s:
                wr(p, m)

    # 6. drop math overrides using unsupported register constraints -------
    # The generic C files below them are used instead.
    if ARCH == 'i386':
        for p in sorted(glob.glob(os.path.join(ROOT, 'src/math/i386/*.c'))):
            t = open(p).read()
            if re.search(r'"\+t"|"=t"|"t\(|"u"\(', t):
                os.remove(p)
        # The lrint family spells the same x87 operand as `"t"(x)` with an
        # `"st"` clobber, which the pattern above does not catch.
        for _f in ('lrint.c', 'llrint.c', 'lrintf.c', 'llrintf.c',
                   'lrintl.c', 'llrintl.c'):
            _p = os.path.join(ROOT, 'src/math/i386', _f)
            if os.path.exists(_p):
                os.remove(_p)
    else:
        # tcc has no x87 "t"/"u" and no SSE "x" constraints.
        for p in sorted(glob.glob(os.path.join(ROOT, 'src/math/x86_64/*.c'))):
            t = open(p).read()
            if re.search(r'"\+t"|"=t"|"t\(|"u"\("|"[+=]x"|"x"\(', t):
                os.remove(p)
        for _f in ('lrint.c', 'llrint.c', 'lrintf.c', 'llrintf.c',
                   'lrintl.c', 'llrintl.c'):
            _p = os.path.join(ROOT, 'src/math/x86_64', _f)
            if os.path.exists(_p):
                os.remove(_p)
        # named register variables in musl's syscall wrappers cannot be used
        # with tcc, so route every __syscallN through a small asm helper.
        p = 'arch/x86_64/syscall_arch.h'
        s = rd(p)
        if '#ifdef __TINYC__' not in s:
            tcc_sys = (
                '#ifdef __TINYC__\n'
                '/* tcc has no named register variables; hand the syscall to an\n'
                '   out-of-line helper that loads r10/r8/r9 itself.  These stay\n'
                '   inline functions because src/internal/syscall.h wraps the\n'
                '   same names in macros. */\n'
                'long __tcc_syscall(long,long,long,long,long,long,long);\n'
                'static __inline long __syscall0(long n) { return __tcc_syscall(n,0,0,0,0,0,0); }\n'
                'static __inline long __syscall1(long n,long a) { return __tcc_syscall(n,a,0,0,0,0,0); }\n'
                'static __inline long __syscall2(long n,long a,long b) { return __tcc_syscall(n,a,b,0,0,0,0); }\n'
                'static __inline long __syscall3(long n,long a,long b,long c) { return __tcc_syscall(n,a,b,c,0,0,0); }\n'
                'static __inline long __syscall4(long n,long a,long b,long c,long d) { return __tcc_syscall(n,a,b,c,d,0,0); }\n'
                'static __inline long __syscall5(long n,long a,long b,long c,long d,long e) { return __tcc_syscall(n,a,b,c,d,e,0); }\n'
                'static __inline long __syscall6(long n,long a,long b,long c,long d,long e,long f) { return __tcc_syscall(n,a,b,c,d,e,f); }\n'
                '#else\n')
            marker = 'static __inline long __syscall0(long n)'
            if marker not in s:
                sys.exit('prepare-musl.py: __syscall0 marker not found')
            wr(p, s.replace(marker, tcc_sys + marker, 1))
            s = rd(p)
            if '#define VDSO_USEFUL\n' not in s:
                sys.exit('prepare-musl.py: VDSO_USEFUL marker not found')
            wr(p, s.replace('#define VDSO_USEFUL\n',
                            '#endif\n\n#define VDSO_USEFUL\n', 1))

    # 7. avoid TLS / clone on i386 (the boot tcc has no working %gs) ------
    if ARCH == 'i386':
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

    # 8. generated headers and the tcc runtime library --------------------
    for d in ('obj/include/bits', 'obj/src/internal', 'tcc-bootstrap'):
        if not os.path.isdir(os.path.join(ROOT, d)):
            os.makedirs(os.path.join(ROOT, d))
    if os.system('cd %s && sed -f tools/mkalltypes.sed %s %s > obj/include/bits/alltypes.h'
                 % (ROOT, arch_path('bits/alltypes.h.in'), 'include/alltypes.h.in')) != 0:
        sys.exit('prepare-musl.py: mkalltypes failed')
    if os.system('cd %s && cp %s obj/include/bits/syscall.h && '
                 "sed -n -e 's/__NR_/SYS_/p' < %s "
                 '>> obj/include/bits/syscall.h'
                 % (ROOT, arch_path('bits/syscall.h.in'), arch_path('bits/syscall.h.in'))) != 0:
        sys.exit('prepare-musl.py: syscall header generation failed')
    open(os.path.join(ROOT, 'obj/src/internal/version.h'), 'w').write(
        '#define VERSION "%s"\n' % open(os.path.join(ROOT, 'VERSION')).read().strip())

    if ARCH == 'x86_64':
        # the out-of-line syscall helper used by arch/x86_64/syscall_arch.h
        open(os.path.join(ROOT, 'tcc-bootstrap/syscall-x86_64.s'), 'w').write(
            '.text\n'
            '.global __tcc_syscall\n'
            '.type __tcc_syscall,@function\n'
            '__tcc_syscall:\n'
            '\tmov %rdi, %rax\n'
            '\tmov %rsi, %rdi\n'
            '\tmov %rdx, %rsi\n'
            '\tmov %rcx, %rdx\n'
            '\tmov %r8, %r10\n'
            '\tmov %r9, %r8\n'
            '\tmov 8(%rsp), %r9\n'
            '\tsyscall\n'
            '\tret\n'
            '.size __tcc_syscall,.-__tcc_syscall\n')

    # the list of sources to build, in musl's Makefile order: src/*, the
    # arch replacements for files that have them, mallocng, crt and
    # compat/time32 (i386 only).  _Complex cannot be compiled by tcc, so
    # src/complex is left out.
    def _rel(p):
        return os.path.relpath(p, ROOT)

    _base, _arch = [], []
    for _d in sorted(glob.glob(os.path.join(ROOT, 'src/*'))):
        if os.path.isdir(_d):
            _base += glob.glob(_d + '/*.c')
            _arch += (glob.glob(_d + '/' + ARCH + '/*.c') +
                      glob.glob(_d + '/' + ARCH + '/*.s'))
    _base += glob.glob(os.path.join(ROOT, 'src/malloc/mallocng/*.c'))
    _base += glob.glob(os.path.join(ROOT, 'crt/*.c'))
    # arch/i386/arch.mak adds compat/time32; x86_64 has no arch.mak, so musl
    # does not build the 32-bit time wrappers there.
    if ARCH == 'i386':
        _base += glob.glob(os.path.join(ROOT, 'compat/time32/*.c'))
    _arch += glob.glob(os.path.join(ROOT, 'crt/' + ARCH + '/*.s'))
    _repl = set(os.path.splitext(_q)[0].replace('/' + ARCH + '/', '/') + '.o'
                for _q in _arch)
    _files = [_q for _q in _base
              if os.path.splitext(_q)[0] + '.o' not in _repl] + _arch
    if ARCH == 'x86_64':
        _files.append(os.path.join(ROOT, 'tcc-bootstrap/syscall-x86_64.s'))
    _files = sorted(set(_rel(_q) for _q in _files if '/src/complex/' not in _q))
    open(os.path.join(ROOT, 'tcc-files'), 'w').write('\n'.join(_files) + '\n')
    print('prepare-musl.py: %d musl sources to build for %s'
          % (len(_files), ARCH))

    # tcc expands @file into arguments; kaem passes a ${var} as one argument,
    # so the long flag list is kept in this response file.
    open(os.path.join(ROOT, 'tcc-cflags'), 'w').write(
        '-D_XOPEN_SOURCE=700 -I%(r)s/arch/%(a)s -I%(r)s/arch/generic'
        ' -I%(r)s/obj/src/internal -I%(r)s/src/include -I%(r)s/src/internal'
        ' -I%(r)s/obj/include -I%(r)s/include'
        ' -std=c99 -ffreestanding -DCRT -nostdinc\n'
        % {'r': '/musl-1.2.5', 'a': ARCH})

    print('prepare-musl.py: musl patched for the bootstrapped tcc (%s)' % ARCH)


if __name__ == '__main__':
    main()
