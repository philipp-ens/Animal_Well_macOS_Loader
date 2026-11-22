/* Milestone 12, game half: milestone 11 plus a check that the exe is the supported version.
 * Milestone 11: optional Steam (achievements).
 * Milestone 10: the game's shaders are translated to Metal at start-up
 * (dxbc2msl.c) instead of being read from a file made on Windows.
 *
 * Sections 1-4 as before (OS layer - now with a lock -, mapping, threads, runtime replacements).
 * Section 5a: a small software mixer. The game creates "voices", hands them decoded sound buffers and sets
 *             volume / pitch / pan; game_audio_mix() turns all playing voices into one stereo stream.
 * Section 5b: the save file is read and written for real (a .bak copy is made before the first write).
 * Section 5c: Steam, optional (achievements).
 * Section 5d: the Platform table (graphics as in milestone 7).
 * Section 6:  game_start, game_frame, game_set_key, game_audio_mix.
 */
#define _CRT_SECURE_NO_WARNINGS
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <stdarg.h>
#include <limits.h>
#include <math.h>
#include <time.h>

/* ===================================================================== 1. OS layer */
#ifdef _WIN32
#include <windows.h>
#define MSABI                               /* on Windows every function already uses this convention */
#define THREAD_LOCAL __declspec(thread)
typedef va_list ms_va_list;
#define ms_va_start va_start
#define ms_va_arg va_arg
#define ms_va_end va_end
static uint8_t *os_reserve(uint64_t want, size_t size) {
    uint8_t *p = VirtualAlloc((void *)(uintptr_t)want, size, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    if (!p) p = VirtualAlloc(NULL, size, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    return p;
}
static int os_make_executable(uint8_t *p, size_t n) { (void)p; (void)n; return 0; }
static void os_set_tls_array(void *array) { (void)array; }      /* Windows owns GS:[0x58] itself */
typedef struct { void *(*fn)(void *); void *arg; } os_start;
static DWORD WINAPI os_tramp(LPVOID p) { os_start s = *(os_start *)p; free(p); s.fn(s.arg); return 0; }
static uintptr_t os_thread_create(void *(*fn)(void *), void *arg) {
    os_start *s = malloc(sizeof *s);
    s->fn = fn; s->arg = arg;
    return (uintptr_t)CreateThread(NULL, 4 << 20, os_tramp, s, 0, NULL);
}
static void os_thread_join(uintptr_t h) { WaitForSingleObject((HANDLE)h, INFINITE); CloseHandle((HANDLE)h); }
static void os_thread_detach(uintptr_t h) { CloseHandle((HANDLE)h); }
static void os_install_crash_handler(void) {}
static CRITICAL_SECTION os_mutex;
static void os_lock_init(void) { InitializeCriticalSection(&os_mutex); }
static void os_lock(void) { EnterCriticalSection(&os_mutex); }
static void os_unlock(void) { LeaveCriticalSection(&os_mutex); }
#else
#include <sys/mman.h>
#include <pthread.h>
#include <signal.h>
#include <unistd.h>
#define MSABI __attribute__((ms_abi))       /* "call this the Windows way" */
#define THREAD_LOCAL _Thread_local
typedef __builtin_ms_va_list ms_va_list;    /* variable arguments of a Windows-convention function */
#define ms_va_start __builtin_ms_va_start
#define ms_va_arg __builtin_va_arg
#define ms_va_end __builtin_ms_va_end
static uint8_t *os_reserve(uint64_t want, size_t size) {
    void *p = mmap((void *)want, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    return p == MAP_FAILED ? NULL : (uint8_t *)p;
}
static int os_make_executable(uint8_t *p, size_t n) { return mprotect(p, n, PROT_READ | PROT_EXEC); }
static void os_set_tls_array(void *array) { __asm__ volatile("movq %0, %%gs:0x58" : : "r"(array)); }
static uintptr_t os_thread_create(void *(*fn)(void *), void *arg) {
    pthread_attr_t attr;
    pthread_t t;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 4 << 20);      /* the game expects at least 1 MB of stack */
    if (pthread_create(&t, &attr, fn, arg) != 0) return 0;
    return (uintptr_t)t;
}
static void os_thread_join(uintptr_t h) { pthread_join((pthread_t)h, NULL); }
static void os_thread_detach(uintptr_t h) { pthread_detach((pthread_t)h); }
static uint8_t *g_base_for_crash;
static void on_crash(int sig, siginfo_t *info, void *ctx) {
    uint64_t rip = ((ucontext_t *)ctx)->uc_mcontext->__ss.__rip;
    uint64_t b = (uint64_t)g_base_for_crash;
    fprintf(stderr, "\n!!! crash (signal %d) touching address %p\n", sig, info->si_addr);
    if (rip >= b && rip < b + 0x2dce000)
        fprintf(stderr, "    in game code at 0x%llx  <- look this address up in Ghidra\n",
                (unsigned long long)(rip - b + 0x140000000ULL));
    else
        fprintf(stderr, "    outside the game image, at %p\n", (void *)rip);
    _exit(1);
}
static void os_install_crash_handler(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = on_crash;
    sa.sa_flags = SA_SIGINFO;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
}
static pthread_mutex_t os_mutex = PTHREAD_MUTEX_INITIALIZER;
static void os_lock_init(void) {}
static void os_lock(void) { pthread_mutex_lock(&os_mutex); }
static void os_unlock(void) { pthread_mutex_unlock(&os_mutex); }
#endif

/* ===================================================================== 2. the mapped exe */
static uint8_t *base;                                   /* where the exe sits in memory */
#define AT(rva) (base + (rva))                          /* address of something inside it */
#define ENGINE AT(0x20dc700)                            /* engine block; its first 0x2d0 bytes = Platform */

static uint16_t rd16(const uint8_t *p) { uint16_t v; memcpy(&v, p, 2); return v; }
static uint32_t rd32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static uint64_t rd64(const uint8_t *p) { uint64_t v; memcpy(&v, p, 8); return v; }

static uint8_t *read_file(const char *path, size_t *size) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); exit(1); }
    fseek(f, 0, SEEK_END);
    *size = (size_t)ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *buf = malloc(*size);
    if (fread(buf, 1, *size, f) != *size) { fprintf(stderr, "%s: short read\n", path); exit(1); }
    fclose(f);
    return buf;
}

static uint32_t text_rva, text_size;

static void map_exe(const char *path) {                 /* milestone 3, unchanged in substance */
    size_t exe_size;
    uint8_t *exe = read_file(path, &exe_size);
    uint32_t pe = rd32(exe + 0x3c);
    if (memcmp(exe + pe, "PE\0\0", 4) != 0) { fprintf(stderr, "not a PE file\n"); exit(1); }
    uint16_t nsec = rd16(exe + pe + 6), optsize = rd16(exe + pe + 20);
    const uint8_t *opt = exe + pe + 24, *sec = opt + optsize;
    uint64_t preferred = rd64(opt + 24);
    uint32_t size_image = rd32(opt + 56), size_hdrs = rd32(opt + 60);
    uint32_t reloc_rva = rd32(opt + 112 + 5 * 8), reloc_size = rd32(opt + 112 + 5 * 8 + 4), reloc_off = 0;

    base = os_reserve(preferred, size_image);
    if (!base) { fprintf(stderr, "cannot reserve memory for the image\n"); exit(1); }
    memcpy(base, exe, size_hdrs);
    for (int i = 0; i < nsec; i++) {
        const uint8_t *s = sec + i * 40;
        uint32_t vsize = rd32(s + 8), rva = rd32(s + 12), rsize = rd32(s + 16), raw = rd32(s + 20);
        memcpy(base + rva, exe + raw, (vsize && vsize < rsize) ? vsize : rsize);
        if (memcmp(s, ".text", 6) == 0) { text_rva = rva; text_size = vsize; }
        if (rva <= reloc_rva && reloc_rva < rva + rsize) reloc_off = reloc_rva - rva + raw;
    }
    uint64_t delta = (uint64_t)(uintptr_t)base - preferred;
    if (delta != 0) {
        const uint8_t *p = exe + reloc_off, *end = p + reloc_size;
        while (p < end) {
            uint32_t page = rd32(p), block = rd32(p + 4);
            if (block == 0) break;
            for (uint32_t j = 0; j < (block - 8) / 2; j++) {
                uint16_t e = rd16(p + 8 + j * 2);
                if ((e >> 12) == 10) {
                    uint8_t *slot = base + page + (e & 0xfff);
                    uint64_t v = rd64(slot) + delta;
                    memcpy(slot, &v, 8);
                }
            }
            p += block;
        }
    }
    printf("image mapped at %p%s\n", (void *)base, delta ? " (relocated)" : " (preferred address)");
    free(exe);
}

/* ===================================================================== 2b. is this the right exe? */
/* Every address in this file (0x1bab0 = setupGame, 0x20dc700 = the engine block, the 56 runtime functions, ...)
 * is true for exactly one build of Animal Well.exe. A different build would crash at best. So the file's
 * SHA-256 fingerprint is compared with the one of the build the loader was made for. */
#define SUPPORTED_EXE_SHA256 "783ce715d09ada0faf116c5130bf768dcb3777624206d42c5ae3e6d115c84346"

static void sha256(const uint8_t *data, size_t len, uint8_t out[32]) {
    static const uint32_t k[64] = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2 };
    uint32_t h[8] = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 };
    uint64_t bits = (uint64_t)len * 8;
    size_t pos = 0;
    int padded = 0, done = 0;
    while (!done) {
        uint8_t block[64];
        size_t n = len - pos < 64 ? len - pos : 64;
        memcpy(block, data + pos, n);
        pos += n;
        if (n < 64) {                                       /* last block(s): 0x80, zeros, the length in bits */
            if (!padded) { block[n++] = 0x80; padded = 1; }
            memset(block + n, 0, 64 - n);
            if (n <= 56) {
                for (int i = 0; i < 8; i++) block[63 - i] = (uint8_t)(bits >> (8 * i));
                done = 1;
            }
        }
        uint32_t w[64], s[8];
        for (int i = 0; i < 16; i++)
            w[i] = (uint32_t)block[i * 4] << 24 | (uint32_t)block[i * 4 + 1] << 16 | (uint32_t)block[i * 4 + 2] << 8 | block[i * 4 + 3];
#define ROR(x, r) ((x) >> (r) | (x) << (32 - (r)))
        for (int i = 16; i < 64; i++)
            w[i] = w[i - 16] + (ROR(w[i - 15], 7) ^ ROR(w[i - 15], 18) ^ (w[i - 15] >> 3)) + w[i - 7] +
                   (ROR(w[i - 2], 17) ^ ROR(w[i - 2], 19) ^ (w[i - 2] >> 10));
        memcpy(s, h, sizeof s);
        for (int i = 0; i < 64; i++) {
            uint32_t t1 = s[7] + (ROR(s[4], 6) ^ ROR(s[4], 11) ^ ROR(s[4], 25)) + ((s[4] & s[5]) ^ (~s[4] & s[6])) + k[i] + w[i];
            uint32_t t2 = (ROR(s[0], 2) ^ ROR(s[0], 13) ^ ROR(s[0], 22)) + ((s[0] & s[1]) ^ (s[0] & s[2]) ^ (s[1] & s[2]));
            s[7] = s[6]; s[6] = s[5]; s[5] = s[4]; s[4] = s[3] + t1; s[3] = s[2]; s[2] = s[1]; s[1] = s[0]; s[0] = t1 + t2;
        }
#undef ROR
        for (int i = 0; i < 8; i++) h[i] += s[i];
    }
    for (int i = 0; i < 8; i++)
        for (int j = 0; j < 4; j++) out[i * 4 + j] = (uint8_t)(h[i] >> (24 - 8 * j));
}

int game_exe_supported(const char *exe_path) {
    FILE *f = exe_path ? fopen(exe_path, "rb") : NULL;
    if (!f) return 0;
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (size <= 0 || size > (200L << 20)) { fclose(f); return 0; }
    uint8_t *data = malloc((size_t)size), digest[32];
    size_t got = fread(data, 1, (size_t)size, f);
    fclose(f);
    char hex[65];
    sha256(data, got, digest);
    free(data);
    for (int i = 0; i < 32; i++) snprintf(hex + i * 2, 3, "%02x", digest[i]);
    return got == (size_t)size && strcmp(hex, SUPPORTED_EXE_SHA256) == 0;
}

/* ===================================================================== 3. per-thread set-up */
/* Game code reads a per-thread block through GS:[0x58] (milestone 2). Every thread that runs game code
 * gets: array[0] -> 16-byte block, initialised from the exe's 8-byte TLS template. */
static THREAD_LOCAL uint8_t *my_tls_block;
static THREAD_LOCAL unsigned my_thread_id;
static THREAD_LOCAL unsigned my_rand_seed = 1;
static unsigned next_thread_id = 1;

static void thread_setup(unsigned id) {
    void **array = calloc(1, sizeof(void *));
    uint8_t *block = calloc(1, 16);
    memcpy(block, AT(0x2db3000), 8);
    array[0] = block;
    os_set_tls_array(array);
    my_tls_block = block;
    my_thread_id = id;
}

/* ===================================================================== 4. runtime replacements */
/* memory */
static void *MSABI rt_malloc(size_t n) { return malloc(n ? n : 1); }
static void MSABI rt_free(void *p) { free(p); }
static void *MSABI rt_realloc(void *p, size_t n) { return realloc(p, n); }

/* math: forward to the Mac's library */
#define F1(name) static float MSABI rt_##name(float x) { return name(x); }
#define F2(name) static float MSABI rt_##name(float x, float y) { return name(x, y); }
#define D1(name) static double MSABI rt_##name(double x) { return name(x); }
#define D2(name) static double MSABI rt_##name(double x, double y) { return name(x, y); }
F1(sinf) F1(cosf) F1(atanf) F1(exp2f) F1(floorf) F1(roundf) F2(atan2f) F2(powf) F2(fmodf) F2(remainderf)
D1(sin) D1(cos) D1(exp) D1(log) D1(exp2) D1(floor) D2(pow)
static double MSABI rt_ldexp(double x, int e) { return ldexp(x, e); }

/* random numbers: Microsoft's exact formula (the game logic depends on the 0..0x7fff range) */
static int MSABI rt_rand(void) {
    my_rand_seed = my_rand_seed * 214013u + 2531011u;
    return (int)((my_rand_seed >> 16) & 0x7fff);
}
static void MSABI rt_srand(unsigned seed) { my_rand_seed = seed; }

/* qsort: the compare function is game code, so it has to be called the Windows way */
typedef int (MSABI *ms_compare)(const void *, const void *);
static void MSABI rt_qsort(void *data, size_t n, size_t size, ms_compare cmp) {
    char *a = data, tmp[256];
    if (size > sizeof tmp) { fprintf(stderr, "qsort: element too big\n"); exit(1); }
    for (size_t gap = n / 2; gap > 0; gap /= 2)            /* shell sort */
        for (size_t i = gap; i < n; i++) {
            size_t j = i;
            memcpy(tmp, a + i * size, size);
            while (j >= gap && cmp(a + (j - gap) * size, tmp) > 0) {
                memcpy(a + j * size, a + (j - gap) * size, size);
                j -= gap;
            }
            memcpy(a + j * size, tmp, size);
        }
}
static long MSABI rt_strtol(const char *s, char **end, int radix) { return strtol(s, end, radix); }
static int MSABI rt_strncmp(const char *a, const char *b, size_t n) { return strncmp(a, b, n); }

/* wide strings: the game's wchar_t is 16 bits, the Mac's is 32 - so these are written by hand */
typedef uint16_t wch;
static size_t MSABI rt_wcslen(const wch *s) { size_t n = 0; while (s[n]) n++; return n; }
static int MSABI rt_wcscmp(const wch *a, const wch *b) {
    while (*a && *a == *b) { a++; b++; }
    return (*a > *b) - (*a < *b);
}
static wch *MSABI rt_wcscpy(wch *d, const wch *s) { wch *r = d; while ((*d++ = *s++) != 0) {} return r; }
static wch *MSABI rt_wcsncpy(wch *d, const wch *s, size_t n) {
    size_t i = 0;
    for (; i < n && s[i]; i++) d[i] = s[i];
    for (; i < n; i++) d[i] = 0;
    return d;
}

/* printf family: one small formatter for 16-bit (wide = 1) and 8-bit (wide = 0) text.
 * Supports what the game uses: %d %i %u %x %c %s %ls %hs, with width and zero padding (e.g. %02d). */
typedef struct { void *buf; size_t cap, n; int wide; } sink;
static void put(sink *s, unsigned ch) {
    if (s->n + 1 < s->cap) {
        if (s->wide) ((wch *)s->buf)[s->n] = (wch)ch; else ((char *)s->buf)[s->n] = (char)ch;
    }
    s->n++;
}
static int format(sink *s, const void *fmt, ms_va_list ap) {
    const wch *wf = fmt;
    const unsigned char *nf = fmt;
    for (size_t i = 0;; i++) {
#define FMT(k) (s->wide ? (unsigned)wf[k] : (unsigned)nf[k])
        unsigned c = FMT(i);
        if (c == 0) break;
        if (c != '%') { put(s, c); continue; }
        int zero = 0, width = 0, lmod = 0, hmod = 0;
        c = FMT(++i);
        if (c == '%') { put(s, '%'); continue; }
        while (c == '0') { zero = 1; c = FMT(++i); }
        while (c >= '0' && c <= '9') { width = width * 10 + (int)(c - '0'); c = FMT(++i); }
        while (c == 'l' || c == 'h' || c == 'w') { if (c == 'h') hmod = 1; else lmod++; c = FMT(++i); }
        if (c == 0) break;
        if (c == 'd' || c == 'i' || c == 'u' || c == 'x' || c == 'X') {
            char digits[32];
            int len = 0, neg = 0;
            unsigned long long v;
            if (c == 'd' || c == 'i') {
                long long sv = lmod >= 2 ? ms_va_arg(ap, long long) : ms_va_arg(ap, int);
                neg = sv < 0;
                v = neg ? 0ULL - (unsigned long long)sv : (unsigned long long)sv;
            } else {
                v = lmod >= 2 ? ms_va_arg(ap, unsigned long long) : ms_va_arg(ap, unsigned);
            }
            unsigned radix = (c == 'x' || c == 'X') ? 16 : 10;
            do { digits[len++] = "0123456789abcdef"[v % radix]; v /= radix; } while (v);
            int pad = width - len - neg;
            if (!zero) while (pad-- > 0) put(s, ' ');
            if (neg) put(s, '-');
            if (zero) while (pad-- > 0) put(s, '0');
            while (len) put(s, (unsigned char)digits[--len]);
        } else if (c == 'c') {
            put(s, (unsigned)ms_va_arg(ap, int));
        } else if (c == 's' || c == 'S') {
            /* Microsoft rule: %s means "same kind as the format string", %ls wide, %hs narrow, %S the other kind */
            int wide_arg = c == 'S' ? !s->wide : (lmod ? 1 : (hmod ? 0 : s->wide));
            const void *str = ms_va_arg(ap, const void *);
            if (!str) str = wide_arg ? (const void *)u"(null)" : (const void *)"(null)";
            if (wide_arg) for (const wch *p = str; *p; p++) put(s, *p);
            else for (const unsigned char *p = str; *p; p++) put(s, *p);
        } else {
            put(s, c);
        }
#undef FMT
    }
    if (s->cap) {
        size_t end = s->n < s->cap ? s->n : s->cap - 1;
        if (s->wide) ((wch *)s->buf)[end] = 0; else ((char *)s->buf)[end] = 0;
    }
    return (int)s->n;
}
static int MSABI rt_swprintf(wch *buf, size_t count, const wch *fmt, ...) {
    sink s = { buf, count, 0, 1 };
    ms_va_list ap;
    ms_va_start(ap, fmt);
    int n = format(&s, fmt, ap);
    ms_va_end(ap);
    return n;
}
static int MSABI rt_sprintf(char *buf, const char *fmt, ...) {
    sink s = { buf, (size_t)1 << 20, 0, 0 };
    ms_va_list ap;
    ms_va_start(ap, fmt);
    int n = format(&s, fmt, ap);
    ms_va_end(ap);
    return n;
}

/* threads: the game starts short-lived worker threads (sound decoding at start-up, saving) */
typedef unsigned (MSABI *ms_thread_fn)(void *);
typedef struct { ms_thread_fn fn; void *arg; unsigned id; } game_thread;
typedef struct { uintptr_t handle; unsigned id; } ms_thrd;     /* what the game's std::thread stores */
static void *game_thread_main(void *p) {
    game_thread t = *(game_thread *)p;
    free(p);
    thread_setup(t.id);
    t.fn(t.arg);
    return NULL;
}
static uintptr_t MSABI rt_beginthreadex(void *security, unsigned stack, ms_thread_fn fn, void *arg,
                                        unsigned flags, unsigned *id_out) {
    (void)security; (void)stack; (void)flags;
    game_thread *t = malloc(sizeof *t);
    t->fn = fn; t->arg = arg; t->id = ++next_thread_id;
    if (id_out) *id_out = t->id;
    return os_thread_create(game_thread_main, t);
}
static int MSABI rt_thrd_join(ms_thrd *t, int *result) { os_thread_join(t->handle); if (result) *result = 0; return 0; }
static int MSABI rt_thrd_detach(ms_thrd *t) { os_thread_detach(t->handle); return 0; }
static unsigned MSABI rt_current_thread_id(void) { return my_thread_id; }

/* "initialise this static variable once" guards (they are why GS:[0x58] matters) */
static int g_epoch = INT_MIN;
static void MSABI rt_init_thread_header(int *guard) {
    if (*guard == 0) *guard = -1;                          /* caller will initialise, then call the footer */
    else if (my_tls_block) memcpy(my_tls_block + 4, &g_epoch, 4);
}
static void MSABI rt_init_thread_footer(int *guard) {
    g_epoch++;
    *guard = g_epoch;
    if (my_tls_block) memcpy(my_tls_block + 4, &g_epoch, 4);
}
static int MSABI rt_atexit(void *fn) { (void)fn; return 0; }

/* things that must never happen: say which one and stop */
#define FATAL(name) static void MSABI rt_##name(void) { fprintf(stderr, "!!! game called " #name "\n"); exit(1); }
FATAL(terminate) FATAL(throw_c_error) FATAL(throw_cpp_error) FATAL(fread) FATAL(fseek) FATAL(feof)
static void MSABI rt_wassert(const wch *msg, const wch *file, unsigned line) {
    fprintf(stderr, "!!! assertion failed: ");
    for (; *msg; msg++) fputc(*msg, stderr);
    fprintf(stderr, " at ");
    for (; *file; file++) fputc(*file, stderr);
    fprintf(stderr, ":%u\n", line);
    exit(1);
}
static void MSABI rt_fatal_error_box(const char *msg) { fprintf(stderr, "!!! fatal error box: %s\n", msg); exit(1); }

/* writing the replacements into the code: 12 bytes "mov rax, <address> ; jmp rax" at the function's start */
static void patch_jump(uint32_t rva, void *fn) {
    uint8_t code[12] = { 0x48, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xE0 };
    memcpy(code + 2, &fn, 8);
    memcpy(AT(rva), code, 12);
}
#define PATCH(rva, fn) patch_jump(rva, (void *)(uintptr_t)(fn))

static void patch_runtime(void) {
    PATCH(0x124b40, rt_malloc);  PATCH(0x104e10, rt_malloc);        /* malloc, operator new */
    PATCH(0x123750, rt_free);    PATCH(0x104e50, rt_free);          /* free, operator delete */
    PATCH(0x127520, rt_realloc);
    PATCH(0x127e00, rt_sinf);    PATCH(0x121f30, rt_cosf);   PATCH(0x1213b0, rt_atan2f);
    PATCH(0x1217b0, rt_atanf);   PATCH(0x1261f0, rt_powf);   PATCH(0x122dc0, rt_exp2f);
    PATCH(0x1231d0, rt_fmodf);   PATCH(0x127530, rt_remainderf);
    PATCH(0x123150, rt_floorf);  PATCH(0x127820, rt_roundf);
    PATCH(0x127890, rt_sin);     PATCH(0x1219b0, rt_cos);    PATCH(0x124b50, rt_pow);
    PATCH(0x122430, rt_exp);     PATCH(0x124060, rt_log);    PATCH(0x122a90, rt_exp2);
    PATCH(0x12309c, rt_floor);   PATCH(0x123ef0, rt_ldexp);
    PATCH(0x1274f0, rt_rand);    PATCH(0x1274d0, rt_srand);  PATCH(0x1270c0, rt_qsort);
    PATCH(0x128770, rt_strtol);  PATCH(0x128670, rt_strncmp);
    PATCH(0x128ba0, rt_wcslen);  PATCH(0x128b40, rt_wcscmp);
    PATCH(0x128b80, rt_wcscpy);  PATCH(0x129000, rt_wcsncpy);
    PATCH(0x013720, rt_swprintf); PATCH(0x016c50, rt_sprintf);
    PATCH(0x11f080, rt_beginthreadex);
    PATCH(0x105df0, rt_thrd_join); PATCH(0x105dd0, rt_thrd_detach);
    PATCH(0x105e60, rt_current_thread_id);
    PATCH(0x114730, rt_init_thread_header); PATCH(0x1147a0, rt_init_thread_footer);
    PATCH(0x104ef0, rt_atexit);
    PATCH(0x128b10, rt_terminate); PATCH(0x105500, rt_throw_c_error); PATCH(0x105540, rt_throw_cpp_error);
    PATCH(0x120b4c, rt_wassert);   PATCH(0x010c70, rt_fatal_error_box);
    PATCH(0x1234d0, rt_fread);     PATCH(0x123770, rt_fseek);  PATCH(0x123070, rt_feof);
    *AT(0x105d10) = 0xC3;       /* _Cnd_do_broadcast_at_thread_exit: return at once */
#ifndef _WIN32
    *AT(0x104ea0) = 0xC3;       /* __chkstk (Windows stack probe): return at once. Windows itself needs the real one. */
#endif
}


/* ===================================================================== 5a. sound: a software mixer */
/* The Windows version gives each sound its own XAudio2 "voice" on one of three buses (0 music, 2 effects) and
 * lets XAudio2 mix. Here the mixing is ~60 lines of C: for every output sample, add up every playing voice. */
#define MAX_VOICES 512
#define MIX_RATE 48000
typedef struct {
    int used, rate, bits, channels, bus;
    float volume, pitch;
    float matrix[4];            /* mono: left = s*m[0], right = s*m[1]; stereo: left = l*m[0] + r*m[1], right = l*m[2] + r*m[3] */
    const uint8_t *data;        /* the game's decoded samples (the game keeps them alive) */
    uint32_t frames;
    int loop, playing;
    double pos;                 /* read position in frames */
} voice;
static voice voices[MAX_VOICES];
static float bus_volume[8] = { 1, 1, 1, 1, 1, 1, 1, 1 }, master_volume = 1.0f;

static voice *voice_of(uint64_t handle) {
    uint64_t i = handle - 0x1000;
    return (i < MAX_VOICES && voices[i].used) ? &voices[i] : NULL;
}

static uint64_t audio_create_voice(int rate, int bits, int channels, int bus) {
    uint64_t handle = (uint64_t)-1;                     /* what the Windows version returns on failure */
    os_lock();
    for (int i = 0; i < MAX_VOICES; i++) {
        voice *v = &voices[i];
        if (v->used) continue;
        memset(v, 0, sizeof *v);
        v->used = 1; v->rate = rate; v->bits = bits; v->channels = channels; v->bus = bus & 7;
        v->volume = 1.0f; v->pitch = 1.0f;
        v->matrix[0] = 1.0f; v->matrix[1] = channels == 1 ? 1.0f : 0.0f; v->matrix[3] = 1.0f;
        handle = 0x1000 + (uint64_t)i;
        break;
    }
    os_unlock();
    return handle;
}

/* audio_play_buffer(buffer, voice): buffer = { void *data; u32 bytes; ...; u8 loop at +0x18 }.
 * Windows does Stop, Flush, Submit, Start - i.e. "restart this voice with this buffer". */
static void audio_play_buffer(const uint8_t *buffer, uint64_t handle) {
    voice *v = voice_of(handle);
    if (!v || !buffer) return;
    const uint8_t *data;
    uint32_t bytes;
    memcpy(&data, buffer, 8);
    memcpy(&bytes, buffer + 8, 4);
    os_lock();
    v->data = data;
    v->frames = bytes / (uint32_t)(v->bits / 8 * v->channels);
    v->loop = buffer[0x18] != 0;
    v->pos = 0;
    v->playing = data != NULL && v->frames > 0;
    os_unlock();
}

static void audio_stop_voice(uint64_t handle) {
    voice *v = voice_of(handle);
    if (!v) return;
    os_lock(); v->playing = 0; os_unlock();
}

/* pan 0 = left, 0.5 = centre, 1 = right (the same formulas as the Windows version) */
static void audio_set_pan(uint64_t handle, float pan) {
    voice *v = voice_of(handle);
    if (!v) return;
    if (pan > 1.0f) pan = 1.0f;
    if (pan < 0.0f) pan = 0.0f;
    float f = pan * 2.0f - 1.0f;
    os_lock();
    if (v->channels == 1) {
        v->matrix[0] = 1.0f - pan; v->matrix[1] = pan;
    } else if (f >= 0.0f) {
        v->matrix[0] = 1.0f - f; v->matrix[1] = 0.0f; v->matrix[2] = f; v->matrix[3] = 1.0f;
    } else {
        v->matrix[0] = 1.0f; v->matrix[1] = -f; v->matrix[2] = 0.0f; v->matrix[3] = f + 1.0f;
    }
    os_unlock();
}

static float sample_at(const voice *v, uint32_t frame, int channel) {
    if (v->bits == 16) {
        int16_t s;
        memcpy(&s, v->data + ((size_t)frame * (size_t)v->channels + (size_t)channel) * 2, 2);
        return (float)s / 32768.0f;
    }
    return ((float)v->data[(size_t)frame * (size_t)v->channels + (size_t)channel] - 128.0f) / 128.0f;
}

/* Fill `frames` stereo frames (interleaved left, right; floats -1..1) at 48000 Hz. Called by the audio output. */
void game_audio_mix(float *out, int frames) {
    memset(out, 0, (size_t)frames * 2 * sizeof(float));
    os_lock();
    for (int i = 0; i < MAX_VOICES; i++) {
        voice *v = &voices[i];
        if (!v->used || !v->playing) continue;
        float gain = v->volume * bus_volume[v->bus] * master_volume;
        double step = (double)v->rate * (double)v->pitch / MIX_RATE;     /* source frames per output frame */
        int right = v->channels > 1 ? 1 : 0;
        for (int n = 0; n < frames; n++) {
            if (v->pos >= (double)v->frames) {
                if (!v->loop) { v->playing = 0; break; }
                while (v->pos >= (double)v->frames) v->pos -= (double)v->frames;
            }
            uint32_t p = (uint32_t)v->pos, q = p + 1;
            float t = (float)(v->pos - (double)p);
            if (q >= v->frames) q = v->loop ? 0 : p;
            float l = sample_at(v, p, 0) * (1.0f - t) + sample_at(v, q, 0) * t;     /* linear interpolation */
            float r = right ? sample_at(v, p, 1) * (1.0f - t) + sample_at(v, q, 1) * t : l;
            if (right) {
                out[n * 2] += (l * v->matrix[0] + r * v->matrix[1]) * gain;
                out[n * 2 + 1] += (l * v->matrix[2] + r * v->matrix[3]) * gain;
            } else {
                out[n * 2] += l * v->matrix[0] * gain;
                out[n * 2 + 1] += l * v->matrix[1] * gain;
            }
            v->pos += step;
        }
    }
    os_unlock();
    for (int n = 0; n < frames * 2; n++) {                  /* keep it inside -1..1 */
        if (out[n] > 1.0f) out[n] = 1.0f;
        if (out[n] < -1.0f) out[n] = -1.0f;
    }
}

/* ===================================================================== 5b. the save file */
static char save_path[1024];

static int save_file_exists(void) {
    FILE *f = save_path[0] ? fopen(save_path, "rb") : NULL;
    if (f) fclose(f);
    return f != NULL;
}

static void save_file_read(void *buffer, size_t size) {
    FILE *f = save_path[0] ? fopen(save_path, "rb") : NULL;
    if (!f) return;
    size_t got = fread(buffer, 1, size, f);
    (void)got;
    fclose(f);
}

static void save_file_write(const void *data, size_t size) {
    char other[1100];
    if (!save_path[0]) return;
    snprintf(other, sizeof other, "%s.bak", save_path);        /* keep the file as it was before this program */
    FILE *bak = fopen(other, "rb");
    if (bak) {
        fclose(bak);
    } else {
        FILE *in = fopen(save_path, "rb");
        if (in) {
            FILE *out = fopen(other, "wb");
            char block[65536];
            size_t n;
            while (out && (n = fread(block, 1, sizeof block, in)) > 0) fwrite(block, 1, n, out);
            if (out) fclose(out);
            fclose(in);
            printf("backup of the save file written to %s\n", other);
        }
    }
    snprintf(other, sizeof other, "%s.tmp", save_path);        /* write a new file, then swap it in */
    FILE *f = fopen(other, "wb");
    if (!f) { perror(other); return; }
    size_t wrote = fwrite(data, 1, size, f);
    fclose(f);
    if (wrote != size) { fprintf(stderr, "save not written completely - old file kept\n"); remove(other); return; }
    remove(save_path);
    if (rename(other, save_path) != 0) perror("rename");
    else printf("game saved to %s\n", save_path);
}

/* ===================================================================== 5c. Steam (optional) */
/* The Windows game talks to Steam for one thing that matters: unlocking achievements by name. On the Mac the
 * same is done through Valve's own library, libsteam_api.dylib (every Steam game for the Mac contains one; it is
 * loaded from a path the user gives, it is not part of this program). Without it everything works, just without
 * Steam. Milestone 11a showed that Steam on the Mac accepts this for a game the account owns. */
#ifndef _WIN32
#include <dlfcn.h>
#include <stdbool.h>
static void *steam_lib, *steam_user_stats;
static void (*steam_run_callbacks)(void);
static void (*steam_shutdown)(void);
static bool (*steam_set_achievement)(void *stats, const char *name);
static bool (*steam_store_stats)(void *stats);
void game_steam_stop(void);                             /* defined below, used by game_steam_start */

/* Steam's functions carry a version number in their name (..._v012, _v013, ...): take the newest that exists */
static void *steam_versioned(const char *pattern) {
    char name[96];
    for (int v = 30; v >= 1; v--) {
        snprintf(name, sizeof name, pattern, v);
        void *fn = dlsym(steam_lib, name);
        if (fn) return fn;
    }
    return NULL;
}

int game_steam_start(const char *path) {
    if (!path || !path[0]) return 0;
    setenv("SteamAppId", "813230", 1);                      /* "this program is Animal Well" */
    if (!getenv("SteamGameId")) setenv("SteamGameId", "813230", 1);     /* keep Steam's own value if it started us */
    steam_lib = dlopen(path, RTLD_NOW);
    if (!steam_lib) { fprintf(stderr, "Steam: cannot load %s (%s)\n", path, dlerror()); return 0; }
    int (*init_flat)(char *) = (int (*)(char *))dlsym(steam_lib, "SteamAPI_InitFlat");
    bool (*init_old)(void) = (bool (*)(void))dlsym(steam_lib, "SteamAPI_Init");
    char message[1024] = "";
    bool ok = init_flat ? init_flat(message) == 0 : (init_old ? init_old() : false);
    if (!ok) {
        fprintf(stderr, "Steam: not connected (%s). Is Steam running and logged in?\n", message[0] ? message : "init failed");
        dlclose(steam_lib);
        steam_lib = NULL;
        return 0;
    }
    void *(*get_stats)(void) = (void *(*)(void))steam_versioned("SteamAPI_SteamUserStats_v%03d");
    steam_user_stats = get_stats ? get_stats() : NULL;
    steam_set_achievement = (bool (*)(void *, const char *))dlsym(steam_lib, "SteamAPI_ISteamUserStats_SetAchievement");
    steam_store_stats = (bool (*)(void *))dlsym(steam_lib, "SteamAPI_ISteamUserStats_StoreStats");
    steam_run_callbacks = (void (*)(void))dlsym(steam_lib, "SteamAPI_RunCallbacks");
    steam_shutdown = (void (*)(void))dlsym(steam_lib, "SteamAPI_Shutdown");
    bool (*request)(void *) = (bool (*)(void *))dlsym(steam_lib, "SteamAPI_ISteamUserStats_RequestCurrentStats");
    if (steam_user_stats && request) request(steam_user_stats);
    if (!steam_user_stats || !steam_set_achievement) {      /* an old copy of the library: of no use here */
        fprintf(stderr, "Steam: %s is too old (no achievement functions)\n", path);
        game_steam_stop();
        return 0;
    }
    printf("Steam: connected, achievements on (%s)\n", path);
    return 1;
}

void game_steam_stop(void) {
    if (steam_lib && steam_shutdown) steam_shutdown();
    steam_lib = NULL;
    steam_user_stats = NULL;
}

static void steam_frame(void) { if (steam_lib && steam_run_callbacks) steam_run_callbacks(); }

/* steam_unlock_achievement(id, name) of the Windows version: SetAchievement(name), then StoreStats */
static void steam_unlock(const char *name) {
    if (!name) return;
    if (!steam_user_stats || !steam_set_achievement) { printf("achievement %s (Steam not connected)\n", name); return; }
    bool ok = steam_set_achievement(steam_user_stats, name);
    if (ok && steam_store_stats) steam_store_stats(steam_user_stats);
    printf("achievement %s -> Steam %s\n", name, ok ? "ok" : "REFUSED");
}
#else
int game_steam_start(const char *path) { (void)path; return 0; }
void game_steam_stop(void) {}
static void steam_frame(void) {}
static void steam_unlock(const char *name) { printf("achievement %s (no Steam in the Windows test)\n", name ? name : "?"); }
#endif

/* ===================================================================== 5d. Platform table */
#include "game.h"
#include "dxbc2msl.h"

const uint8_t *game_fullscreen_quad;

/* offset in the Platform table, name (notes/platform_interface.md has every signature) */
#define SLOTS(X) \
    X(0x000, sys_get_os_language) X(0x008, sys_get_local_time) X(0x010, steam_get_persona_name) \
    X(0x018, steam_is_on_steam_deck) X(0x020, sys_print_image) X(0x028, sys_printer_available) \
    X(0x030, audio_create_voice) X(0x038, audio_alloc) X(0x040, audio_free) X(0x048, audio_play_buffer) \
    X(0x050, audio_stop_voice) \
    \
    X(0x088, audio_is_voice_playing) X(0x090, audio_is_ready) X(0x098, audio_is_ready_b) \
    X(0x0a0, pad_button_down) X(0x0a8, pad_button_pressed) X(0x0b0, pad_button_released) \
    X(0x0b8, pad_vbutton_down) X(0x0c0, pad_vbutton_pressed) X(0x0c8, pad_vbutton_released) \
    X(0x0d0, pad_set_rumble) X(0x0e8, pad_get_touch_pos) X(0x0f0, pad_get_touch_size) \
    X(0x0f8, pad_set_lightbar) X(0x100, key_down) X(0x108, key_pressed) X(0x110, key_released) \
    X(0x120, mouse_get_pos) X(0x128, pad_get_type) X(0x130, pad_get_name) \
    X(0x138, save_exists) X(0x140, write_save_file) X(0x148, read_save_file) X(0x150, delete_save_file) \
    X(0x158, gfx_create_blend_state) X(0x160, gfx_stub_08) X(0x168, gfx_register_shader) X(0x170, gfx_stub_18) \
    X(0x178, gfx_set_topology) X(0x180, gfx_create_pipeline) X(0x188, gfx_set_pipeline) X(0x190, gfx_list_set) \
    X(0x198, gfx_recreate_pipeline) X(0x1a0, gfx_clear_target) X(0x1a8, gfx_clear_backbuffer) \
    X(0x1b0, gfx_set_target) X(0x1b8, gfx_set_backbuffer_target) X(0x1c0, gfx_bind_target_texture) \
    X(0x1c8, gfx_bind_texture) X(0x1d0, gfx_create_target) X(0x1d8, gfx_create_texture) \
    X(0x1e0, gfx_update_texture) X(0x1f0, gfx_update_constant_buffer) X(0x1f8, gfx_create_constant_buffer) \
    X(0x200, gfx_bind_constant_buffer) X(0x208, gfx_draw) X(0x210, gfx_draw_fullscreen_quad) \
    X(0x218, gfx_map_vertex_buffer) X(0x220, gfx_unmap_vertex_buffer) \
    X(0x230, gfx_set_present_param) X(0x238, gfx_end_frame) X(0x240, gfx_stub_e8) X(0x248, gfx_marker_begin) \
    X(0x250, gfx_marker_end) X(0x258, gfx_get_info) \
    X(0x268, misc_00) X(0x270, misc_08) X(0x278, misc_10) X(0x280, misc_18) X(0x288, misc_20) \
    X(0x290, steam_unlock_achievement) X(0x298, steam_reset_all_stats) \
    X(0x2b0, mem_alloc) X(0x2b8, mem_free)


/* Every graphics handle the game holds is one of these. The game itself only reads the first 4 bytes, and only
 * of textures (width, height). `id` is the number the Metal half gave the thing. */
enum { OBJ_OTHER, OBJ_TEXTURE, OBJ_TARGET, OBJ_PIPELINE, OBJ_CBUFFER };
typedef struct {
    uint16_t width, height;     /* must stay first */
    int kind;
    int id;
    int pixel_shader;           /* OBJ_PIPELINE: which psNN it uses */
} gfx_object;

static gfx_object *new_object(int kind, int id, unsigned width, unsigned height) {
    gfx_object *obj = calloc(1, sizeof *obj);
    obj->kind = kind;
    obj->id = id;
    obj->width = (uint16_t)width;
    obj->height = (uint16_t)height;
    return obj;
}

/* gfx_register_shader hands over one compiled Direct3D pixel shader (bytes inside the exe). It is translated
 * to Metal's shader language on the spot (dxbc2msl.c) and added to one big source text, as the function "psNN"
 * where NN is the number this call returns - the number the game later passes to gfx_create_pipeline. */
static char *shader_source;
static size_t shader_source_len;
static unsigned shader_texture_slots[64];               /* which texture slots each shader reads (bit n = slot n) */
static int shader_count;

static void shader_source_add(const char *text) {
    size_t n = strlen(text);
    shader_source = realloc(shader_source, shader_source_len + n + 1);
    memcpy(shader_source + shader_source_len, text, n + 1);
    shader_source_len += n;
}

static int register_shader(const uint8_t *bytecode, size_t size) {
    char name[16];
    const char *error = NULL;
    if (shader_count >= 64) { fprintf(stderr, "too many shaders\n"); exit(1); }
    if (!shader_source) shader_source_add(dxbc2msl_head());
    snprintf(name, sizeof name, "ps%02d", shader_count);
    char *msl = dxbc2msl_pixel_shader(bytecode, size, name, &shader_texture_slots[shader_count], &error);
    if (!msl) { fprintf(stderr, "cannot translate shader %d: %s\n", shader_count, error); exit(1); }
    shader_source_add("\n");
    shader_source_add(msl);
    free(msl);
    return shader_count++;
}

const char *game_shader_source(void) { return shader_source ? shader_source : ""; }

static unsigned cur_texture_slots;                      /* of the pipeline that is set right now */

/* keyboard: Windows virtual-key codes (the game's own input code asks for them by number) */
static uint8_t keys_held[256], keys_tapped[256];        /* set by the window half */
static uint8_t keys_down[256], keys_pressed[256];       /* what the game sees during this frame */

void game_set_key(int vk, int down) {
    if (vk < 0 || vk > 255) return;
    keys_held[vk] = (uint8_t)down;
    if (down) keys_tapped[vk] = 1;                      /* remembered until the next frame, so a quick tap is not lost */
}

/* gamepad: the game asks with XInput button bits. The window half reports the pad once per frame. */
static int pad_connected, pad_type;
static unsigned pad_buttons, pad_buttons_prev, pad_buttons_next;
static float pad_x, pad_y, pad_x_prev, pad_y_prev, pad_x_next, pad_y_next;

void game_set_pad(int connected, int type, unsigned buttons, float stick_x, float stick_y) {
    pad_connected = connected;
    pad_type = type;
    pad_buttons_next = connected ? buttons : 0;
    pad_x_next = connected ? stick_x : 0.0f;
    pad_y_next = connected ? stick_y : 0.0f;
}

/* The game also uses the left stick as four digital "buttons": 1 up, 2 down, 4 left, 8 right.
 * Windows compares the raw stick value (-32768..32767) with 20000. */
static int stick_direction(int which, float x, float y) {
    float rx = x * 32767.0f, ry = y * 32767.0f;
    switch (which) {
    case 1: return ry > 19999.0f;
    case 2: return ry < -20000.0f;
    case 4: return rx < -20000.0f;
    case 8: return rx > 19999.0f;
    default: return 0;
    }
}

/* analog stick value as the Windows version computes it: a dead zone of 7849, the rest stretched to -1..1 */
static float stick_value(float v) {
    float raw = v * 32767.0f;
    if (raw >= 7850.0f) return (raw - 7849.0f) / 24918.0f;
    if (raw < -7849.0f) return (raw + 7849.0f) / 24919.0f;
    return 0.0f;
}

void game_set_window_size(int width, int height) {      /* engine block +0x89ffa8: int width, int height */
    if (!base || width <= 0 || height <= 0) return;
    memcpy(ENGINE + 0x89ffa8, &width, 4);
    memcpy(ENGINE + 0x89ffac, &height, 4);
}
int game_wants_fullscreen(void) { return base ? ENGINE[0x89ff6a] != 0 : 0; }   /* written by the options menu */
int game_wants_quit(void) { return base ? ENGINE[0x89ff6b] != 0 : 0; }         /* written by the main menu's "quit" */

#define OBJ(x) ((gfx_object *)(uintptr_t)(x))
#define PTR(x) ((uint64_t)(uintptr_t)(x))

static uint64_t slot_called(int off, const uint64_t *arg) {
    uint64_t a = arg[0], b = arg[1], c = arg[2], d = arg[3];
    switch (off) {
    /* ---- things that must return something real ---- */
    case 0x008: {                                               /* sys_get_local_time: packed date */
        time_t now = time(NULL);
        struct tm *t = localtime(&now);
        return (uint64_t)(t->tm_year + 1900) | (uint64_t)(t->tm_mon + 1) << 16 | (uint64_t)t->tm_mday << 24 |
               (uint64_t)t->tm_hour << 32 | (uint64_t)t->tm_min << 40 | (uint64_t)t->tm_sec << 48;
    }
    case 0x038: case 0x2b0: return PTR(malloc(a ? a : 1));      /* audio_alloc, mem_alloc */
    case 0x040: case 0x2b8: free((void *)(uintptr_t)a); return 0;   /* audio_free, mem_free */
    /* ---- sound ---- */
    case 0x030: return audio_create_voice((int)a, (int)(b & 0xffff), (int)(c & 0xffff), (int)d);
    case 0x048: audio_play_buffer((const uint8_t *)(uintptr_t)a, b); return 0;
    case 0x050: audio_stop_voice(a); return 0;
    case 0x088: { voice *v = voice_of(a); return v && v->playing; }     /* audio_is_voice_playing */
    case 0x090: case 0x098: return 0;       /* "controller speaker / haptics device ready?" - there is none */

    /* ---- save file ---- */
    case 0x138: return (uint64_t)save_file_exists();
    case 0x148: save_file_read((void *)(uintptr_t)a, (size_t)(uint32_t)b); return 0;
    case 0x140: save_file_write((const void *)(uintptr_t)a, (size_t)(uint32_t)b); return 0;

    /* ---- gamepad ---- */
    case 0x0a0: return (pad_buttons & (uint32_t)a & 0xffff) != 0;                          /* pad_button_down(bits) */
    case 0x0a8: return (pad_buttons & (uint32_t)a & 0xffff) != 0 &&
                       (pad_buttons_prev & (uint32_t)a & 0xffff) == 0;                     /* pad_button_pressed */
    case 0x0b8: return (uint64_t)stick_direction((int)(a & 0xffff), pad_x, pad_y);         /* pad_vbutton_down */
    case 0x0c0: return (uint64_t)(stick_direction((int)(a & 0xffff), pad_x, pad_y) &&
                                  !stick_direction((int)(a & 0xffff), pad_x_prev, pad_y_prev));
    case 0x128: return pad_connected ? (uint64_t)pad_type : 3;      /* pad_get_type: 3 = show keyboard keys */

    /* ---- Steam ---- */
    case 0x290: steam_unlock((const char *)(uintptr_t)b); return 0;     /* steam_unlock_achievement(id, name) */
    case 0x298: printf("(the game asked Steam to reset all stats - ignored)\n"); return 0;

    /* ---- keyboard ---- */
    case 0x100: return keys_down[a & 0xff];                     /* key_down(vk) */
    case 0x108: return keys_pressed[a & 0xff];                  /* key_pressed(vk) */

    /* ---- graphics: creating things ---- */
    case 0x1d8:                                                 /* gfx_create_texture(pixels, w, h) */
        return PTR(new_object(OBJ_TEXTURE, host_texture_create((const void *)(uintptr_t)a, (int)b, (int)c),
                              (unsigned)b, (unsigned)c));
    case 0x1e0:                                                 /* gfx_update_texture(texture, pixels, w, h) */
        if (a && OBJ(a)->kind == OBJ_TEXTURE)
            host_texture_update(OBJ(a)->id, (const void *)(uintptr_t)b, (int)c, (int)d);
        return 0;
    case 0x1d0:                                                 /* gfx_create_target(name, format, w, h, clear colour) */
        return PTR(new_object(OBJ_TARGET,
                              host_target_create((const char *)(uintptr_t)a, (int)b, (int)c, (int)d,
                                                 (const float *)(uintptr_t)arg[4]),
                              (unsigned)c, (unsigned)d));
    case 0x158:                                                 /* gfx_create_blend_state(8 numbers, name) -> number */
        return (uint64_t)host_blend_create((int)(a & 0xff), (int)b, (int)c, (int)d, (int)arg[4], (int)arg[5],
                                           (int)arg[6], (int)(arg[7] & 0xff));
    case 0x168:                                                 /* gfx_register_shader(bytecode, size, name) -> number */
        return (uint64_t)register_shader((const uint8_t *)(uintptr_t)a, (size_t)(uint32_t)b);
    case 0x180: {                                               /* gfx_create_pipeline(shader, blend, format, topology) */
        int ps = (int)(uint32_t)a;                              /* the number register_shader returned */
        gfx_object *obj = new_object(OBJ_PIPELINE, host_pipeline_create(ps, (int)b, (int)c), 0, 0);
        obj->pixel_shader = ps;
        return PTR(obj);
    }
    case 0x1f8:                                                 /* gfx_create_constant_buffer(size, name) */
        return PTR(new_object(OBJ_CBUFFER, host_cbuffer_create((int)a), 0, 0));
    case 0x1f0:                                                 /* gfx_update_constant_buffer(cb, data, size) */
        if (a) host_cbuffer_update(OBJ(a)->id, (const void *)(uintptr_t)b, (int)c);
        return 0;

    /* ---- graphics: per-frame state and draws ---- */
    case 0x218: return PTR(host_vertex_memory());               /* gfx_map_vertex_buffer: the game fills it */
    case 0x1b0: if (a) host_set_target(OBJ(a)->id); return 0;   /* gfx_set_target(target) */
    case 0x1b8: host_set_target(-1); return 0;                  /* gfx_set_backbuffer_target */
    case 0x1a0: if (a) host_clear_target(OBJ(a)->id); return 0; /* gfx_clear_target(target) */
    case 0x1a8: host_clear_target(-1); return 0;                /* gfx_clear_backbuffer */
    case 0x188:                                                 /* gfx_set_pipeline(pipeline) */
        if (a) {
            host_set_pipeline(OBJ(a)->id);
            cur_texture_slots = shader_texture_slots[OBJ(a)->pixel_shader];
        }
        return 0;
    case 0x178: host_set_topology((uint32_t)a == 1); return 0;  /* gfx_set_topology */
    case 0x1c0: case 0x1c8:                                     /* gfx_bind_(target_)texture(slot, object, flag) */
        if (b && (uint32_t)a < 10 && (OBJ(b)->kind == OBJ_TEXTURE || OBJ(b)->kind == OBJ_TARGET))
            host_bind_texture((int)a, OBJ(b)->kind == OBJ_TARGET, OBJ(b)->id);
        return 0;
    case 0x200:                                                 /* gfx_bind_constant_buffer(slot, cb) */
        if (b && (uint32_t)a < 4) host_bind_cbuffer((int)a, OBJ(b)->id);
        return 0;
    case 0x208: host_draw((int)(uint32_t)a, (int)(uint32_t)b, cur_texture_slots); return 0;     /* gfx_draw */
    case 0x210: host_draw_fullscreen(cur_texture_slots); return 0;                              /* gfx_draw_fullscreen_quad */
    default: return 0;                                          /* everything else: not needed yet */
    }
}

/* One stub per slot. They take 9 arguments because gfx_create_blend_state passes 9; for slots with fewer the
 * extra ones just hold whatever was in memory, and slot_called never looks at them. */
#define X(off, name) \
    static uint64_t MSABI stub_##name(uint64_t a, uint64_t b, uint64_t c, uint64_t d, uint64_t e, uint64_t f, \
                                      uint64_t g, uint64_t h, uint64_t i) { \
        uint64_t arg[9] = { a, b, c, d, e, f, g, h, i }; \
        return slot_called(off, arg); }
SLOTS(X)
#undef X

/* slots with float arguments or a float result need their own stubs (floats travel in different registers) */
static float MSABI stub_audio_get_voice_volume(uint64_t handle) {
    voice *v = voice_of(handle);
    return v ? v->volume : 0.0f;
}
static void MSABI stub_audio_set_voice_volume(uint64_t handle, float volume) {
    voice *v = voice_of(handle);
    if (v) { os_lock(); v->volume = volume; os_unlock(); }
}
static void MSABI stub_audio_set_voice_pitch(uint64_t handle, float ratio) {
    voice *v = voice_of(handle);
    if (v) { os_lock(); v->pitch = ratio; os_unlock(); }
}
static void MSABI stub_audio_set_voice_pan(uint64_t handle, float pan) { audio_set_pan(handle, pan); }
static void MSABI stub_audio_set_master_volume(float volume) { os_lock(); master_volume = volume; os_unlock(); }
static void MSABI stub_audio_set_bus_volume(int bus, float volume) {
    os_lock(); bus_volume[bus & 7] = volume; os_unlock();
}
static float MSABI stub_pad_stick_x(void) { return stick_value(pad_x); }
static float MSABI stub_pad_stick_y(void) { return stick_value(pad_y); }
static void MSABI stub_gfx_set_viewport(float x, float y, float w, float h) { host_set_viewport(x, y, w, h); }

static void set_slot(int off, void *fn) { memcpy(ENGINE + off, &fn, 8); }

static void fill_platform(void) {
#define X(off, name) set_slot(off, (void *)(uintptr_t)stub_##name);
    SLOTS(X)
#undef X
    set_slot(0x060, (void *)(uintptr_t)stub_audio_get_voice_volume);
    set_slot(0x058, (void *)(uintptr_t)stub_audio_set_voice_volume);
    set_slot(0x068, (void *)(uintptr_t)stub_audio_set_voice_pitch);
    set_slot(0x070, (void *)(uintptr_t)stub_audio_set_voice_pan);
    set_slot(0x078, (void *)(uintptr_t)stub_audio_set_master_volume);
    set_slot(0x080, (void *)(uintptr_t)stub_audio_set_bus_volume);
    set_slot(0x0d8, (void *)(uintptr_t)stub_pad_stick_x);
    set_slot(0x0e0, (void *)(uintptr_t)stub_pad_stick_y);
    set_slot(0x228, (void *)(uintptr_t)stub_gfx_set_viewport);
    set_slot(0x2c0, AT(0x15d0));                            /* asset_get: the exe's own code */
    set_slot(0x2c8, AT(0x1650));                            /* asset_decrypt: the exe's own code */
}

/* ===================================================================== 6. the calls the window half makes */
typedef void (MSABI *ms_void_fn)(void);
typedef void (MSABI *ms_engine_fn)(void *engine);
static uint8_t *g_game;
static uint32_t last_mode, last_menu;

void game_start(const char *exe_path, const char *sav_path, int window_width, int window_height) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (!game_exe_supported(exe_path)) {
        fprintf(stderr, "%s is not the version of Animal Well.exe this loader was made for\n", exe_path);
        exit(1);
    }
    map_exe(exe_path);
    os_lock_init();
    if (sav_path) snprintf(save_path, sizeof save_path, "%s", sav_path);
    game_fullscreen_quad = AT(0x209b600);                   /* 6 vertices: 0..320 x 0..180, uv 0..1024 x 0..2048 */
    patch_runtime();
    fill_platform();
    if (os_make_executable(AT(text_rva), (text_size + 0xfff) & ~(size_t)0xfff) != 0) { perror("mprotect"); exit(1); }
#ifndef _WIN32
    g_base_for_crash = base;
#endif
    os_install_crash_handler();
    thread_setup(1);                                        /* call game_start and game_frame from the same thread */
    /* the window size lives in the engine block (+0x89ffa8: int width, int height); the game computes the final
     * picture's position from it (largest whole multiple of 320 x 180 that fits, centred) */
    memcpy(ENGINE + 0x89ffa8, &window_width, 4);
    memcpy(ENGINE + 0x89ffac, &window_height, 4);
    ((ms_void_fn)AT(0x26b0))();                             /* the three static initialisers */
    ((ms_void_fn)AT(0x118a0))();
    ((ms_void_fn)AT(0x620e0))();
    ((ms_engine_fn)AT(0x1bab0))(ENGINE);                    /* setupGame */
    memcpy(&g_game, AT(0x2d285f8), 8);
    printf("game started (game mode %u)\n", rd32(g_game + 0x754cc));
}

void game_frame(void) {
    for (int vk = 0; vk < 256; vk++) {
        keys_pressed[vk] = keys_tapped[vk];
        keys_down[vk] = keys_held[vk] | keys_tapped[vk];
        keys_tapped[vk] = 0;
    }
    pad_buttons_prev = pad_buttons; pad_x_prev = pad_x; pad_y_prev = pad_y;
    pad_buttons = pad_buttons_next; pad_x = pad_x_next; pad_y = pad_y_next;
    steam_frame();                                          /* let Steam deliver what it has for us */
    os_lock(); master_volume = 3.0f; os_unlock();           /* the Windows frame loop sets this every frame */
    ((ms_engine_fn)AT(0x1bbb0))(ENGINE);                    /* updateGame */

    uint32_t mode = rd32(g_game + 0x754cc), menu = rd32(g_game + 0x93644);
    if (mode != last_mode || menu != last_menu) {
        printf("frame %u: game mode %u, menu %u\n", rd32(g_game + 0x46b5a0), mode, menu);
        last_mode = mode; last_menu = menu;
    }
}

#ifdef GAME_TEST_MAIN
/* Windows-only test host: no window, no GPU. It implements every host_* function as a checker that follows the
 * same rules Metal enforces, and reports what a real renderer would trip over.
 *   cl /DGAME_TEST_MAIN game.c   ->   game.exe "Animal Well.exe" AnimalWell.sav 900 -1 out.wav */
#define MAXT 64
static struct { char name[40]; int format, w, h; } t_targets[MAXT];
static int n_textures, n_targets, n_blends, n_pipelines, n_cbuffers;
static int p_format[128], p_shader[128];
static int cur_target = -1, cur_pipeline = -1, bound_is_target[10], bound_id[10];
static float vp[4];
static int win_w = 1280, win_h = 720;
static long n_draws, n_quads, n_feedback, n_format_mismatch, n_unbound, n_bad_viewport;
static uint8_t vertex_mem[4 << 20];
static int report_frame;

int host_texture_create(const void *rgba, int w, int h) { (void)rgba; (void)w; (void)h; return n_textures++; }
void host_texture_update(int t, const void *rgba, int w, int h) { (void)t; (void)rgba; (void)w; (void)h; }
int host_target_create(const char *name, int format, int w, int h, const float clear[4]) {
    (void)clear;
    strncpy(t_targets[n_targets].name, name, 39);
    t_targets[n_targets].format = format; t_targets[n_targets].w = w; t_targets[n_targets].h = h;
    return n_targets++;
}
int host_blend_create(int e, int s, int sa, int op, int opa, int d, int da, int mask) {
    printf("blend %d: enable %d colour (%d, %d, op %d) alpha (%d, %d, op %d) mask %#x\n", n_blends, e, s, d, op, sa, da, opa, mask);
    return n_blends++;
}
int host_pipeline_create(int ps, int blend, int format) {
    (void)blend;
    p_format[n_pipelines] = format; p_shader[n_pipelines] = ps;
    return n_pipelines++;
}
int host_cbuffer_create(int size) { (void)size; return n_cbuffers++; }
void host_cbuffer_update(int cb, const void *data, int size) { (void)cb; (void)data; (void)size; }
void *host_vertex_memory(void) { return vertex_mem; }
void host_set_target(int t) { cur_target = t; }
void host_clear_target(int t) { (void)t; }
void host_set_pipeline(int p) { cur_pipeline = p; }
void host_set_topology(int lines) { (void)lines; }
void host_bind_texture(int slot, int is_target, int id) { bound_is_target[slot] = is_target; bound_id[slot] = id + 1; }
void host_bind_cbuffer(int slot, int cb) { (void)slot; (void)cb; }
void host_set_viewport(float x, float y, float w, float h) { vp[0] = x; vp[1] = y; vp[2] = w; vp[3] = h; }

static void check_draw(unsigned slots, const char *what) {
    n_draws++;
    int tw = cur_target < 0 ? win_w : t_targets[cur_target].w, th = cur_target < 0 ? win_h : t_targets[cur_target].h;
    int tf = cur_target < 0 ? 0 : t_targets[cur_target].format;
    const char *tn = cur_target < 0 ? "back buffer" : t_targets[cur_target].name;
    if (cur_pipeline >= 0 && p_format[cur_pipeline] != tf) {
        if (n_format_mismatch++ < 5 || report_frame)
            printf("  FORMAT: pipeline %d (ps%02d, format %d) draws into %s (format %d)\n",
                   cur_pipeline, p_shader[cur_pipeline], p_format[cur_pipeline], tn, tf);
    }
    if (vp[0] < 0 || vp[1] < 0 || vp[0] + vp[2] > tw || vp[1] + vp[3] > th) {
        if (n_bad_viewport++ < 5 || report_frame)
            printf("  VIEWPORT: (%g, %g, %g, %g) does not fit %s (%d x %d)\n", vp[0], vp[1], vp[2], vp[3], tn, tw, th);
    }
    for (int s = 0; s < 10; s++) {
        if (!(slots & (1u << s))) continue;
        if (!bound_id[s]) {
            if (n_unbound++ < 5 || report_frame) printf("  UNBOUND: ps%02d reads slot %d, nothing bound (%s)\n", p_shader[cur_pipeline], s, what);
        } else if (bound_is_target[s] && bound_id[s] - 1 == cur_target) {
            if (n_feedback++ < 10 || report_frame)
                printf("  FEEDBACK: ps%02d reads slot %d = %s while drawing into it (%s)\n", p_shader[cur_pipeline], s, tn, what);
        }
    }
    if (report_frame)
        printf("  %-10s -> %-18s pipeline %2d ps%02d viewport (%g, %g, %g, %g)\n", what, tn, cur_pipeline,
               p_shader[cur_pipeline], vp[0], vp[1], vp[2], vp[3]);
}
void host_draw(int first, int count, unsigned slots) { (void)first; n_quads += count / 6; check_draw(slots, "draw"); }
void host_draw_fullscreen(unsigned slots) { check_draw(slots, "fullscreen"); }

int main(int argc, char **argv) {
    int frames = argc > 3 ? atoi(argv[3]) : 600;
    printf("exe check: %s; the save file as an exe: %s\n",
           game_exe_supported(argc > 1 ? argv[1] : "Animal Well.exe") ? "supported" : "NOT SUPPORTED",
           game_exe_supported(argc > 2 ? argv[2] : "") ? "supported (WRONG)" : "refused (right)");
    int show = argc > 4 ? atoi(argv[4]) : -1;               /* print every draw of this frame */
    const char *wav_path = argc > 5 ? argv[5] : NULL;
    int16_t *wav = wav_path ? malloc((size_t)frames * 800 * 2 * sizeof(int16_t)) : NULL;
    static float mix[800 * 2];
    double sum_squares = 0, peak = 0;
    long clipped = 0;
    game_start(argc > 1 ? argv[1] : "Animal Well.exe", argc > 2 ? argv[2] : NULL, 1280, 720);
    printf("%d textures, %d targets, %d blend states, %d pipelines, %d constant buffers, %d shaders "
           "(%zu bytes of Metal source)\n", n_textures, n_targets, n_blends, n_pipelines, n_cbuffers, shader_count,
           strlen(game_shader_source()));
    if (argc > 7) { FILE *sf = fopen(argv[7], "wb"); fputs(game_shader_source(), sf); fclose(sf); }
    for (int i = 0; i < frames; i++) {
        /* press A on the pad for 5 frames once a second; push the stick right in between */
        int a_down = i >= 120 && i % 60 < 5;
        game_set_pad(1, 1, a_down ? 0x1000 : 0, (i >= 300 && i % 120 < 40) ? 1.0f : 0.0f, 0.0f);
        if (i == 400) { win_w = 3456; win_h = 2234; game_set_window_size(win_w, win_h); printf("window now %d x %d\n", win_w, win_h); }
        report_frame = i == show;
        if (report_frame) printf("---- frame %d ----\n", i);
        game_frame();
        game_audio_mix(mix, 800);                               /* 1/60 s of sound at 48000 Hz */
        for (int k = 0; k < 1600; k++) {
            double s = mix[k] < 0 ? -mix[k] : mix[k];
            sum_squares += s * s;
            if (s > peak) peak = s;
            if (s >= 1.0) clipped++;
            if (wav) wav[(size_t)i * 1600 + (size_t)k] = (int16_t)(mix[k] * 32767.0f);
        }
        if (i % 120 == 119) {
            int playing = 0, used = 0;
            for (int k = 0; k < MAX_VOICES; k++) { used += voices[k].used; playing += voices[k].used && voices[k].playing; }
            printf("frame %d: %d voices, %d playing\n", i, used, playing);
        }
    }
    printf("sound: peak %.3f, rms %.4f, %ld samples at the limit\n", peak, sqrt(sum_squares / ((double)frames * 1600)), clipped);
    if (wav) {
        uint32_t bytes = (uint32_t)frames * 1600 * 2, rate = 48000, byte_rate = 48000 * 4, v32;
        uint16_t v16;
        FILE *f = fopen(wav_path, "wb");
        fwrite("RIFF", 1, 4, f); v32 = 36 + bytes; fwrite(&v32, 4, 1, f); fwrite("WAVEfmt ", 1, 8, f);
        v32 = 16; fwrite(&v32, 4, 1, f); v16 = 1; fwrite(&v16, 2, 1, f); v16 = 2; fwrite(&v16, 2, 1, f);
        fwrite(&rate, 4, 1, f); fwrite(&byte_rate, 4, 1, f); v16 = 4; fwrite(&v16, 2, 1, f); v16 = 16; fwrite(&v16, 2, 1, f);
        fwrite("data", 1, 4, f); fwrite(&bytes, 4, 1, f); fwrite(wav, 1, bytes, f); fclose(f);
        printf("sound written to %s\n", wav_path);
    }
    printf("player x %.1f, fullscreen wanted %d, quit wanted %d\n",
           (double)*(float *)(g_game + 0x93670), game_wants_fullscreen(), game_wants_quit());
    printf("%ld draws (%ld sprites) in %d frames; problems: %ld feedback, %ld format mismatches, %ld unbound slots, "
           "%ld viewports outside the target\n", n_draws, n_quads, frames, n_feedback, n_format_mismatch, n_unbound,
           n_bad_viewport);
    if (argc > 6 && strcmp(argv[6], "savetest") == 0) {         /* write the save back unchanged, twice */
        size_t size;
        uint8_t *copy = read_file(save_path, &size), *again;
        save_file_write(copy, size);
        save_file_write(copy, size);
        again = read_file(save_path, &size);
        printf("save test: %s, exists %d\n", memcmp(copy, again, size) == 0 ? "file identical after rewrite" : "FILE CHANGED",
               save_file_exists());
    }
    return 0;
}
#endif
