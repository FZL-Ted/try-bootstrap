/* Extra libc functions missing from pnut's portable libc but referenced by
   TCC 0.9.28rc.  Used only for the pnut-built TCC bootstrap binary. */
#include <stdlib.h>
#include <setjmp.h>

char *strpbrk(const char *s, const char *accept) {
    const char *a;
    for (; *s; ++s) {
        for (a = accept; *a; ++a) {
            if (*s == *a) {
                return (char *)s;
            }
        }
    }
    return 0;
}

char *strerror(int errnum) {
    (void)errnum;
    return "error";
}

/* TCC calls longjmp() after a compiling error.  The portable libc's setjmp()
   is a stub, so error recovery is not available; exiting is acceptable for
   the bootstrap compiler. */
void longjmp(jmp_buf env, int val) {
    (void)env;
    (void)val;
    exit(1);
}
