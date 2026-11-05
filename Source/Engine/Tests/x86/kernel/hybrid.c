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

static u64 gdt[3] __attribute__((aligned(16))) = {0, 0x00AF9A000000FFFFULL, 0x00CF92000000FFFFULL};
typedef struct {
    u16 off0, sel;
    u8 ist, attr;
    u16 off1;
    u32 off2, r;
} __attribute__((packed)) Gate;
static Gate idt[256] __attribute__((aligned(16)));
volatile u64 nm_count, irq_count, bad_vector;

__asm__(".text\n"
        "_nm_stub:\n"
        "  pushq %rax\n"
        "  incq _nm_count(%rip)\n"
        "  movq %cr0, %rax\n"
        "  andq $~8, %rax\n"
        "  movq %rax, %cr0\n"
        "  popq %rax\n"
        "  iretq\n"
        "_irq_stub:\n"
        "  incq _irq_count(%rip)\n"
        "  iretq\n"
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
                     ".byte 0x66, 0x0F, 0x38, 0x40, 0xC1\n" // pmulld xmm0, xmm1: the decoder has no SSE4 and #UD is not
                                                            // its call to make
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
    __asm__ volatile("mov $0, %%r13\n mov $2, %%r14\n .byte 0xDB, 0xE3\n" : : : "r13", "r14"); // fninit
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
    test_view_churn(root);
    CHECK(!bad_vector);
    puts_("hybrid checks passed\n");
    done(0);
}
