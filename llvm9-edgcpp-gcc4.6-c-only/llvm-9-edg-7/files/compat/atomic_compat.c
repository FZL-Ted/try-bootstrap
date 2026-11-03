/* Minimal libatomic for GCC 4.6 + EDG 5.1's C output.
   EDG emits calls to __atomic_<op>_<size>; GCC 4.6 has no libatomic (4.7+),
   so provide them on top of the __sync_* builtins GCC 4.6 does have.
   x86-64: every access up to 8 bytes is lock-free; orderings are approximated
   with full barriers (correct, merely slower). */
typedef unsigned char  u1;
typedef unsigned short u2;
typedef unsigned int   u4;
typedef unsigned long  u8;

#define EDG_ATOMIC_IMPL(SFX, T)                                                \
T __atomic_load_##SFX(const volatile void *p, int mo) {                        \
  T v; (void)mo; __sync_synchronize();                                          \
  v = *(const volatile T *)p; __sync_synchronize(); return v; }                 \
void __atomic_store_##SFX(volatile void *p, T v, int mo) {                     \
  (void)mo; __sync_synchronize(); *(volatile T *)p = v; __sync_synchronize(); } \
T __atomic_exchange_##SFX(volatile void *p, T v, int mo) {                     \
  T r; (void)mo; r = __sync_lock_test_and_set((volatile T *)p, v);             \
  __sync_synchronize(); return r; }                                             \
int __atomic_compare_exchange_##SFX(volatile void *p, void *exp, T desired,    \
                                    int weak, int so, int fo) {                 \
  T e = *(T *)exp; T o; (void)weak; (void)so; (void)fo;                         \
  o = __sync_val_compare_and_swap((volatile T *)p, e, desired);                 \
  if (o == e) return 1; *(T *)exp = o; return 0; }

EDG_ATOMIC_IMPL(1, u1)
EDG_ATOMIC_IMPL(2, u2)
EDG_ATOMIC_IMPL(4, u4)
EDG_ATOMIC_IMPL(8, u8)

#define EDG_ATOMIC_ADDSUB(SFX, T)                                              \
T __atomic_add_fetch_##SFX(volatile void *p, T v, int mo) {                    \
  (void)mo; return __sync_add_and_fetch((volatile T *)p, v); }                  \
T __atomic_fetch_add_##SFX(volatile void *p, T v, int mo) {                    \
  (void)mo; return __sync_fetch_and_add((volatile T *)p, v); }                  \
T __atomic_sub_fetch_##SFX(volatile void *p, T v, int mo) {                    \
  (void)mo; return __sync_sub_and_fetch((volatile T *)p, v); }                  \
T __atomic_fetch_sub_##SFX(volatile void *p, T v, int mo) {                    \
  (void)mo; return __sync_fetch_and_sub((volatile T *)p, v); }

EDG_ATOMIC_ADDSUB(1, u1)
EDG_ATOMIC_ADDSUB(2, u2)
EDG_ATOMIC_ADDSUB(4, u4)
EDG_ATOMIC_ADDSUB(8, u8)

#define EDG_ATOMIC_LOGIC(SFX, T)                                               \
T __atomic_fetch_and_##SFX(volatile void *p, T v, int mo) {                    \
  (void)mo; return __sync_fetch_and_and((volatile T *)p, v); }                  \
T __atomic_fetch_or_##SFX(volatile void *p, T v, int mo) {                     \
  (void)mo; return __sync_fetch_and_or((volatile T *)p, v); }                   \
T __atomic_fetch_xor_##SFX(volatile void *p, T v, int mo) {                    \
  (void)mo; return __sync_fetch_and_xor((volatile T *)p, v); }                  \
T __atomic_and_fetch_##SFX(volatile void *p, T v, int mo) {                    \
  (void)mo; return __sync_and_and_fetch((volatile T *)p, v); }                  \
T __atomic_or_fetch_##SFX(volatile void *p, T v, int mo) {                     \
  (void)mo; return __sync_or_and_fetch((volatile T *)p, v); }                   \
T __atomic_xor_fetch_##SFX(volatile void *p, T v, int mo) {                    \
  (void)mo; return __sync_xor_and_fetch((volatile T *)p, v); }

EDG_ATOMIC_LOGIC(1, u1)
EDG_ATOMIC_LOGIC(2, u2)
EDG_ATOMIC_LOGIC(4, u4)
EDG_ATOMIC_LOGIC(8, u8)

void __atomic_thread_fence(int mo) { (void)mo; __sync_synchronize(); }
void __atomic_signal_fence(int mo) { (void)mo; __sync_synchronize(); }
int  __atomic_is_lock_free(unsigned long size, const volatile void *p) {
  (void)p; return size <= sizeof(void *);
}

/* EDG 5.1 emits calls to GCC's __builtin_assume_aligned, which GCC 4.6 lacks. */
void *__builtin_assume_aligned(const void *p, unsigned long align, ...) {
  (void)align; return (void *)p;
}
