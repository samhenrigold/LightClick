// Checks what the QEMU accelerator relies on, without QEMU: a split RAM map with a hole, single instructions run by
// "the host" (the harness plays TCG, by advancing rip and changing registers), state written back at each, writes
// behind the monitor's back, CR0.TS, level-triggered interrupts. Each fallback site loads r13 with an action and r14
// with the instruction's length, so the harness never has to decode x86.
#include <stdbool.h>
#include <stdint.h>

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;

#define PHYSMAP 0xFFFF880000000000ULL
#define PHYS(gpa) ((volatile u64 *)(PHYSMAP + (gpa)))
#define HIGH (1ULL << 32) // first RAM above the hole
#define HOLE (2ULL << 30)
#define MARKED 0xA0000ULL // RAM behind it, device in front
#define MAILBOX PHYS(0x3000)
#define PRESENT_RW 3ULL

static inline void outb(u16 port, u8 v) { __asm__ volatile("outb %0, %1" : : "a"(v), "Nd"(port)); }
static inline void outl(u16 port, u32 v) { __asm__ volatile("outl %0, %1" : : "a"(v), "Nd"(port)); }
static inline u64 rdtsc(void) {
    u32 a, d;
    __asm__ volatile("rdtsc" : "=a"(a), "=d"(d));
    return (u64)d << 32 | a;
}
static void puts_(const char *s) {
    while (*s)
        outb(0xE9, (u8)*s++);
}
static void command(u32 n) { outl(0xF8, n); }
static void done(u32 code) {
    outl(0xF4, code);
    for (;;)
        ;
}
#define CHECK(x)                                                                                                       \
    do {                                                                                                               \
        if (!(x)) {                                                                                                    \
            puts_("FAIL: " #x "\n");                                                                                   \
            done(1);                                                                                                   \
        }                                                                                                              \
    } while (0)

static u64 gdt[8] __attribute__((aligned(16))) = {0, 0x00AF9A000000FFFFULL, 0x00CF92000000FFFFULL};
typedef struct {
    u16 off0, sel;
    u8 ist, attr;
    u16 off1;
    u32 off2, r;
} __attribute__((packed)) Gate;
static Gate idt[256] __attribute__((aligned(16)));
volatile u64 nm_count, irq_count, bad_vector;

volatile u64 fp_model, fp_live;

__asm__(".text\n"
        "_nm_stub:\n"
        "  cmpq $0, _fp_model(%rip)\n"
        "  jne 7f\n"
        "  pushq %rax\n"
        "  incq _nm_count(%rip)\n"
        "  movq %cr0, %rax\n"
        "  andq $~8, %rax\n"
        "  movq %rax, %cr0\n"
        "  popq %rax\n"
        "  iretq\n"
        // The lazy FP model of the test below: what a kernel's trap does with state it holds, what it does on the way
        // out of an interrupt.
        "7: pushq %rax\n pushq %rcx\n pushq %rdx\n pushq %rsi\n pushq %rdi\n"
        "  pushq %r8\n pushq %r9\n pushq %r10\n pushq %r11\n"
        "  call _lazy_nm\n"
        "  popq %r11\n popq %r10\n popq %r9\n popq %r8\n"
        "  popq %rdi\n popq %rsi\n popq %rdx\n popq %rcx\n popq %rax\n"
        "  iretq\n"
        "_irq_stub:\n"
        "  incq _irq_count(%rip)\n"
        "  cmpq $0, _fp_model(%rip)\n"
        "  je 9f\n"
        "  pushq %rax\n"
        "  cmpq $0, _fp_live(%rip)\n"
        "  je 8f\n"
        "  clts\n"
        "  jmp 6f\n"
        "8: movq %cr0, %rax\n"
        "  orq $8, %rax\n"
        "  movq %rax, %cr0\n"
        "6: popq %rax\n"
        "9: iretq\n"
        "_bad_stub:\n"
        "  movq $1, _bad_vector(%rip)\n"
        "  hlt\n");
extern char nm_stub[] __asm__("_nm_stub"), irq_stub[] __asm__("_irq_stub"), bad_stub[] __asm__("_bad_stub");

static void gate(int v, void *h) {
    u64 a = (u64)h;
    idt[v] = (Gate){(u16)a, 8, 0, 0x8E, (u16)(a >> 16), (u32)(a >> 32), 0};
}

static void tables(void) {
    struct {
        u16 limit;
        u64 base;
    } __attribute__((packed)) g = {sizeof gdt - 1, (u64)gdt}, i = {sizeof idt - 1, (u64)idt};
    __asm__ volatile("lgdt %0\n lidt %1" : : "m"(g), "m"(i));
    for (int v = 0; v < 32; v++)
        gate(v, bad_stub);
    gate(7, nm_stub);
    gate(0x40, irq_stub);
}

// Harness actions: 1 sets rbx to 0x1234; 2 clears CR0.TS; 3 returns far: rip from r11, cs from r10, pops two; 4
// switches cr3 to r12; 5 sets rax to 7.

// ---- Memory above the hole: tables, data and code ----
static u64 next_frame = HIGH + (64 << 20);
static u64 frame(void) {
    u64 f = next_frame;
    next_frame += 4096;
    for (int i = 0; i < 512; i++)
        PHYS(f)[i] = 0;
    return f;
}

static u64 *pte_of(u64 root, u64 va) {
    u64 t = root;
    for (int level = 3; level > 0; level--) {
        volatile u64 *e = &PHYS(t)[(va >> (12 + 9 * level)) & 0x1ff];
        if (!(*e & 1))
            *e = frame() | PRESENT_RW;
        t = *e & 0x000FFFFFFFFFF000ULL;
    }
    return (u64 *)&PHYS(t)[(va >> 12) & 0x1ff];
}

static u64 read_cr3(void) {
    u64 v;
    __asm__ volatile("mov %%cr3, %0" : "=r"(v));
    return v;
}
static void write_cr3(u64 v) { __asm__ volatile("mov %0, %%cr3" : : "r"(v)); }

// A new root sharing everything but what callers map: a table page and its contents above 4 GB.
static u64 root_copy(u64 from) {
    u64 r = frame();
    for (int i = 0; i < 512; i++)
        PHYS(r)[i] = PHYS(from)[i];
    return r;
}

#define TEST_VA 0x0000200000000000ULL

static void put_function(u64 gpa, u32 value) {
    // mov eax, imm32; ret
    volatile u8 *p = (volatile u8 *)PHYS(gpa);
    p[0] = 0xB8;
    *(volatile u32 *)(p + 1) = value;
    p[5] = 0xC3;
}

static void test_ram_map(u64 root) {
    CHECK(*PHYS(HIGH + 0x1000) == 0x1122334455667788ULL); // seeded by the host
    *PHYS(HIGH + 0x2000) = 0xAABBCCDDEEFF0011ULL;
    command(1); // the host checks it where it expects it
    // Below the top of RAM but in the hole, and a low page marked as a device.
    CHECK(*PHYS(HOLE + 0x40) == (HOLE + 0x40) * 3);
    *PHYS(HOLE + 0x48) = 77;
    CHECK(MAILBOX[0] == 77);
    CHECK(*PHYS(MARKED) == MARKED * 3);
    // Tables, code and data all in high frames.
    u64 root2 = root_copy(root);
    write_cr3(root2);
    u64 code = frame();
    put_function(code, 41);
    *pte_of(root2, TEST_VA) = code | PRESENT_RW;
    CHECK(((u32 (*)(void))TEST_VA)() == 41);
    write_cr3(root);
}

static void test_fallback_state(void) {
    // Everything the instruction did not touch survives the trip through the host, flags included.
    u64 rbx = 0, r15 = 0xF15F15F15F15F15ULL, flags = 0,
        xmm[2] __attribute__((aligned(16))) = {0x0123456789ABCDEFULL, 0xFEDCBA9876543210ULL},
        back[2] __attribute__((aligned(16)));
    __asm__ volatile("movaps %[xi], %%xmm15\n"
                     "stc\n"
                     "mov $1, %%r13\n mov $5, %%r14\n"
                     ".byte 0x66, 0x0F, 0x38, 0x41, 0xC1\n" // phminposuw xmm0, xmm1: the decoder has no SSE4 and #UD is
                                                            // not its call to make
                     "pushfq\n popq %[fl]\n"
                     "movaps %%xmm15, %[xo]\n"
                     : "=b"(rbx), [fl] "=r"(flags), [xo] "=m"(back), "+r"(r15)
                     : [xi] "m"(xmm)
                     : "r13", "r14", "xmm0", "xmm15", "cc");
    CHECK(rbx == 0x1234);
    CHECK(flags & 1);
    CHECK(r15 == 0xF15F15F15F15F15ULL);
    CHECK(back[0] == xmm[0] && back[1] == xmm[1]);

    // Other kinds of stop: x87, far return, an MSR the APIC owns, hlt, cr8.
    __asm__ volatile("mov $0, %%r13\n mov $2, %%r14\n .byte 0xD9, 0xFF\n" : : : "r13", "r14"); // fninit
    __asm__ volatile("mov $0, %%r13\n mov $1, %%r14\n hlt\n" : : : "r13", "r14");
    u64 rax = 0;
    __asm__ volatile("mov $5, %%r13\n mov $4, %%r14\n mov %%cr8, %%rax\n" : "=a"(rax) : : "r13", "r14");
    CHECK(rax == 7);
    __asm__ volatile("mov $5, %%r13\n mov $2, %%r14\n mov $0x1B, %%ecx\n rdmsr\n"
                     : "=a"(rax)
                     :
                     : "r13", "r14", "rcx", "rdx");
    CHECK(rax == 7);
    __asm__ volatile("mov $0, %%r13\n mov $2, %%r14\n mov $0x6E0, %%ecx\n xor %%eax, %%eax\n xor %%edx, %%edx\n wrmsr\n"
                     :
                     :
                     : "r13", "r14", "rcx", "rax", "rdx");
    rax = 1;
    __asm__ volatile("mov $5, %%r13\n mov $5, %%r14\n .byte 0xF3, 0x48, 0x0F, 0xB8, 0xC1\n"
                     : "=a"(rax)
                     :
                     : "r13", "r14"); // popcnt rax, rcx
    CHECK(rax == 7);
    // lretq, played by the host: it takes the target from r11 and CS from r10.
    rax = 0;
    __asm__ volatile("mov $3, %%r13\n mov $0, %%r14\n"
                     "lea 1f(%%rip), %%r11\n mov $8, %%r10\n"
                     "pushq $8\n pushq %%r11\n"
                     ".byte 0x48, 0xCB\n"
                     "ud2\n"
                     "1: mov $9, %%eax\n"
                     : "=a"(rax)
                     :
                     : "r10", "r11", "r13", "r14");
    CHECK(rax == 9);
    // SIMD to a device: an MMIO form the monitor cannot complete. The instruction is in the host's hands, nothing has
    // happened yet.
    u64 *hole = (u64 *)PHYS(HOLE + 0x80);
    __asm__ volatile("xor %%ebx, %%ebx\n mov $1, %%r13\n mov $4, %%r14\n .byte 0x0F, 0x10, 0x00, 0x90\n"
                     : "=b"(rbx)
                     : "a"(hole)
                     : "r13", "r14", "xmm0");
    CHECK(rbx == 0x1234);
}

static void test_host_changes_cr3(u64 root) {
    u64 root2 = root_copy(root);
    u64 a = frame(), b = frame();
    PHYS(a)[0] = 0xAAAA;
    PHYS(b)[0] = 0xBBBB;
    *pte_of(root, TEST_VA + 0x10000) = a | PRESENT_RW;
    *pte_of(root2, TEST_VA + 0x10000) = b | PRESENT_RW;
    CHECK(*(volatile u64 *)(TEST_VA + 0x10000) == 0xAAAA);
    __asm__ volatile("mov %0, %%r12\n mov $4, %%r13\n mov $3, %%r14\n .byte 0x0F, 0x00, 0xE0\n"
                     :
                     : "r"(root2)
                     : "r12", "r13", "r14"); // verr ax
    CHECK(read_cr3() == root2);
    CHECK(*(volatile u64 *)(TEST_VA + 0x10000) == 0xBBBB);
    write_cr3(root);
}

// Writes made by a device or TCG reach code and tables with no trap in the monitor.
static void test_notes(u64 root) {
    u64 code = frame();
    put_function(code, 1);
    *pte_of(root, TEST_VA + 0x20000) = code | PRESENT_RW;
    u32 (*f)(void) = (u32 (*)(void))(TEST_VA + 0x20000);
    CHECK(f() == 1);
    MAILBOX[1] = code + 1;
    MAILBOX[2] = 2;
    command(2); // writes the 32-bit value at the GPA, notes it
    CHECK(f() == 2);

    u64 *slot = pte_of(root, TEST_VA + 0x30000);
    u64 a = frame(), b = frame();
    PHYS(a)[0] = 0xA;
    PHYS(b)[0] = 0xB;
    *slot = a | PRESENT_RW;
    volatile u64 *p = (volatile u64 *)(TEST_VA + 0x30000);
    CHECK(*p == 0xA);
    MAILBOX[1] = (u64)slot - PHYSMAP;
    MAILBOX[2] = b | PRESENT_RW;
    command(3); // writes the 64-bit value at the GPA, notes it
    CHECK(*p == 0xB);
    command(7); // with so many notes that the ring overflows: everything marked is still handled
    MAILBOX[1] = code + 1;
    MAILBOX[2] = 3;
    command(2);
    CHECK(f() == 3);
}

static void test_ts(void) {
    u64 cr0;
    __asm__ volatile("mov %%cr0, %0" : "=r"(cr0));
    __asm__ volatile("mov %0, %%cr0" : : "r"(cr0 | 8));
    __asm__ volatile("movaps %%xmm1, %%xmm0" : : : "xmm0");
    CHECK(nm_count == 1); // the handler cleared TS and the instruction ran
    __asm__ volatile("mov %0, %%cr0" : : "r"(cr0 | 8));
    // A kernel's bcopy with TS set: nothing x86 touched SIMD, so no #NM.
    static u64 from[64], to[64];
    for (int i = 0; i < 64; i++)
        from[i] = (u64)i * 3;
    u64 count = 64;
    u64 *s = from, *d = to;
    __asm__ volatile("cld\n rep movsq" : "+S"(s), "+D"(d), "+c"(count) : : "memory");
    for (int i = 0; i < 64; i++)
        CHECK(to[i] == (u64)i * 3);
    d = to;
    count = 64;
    __asm__ volatile("rep stosq" : "+D"(d), "+c"(count) : "a"(5ULL) : "memory");
    CHECK(to[63] == 5);
    CHECK(nm_count == 1);
    u32 m;
    __asm__ volatile("stmxcsr %0" : "=m"(m));
    CHECK(nm_count == 2);
    // clts, in the host's hands: the monitor must notice TS went away.
    __asm__ volatile("mov %0, %%cr0" : : "r"(cr0 | 8));
    __asm__ volatile("mov $2, %%r13\n mov $2, %%r14\n .byte 0x0F, 0x06\n" : : : "r13", "r14");
    __asm__ volatile("movaps %%xmm1, %%xmm0" : : : "xmm0");
    CHECK(nm_count == 2);
}

static void test_level_interrupts(void) {
    __asm__ volatile("cli");
    MAILBOX[1] = 0;
    command(4); // raises the line, kicks: IF is clear, so the vector must stay in the APIC
    for (volatile int i = 0; i < 1000; i++)
        ;
    command(5); // the harness checks it was not acknowledged
    CHECK(irq_count == 0);
    __asm__ volatile("sti\n nop");
    CHECK(irq_count == 1);
    // sti; hlt with one waiting does not sleep.
    __asm__ volatile("cli");
    command(4);
    __asm__ volatile("mov $0, %%r13\n mov $1, %%r14\n sti\n hlt\n" : : : "r13", "r14");
    CHECK(irq_count == 2);
}

static void test_tsc(void) {
    u64 a = rdtsc();
    CHECK(a > 1ULL << 50);
    command(6); // sleeps, measures
    MAILBOX[1] = rdtsc() - a;
    command(8); // checks the rate is 1.2 GHz, as set
}

// Boundary stops land anywhere in here, each a full state round trip with the monitor resyncing.
static void test_busy(void) {
    u64 sum = 0, cf_seen = 0;
    for (u64 i = 1; i <= 40000000; i++) {
        u64 carry;
        __asm__ volatile("add %2, %0\n sbb %1, %1" : "+r"(sum), "=r"(carry) : "r"(i) : "cc");
        cf_seen += carry & 1;
    }
    CHECK(sum == 40000000ULL * 40000001ULL / 2);
    CHECK(cf_seen == 0);
}

// XNU turns on MCE among its first acts, and nothing here needs to care: it must not stop.
static void test_cr4(void) {
    u64 cr4;
    __asm__ volatile("mov %%cr4, %0" : "=r"(cr4));
    __asm__ volatile("mov %0, %%cr4" : : "r"(cr4 | 0x40 | 0x100));
    u64 back;
    __asm__ volatile("mov %%cr4, %0" : "=r"(back));
    CHECK(back == (cr4 | 0x40 | 0x100));
}

#ifndef CHURN_ROUNDS
#define CHURN_ROUNDS 2
#endif
#define CHURN_TABLES 200
#define CHURN_VA 0x0000300000000000ULL
// More address spaces than views, each with hundreds of shadow tables: the shape of a real boot's EL1 fault, in a root
// built by an eviction. This did not reproduce that fault, even at 800 tables over 2880 evictions, so it guards
// eviction in general and not the barrier in view_build.
static void test_view_churn(u64 root) {
    static u64 roots[72];
    u64 data = frame();
    for (int i = 0; i < CHURN_TABLES; i++)
        *pte_of(root, CHURN_VA + ((u64)i << 21)) = data | PRESENT_RW;
    for (int i = 0; i < 72; i++)
        roots[i] = root_copy(root);
    for (int round = 0; round < CHURN_ROUNDS; round++)
        for (int i = 0; i < 72; i++) {
            write_cr3(roots[i]);
            for (int t = 0; t < CHURN_TABLES; t++)
                *(volatile u64 *)(CHURN_VA + ((u64)t << 21)) = (u64)t;
        }
    write_cr3(root);
    CHECK(PHYS(data)[0] == CHURN_TABLES - 1);
}

// The VMware backdoor reads the CPU's registers in its device model: it has to run where those are.
static void test_vmport(void) {
    u64 rax = 0;
    __asm__ volatile("mov $5, %%r13\n mov $1, %%r14\n mov $0x5658, %%dx\n inl %%dx, %%eax\n"
                     : "=a"(rax)
                     :
                     : "r13", "r14", "rdx");
    CHECK(rax == 7);
}

// A write to PM1a_CNT is how a guest powers off, so its size and value had better be what the instruction says, with
// the rest of rax not leaking in.
static void test_port_forms(void) {
    __asm__ volatile("mov $0xA5A50000, %%rax\n or $0x2000, %%rax\n mov $0x604, %%dx\n outw %%ax, %%dx"
                     :
                     :
                     : "rax", "rdx");
    __asm__ volatile("mov $0xA5A50020, %%rax\n mov $0x605, %%dx\n outb %%al, %%dx" : : : "rax", "rdx");
    __asm__ volatile("mov $0xA5A50006, %%rax\n outb %%al, $0x70" : : : "rax");
    __asm__ volatile("mov $0x12345678, %%rax\n mov $0x608, %%dx\n outl %%eax, %%dx" : : : "rax", "rdx");
    command(9); // the host checks what it saw
}

// ---- Two tasks' FP state under lazy switching, as XNU does it: xmm in both, the x87 stack in one and MMX in the other ----
// The state lives only in xmm registers, so C here mustn't use them: this file is built without implicit float.
#define LAZY_STEPS 2000000
typedef struct {
    u8 *area; // fxsave image, in the physmap
    u64 steps;
    bool saved;
    u64 result[12];
} Task;
static Task tasks[2];
static volatile int lazy_current;
static volatile u64 lazy_nm_count;
static const u8 byte_swap[16] __attribute__((aligned(16))) = {3, 2, 1, 0, 7, 6, 5, 4, 11, 10, 9, 8, 15, 14, 13, 12};

// Each task's own rounding and precision, so that a mix-up changes the numbers. Every 16th step: costs a monitor call or several.
static const u16 task_cw[2] = {0xA7F, 0x77F};
static inline void task_fp_seed(int n) {
    __asm__ volatile("fninit\n" : : : "memory");
    if (n == 0)
        __asm__ volatile("fldcw (%0)\n fld1\n fldpi\n" : : "r"(&task_cw[n]) : "memory");
    else
        __asm__ volatile("movq %0, %%mm3\n movq %0, %%mm6\n" : : "r"(0x0102030405060708ULL) : "memory");
}
static inline void task_fp_step(int n, u64 step) {
    if (step & 15)
        return;
    if (n == 0)
        __asm__ volatile("fadd %%st(1), %%st\n fsqrt\n fxch\n fld1\n faddp\n fxch\n" : : : "memory");
    else
        __asm__ volatile("movq %0, %%mm2\n paddq %%mm2, %%mm3\n pxor %%mm3, %%mm6\n psllq $1, %%mm3\n" : : "r"(step) : "memory");
}
static void task_fp_read(int n, u64 *out) {
    if (n == 0)
        __asm__ volatile("fld %%st(0)\n fstpt (%0)\n fld %%st(1)\n fstpt 16(%0)\n fnstcw 32(%0)\n" : : "r"(out) : "memory");
    else
        __asm__ volatile("movq %%mm3, (%0)\n movq %%mm6, 16(%0)\n" : : "r"(out) : "memory");
}

static void task_seed(u64 seed) {
    __asm__ volatile("pxor %%xmm0, %%xmm0\n pxor %%xmm1, %%xmm1\n pxor %%xmm2, %%xmm2\n pxor %%xmm3, %%xmm3\n"
                     "pxor %%xmm4, %%xmm4\n pxor %%xmm5, %%xmm5\n pxor %%xmm6, %%xmm6\n pxor %%xmm8, %%xmm8\n pxor "
                     "%%xmm15, %%xmm15\n"
                     "movq %0, %%xmm0\n movq %0, %%xmm8\n"
                     :
                     : "r"(seed));
}
// Shapes of a SHA-1 round: pshufb, palignr, shuffles, integer adds, xor. No clobbers on purpose: the registers carry
// state from one call to the next.
static inline void task_step(u64 a, u64 b) {
    u64 message[2] __attribute__((aligned(16))) = {a, b};
    __asm__ volatile("movdqu (%0), %%xmm7\n pshufb (%1), %%xmm7\n paddd %%xmm7, %%xmm0\n movdqa %%xmm0, %%xmm3\n "
                     "palignr $4, %%xmm1, %%xmm3\n"
                     "movdqa %%xmm3, %%xmm1\n pxor %%xmm1, %%xmm2\n pshufd $0x39, %%xmm2, %%xmm3\n paddd %%xmm3, "
                     "%%xmm4\n pxor %%xmm4, %%xmm5\n"
                     "movdqa %%xmm5, %%xmm6\n palignr $8, %%xmm0, %%xmm6\n paddq %%xmm6, %%xmm0\n pxor %%xmm0, "
                     "%%xmm8\n paddd %%xmm8, %%xmm15\n"
                     :
                     : "r"(message), "r"(byte_swap)
                     : "memory");
}
static void task_read(u64 *out) {
    __asm__ volatile("movups %%xmm0, (%0)\n movups %%xmm5, 16(%0)\n movups %%xmm15, 32(%0)\n" : : "r"(out) : "memory");
}
// #NM: load this task's state. Runs on the task's stack, with interrupts off through the gate.
void lazy_nm(void) {
    Task *t = &tasks[lazy_current];
    lazy_nm_count++;
    __asm__ volatile("clts");
    if (t->saved)
        __asm__ volatile("fxrstor64 (%0)" : : "r"(t->area) : "memory");
    else
        task_seed(lazy_current + 1), task_fp_seed(lazy_current);
    t->saved = false;
    fp_live = 1;
}

// A context switch: save what's live, set TS, leave the next task to take #NM.
static void lazy_switch(void) {
    __asm__ volatile("cli");
    if (fp_live) {
        Task *t = &tasks[lazy_current];
        __asm__ volatile("fxsave64 (%0)" : : "r"(t->area) : "memory");
        t->saved = true;
        fp_live = 0;
    }
    u64 cr0;
    __asm__ volatile("mov %%cr0, %0" : "=r"(cr0));
    __asm__ volatile("mov %0, %%cr0" : : "r"(cr0 | 8));
    lazy_current ^= 1;
    __asm__ volatile("sti");
}

// The shape of the guest's integrity check: hashing pages that fault in, with the kernel using xmm itself on the way,
// as a code-signing check in vm_fault does.
#define LAZY_PAGES 32
#define LAZY_VA (TEST_VA + 0x10000000)
static u64 lazy_frames[LAZY_PAGES], *lazy_ptes[LAZY_PAGES];
static volatile u64 lazy_pf_count;
__asm__(".text\n"
        "_lazy_pf_stub:\n"
        "  pushq %rax\n pushq %rcx\n pushq %rdx\n pushq %rsi\n pushq %rdi\n"
        "  pushq %r8\n pushq %r9\n pushq %r10\n pushq %r11\n"
        "  pushq %rbp\n"
        "  movq %rsp, %rbp\n"
        "  andq $-16, %rsp\n" // it spills xmm with movaps
        "  call _lazy_pf\n"
        "  movq %rbp, %rsp\n"
        "  popq %rbp\n"
        "  popq %r11\n popq %r10\n popq %r9\n popq %r8\n"
        "  popq %rdi\n popq %rsi\n popq %rdx\n popq %rcx\n popq %rax\n"
        "  addq $8, %rsp\n"
        "  iretq\n");
extern char lazy_pf_stub[] __asm__("_lazy_pf_stub");

void lazy_pf(void) {
    u64 cr2;
    __asm__ volatile("mov %%cr2, %0" : "=r"(cr2));
    u64 page = (cr2 - LAZY_VA) >> 12;
    if (page >= LAZY_PAGES) {
        puts_("FAIL: a page fault outside the lazy test's pages\n");
        done(3);
    }
    lazy_pf_count++;
    *lazy_ptes[page] = lazy_frames[page] | PRESENT_RW;
    // What a kernel hash does with the registers it borrows. Under TS this takes #NM first, in the kernel, as XNU's
    // does.
    u64 saved[8] __attribute__((aligned(16)));
    __asm__ volatile("movaps %%xmm0, 0(%0)\n movaps %%xmm7, 16(%0)\n movaps %%xmm15, 32(%0)\n"
                     "pxor %%xmm0, %%xmm0\n pcmpeqd %%xmm7, %%xmm7\n paddd %%xmm7, %%xmm15\n"
                     "movaps 0(%0), %%xmm0\n movaps 16(%0), %%xmm7\n movaps 32(%0), %%xmm15\n"
                     :
                     : "r"(saved)
                     : "memory");
}

static inline void task_touch(u64 step) {
    const u8 *at = (const u8 *)LAZY_VA + (step * 40 % (LAZY_PAGES * 4096 - 32));
    __asm__ volatile("movdqu (%0), %%xmm7\n paddd %%xmm7, %%xmm15\n pxor 16(%1), %%xmm2\n"
                     :
                     : "r"(at), "r"((u64)at & ~15ULL)
                     : "memory");
    if ((step & 0x3FF) == 0) { // the page goes away again
        u64 page = (step >> 10) % LAZY_PAGES;
        *lazy_ptes[page] = 0;
        __asm__ volatile("invlpg (%0)" : : "r"(LAZY_VA + (page << 12)));
    }
}

static void test_lazy_fp(u64 root) {
    u64 golden[2][12];
    for (int i = 0; i < LAZY_PAGES; i++) {
        lazy_frames[i] = frame();
        for (int w = 0; w < 512; w++)
            PHYS(lazy_frames[i])[w] = 0x9E3779B97F4A7C15ULL * (u64)(i * 512 + w + 1);
        lazy_ptes[i] = pte_of(root, LAZY_VA + ((u64)i << 12));
    }
    gate(14, lazy_pf_stub);
    for (int n = 0; n < 2; n++) {
        task_seed(n + 1);
        task_fp_seed(n);
        for (u64 i = 0; i < LAZY_STEPS; i++) {
            task_step(i * (n + 3), ~i);
            task_fp_step(n, i);
            task_touch(i);
        }
        task_read(golden[n]);
        task_fp_read(n, &golden[n][6]);
    }
    for (int n = 0; n < 2; n++) {
        tasks[n].area = (u8 *)PHYS(frame());
        tasks[n].steps = 0;
        tasks[n].saved = false;
    }
    __asm__ volatile("cli");
    command(10); // the host starts a timer interrupt
    fp_model = 1;
    fp_live = 0;
    lazy_current = 0;
    u64 cr0;
    __asm__ volatile("mov %%cr0, %0" : "=r"(cr0));
    __asm__ volatile("mov %0, %%cr0" : : "r"(cr0 | 8));
    __asm__ volatile("sti");
    int finished = 0;
    u64 quantum = 1;
    while (finished < 2) {
        Task *t = &tasks[lazy_current];
        int n = lazy_current;
        for (u64 run = 0; run < quantum && t->steps < LAZY_STEPS; run++, t->steps++) {
            task_step(t->steps * (n + 3), ~t->steps);
            task_fp_step(n, t->steps);
            task_touch(t->steps);
            if ((t->steps & 0xFFF) ==
                0) // a fallback in the middle of a task: its xmm state goes through the host and back
                __asm__ volatile("mov $0, %%r13\n mov $2, %%r14\n .byte 0xD9, 0xFF\n" : : : "r13", "r14");
        }
        if (t->steps == LAZY_STEPS) {
            t->steps++;
            task_read(t->result);
            task_fp_read(n, &t->result[6]);
            finished++;
        }
        quantum = quantum * 7 % 4093 + 1;
        lazy_switch();
    }
    __asm__ volatile("cli");
    fp_model = 0;
    command(11);
    __asm__ volatile("mov %%cr0, %0" : "=r"(cr0));
    __asm__ volatile("mov %0, %%cr0" : : "r"(cr0 & ~8ULL));
    __asm__ volatile("sti");
    for (int n = 0; n < 2; n++)
        for (int i = 0; i < 12; i++)
            CHECK(tasks[n].result[i] == golden[n][i]);
    __asm__ volatile("emms\n fninit");
    CHECK(lazy_nm_count > 100);
    CHECK(lazy_pf_count > 1000);
    gate(14, bad_stub);
    CHECK(irq_count > 2);
}

// A store straddling into a page-table frame, as a kernel writes file data into a freed table that is still tracked.
// Each byte must land where the instruction says.
static void test_store_into_table(u64 root) {
    u64 va = TEST_VA + 0x600000;
    u64 *slots = pte_of(root, va); // a leaf table in use, so its frame is tracked once it is walked
    u64 table = ((u64)slots - PHYSMAP) & ~0xFFFULL;
    u64 before = frame();
    slots[0] = before | PRESENT_RW;
    slots[1] = table | PRESENT_RW; // and it is mapped as data right after an ordinary page
    volatile u8 *low = (volatile u8 *)va, *high = low + 4096;
    low[0] = 1;
    CHECK(high[9] == (u8)(table >> 8)); // the second slot of the frame, through the mapping: a walk has happened
    static const int widths[] = {8, 4, 2};
    for (int w = 0; w < 3; w++) {
        for (int at = 1; at < widths[w]; at++) {
            for (int i = 0; i < 16; i++) {
                low[4080 + i] = 0;
            }
            u64 value = 0x1122334455667788ULL;
            u64 saved = PHYS(table)[0];
            volatile u8 *to = high - at;
            // If the monitor sends it back, the harness does the store as TCG would, from the mailbox's frames.
            MAILBOX[1] = before;
            MAILBOX[2] = table;
            MAILBOX[3] = (u64)widths[w];
            if (widths[w] == 8)
                __asm__ volatile(
                    "mov %0, %%r11\n mov %1, %%r12\n mov $8, %%r13\n mov $4, %%r14\n .byte 0x4D, 0x89, 0x1C, 0x24\n"
                    :
                    : "r"(value), "r"(to)
                    : "r11", "r12", "r13", "r14", "memory");
            else if (widths[w] == 4)
                __asm__ volatile(
                    "mov %0, %%r11\n mov %1, %%r12\n mov $8, %%r13\n mov $4, %%r14\n .byte 0x45, 0x89, 0x1C, 0x24\n"
                    :
                    : "r"(value), "r"(to)
                    : "r11", "r12", "r13", "r14", "memory");
            else
                __asm__ volatile("mov %0, %%r11\n mov %1, %%r12\n mov $8, %%r13\n mov $5, %%r14\n .byte 0x66, 0x45, "
                                 "0x89, 0x1C, 0x24\n"
                                 :
                                 : "r"(value), "r"(to)
                                 : "r11", "r12", "r13", "r14", "memory");
            for (int i = 0; i < widths[w]; i++) {
                u8 want = (u8)(value >> (i * 8));
                // Through the physmap: a misplaced store lands on the slot that maps `low`, which would fault here
                // instead of failing.
                u8 got = i < at ? ((volatile u8 *)PHYS(before))[4096 - at + i] : ((volatile u8 *)PHYS(table))[i - at];
                CHECK(got == want);
            }
            PHYS(table)[0] = saved;
        }
    }

    // A 16-byte store across two tracked frames runs natively on one opened page at a time: neither may stay writable
    // after it.
    u64 va2 = TEST_VA + 0x800000;
    u64 *slots2 = pte_of(root, va2);
    u64 table2 = ((u64)slots2 - PHYSMAP) & ~0xFFFULL;
    u64 first = frame(), second = frame();
    PHYS(first)[0] = 0xA;
    PHYS(second)[0] = 0xB;
    slots2[3] = first | PRESENT_RW;
    CHECK(*(volatile u64 *)(va2 + 3 * 4096) == 0xA);
    // The second page gets a table of its own: rewriting the slot that maps the first page would take its writable
    // mapping away and hide the bug.
    u64 *slots3 = pte_of(root, TEST_VA + 0xA00000);
    u64 table3 = ((u64)slots3 - PHYSMAP) & ~0xFFFULL;
    slots3[1] = first | PRESENT_RW;
    CHECK(*(volatile u64 *)(TEST_VA + 0xA00000 + 4096) == 0xA);
    slots[0] = table2 | PRESENT_RW;
    slots[1] = table3 | PRESENT_RW;
    CHECK(low[3 * 8 + 1] == (u8)(first >> 8));
    CHECK(high[9] == (u8)(first >> 8));
    u64 value = 0x1122334455667788ULL;
    volatile u8 *to = high - 8;
    MAILBOX[1] = table2;
    MAILBOX[2] = table3;
    MAILBOX[3] = 16;
    __asm__ volatile("mov %0, %%r11\n mov %1, %%r12\n mov $8, %%r13\n mov $5, %%r14\n movq %%r11, %%xmm0\n punpcklqdq "
                     "%%xmm0, %%xmm0\n"
                     ".byte 0x41, 0x0F, 0x11, 0x04, 0x24\n"
                     :
                     : "r"(value), "r"(to)
                     : "r11", "r12", "r13", "r14", "xmm0", "memory");
    CHECK(PHYS(table2)[511] == value);
    CHECK(PHYS(table3)[0] == value);
    PHYS(table3)[0] = 0;
    PHYS(table2)[511] = 0;
    *(volatile u64 *)(va + 3 * 8) =
        second | PRESENT_RW; // through the mapping: only write protection tells the monitor of this one
    CHECK(*(volatile u64 *)(va2 + 3 * 4096) == 0xB);
    slots[0] = before | PRESENT_RW;
    slots[1] = 0;

    // A load that starts in RAM and ends in a device: emulating it at FAR would read the device for all 8 bytes.
    u64 got;
    __asm__ volatile("mov %1, %%r12\n mov $5, %%r13\n mov $4, %%r14\n .byte 0x49, 0x8B, 0x04, 0x24\n"
                     : "=a"(got)
                     : "r"(PHYSMAP + (1ULL << 30) - 4)
                     : "r12", "r13", "r14", "memory");
    CHECK(got == 7);
}

// A bulk copy into a page table: every entry it reaches must be seen, past the first few slots too.
static void test_rep_into_table(u64 root) {
    enum { COUNT = 16 };
    u64 frames[2];
    frames[0] = frame();
    frames[1] = frame();
    PHYS(frames[0])[0] = 0xA;
    PHYS(frames[1])[0] = 0xB;
    u64 va = TEST_VA + 0x400000;
    u64 *slots = pte_of(root, va);
    static u64 fresh[COUNT] __attribute__((aligned(32)));
    for (int i = 0; i < COUNT; i++) {
        slots[i] = frames[0] | PRESENT_RW;
        fresh[i] = frames[1] | PRESENT_RW;
    }
    for (int i = 0; i < COUNT; i++)
        CHECK(*(volatile u64 *)(va + (u64)i * 4096) == 0xA);
    u64 count = COUNT;
    u64 *s = fresh, *d = slots;
    __asm__ volatile("cld\n rep movsq" : "+S"(s), "+D"(d), "+c"(count) : : "memory");
    for (int i = 0; i < COUNT; i++)
        CHECK(*(volatile u64 *)(va + (u64)i * 4096) == 0xB);
}

// ---- A small process in ring 3, for the tally's process log: a fault, a wait4 that returns a status, an exit ----
static u64 tss[13];
u64 user_saved_rsp;
__asm__(".text\n"
        "_user_blob:\n"
        "  int3\n"
        "  leaq -16(%rsp), %rsi\n"
        "  movq $-1, %rdi\n"
        "  movl $0x2000007, %eax\n"
        "  syscall\n"
        "  movl $7, %edi\n"
        "  movl $0x2000001, %eax\n"
        "  syscall\n"
        "  ud2\n"
        "_user_blob_end:\n"
        "_user_int3:\n"
        "  iretq\n"
        "_user_syscall:\n"
        "  cmpl $0x2000001, %eax\n"
        "  je 1f\n"
        "  movl $0x300, (%rsi)\n"
        "  movl $77, %eax\n"
        "  sysretq\n"
        "1: movq _user_saved_rsp(%rip), %rsp\n"
        "  retq\n"
        ".globl _enter_user\n"
        "_enter_user:\n" // rdi rip, rsi rsp. Registers the C caller expects kept are kept by its asm clobbers.
        "  movq %rsp, _user_saved_rsp(%rip)\n"
        "  pushq $0x23\n pushq %rsi\n pushq $0x202\n pushq $0x2B\n pushq %rdi\n"
        "  iretq\n");
extern char user_blob[] __asm__("_user_blob"), user_blob_end[] __asm__("_user_blob_end"),
    user_int3[] __asm__("_user_int3"), user_syscall[] __asm__("_user_syscall");
void enter_user(u64 rip, u64 rsp);

static void test_process_log(u64 root) {
    u64 t = (u64)tss;
    gdt[3] = 0x00CFF2000000FFFFULL;
    gdt[4] = 0x00CFF2000000FFFFULL;
    gdt[5] = 0x00AFFA000000FFFFULL;
    gdt[6] =
        ((t & 0xffff) << 16) | ((t >> 16 & 0xff) << 32) | (0x89ULL << 40) | ((t >> 24 & 0xff) << 56) | (sizeof tss - 1);
    gdt[7] = t >> 32;
    static u8 kernel_stack[4096] __attribute__((aligned(16)));
    tss[0] = (u64)(kernel_stack + sizeof kernel_stack) << 32; // rsp0 sits at byte 4
    tss[1] = (u64)(kernel_stack + sizeof kernel_stack) >> 32;
    struct {
        u16 limit;
        u64 base;
    } __attribute__((packed)) g = {sizeof gdt - 1, (u64)gdt};
    __asm__ volatile("lgdt %0\n ltr %%ax" : : "m"(g), "a"(0x30));
    u64 a = (u64)user_int3;
    idt[3] = (Gate){(u16)a, 8, 0, 0xEE, (u16)(a >> 16), (u32)(a >> 32), 0};
    __asm__ volatile("wrmsr" : : "c"(0xC0000081), "a"(0), "d"(0x00180008));
    a = (u64)user_syscall;
    __asm__ volatile("wrmsr" : : "c"(0xC0000082), "a"((u32)a), "d"((u32)(a >> 32)));

    u64 va = TEST_VA + 0x800000;
    u64 *slot = pte_of(root, va);
    u64 table = root;
    for (int level = 3; level > 0; level--) { // user access needs U at every level
        volatile u64 *e = &PHYS(table)[(va >> (12 + 9 * level)) & 0x1ff];
        *e |= 4;
        table = *e & 0x000FFFFFFFFFF000ULL;
    }
    u64 page = frame();
    u8 *to = (u8 *)PHYS(page);
    for (int i = 0; i < user_blob_end - user_blob; i++)
        to[i] = (u8)user_blob[i];
    *slot = page | PRESENT_RW | 4;
    __asm__ volatile("call _enter_user"
                     :
                     : "D"(va), "S"(va + 4096)
                     : "rax", "rbx", "rcx", "rdx", "rbp", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15",
                       "memory");
    // The harness checks the log. The gate needs putting back for nothing else: nothing here takes a breakpoint again.
}

// A table the guest stopped using and now keeps data in. Trapping every store there cost one boot 250,000 stores a
// second.
static void test_stale_table(u64 root) {
    u64 va = TEST_VA + 0x40000000; // a page directory entry of its own
    u64 *leaf = pte_of(root, va);
    u64 table = ((u64)leaf - PHYSMAP) & ~0xFFFULL;
    u64 third = PHYS(root)[(va >> 39) & 0x1ff] & 0x000FFFFFFFFFF000ULL;
    volatile u64 *directory = PHYS(PHYS(third)[(va >> 30) & 0x1ff] & 0x000FFFFFFFFFF000ULL);
    leaf[0] = frame() | PRESENT_RW;
    CHECK(*(volatile u64 *)va != 1); // walked: the frame is tracked
    directory[(va >> 21) & 0x1ff] = 0; // no longer a table
    for (int round = 0; round < 500; round++)
        for (int i = 0; i < 512; i++)
            PHYS(table)[i] = (u64)(round + i);
    CHECK(PHYS(table)[511] == 499 + 511);
}

static void test_ptest_flags(void) {
    u64 flags, set = 0xFFFFFFFFFFFFFFFFULL;
    __asm__ volatile("movq %1, %%xmm0\n movq %1, %%xmm1\n"
                     "mov $0x7f, %%al\n add $1, %%al\n" // sets SF, OF and AF
                     "ptest %%xmm0, %%xmm1\n pushfq\n popq %0\n"
                     : "=r"(flags)
                     : "r"(set)
                     : "rax", "xmm0", "xmm1", "cc");
    CHECK((flags & 0x8D5) == 0x01); // both all ones: CF only, of CF PF AF ZF SF OF
}

static u64 tsc(void) {
    u32 lo, hi;
    __asm__ volatile("lfence\n rdtsc" : "=a"(lo), "=d"(hi));
    return (u64)hi << 32 | lo;
}

static u64 copy_megabyte(void) {
    u64 count = 1 << 20, t0 = tsc();
    volatile u8 *s = (volatile u8 *)PHYS(0x20000000), *d = (volatile u8 *)PHYS(0x21000000);
    __asm__ volatile("cld\n rep movsb" : "+S"(s), "+D"(d), "+c"(count) : : "memory");
    return tsc() - t0;
}

// A kernel or a program that copies with TS set, as it is after a context switch, and nothing to clear it: no x86 SIMD
// ran, so no #NM. Costing a trap per byte made one lc-bench test look hung.
static void test_rep_speed_under_ts(void) {
    for (int i = 0; i < 1 << 20; i += 4096)
        *(volatile u8 *)((u64)PHYS(0x20000000) + (u64)i) = (u8)(i >> 12);
    copy_megabyte();
    u64 plain = copy_megabyte(), cr0, nm = nm_count;
    __asm__ volatile("mov %%cr0, %0" : "=r"(cr0));
    __asm__ volatile("mov %0, %%cr0" : : "r"(cr0 | 8));
    u64 under_ts = copy_megabyte();
    __asm__ volatile("mov %0, %%cr0" : : "r"(cr0 & ~8ULL));
    CHECK(nm_count == nm);
    CHECK(*(volatile u8 *)((u64)PHYS(0x21000000) + 4096 * 200) == 200);
    if (under_ts >= plain * 200) {
        MAILBOX[1] = plain;
        MAILBOX[2] = under_ts;
        command(12);
    }
}

// A dead process: the kernel frees its tables and poisons them while its view still holds translated code. Nothing may
// walk those tables as though they meant something.
static void test_poisoned_tables(u64 root) {
    u64 va = TEST_VA + 0xE00000, code = frame(), other = frame();
    for (int i = 0; i < 512; i++)
        PHYS(other)[i] = PHYS(root)[i];
    *(volatile u8 *)PHYS(code) = 0xC3; // ret
    pte_of(root, va)[0] = code | PRESENT_RW;
    __asm__ volatile("mov %0, %%cr3" : : "r"(other));
    ((void (*)(void))va)();
    CHECK(*(volatile u8 *)va == 0xC3); // translated from, and mapped for data, in that view
    __asm__ volatile("mov %0, %%cr3" : : "r"(root));
    PHYS(other)[(va >> 39) & 0x1ff] = 0xDEADBEEFDEADBEEFULL;
}

// MMX registers live with the engine between fallbacks, and TCG needs them, with the tags as MMX leaves them, at each
// one.
static void test_mmx(void) {
    u64 value = 0x1122334455667788ULL, out = 0, after = 0;
    // Action 9 checks and swaps what TCG would see: mm3 holds value, MMX has entered; it hands back ~value.
    __asm__ volatile(
        "movq %1, %%mm3\n mov $9, %%r13\n mov $5, %%r14\n .byte 0x66, 0x0F, 0x38, 0x41, 0xC1\n movq %%mm3, %0\n"
        : "=r"(out)
        : "r"(value)
        : "r13", "r14", "xmm0", "memory");
    CHECK(out == ~value);
    __asm__ volatile("emms\n mov $10, %%r13\n mov $5, %%r14\n .byte 0x66, 0x0F, 0x38, 0x41, 0xC1\n"
                     :
                     :
                     : "r13", "r14", "xmm0", "memory");
    // TS: #NM for each form, including those that need no vector register to do their job.
    u64 nm = nm_count, cr0;
    __asm__ volatile("mov %%cr0, %0" : "=r"(cr0));
    __asm__ volatile("mov %0, %%cr0" : : "r"(cr0 | 8));
    __asm__ volatile("movq %1, %%mm3\n movq %%mm3, %0\n" : "=r"(after) : "r"(value) : "memory");
    CHECK(nm_count == nm + 1);
    CHECK(after == value);
    __asm__ volatile("mov %0, %%cr0" : : "r"(cr0 | 8));
    __asm__ volatile("emms");
    CHECK(nm_count == nm + 2);
}

// A split store onto a tracked frame whose second page is missing: the fault names that page, and the store then
// finishes.
static void test_split_store_fault(u64 root) {
    u64 *slots = pte_of(root, TEST_VA + 0xC00000);
    u64 table = ((u64)slots - PHYSMAP) & ~0xFFFULL;
    slots[0] = frame() | PRESENT_RW;
    CHECK(*(volatile u64 *)(TEST_VA + 0xC00000) != 1); // walked, so the frame is tracked
    *lazy_ptes[0] = table | PRESENT_RW;
    *lazy_ptes[1] = 0;
    __asm__ volatile("invlpg (%0)\n invlpg (%1)" : : "r"(LAZY_VA), "r"(LAZY_VA + 4096));
    PHYS(lazy_frames[1])[0] = 0;
    gate(14, lazy_pf_stub);
    u64 count = lazy_pf_count, value = 0x1122334455667788ULL;
    *(volatile u8 *)LAZY_VA; // the first page is mapped, so only the second can refuse
    __asm__ volatile("movq %0, (%1)" : : "r"(value), "r"(LAZY_VA + 4096 - 3) : "memory");
    gate(14, bad_stub);
    CHECK(lazy_pf_count == count + 1);
    CHECK((PHYS(table)[511] >> 40) == (value & 0xFFFFFF));
    CHECK(PHYS(lazy_frames[1])[0] == value >> 24);
    PHYS(table)[511] = 0;
}

// ---- x87: what Rosetta can't be compared on, by the SDM, and what TCG sees at a fallback ----
extern volatile u64 gp_count;
volatile u64 gp_count;
__asm__(".text\n"
        "_gp_skip5:\n" // #GP from the five-byte fxrstor64 below: count it and step over
        "  incq _gp_count(%rip)\n"
        "  addq $8, %rsp\n"
        "  addq $5, (%rsp)\n"
        "  iretq\n");
extern char gp_skip5[] __asm__("_gp_skip5");

static inline u16 x87_sw(void) {
    u16 v;
    __asm__ volatile("fnstsw %0" : "=a"(v));
    return v;
}

static void test_x87(void) {
    u8 *area = (u8 *)PHYS(frame());
    u16 sw;
    u64 lo;
    // Stack underflow, masked: the indefinite, IE and SF, C1 clear.
    __asm__ volatile("fninit\n fadd %%st(1), %%st\n" : : : "memory");
    sw = x87_sw();
    CHECK((sw & 0x7F) == 0x41 && !(sw & 0x200));
    __asm__ volatile("fnclex\n fxsave64 (%0)" : : "r"(area) : "memory");
    CHECK(*(u64 *)(area + 32) == 0xC000000000000000ULL && *(u16 *)(area + 40) == 0xFFFF);
    // A NaN in ST0 doesn't change that, where Rosetta runs the NaN rules against its empty register.
    __asm__ volatile("fninit\n fldt (%0)\n fadd %%st(3), %%st\n fxsave64 (%1)" : : "r"((const u8[10]){1, 0, 0, 0, 0, 0, 0, 0xC0, 0xFF, 0x7F}), "r"(area) : "memory");
    CHECK(*(u64 *)(area + 32) == 0xC000000000000000ULL && *(u16 *)(area + 40) == 0xFFFF);
    // Stack overflow: the same with C1 set, TOP moved, and the register overwritten.
    __asm__ volatile("fninit\n fld1\n fld1\n fld1\n fld1\n fld1\n fld1\n fld1\n fld1\n fnclex\n fldpi\n" : : : "memory");
    sw = x87_sw();
    CHECK((sw & 0x7F) == 0x41 && (sw & 0x200) && (sw >> 11 & 7) == 7);
    // fbld as well, which Rosetta lets through.
    __asm__ volatile("fnclex\n fbld (%0)\n" : : "r"((const u8[10]){0x12, 0x34}) : "memory");
    sw = x87_sw();
    CHECK((sw & 0x41) == 0x41 && (sw & 0x200));
    // Popping an empty register stores the indefinite. An integer store gives the integer indefinite.
    double d = 1;
    int i32 = 0;
    __asm__ volatile("fninit\n fstpl %0\n" : "=m"(d));
    CHECK(*(u64 *)&d == 0xFFF8000000000000ULL);
    __asm__ volatile("fninit\n fistpl %0\n" : "=m"(i32));
    CHECK((u32)i32 == 0x80000000);

    // Empty registers keep what they held: a CPU's image shows it, tagged empty.
    __asm__ volatile("fninit\n fldpi\n fstp %%st(0)\n fxsave64 (%0)" : : "r"(area) : "memory");
    CHECK(area[4] == 0 && *(u64 *)(area + 32 + 15 * 0) != 0xC000000000000000ULL);
    CHECK(*(u64 *)(area + 32 + 16 * 7) == 0xC90FDAA22168C235ULL && *(u16 *)(area + 40 + 16 * 7) == 0x4000);

    // Instruction and data pointers, and the opcode. r12 as the base, so the ModRM byte is known; a label gives the rip.
    u64 at, cell = 0;
    __asm__ volatile("fninit\n lea 1f(%%rip), %0\n mov %1, %%r12\n 1: .byte 0x41, 0xDD, 0x04, 0x24\n" // fldl (%r12)
                     "fxsave64 (%2)\n"
                     : "=&r"(at)
                     : "r"(&cell), "r"(area)
                     : "r12", "memory");
    CHECK(*(u16 *)(area + 6) == 0x504 && *(u64 *)(area + 8) == at && *(u64 *)(area + 16) == (u64)&cell);
    // The small format and fnstenv's: reserved words all ones, opcode beside the selector.
    __asm__ volatile("fnstenv (%0)" : : "r"(area) : "memory");
    CHECK(*(u32 *)(area + 0) == 0xFFFF037F && *(u32 *)(area + 12) == (u32)at && *(u32 *)(area + 16) == (0x504u << 16 | 8) && *(u32 *)(area + 20) == (u32)(u64)&cell);
    CHECK(*(u16 *)(area + 8) == 0x7FFF); // the one register in use, physical 7, holds zero: tag 01
    __asm__ volatile("fldcw (%0)\n" : : "r"((const u16[1]){0x37F}) : "memory");
    __asm__ volatile("fxsave (%0)" : : "r"(area) : "memory");
    CHECK(*(u32 *)(area + 8) == (u32)at && *(u16 *)(area + 12) == 8 && *(u32 *)(area + 16) == (u32)(u64)&cell);
    // A control instruction moves neither pointer.
    __asm__ volatile("fnstcw (%0)\n fnclex\n fxsave64 (%1)" : : "r"(&cell), "r"(area) : "memory");
    CHECK(*(u64 *)(area + 8) == at);
    // Data16 images are the short ones.
    __asm__ volatile(".byte 0x66, 0xD9, 0x30\n" : : "a"(area) : "memory"); // data16 fnstenv (%rax)
    CHECK(*(u16 *)(area + 0) == 0x37F && *(u16 *)(area + 2) >> 11 == 7);

    // fxsave leaves the end of the image alone, and fxrstor brings back everything it holds. ST order, not physical.
    for (int w = 52; w < 64; w++)
        ((u64 *)area)[w] = 0x5A5A5A5A5A5A5A5AULL;
    u64 xmm3[2] __attribute__((aligned(16))) = {0x1111222233334444ULL, 0x5555666677778888ULL}, back[2] __attribute__((aligned(16)));
    __asm__ volatile("movaps (%1), %%xmm3\n fninit\n fld1\n fldpi\n fxsave64 (%0)\n fninit\n pxor %%xmm3, %%xmm3\n fxrstor64 (%0)\n movaps %%xmm3, (%2)\n" : : "r"(area), "r"(xmm3), "r"(back) : "memory", "xmm3");
    CHECK(back[0] == xmm3[0] && back[1] == xmm3[1]);
    CHECK(((u64 *)area)[52] == 0x5A5A5A5A5A5A5A5AULL && ((u64 *)area)[63] == 0x5A5A5A5A5A5A5A5AULL);
    CHECK(area[4] == 0xC0 && *(u64 *)(area + 32) == 0xC90FDAA22168C235ULL && *(u64 *)(area + 48) == 0x8000000000000000ULL);
    __asm__ volatile("fstpl %0\n" : "=m"(d));
    __asm__ volatile("fstp %st(0)");
    CHECK(*(u64 *)&d == 0x400921FB54442D18ULL);
    // Reserved MXCSR bits: #GP, nothing restored.
    gate(13, gp_skip5);
    *(u32 *)(area + 24) = 0x10000 | 0x1F80;
    __asm__ volatile("fninit\n fldz\n mov %0, %%r12\n .byte 0x49, 0x0F, 0xAE, 0x0C, 0x24\n" : : "r"(area) : "r12", "memory");
    gate(13, bad_stub);
    CHECK(gp_count == 1);
    sw = x87_sw();
    CHECK((sw >> 11 & 7) == 7);
    __asm__ volatile("fninit");

    // MMX and the stack: TOP 0, all valid, exponents all ones where written; emms empties the tags and leaves TOP.
    __asm__ volatile("fninit\n fld1\n fld1\n movq %0, %%mm2\n fxsave64 (%1)\n" : : "r"(lo = 0x0123456789ABCDEFULL), "r"(area) : "memory");
    CHECK((*(u16 *)(area + 2) >> 11 & 7) == 0 && area[4] == 0xFF && *(u64 *)(area + 32 + 2 * 16) == lo && *(u16 *)(area + 40 + 2 * 16) == 0xFFFF);
    __asm__ volatile("emms\n fxsave64 (%0)" : : "r"(area) : "memory");
    CHECK(area[4] == 0 && (*(u16 *)(area + 2) >> 11 & 7) == 0);
    // ...and x87 can read what MMX left: a NaN whose significand is the MMX value, by physical number.
    __asm__ volatile("fninit\n movq %0, %%mm7\n emms\n fld %%st(7)\n fxsave64 (%1)\n" : : "r"(lo), "r"(area) : "memory");
    CHECK(*(u16 *)(area + 2) >> 11 == 7);

    // A fault on a store changes nothing: the page faults in and the instruction runs once. TOP moved once, the value is whole.
    u64 before = lazy_pf_count;
    *lazy_ptes[2] = 0;
    __asm__ volatile("invlpg (%0)" : : "r"(LAZY_VA + (2ULL << 12)));
    gate(14, lazy_pf_stub);
    u8 *split = (u8 *)LAZY_VA + (2ULL << 12) - 4; // an 80-bit store whose tail is on the missing page
    *(volatile u64 *)(split - 8) = 0;
    __asm__ volatile("fninit\n fld1\n fldpi\n fstpt (%0)\n" : : "r"(split) : "memory");
    CHECK(lazy_pf_count == before + 1);
    sw = x87_sw();
    CHECK((sw >> 11 & 7) == 7);
    CHECK(*(u64 *)split == 0xC90FDAA22168C235ULL && *(u16 *)(split + 8) == 0x4000);
    // And a load: nothing pushed until it arrives.
    *lazy_ptes[3] = 0;
    __asm__ volatile("invlpg (%0)" : : "r"(LAZY_VA + (3ULL << 12)));
    before = lazy_pf_count;
    __asm__ volatile("fninit\n fldt (%0)\n" : : "r"((u8 *)LAZY_VA + (3ULL << 12)) : "memory");
    sw = x87_sw();
    CHECK(lazy_pf_count == before + 1 && (sw >> 11 & 7) == 7);
    // A store to the page that's missing, under TS: #NM comes first and clears TS, then the fault.
    __asm__ volatile("fninit\n fld1");
    *lazy_ptes[4] = 0;
    __asm__ volatile("invlpg (%0)" : : "r"(LAZY_VA + (4ULL << 12)));
    u64 nm = nm_count, cr0;
    __asm__ volatile("mov %%cr0, %0" : "=r"(cr0));
    __asm__ volatile("mov %0, %%cr0" : : "r"(cr0 | 8));
    before = lazy_pf_count;
    __asm__ volatile("fstpl (%0)\n" : : "r"((u8 *)LAZY_VA + (4ULL << 12)) : "memory");
    CHECK(nm_count >= nm + 1 && lazy_pf_count == before + 1);
    // Register forms, control forms and fwait under TS.
    __asm__ volatile("mov %0, %%cr0" : : "r"(cr0 | 8));
    nm = nm_count;
    __asm__ volatile("fninit");
    CHECK(nm_count == nm + 1);
    __asm__ volatile("mov %0, %%cr0" : : "r"(cr0 | 8));
    __asm__ volatile("fnstsw %%ax" : : : "ax");
    CHECK(nm_count == nm + 2);
    __asm__ volatile("mov %0, %%cr0" : : "r"(cr0 | 8));
    __asm__ volatile("fxsave64 (%0)" : : "r"(area) : "memory");
    CHECK(nm_count == nm + 3);
    __asm__ volatile("mov %0, %%cr0" : : "r"(cr0 | 0x8 | 0x2)); // MP and TS: fwait traps too
    __asm__ volatile("fwait");
    CHECK(nm_count == nm + 4);
    __asm__ volatile("mov %0, %%cr0" : : "r"(cr0));
    gate(14, bad_stub);

    // At a fallback TCG gets all of it. Action 13 checks the stack as this leaves it, and writes ST0 and the status word for the way back.
    __asm__ volatile("fninit\n fldcw (%0)\n fld1\n fldpi\n" : : "r"((const u16[1]){0xB7F}) : "memory");
    __asm__ volatile("mov $13, %%r13\n mov $2, %%r14\n .byte 0xD9, 0xFF\n fxsave64 (%0)" : : "r"(area) : "r13", "r14", "memory");
    CHECK(*(u64 *)(area + 32) == 0xFEDCBA9876543210ULL && *(u16 *)(area + 40) == 0x4005 && (*(u16 *)(area + 2) & 0x7F) == 0x20);
    // An unmasked exception takes the operation to TCG (action 14 checks that nothing moved). Flags now unmasked are pending, and fwait goes too.
    __asm__ volatile("fninit\n fld1\n fld1\n fldcw (%0)\n" : : "r"((const u16[1]){0x37E}) : "memory");
    __asm__ volatile("mov $14, %%r13\n mov $2, %%r14\n faddp\n" : : : "r13", "r14");
    __asm__ volatile("fninit\n fld1\n fldz\n fdivrp\n fldcw (%0)\n" : : "r"((const u16[1]){0x37B}) : "memory");
    sw = x87_sw();
    CHECK((sw & 0x80) && (sw & 4));
    __asm__ volatile("mov $15, %%r13\n mov $1, %%r14\n fwait\n" : : : "r13", "r14");
    __asm__ volatile("fninit");
}

void kmain(void) {
    __asm__ volatile("mov $0x10, %%ax\n mov %%ax, %%ds\n mov %%ax, %%es\n mov %%ax, %%ss\n" : : : "ax");
    tables();
    u64 root = read_cr3();
    test_ram_map(root);
    test_fallback_state();
    test_host_changes_cr3(root);
    test_notes(root);
    test_ts();
    test_level_interrupts();
    test_tsc();
    test_busy();
    test_cr4();
    test_vmport();
    test_port_forms();
    test_store_into_table(root);
    test_rep_into_table(root);
    test_lazy_fp(root);
    test_split_store_fault(root);
    test_mmx();
    test_x87();
    test_stale_table(root);
    test_poisoned_tables(root);
    test_rep_speed_under_ts();
    test_ptest_flags();
    test_process_log(root);
    test_view_churn(root);
    CHECK(!bad_vector);
    puts_("hybrid checks passed\n");
    done(0);
}
