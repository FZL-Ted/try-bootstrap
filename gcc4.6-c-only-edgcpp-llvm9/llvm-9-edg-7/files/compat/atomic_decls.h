/* Declarations for the __atomic_* entry points that EDG 5.1's C back end
   emits (GCC >= 4.7 would know them as builtins, GCC 4.6 does not).
   Used with: gcc -include atomic_decls.h -c <edg-generated>.c
   Definitions live in atomic_compat.c. */
#ifndef EDG_ATOMIC_DECLS_H
#define EDG_ATOMIC_DECLS_H
#ifdef __cplusplus
extern "C" {
#endif
unsigned char     __atomic_load_1(const volatile void *, int);
unsigned short    __atomic_load_2(const volatile void *, int);
unsigned int      __atomic_load_4(const volatile void *, int);
unsigned long     __atomic_load_8(const volatile void *, int);
void __atomic_store_1(volatile void *, unsigned char, int);
void __atomic_store_2(volatile void *, unsigned short, int);
void __atomic_store_4(volatile void *, unsigned int, int);
void __atomic_store_8(volatile void *, unsigned long, int);
unsigned char     __atomic_exchange_1(volatile void *, unsigned char, int);
unsigned short    __atomic_exchange_2(volatile void *, unsigned short, int);
unsigned int      __atomic_exchange_4(volatile void *, unsigned int, int);
unsigned long     __atomic_exchange_8(volatile void *, unsigned long, int);
int __atomic_compare_exchange_1(volatile void *, void *, unsigned char, int, int, int);
int __atomic_compare_exchange_2(volatile void *, void *, unsigned short, int, int, int);
int __atomic_compare_exchange_4(volatile void *, void *, unsigned int, int, int, int);
int __atomic_compare_exchange_8(volatile void *, void *, unsigned long, int, int, int);
unsigned int  __atomic_add_fetch_4(volatile void *, unsigned int, int);
unsigned long __atomic_add_fetch_8(volatile void *, unsigned long, int);
unsigned int  __atomic_fetch_add_4(volatile void *, unsigned int, int);
unsigned long __atomic_fetch_add_8(volatile void *, unsigned long, int);
unsigned int  __atomic_sub_fetch_4(volatile void *, unsigned int, int);
unsigned long __atomic_sub_fetch_8(volatile void *, unsigned long, int);
unsigned int  __atomic_fetch_sub_4(volatile void *, unsigned int, int);
unsigned long __atomic_fetch_sub_8(volatile void *, unsigned long, int);
unsigned char  __atomic_fetch_and_1(volatile void *, unsigned char, int);
unsigned short __atomic_fetch_and_2(volatile void *, unsigned short, int);
unsigned int   __atomic_fetch_and_4(volatile void *, unsigned int, int);
unsigned long  __atomic_fetch_and_8(volatile void *, unsigned long, int);
unsigned char  __atomic_fetch_or_1(volatile void *, unsigned char, int);
unsigned short __atomic_fetch_or_2(volatile void *, unsigned short, int);
unsigned int   __atomic_fetch_or_4(volatile void *, unsigned int, int);
unsigned long  __atomic_fetch_or_8(volatile void *, unsigned long, int);
unsigned char  __atomic_fetch_xor_1(volatile void *, unsigned char, int);
unsigned short __atomic_fetch_xor_2(volatile void *, unsigned short, int);
unsigned int   __atomic_fetch_xor_4(volatile void *, unsigned int, int);
unsigned long  __atomic_fetch_xor_8(volatile void *, unsigned long, int);

/* libc++ 9 uses GCC's *generic* __atomic_* builtins (__atomic_load(ptr, ret,
   memorder), ...); EDG emits them as plain calls, but GCC 4.6 has neither
   the builtins nor libatomic.  These macros dispatch on the pointee size to
   the size-suffixed implementations above. */
static __inline__ void __edg_atomic_load_gen(unsigned long sz, const volatile void *p, void *r, int mo) {
  switch (sz) {
    case 1: *(unsigned char *)r = __atomic_load_1(p, mo); break;
    case 2: *(unsigned short *)r = __atomic_load_2(p, mo); break;
    case 4: *(unsigned int *)r = __atomic_load_4(p, mo); break;
    case 8: *(unsigned long *)r = __atomic_load_8(p, mo); break;
    default: { unsigned long i; __sync_synchronize();
               for (i = 0; i < sz; ++i) ((unsigned char *)r)[i] = ((const volatile unsigned char *)p)[i];
               __sync_synchronize(); } break;
  }
}
static __inline__ void __edg_atomic_store_gen(unsigned long sz, volatile void *p, const void *v, int mo) {
  switch (sz) {
    case 1: __atomic_store_1(p, *(const unsigned char *)v, mo); break;
    case 2: __atomic_store_2(p, *(const unsigned short *)v, mo); break;
    case 4: __atomic_store_4(p, *(const unsigned int *)v, mo); break;
    case 8: __atomic_store_8(p, *(const unsigned long *)v, mo); break;
    default: { unsigned long i; __sync_synchronize();
               for (i = 0; i < sz; ++i) ((volatile unsigned char *)p)[i] = ((const unsigned char *)v)[i];
               __sync_synchronize(); } break;
  }
}
static __inline__ void __edg_atomic_exchange_gen(unsigned long sz, volatile void *p, const void *v, void *r, int mo) {
  switch (sz) {
    case 1: *(unsigned char *)r = __atomic_exchange_1(p, *(const unsigned char *)v, mo); break;
    case 2: *(unsigned short *)r = __atomic_exchange_2(p, *(const unsigned short *)v, mo); break;
    case 4: *(unsigned int *)r = __atomic_exchange_4(p, *(const unsigned int *)v, mo); break;
    case 8: *(unsigned long *)r = __atomic_exchange_8(p, *(const unsigned long *)v, mo); break;
    default: __edg_atomic_load_gen(sz, p, r, mo); __edg_atomic_store_gen(sz, p, v, mo); break;
  }
}
static __inline__ int __edg_atomic_cmpxchg_gen(unsigned long sz, volatile void *p, void *e,
                                               const void *d, int weak, int so, int fo) {
  switch (sz) {
    case 1: return __atomic_compare_exchange_1(p, e, *(const unsigned char *)d, weak, so, fo);
    case 2: return __atomic_compare_exchange_2(p, e, *(const unsigned short *)d, weak, so, fo);
    case 4: return __atomic_compare_exchange_4(p, e, *(const unsigned int *)d, weak, so, fo);
    case 8: return __atomic_compare_exchange_8(p, e, *(const unsigned long *)d, weak, so, fo);
    default: { unsigned long i; int ok = 1; __sync_synchronize();
               for (i = 0; i < sz; ++i) if (((unsigned char *)e)[i] != ((const volatile unsigned char *)p)[i]) ok = 0;
               if (ok) { for (i = 0; i < sz; ++i) ((volatile unsigned char *)p)[i] = ((const unsigned char *)d)[i]; }
               else { for (i = 0; i < sz; ++i) ((unsigned char *)e)[i] = ((const volatile unsigned char *)p)[i]; }
               __sync_synchronize(); return ok; }
  }
}
#define __atomic_load(p, r, mo)                __edg_atomic_load_gen(sizeof(*(p)), (p), (r), (mo))
#define __atomic_store(p, v, mo)               __edg_atomic_store_gen(sizeof(*(p)), (p), (v), (mo))
#define __atomic_exchange(p, v, r, mo)         __edg_atomic_exchange_gen(sizeof(*(p)), (p), (v), (r), (mo))
#define __atomic_compare_exchange(p, e, d, w, so, fo) \
        __edg_atomic_cmpxchg_gen(sizeof(*(p)), (p), (e), (d), (w), (so), (fo))
#define __atomic_fetch_add(p, v, mo)   ((sizeof(*(p)) == 1) ? (unsigned char)__atomic_fetch_add_1((volatile void *)(p), (unsigned char)(v), (mo)) : \
                                        (sizeof(*(p)) == 2) ? (unsigned short)__atomic_fetch_add_2((volatile void *)(p), (unsigned short)(v), (mo)) : \
                                        (sizeof(*(p)) == 4) ? __atomic_fetch_add_4((volatile void *)(p), (unsigned int)(v), (mo)) : \
                                                              __atomic_fetch_add_8((volatile void *)(p), (unsigned long)(v), (mo)))
#define __atomic_fetch_sub(p, v, mo)   ((sizeof(*(p)) == 1) ? (unsigned char)__atomic_fetch_sub_1((volatile void *)(p), (unsigned char)(v), (mo)) : \
                                        (sizeof(*(p)) == 2) ? (unsigned short)__atomic_fetch_sub_2((volatile void *)(p), (unsigned short)(v), (mo)) : \
                                        (sizeof(*(p)) == 4) ? __atomic_fetch_sub_4((volatile void *)(p), (unsigned int)(v), (mo)) : \
                                                              __atomic_fetch_sub_8((volatile void *)(p), (unsigned long)(v), (mo)))
#define __atomic_fetch_and(p, v, mo)   ((sizeof(*(p)) == 1) ? (unsigned char)__atomic_fetch_and_1((volatile void *)(p), (unsigned char)(v), (mo)) : \
                                        (sizeof(*(p)) == 2) ? (unsigned short)__atomic_fetch_and_2((volatile void *)(p), (unsigned short)(v), (mo)) : \
                                        (sizeof(*(p)) == 4) ? __atomic_fetch_and_4((volatile void *)(p), (unsigned int)(v), (mo)) : \
                                                              __atomic_fetch_and_8((volatile void *)(p), (unsigned long)(v), (mo)))
#define __atomic_fetch_or(p, v, mo)    ((sizeof(*(p)) == 1) ? (unsigned char)__atomic_fetch_or_1((volatile void *)(p), (unsigned char)(v), (mo)) : \
                                        (sizeof(*(p)) == 2) ? (unsigned short)__atomic_fetch_or_2((volatile void *)(p), (unsigned short)(v), (mo)) : \
                                        (sizeof(*(p)) == 4) ? __atomic_fetch_or_4((volatile void *)(p), (unsigned int)(v), (mo)) : \
                                                              __atomic_fetch_or_8((volatile void *)(p), (unsigned long)(v), (mo)))
#define __atomic_fetch_xor(p, v, mo)   ((sizeof(*(p)) == 1) ? (unsigned char)__atomic_fetch_xor_1((volatile void *)(p), (unsigned char)(v), (mo)) : \
                                        (sizeof(*(p)) == 2) ? (unsigned short)__atomic_fetch_xor_2((volatile void *)(p), (unsigned short)(v), (mo)) : \
                                        (sizeof(*(p)) == 4) ? __atomic_fetch_xor_4((volatile void *)(p), (unsigned int)(v), (mo)) : \
                                                              __atomic_fetch_xor_8((volatile void *)(p), (unsigned long)(v), (mo)))

void __atomic_thread_fence(int);
void __atomic_signal_fence(int);
int  __atomic_is_lock_free(unsigned long, const volatile void *);
#ifdef __cplusplus
}
#endif
#endif

/* GCC 4.6 has no __builtin_assume_aligned; EDG emits it as a plain call. */
void *__builtin_assume_aligned(const void *, unsigned long, ...);
