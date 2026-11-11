/* tcc runtime support for a musl built with tcc.
 *
 * tcc generates calls to a small set of 64 bit helper routines (the role
 * libgcc plays for gcc); on i386 it has no native support for 64 bit
 * division, 64 bit shifts or 64 bit <-> floating point conversion.
 *
 * This file replaces the (deliberately incomplete) kit/libtcc1.c used during
 * the pnut/tcc bootstrap with routines that are correct for the full range of
 * inputs.  It is compiled by tcc itself, so it only uses constructs tcc
 * supports and avoids calling the very routines it implements.
 */

typedef union {
    long long ll;
    struct { int low, high; } s;
} DW;

/* ---- 64 bit shifts (tcc has no native variable 64 bit shift) ---------- */

unsigned long long __lshrdi3(unsigned long long a, int b)
{
    DW u;
    u.ll = (long long)a;
    if (b >= 32) {
        u.s.low = (unsigned)u.s.high >> (b - 32);
        u.s.high = 0;
    } else if (b != 0) {
        u.s.low = ((unsigned)u.s.low >> b) | (u.s.high << (32 - b));
        u.s.high = (unsigned)u.s.high >> b;
    }
    return (unsigned long long)u.ll;
}

long long __ashrdi3(long long a, int b)
{
    DW u;
    u.ll = a;
    if (b >= 32) {
        u.s.low = u.s.high >> (b - 32);
        u.s.high = u.s.high >> 31;
    } else if (b != 0) {
        u.s.low = (u.s.low >> b) | (u.s.high << (32 - b));
        u.s.high = u.s.high >> b;
    }
    return u.ll;
}

long long __ashldi3(long long a, int b)
{
    DW u;
    u.ll = a;
    if (b >= 32) {
        u.s.high = (int)((unsigned)u.s.low << (b - 32));
        u.s.low = 0;
    } else if (b != 0) {
        u.s.high = (int)(((unsigned)u.s.high << b) | ((unsigned)u.s.low >> (32 - b)));
        u.s.low = (int)((unsigned)u.s.low << b);
    }
    return u.ll;
}

/* ---- 64 bit division ------------------------------------------------ */

static unsigned long long udivmod64(unsigned long long n, unsigned long long d,
                                    unsigned long long *rem)
{
    unsigned long long q = 0, r = 0;
    int i;

    if (d == 0) {
        if (rem) *rem = n;
        return 0;
    }
    for (i = 63; i >= 0; i--) {
        r = r + r;
        if ((n >> i) & 1ULL) r = r + 1;
        if (r >= d) {
            r = r - d;
            q = q | ((unsigned long long)1 << i);
        }
    }
    if (rem) *rem = r;
    return q;
}

unsigned long long __udivmoddi4(unsigned long long a, unsigned long long b,
                               unsigned long long *rem)
{
    return udivmod64(a, b, rem);
}

unsigned long long __udivdi3(unsigned long long a, unsigned long long b)
{
    return udivmod64(a, b, 0);
}

unsigned long long __umoddi3(unsigned long long a, unsigned long long b)
{
    unsigned long long r;
    udivmod64(a, b, &r);
    return r;
}

long long __divdi3(long long a, long long b)
{
    int neg = 0;
    unsigned long long ua, ub, q;
    if (a < 0) { neg = !neg; ua = (unsigned long long)0 - (unsigned long long)a; }
    else ua = (unsigned long long)a;
    if (b < 0) { neg = !neg; ub = (unsigned long long)0 - (unsigned long long)b; }
    else ub = (unsigned long long)b;
    q = udivmod64(ua, ub, 0);
    return neg ? (long long)((unsigned long long)0 - q) : (long long)q;
}

long long __moddi3(long long a, long long b)
{
    int neg = 0;
    unsigned long long ua, ub, r;
    if (a < 0) { neg = 1; ua = (unsigned long long)0 - (unsigned long long)a; }
    else ua = (unsigned long long)a;
    if (b < 0) ub = (unsigned long long)0 - (unsigned long long)b;
    else ub = (unsigned long long)b;
    udivmod64(ua, ub, &r);
    return neg ? (long long)((unsigned long long)0 - r) : (long long)r;
}

/* ---- floating point <-> 64 bit integer ------------------------------ */

/* the union member used for conversions is signed on purpose: a signed
 * long long <-> floating point conversion is native in tcc, an unsigned one
 * would call these very routines again. */

#define FLT_EXCESS   126
#define FLT_SIGNBIT  0x80000000
#define FLT_HIDDEN   (1 << 23)
#define FLT_EXP(f)   (((f) >> 23) & 0xFF)
#define FLT_MANT(f)  (((f) & 0x7FFFFF) | FLT_HIDDEN)

#define DBL_EXCESS   1022
#define DBL_HIDDEN   ((long long)1 << 52)
#define DBL_EXPD(f)  ((((f).w.high) >> 20) & 0x7FF)
#define DBL_MANTD(f) (((f).ll & (DBL_HIDDEN - 1)) | DBL_HIDDEN)

#define LDBL_EXCESS  16382
#define LDBL_EXPLD(f) ((f).l.upper & 0x7fff)

union float_long { float f; unsigned int l; };

union double_long {
    double d;
    long long ll;
    struct { unsigned int low; int high; } w;
};

union ldouble_long {
    long double ld;
    struct { unsigned long long lower; unsigned short upper; } l;
};

/* unsigned long long -> float/double/long double */
float __floatundisf(unsigned long long a)
{
    DW uu;
    long double r;
    uu.ll = (long long)a;
    if (uu.s.high >= 0) {
        return (float)uu.ll;
    } else {
        r = (long double)uu.ll;
        r += 4294967296.0 * 4294967296.0;
        return (float)r;
    }
}

double __floatundidf(unsigned long long a)
{
    DW uu;
    long double r;
    uu.ll = (long long)a;
    if (uu.s.high >= 0) {
        return (double)uu.ll;
    } else {
        r = (long double)uu.ll;
        r += 4294967296.0 * 4294967296.0;
        return (double)r;
    }
}

long double __floatundixf(unsigned long long a)
{
    DW uu;
    long double r;
    uu.ll = (long long)a;
    if (uu.s.high >= 0) {
        return (long double)uu.ll;
    } else {
        r = (long double)uu.ll;
        r += 4294967296.0 * 4294967296.0;
        return r;
    }
}

/* float -> unsigned/signed long long */
unsigned long long __fixunssfdi(float a1)
{
    union float_long fl;
    int exp;
    unsigned int l;
    fl.f = a1;
    if (fl.l == 0) return 0;
    exp = FLT_EXP(fl.l) - FLT_EXCESS - 24;
    l = FLT_MANT(fl.l);
    if (exp >= 41) return (unsigned long long)-1;
    else if (exp >= 0) return (unsigned long long)l << exp;
    else if (exp >= -23) return (unsigned long long)(l >> -exp);
    else return 0;
}

long long __fixsfdi(float a1)
{
    long long ret;
    int s;
    ret = (long long)__fixunssfdi((s = a1 >= 0) ? a1 : -a1);
    return s ? ret : -ret;
}

/* double -> unsigned/signed long long */
unsigned long long __fixunsdfdi(double a1)
{
    union double_long dl;
    int exp;
    unsigned long long l;
    dl.d = a1;
    if (dl.ll == 0) return 0;
    exp = DBL_EXPD(dl) - DBL_EXCESS - 53;
    l = (unsigned long long)DBL_MANTD(dl);
    if (exp >= 12) return (unsigned long long)-1;
    else if (exp >= 0) return l << exp;
    else if (exp >= -52) return l >> -exp;
    else return 0;
}

long long __fixdfdi(double a1)
{
    long long ret;
    int s;
    ret = (long long)__fixunsdfdi((s = a1 >= 0) ? a1 : -a1);
    return s ? ret : -ret;
}

/* long double -> unsigned/signed long long */
unsigned long long __fixunsxfdi(long double a1)
{
    union ldouble_long dl;
    int exp;
    unsigned long long l;
    dl.ld = a1;
    if (dl.l.lower == 0 && dl.l.upper == 0) return 0;
    exp = (int)LDBL_EXPLD(dl) - LDBL_EXCESS - 64;
    l = dl.l.lower;
    if (exp > 0) return (unsigned long long)-1;
    else if (exp >= -63) return l >> -exp;
    else return 0;
}

long long __fixxfdi(long double a1)
{
    long long ret;
    int s;
    ret = (long long)__fixunsxfdi((s = a1 >= 0) ? a1 : -a1);
    return s ? ret : -ret;
}
