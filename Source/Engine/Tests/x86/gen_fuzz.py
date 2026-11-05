#!/usr/bin/env python3
"""Generates fuzz_forms.s: one x86-64 test function per instruction form, plus a table of names and defined-flag masks.
Each form runs with random registers, flags and memory (fuzz_driver.c). The same image runs under the engine and under Rosetta and
the transcripts are compared. Flags the SDM calls undefined are masked per form. r15 points at the data buffer; rsp is untouched
unless the form says so."""
import sys

F_C, F_P, F_A, F_Z, F_S, F_O = 1, 4, 0x10, 0x40, 0x80, 0x800
ALL = F_C | F_P | F_A | F_Z | F_S | F_O

forms = []  # (name, body lines, flag mask, kind)


def form(name, body, mask=ALL, kind="int"):
    forms.append((name, body if isinstance(body, list) else [body], mask, kind))


R = {
    8: ["%rax", "%rbx", "%rcx", "%rdx", "%rsi", "%rdi", "%r8", "%r9", "%r12", "%r14"],
    4: ["%eax", "%ebx", "%ecx", "%edx", "%esi", "%edi", "%r8d", "%r9d", "%r12d", "%r14d"],
    2: ["%ax", "%bx", "%cx", "%dx", "%si", "%di", "%r8w", "%r9w", "%r12w", "%r14w"],
    1: ["%al", "%bl", "%cl", "%dl", "%sil", "%dil", "%r8b", "%r9b", "%r12b", "%r14b"],
}
HIGH = ["%ah", "%bh", "%ch", "%dh"]
S = {8: "q", 4: "l", 2: "w", 1: "b"}
IMMS = {1: ["$0x7f", "$0x80", "$1", "$0"], 2: ["$0x7fff", "$0x1234", "$-1"], 4: ["$0x12345678", "$-2", "$0x7fffffff"],
        8: ["$0x12345678", "$-2", "$0x7f", "$-4096"]}
SRC = {8: "%rbx", 4: "%ebx", 2: "%bx", 1: "%bl"}
DST = {8: "%rax", 4: "%eax", 2: "%ax", 1: "%al"}
MEM = ["(%r15)", "8(%r15)", "0x123(%r15)", "-16(%r13)", "(%r15,%r11,1)", "16(%r15,%r11,8)"]

for op in ["add", "or", "adc", "sbb", "and", "sub", "xor", "cmp", "test"]:
    logic = op in ("or", "and", "xor", "test")
    mask = ALL & ~F_A if logic else ALL
    for sz in (8, 4, 2, 1):
        s = S[sz]
        form(f"{op}{s} r,r", f"{op}{s} {SRC[sz]},{DST[sz]}", mask)
        form(f"{op}{s} r,r same", f"{op}{s} {DST[sz]},{DST[sz]}", mask)
        form(f"{op}{s} r,m", f"{op}{s} {SRC[sz]},8(%r15)", mask)
        if op != "test":
            form(f"{op}{s} m,r", f"{op}{s} 8(%r15),{DST[sz]}", mask)
        for imm in IMMS[sz]:
            form(f"{op}{s} {imm},r", f"{op}{s} {imm},{DST[sz]}", mask)
            form(f"{op}{s} {imm},m", f"{op}{s} {imm},8(%r15)", mask)
        form(f"{op}{s} imm,other", f"{op}{s} {IMMS[sz][0]},{R[sz][7]}", mask)
    for h in HIGH:
        form(f"{op}b {h},%dil", f"{op}b {h},%al" if h != "%ah" else f"{op}b {h},%bl", mask)
        form(f"{op}b %bl,{h}", f"{op}b %bl,{h}", mask)
        form(f"{op}b $5,{h}", f"{op}b $5,{h}", mask)
    if op not in ("cmp", "test"):
        for sz in (8, 4, 2, 1):
            form(f"lock {op}{S[sz]} r,m", f"lock {op}{S[sz]} {SRC[sz]},8(%r15)", mask)
            form(f"lock {op}{S[sz]} imm,m", f"lock {op}{S[sz]} {IMMS[sz][0]},8(%r15)", mask)

for m in MEM:
    form(f"add mem {m}", f"addq {m},%rax")
    form(f"mov mem {m}", f"movq %rbx,{m}")

for op in ["inc", "dec", "neg", "not"]:
    for sz in (8, 4, 2, 1):
        s = S[sz]
        form(f"{op}{s} r", f"{op}{s} {DST[sz]}")
        form(f"{op}{s} m", f"{op}{s} 8(%r15)")
        form(f"lock {op}{s} m", f"lock {op}{s} 8(%r15)")
    form(f"{op}b %ah", f"{op}b %ah")

for op in ["shl", "shr", "sar", "rol", "ror", "rcl", "rcr"]:
    rot = op in ("rol", "ror", "rcl", "rcr")
    for sz in (8, 4, 2, 1):
        s = S[sz]
        bits = sz * 8
        # Count 1: all defined. Larger counts: OF undefined. AF undefined for shifts. Rotates touch only CF and OF.
        m1 = (ALL & ~F_A) if not rot else ALL
        mn = m1 & ~F_O
        for dst in (DST[sz], "8(%r15)"):
            o = "r" if dst[0] == "%" else "m"
            form(f"{op}{s} $1,{o}", f"{op}{s} ${1},{dst}", m1)
            form(f"{op}{s} $3,{o}", f"{op}{s} $3,{dst}", mn)
            form(f"{op}{s} $0,{o}", f"{op}{s} $0,{dst}", ALL)
            form(f"{op}{s} $big,{o}", f"{op}{s} ${bits - 1},{dst}", mn)
            # Masked counts above the width are undefined in CF for narrow shifts.
            nm = mn & ~F_C if sz < 4 and not rot else mn
            form(f"{op}{s} %cl small,{o}", ["andb $7,%cl", "orb $2,%cl", f"{op}{s} %cl,{dst}"], mn)
            form(f"{op}{s} %cl one,{o}", ["movb $1,%cl", f"{op}{s} %cl,{dst}"], m1)
            form(f"{op}{s} %cl zero,{o}", ["movb $0,%cl", f"{op}{s} %cl,{dst}"], ALL)
            form(f"{op}{s} %cl any,{o}", [f"{op}{s} %cl,{dst}"], nm if not rot else (F_C if sz >= 4 else F_C) & 0 or 0)
    form(f"{op}b $2,%ah", f"{op}b $2,%ah", (ALL & ~F_A & ~F_O) if not rot else (ALL & ~F_O))

for op in ["shld", "shrd"]:
    for sz in (8, 4, 2):
        s = S[sz]
        for dst, o in ((DST[sz], "r"), ("8(%r15)", "m")):
            form(f"{op}{s} $1,{o}", f"{op}{s} $1,{SRC[sz]},{dst}", ALL & ~F_A)
            form(f"{op}{s} $5,{o}", f"{op}{s} $5,{SRC[sz]},{dst}", ALL & ~F_A & ~F_O)
            form(f"{op}{s} $0,{o}", f"{op}{s} $0,{SRC[sz]},{dst}", ALL)
            form(f"{op}{s} %cl,{o}", ["andb $7,%cl", "orb $1,%cl", f"{op}{s} %cl,{SRC[sz]},{dst}"], F_C | F_S | F_Z | F_P)

for op in ["mul", "imul"]:
    for sz in (8, 4, 2, 1):
        s = S[sz]
        form(f"{op}{s} r", f"{op}{s} {SRC[sz]}", F_C | F_O)
        form(f"{op}{s} m", f"{op}{s} 8(%r15)", F_C | F_O)
for sz in (8, 4, 2):
    s = S[sz]
    form(f"imul{s} r,r", f"imul{s} {SRC[sz]},{DST[sz]}", F_C | F_O)
    form(f"imul{s} m,r", f"imul{s} 8(%r15),{DST[sz]}", F_C | F_O)
    form(f"imul{s} imm,r,r", f"imul{s} ${0x1234},{SRC[sz]},{DST[sz]}", F_C | F_O)
    form(f"imul{s} imm8,m,r", f"imul{s} $-3,8(%r15),{DST[sz]}", F_C | F_O)

# Division: operands conditioned so that no #DE occurs, with both fast and slow paths reached.
for sz, (hi, lo, div) in {8: ("%rdx", "%rax", "%rbx"), 4: ("%edx", "%eax", "%ebx")}.items():
    s = S[sz]
    form(f"div{s} hi=0", [f"xor{s} {hi},{hi}", f"or{s} $1,{div}", f"div{s} {div}"], 0)
    form(f"div{s} hi<div", [f"and{s} $0xff,{hi}", f"or{s} $0x100,{div}", f"div{s} {div}"], 0)
    form(f"idiv{s} sext", ["cqo" if sz == 8 else "cdq", f"and{s} $-3,{div}", f"or{s} $1,{div}", f"idiv{s} {div}"], 0)
    form(f"idiv{s} wide", [f"and{s} $0xff,{hi}", f"and{s} $0x7fffffff,{div}", f"or{s} $0x10000,{div}", f"idiv{s} {div}"], 0)
    form(f"div{s} m", [f"and{s} $0xff,{hi}", f"or{s} $0x100,8(%r15)", f"div{s} 8(%r15)"], 0)
form("divw", ["andw $0xff,%dx", "orw $0x100,%bx", "divw %bx"], 0)
form("idivw", ["cwd", "andw $-3,%bx", "orw $1,%bx", "idivw %bx"], 0)
form("divb", ["andw $0xff,%ax", "orb $0x80,%bl", "shrw $1,%ax", "divb %bl"], 0)
form("idivb", ["cbw", "andb $-3,%bl", "orb $1,%bl", "idivb %bl"], 0)

for sz in (8, 4, 2, 1):
    s = S[sz]
    form(f"mov{s} r,r", f"mov{s} {SRC[sz]},{DST[sz]}", ALL)
    form(f"mov{s} m,r", f"mov{s} 8(%r15),{DST[sz]}", ALL)
    form(f"mov{s} r,m", f"mov{s} {SRC[sz]},9(%r15)", ALL)
    form(f"mov{s} imm,r", f"mov{s} {IMMS[sz][0]},{DST[sz]}", ALL)
    form(f"mov{s} imm,m", f"mov{s} {IMMS[sz][1]},3(%r15)", ALL)
    form(f"xchg{s} r,r", f"xchg{s} {SRC[sz]},{DST[sz]}", ALL)
    form(f"xchg{s} r,m", f"xchg{s} {SRC[sz]},8(%r15)", ALL)
    form(f"xadd{s} r,r", f"xadd{s} {SRC[sz]},{DST[sz]}")
    form(f"xadd{s} r,m", f"xadd{s} {SRC[sz]},8(%r15)")
    form(f"lock xadd{s}", f"lock xadd{s} {SRC[sz]},8(%r15)")
    # Rosetta computes the failing case as dest - acc; the SDM says acc - dest. Only ZF can be compared there. See DESIGN.md.
    form(f"cmpxchg{s} r,r", f"cmpxchg{s} {SRC[sz]},{R[sz][7]}", F_Z)
    form(f"cmpxchg{s} r,m", f"cmpxchg{s} {SRC[sz]},8(%r15)", F_Z)
    form(f"lock cmpxchg{s} eq", [f"mov{s} 8(%r15),{DST[sz]}", f"lock cmpxchg{s} {SRC[sz]},8(%r15)"])
    form(f"lock cmpxchg{s}", f"lock cmpxchg{s} {SRC[sz]},8(%r15)", F_Z)
form("movabs", "movabsq $0x123456789abcdef0,%rax", ALL)
form("mov ah,bl", "movb %ah,%bl", ALL)
form("mov bl,ah", "movb %bl,%ah", ALL)
form("mov ah,bh", "movb %ah,%bh", ALL)
form("mov m,ah", ["movq %r15,%rsi", "movb 8(%rsi),%ah"], ALL)
form("mov ah,m", ["movq %r15,%rsi", "movb %ah,8(%rsi)"], ALL)
form("mov imm,bh", "movb $0x5a,%bh", ALL)
form("xchg ah,bl", "xchgb %ah,%bl", ALL)
form("xchg r15-free", "xchgq %rax,%r8", ALL)
form("cmpxchg8b eq", ["movq 8(%r15),%rax", "movq %rax,%rdx", "shrq $32,%rdx", "lock cmpxchg8b 8(%r15)"], F_Z)
form("cmpxchg8b", "cmpxchg8b 8(%r15)", F_Z)
form("cmpxchg16b eq", ["movq 16(%r15),%rax", "movq 24(%r15),%rdx", "lock cmpxchg16b 16(%r15)"], F_Z)
form("cmpxchg16b", "lock cmpxchg16b 16(%r15)", F_Z)

for src, n in (("%bl", "bq"), ("%bx", "wq")):
    form(f"movz{n}", f"movz{n} {src},%rax", ALL)
    form(f"movs{n}", f"movs{n} {src},%rax", ALL)
for n, mem in (("bl", "movzbl"), ("wl", "movzwl")):
    form(f"{mem} m", f"{mem} 8(%r15),%eax", ALL)
    form(f"movs{n} m", f"movs{n} 8(%r15),%eax", ALL)
    form(f"movs{n} m64", f"movs{n[0]}q 8(%r15),%rax", ALL)
form("movzbw", "movzbw %bl,%ax", ALL)
form("movsbw", "movsbw %bl,%ax", ALL)
form("movzbw m", "movzbw 8(%r15),%ax", ALL)
form("movsbl ah", "movsbl %ah,%ebx", ALL)
form("movzbl ah", "movzbl %ah,%ebx", ALL)
form("movslq", "movslq %ebx,%rax", ALL)
form("movslq m", "movslq 8(%r15),%rax", ALL)
form("cbw", "cbtw", ALL)
form("cwde", "cwtl", ALL)
form("cdqe", "cltq", ALL)
form("cwd", "cwtd", ALL)
form("cdq", "cltd", ALL)
form("cqo", "cqto", ALL)
form("bswapq", "bswapq %rax", ALL)
form("bswapl", "bswapl %eax", ALL)
for m in ["(%rbx)", "4(%rbx)", "-4(%rbx)", "0x12345(%rbx)", "(%rbx,%rcx)", "(%rbx,%rcx,2)", "(%rbx,%rcx,4)", "(%rbx,%rcx,8)", "1(%rbx,%rcx,8)",
          "-0x12345(%rbx,%rcx,4)", "(,%rcx,8)", "0x10(,%rcx,2)", "(%rbp)", "(%r13)", "(%r12)", "(%r12,%rcx,2)", "0x7fffffff(%rbx)", "-0x80000000(%rbx)"]:
    form(f"lea64 {m}", f"leaq {m},%rax", ALL)
    form(f"lea32 {m}", f"leal {m},%eax", ALL)
    form(f"lea16 {m}", f"leaw {m},%ax", ALL)
form("lea addr32", "leal (%ebx,%ecx,2),%eax", ALL)
form("lea64 addr32", "leaq 5(%ebx),%rax", ALL)

CC = ["o", "no", "b", "ae", "e", "ne", "be", "a", "s", "ns", "p", "np", "l", "ge", "le", "g"]
for cc in CC:
    form(f"set{cc}", f"set{cc} %bl", ALL)
    form(f"set{cc} m", f"set{cc} 8(%r15)", ALL)
    form(f"set{cc} ah", f"set{cc} %ah", ALL)
    for sz in (8, 4, 2):
        form(f"cmov{cc}{S[sz]}", f"cmov{cc}{S[sz]} {SRC[sz]},{DST[sz]}", ALL)
        form(f"cmov{cc}{S[sz]} m", f"cmov{cc}{S[sz]} 8(%r15),{DST[sz]}", ALL)
    form(f"j{cc} fwd", [f"j{cc} 1f", "movq $1,%r8", "1:"], ALL)
    form(f"j{cc} long", [f"j{cc} 1f", ".skip 200,0x90", "movq $1,%r8", "1:"], ALL)
    # A compare whose flags reach this consumer through a side-exit and a following block.
    form(f"add;j{cc}", ["addq %rbx,%rax", f"j{cc} 1f", "movq $1,%r8", "1:"], ALL)
    form(f"sub;j{cc}", ["subl %ebx,%eax", f"j{cc} 1f", "movq $1,%r8", "1:"], ALL)
    form(f"addb;set{cc}", ["addb %bl,%al", f"set{cc} %cl"], ALL)
    form(f"logic;set{cc}", ["andq %rbx,%rax", f"set{cc} %cl"], ALL & ~F_A)
    form(f"inc;set{cc}", ["incq %rax", f"set{cc} %cl"], ALL)
    form(f"shl;set{cc}", ["shlq $1,%rax", f"set{cc} %cl"], ALL & ~F_A)

form("jrcxz", ["jrcxz 1f", "movq $1,%r8", "1:"], ALL)
form("jecxz", ["jecxz 1f", "movq $1,%r8", "1:"], ALL)
form("loop", ["andq $7,%rcx", "orq $1,%rcx", "1:", "incq %r8", "loop 1b"], F_C)
form("loope", ["andq $7,%rcx", "orq $1,%rcx", "1:", "incl %r8d", "cmpq $3,%r8", "loope 1b"], ALL)
form("loopne", ["andq $7,%rcx", "orq $1,%rcx", "1:", "incl %r8d", "cmpq $3,%r8", "loopne 1b"], ALL)

for op, sub in [("bt", 0), ("bts", 1), ("btr", 2), ("btc", 3)]:
    for sz in (8, 4, 2):
        s = S[sz]
        form(f"{op}{s} r,r", f"{op}{s} {SRC[sz]},{DST[sz]}", F_C)
        form(f"{op}{s} $7,r", f"{op}{s} $7,{DST[sz]}", F_C)
        form(f"{op}{s} $7,m", f"{op}{s} $7,8(%r15)", F_C)
        # The register offset can leave the operand: keep it inside the buffer.
        form(f"{op}{s} r,m", [f"and{s} $0x3f,{SRC[sz]}", f"{op}{s} {SRC[sz]},8(%r15)"], F_C)
        form(f"{op}{s} neg r,m", [f"and{s} $0x1f,{SRC[sz]}", f"neg{s} {SRC[sz]}", f"{op}{s} {SRC[sz]},128(%r15)"], F_C)
        if op != "bt":
            form(f"lock {op}{s} r,m", [f"and{s} $0x3f,{SRC[sz]}", f"lock {op}{s} {SRC[sz]},8(%r15)"], F_C)
            form(f"lock {op}{s} $7,m", f"lock {op}{s} $7,8(%r15)", F_C)
for sz in (8, 4, 2):
    s = S[sz]
    for op in ("bsf", "bsr"):
        # A zero source leaves the destination in practice but the SDM calls it undefined: force a non-zero source.
        form(f"{op}{s} nz", [f"or{s} $0x101,{SRC[sz]}", f"{op}{s} {SRC[sz]},{DST[sz]}"], F_Z)
        form(f"{op}{s} m nz", [f"or{s} $0x101,8(%r15)", f"{op}{s} 8(%r15),{DST[sz]}"], F_Z)

form("pushfq", ["pushfq", "popq %rax"], ALL)
form("lahf", "lahf", ALL)
form("sahf", "sahf", ALL & ~F_O)
form("add;sahf", ["addq %rbx,%rcx", "sahf"], ALL)
form("add;lahf", ["addq %rbx,%rcx", "lahf"], ALL)
form("popfq", ["andq $0x8d5,%rax", "orq $2,%rax", "pushq %rax", "popfq"], ALL)
form("cmc", "cmc", ALL)
form("clc", "clc", ALL)
form("stc", "stc", ALL)
form("std;pushf;cld", ["std", "pushfq", "cld", "popq %rax"], ALL)
form("push r", ["pushq %rax", "popq %rbx"], ALL)
form("push rsp", ["pushq %rsp", "popq %rax", "subq %rsp,%rax"], ALL)
form("pop rsp", ["pushq %rsp", "popq %rsp"], ALL)
form("push imm", ["pushq $-5", "popq %rax"], ALL)
form("push imm8", ["pushq $-1", "popq %rax"], ALL)
form("push m", ["pushq 8(%r15)", "popq %rax"], ALL)
form("pop m", ["pushq %rax", "popq 8(%r15)"], ALL)
form("pop m rsp", ["pushq %rax", "pushq %rbx", "popq (%rsp)", "popq %rcx"], ALL)
form("pushw", ["pushw %ax", "popw %bx"], ALL)
form("leave", ["pushq %rbp", "movq %rsp,%rbp", "pushq %rbx", "leave"], ALL)
form("call;ret", ["call 2f", "jmp 3f", "2:", "incq %rax", "ret", "3:"], ALL)
form("call;ret imm", ["pushq %rcx", "call 2f", "jmp 3f", "2:", "incq %rax", "ret $8", "3:"], ALL)
form("call flags", ["addq %rbx,%rax", "call 2f", "jmp 3f", "2:", "setc %cl", "ret", "3:"], ALL)
form("call*r", ["leaq 2f(%rip),%r8", "call *%r8", "jmp 3f", "2:", "incq %rax", "ret", "3:"], ALL)
form("call*m", ["leaq 2f(%rip),%r8", "movq %r8,8(%r15)", "call *8(%r15)", "jmp 3f", "2:", "incq %rax", "ret", "3:"], ALL)
form("jmp*r", ["leaq 2f(%rip),%r8", "jmp *%r8", "incq %rax", "2:"], ALL)
form("jmp*m", ["leaq 2f(%rip),%r8", "movq %r8,8(%r15)", "jmp *8(%r15)", "incq %rax", "2:"], ALL)
form("push;ret", ["leaq 2f(%rip),%r8", "pushq %r8", "ret", "incq %rax", "2:"], ALL)
form("ret mismatch", ["call 2f", "jmp 4f", "2:", "leaq 3f(%rip),%r8", "movq %r8,(%rsp)", "ret", "3:", "incq %rbx", "4:"], ALL)

# Strings. Pointers point into the buffer, counts are small. rep with a zero count runs too.
SETUP = ["leaq 64(%r15),%rsi", "leaq 128(%r15),%rdi", "andq $31,%rcx"]
for sz, s in ((1, "b"), (2, "w"), (4, "l"), (8, "q")):
    form(f"movs{s}", SETUP + [f"movs{s}"], ALL)
    form(f"rep movs{s}", SETUP + [f"rep movs{s}"], ALL)
    form(f"stos{s}", SETUP + [f"stos{s}"], ALL)
    form(f"rep stos{s}", SETUP + [f"rep stos{s}"], ALL)
    form(f"lods{s}", SETUP + [f"lods{s}"], ALL)
    form(f"scas{s}", SETUP + [f"scas{s}"], ALL)
    form(f"cmps{s}", SETUP + [f"cmps{s}"], ALL)
    form(f"repe scas{s}", SETUP + [f"repe scas{s}"], ALL)
    form(f"repne scas{s}", SETUP + [f"repne scas{s}"], ALL)
    form(f"repe cmps{s}", SETUP + [f"repe cmps{s}"], ALL)
    form(f"repne cmps{s}", SETUP + [f"repne cmps{s}"], ALL)
    form(f"std rep movs{s}", ["leaq 256(%r15),%rsi", "leaq 512(%r15),%rdi", "andq $31,%rcx", "std", f"rep movs{s}", "cld"], ALL)
    form(f"std scas{s}", ["leaq 256(%r15),%rdi", "std", f"scas{s}", "cld"], ALL)
    form(f"rep movs{s} long", ["leaq 1024(%r15),%rsi", "leaq 2048(%r15),%rdi", "movl $200,%ecx", f"rep movs{s}"], ALL)
    form(f"rep stos{s} long", ["leaq 2048(%r15),%rdi", "movl $200,%ecx", f"rep stos{s}"], ALL)
form("rep movsb overlap", ["leaq 64(%r15),%rsi", "leaq 65(%r15),%rdi", "movl $40,%ecx", "rep movsb"], ALL)
form("xlat", ["leaq 8(%r15),%rbx", "xlat"], ALL)
form("nop", "nop", ALL)
form("nopw", "nopw 8(%rax,%rax,2)", ALL)
form("pause", "pause", ALL)
form("mfence", "mfence", ALL)
form("sfence", "sfence", ALL)
form("lfence", "lfence", ALL)
form("prefetch", "prefetcht0 (%r15)", ALL)
form("clflush", "clflush (%r15)", ALL)
form("movnti", "movntiq %rbx,8(%r15)", ALL)
form("fs-free rip", ["movq buffer_ptr_cell(%rip),%rax"], ALL)

# ---- SSE ----
FP = "fp"
for op, enc in [("add", "add"), ("sub", "sub"), ("mul", "mul"), ("div", "div"), ("min", "min"), ("max", "max"), ("sqrt", "sqrt")]:
    for t in ("ps", "pd", "ss", "sd"):
        form(f"{op}{t} x,x", f"{enc}{t} %xmm2,%xmm1", ALL, FP)
        form(f"{op}{t} m,x", f"{enc}{t} 32(%r15),%xmm1", ALL, FP)
        form(f"{op}{t} high regs", f"{enc}{t} %xmm12,%xmm9", ALL, FP)
for op in ["and", "andn", "or", "xor"]:
    for t in ("ps", "pd"):
        form(f"{op}{t} x,x", f"{op}{t} %xmm2,%xmm1", ALL, FP)
        form(f"{op}{t} m,x", f"{op}{t} 32(%r15),%xmm1", ALL, FP)
for pred in range(8):
    for t in ("ps", "pd", "ss", "sd"):
        form(f"cmp{pred}{t}", f"cmp{t} ${pred},%xmm2,%xmm1", ALL, FP)
        form(f"cmp{pred}{t} m", f"cmp{t} ${pred},32(%r15),%xmm1", ALL, FP)
for op in ("ucomiss", "ucomisd", "comiss", "comisd"):
    form(f"{op}", f"{op} %xmm2,%xmm1", ALL, FP)
    form(f"{op} m", f"{op} 32(%r15),%xmm1", ALL, FP)
    form(f"{op};seta", [f"{op} %xmm2,%xmm1", "seta %al", "setp %bl", "setb %cl", "sete %dl"], ALL, FP)
    form(f"{op};jp", [f"{op} %xmm2,%xmm1", "jp 1f", "movq $1,%r8", "1:"], ALL, FP)

for a, b in [("movaps", "%xmm2,%xmm1"), ("movapd", "%xmm2,%xmm1"), ("movups", "%xmm2,%xmm1"), ("movupd", "%xmm2,%xmm1"),
             ("movss", "%xmm2,%xmm1"), ("movsd", "%xmm2,%xmm1"), ("movhlps", "%xmm2,%xmm1"), ("movlhps", "%xmm2,%xmm1"),
             ("movdqa", "%xmm2,%xmm1"), ("movdqu", "%xmm2,%xmm1"), ("movq", "%xmm2,%xmm1"),
             ("movaps", "32(%r15),%xmm1"), ("movaps", "%xmm1,32(%r15)"), ("movapd", "32(%r15),%xmm1"), ("movups", "33(%r15),%xmm1"),
             ("movups", "%xmm1,33(%r15)"), ("movupd", "37(%r15),%xmm1"), ("movdqa", "32(%r15),%xmm1"), ("movdqa", "%xmm1,32(%r15)"),
             ("movdqu", "35(%r15),%xmm1"), ("movdqu", "%xmm1,35(%r15)"), ("movss", "32(%r15),%xmm1"), ("movss", "%xmm1,33(%r15)"),
             ("movsd", "32(%r15),%xmm1"), ("movsd", "%xmm1,33(%r15)"), ("movlps", "32(%r15),%xmm1"), ("movlps", "%xmm1,33(%r15)"),
             ("movhps", "32(%r15),%xmm1"), ("movhps", "%xmm1,33(%r15)"), ("movlpd", "32(%r15),%xmm1"), ("movlpd", "%xmm1,33(%r15)"),
             ("movhpd", "32(%r15),%xmm1"), ("movhpd", "%xmm1,33(%r15)"), ("movq", "32(%r15),%xmm1"), ("movq", "%xmm1,33(%r15)"),
             ("movd", "%eax,%xmm1"), ("movd", "%xmm1,%eax"), ("movd", "32(%r15),%xmm1"), ("movd", "%xmm1,33(%r15)"),
             ("movq", "%rax,%xmm1"), ("movq", "%xmm1,%rax"), ("movntps", "%xmm1,32(%r15)"), ("movntpd", "%xmm1,32(%r15)"),
             ("movntdq", "%xmm1,32(%r15)"), ("movmskps", "%xmm1,%eax"), ("movmskpd", "%xmm1,%eax"), ("pmovmskb", "%xmm1,%eax")]:
    form(f"{a} {b}", f"{a} {b}", ALL, FP)

for op in ("cvtsi2ss", "cvtsi2sd"):
    form(f"{op}l r", f"{op}l %eax,%xmm1", ALL, FP)
    form(f"{op}q r", f"{op}q %rax,%xmm1", ALL, FP)
    form(f"{op}l m", f"{op}l 8(%r15),%xmm1", ALL, FP)
    form(f"{op}q m", f"{op}q 8(%r15),%xmm1", ALL, FP)
for op in ("cvtss2si", "cvttss2si", "cvtsd2si", "cvttsd2si"):
    form(f"{op} l", f"{op} %xmm2,%eax", ALL, FP)
    form(f"{op} q", f"{op} %xmm2,%rax", ALL, FP)
    form(f"{op} m", f"{op} 32(%r15),%eax", ALL, FP)
for op in ("cvtss2sd", "cvtsd2ss", "cvtps2pd", "cvtpd2ps", "cvtdq2ps", "cvtps2dq", "cvttps2dq", "cvtdq2pd", "cvttpd2dq", "cvtpd2dq"):
    form(f"{op} x", f"{op} %xmm2,%xmm1", ALL, FP)
    form(f"{op} m", f"{op} 32(%r15),%xmm1", ALL, FP)
for imm in (0, 0x1b, 0xe4, 0x4e, 0xff, 0xa5):
    form(f"shufps {imm}", f"shufps ${imm},%xmm2,%xmm1", ALL, FP)
    form(f"shufps {imm} m", f"shufps ${imm},32(%r15),%xmm1", ALL, FP)
    form(f"pshufd {imm}", f"pshufd ${imm},%xmm2,%xmm1", ALL, FP)
    form(f"pshuflw {imm}", f"pshuflw ${imm},%xmm2,%xmm1", ALL, FP)
    form(f"pshufhw {imm}", f"pshufhw ${imm},%xmm2,%xmm1", ALL, FP)
    form(f"pshufd {imm} same", f"pshufd ${imm},%xmm1,%xmm1", ALL, FP)
    form(f"pshuflw {imm} same", f"pshuflw ${imm},%xmm1,%xmm1", ALL, FP)
for imm in (0, 1, 2, 3):
    form(f"shufpd {imm}", f"shufpd ${imm},%xmm2,%xmm1", ALL, FP)
    form(f"shufpd {imm} same", f"shufpd ${imm},%xmm1,%xmm1", ALL, FP)
for op in ["unpcklps", "unpckhps", "unpcklpd", "unpckhpd", "punpcklbw", "punpcklwd", "punpckldq", "punpcklqdq", "punpckhbw", "punpckhwd",
           "punpckhdq", "punpckhqdq", "packsswb", "packssdw", "packuswb", "paddb", "paddw", "paddd", "paddq", "psubb", "psubw", "psubd", "psubq",
           "paddsb", "paddsw", "paddusb", "paddusw", "psubsb", "psubsw", "psubusb", "psubusw", "pmullw", "pmulhw", "pmulhuw", "pmuludq", "pmaddwd",
           "pavgb", "pavgw", "pminub", "pmaxub", "pminsw", "pmaxsw", "psadbw", "pcmpeqb", "pcmpeqw", "pcmpeqd", "pcmpgtb", "pcmpgtw", "pcmpgtd",
           "pand", "pandn", "por", "pxor"]:
    form(f"{op} x", f"{op} %xmm2,%xmm1", ALL, FP)
    form(f"{op} m", f"{op} 32(%r15),%xmm1", ALL, FP)
    form(f"{op} same", f"{op} %xmm1,%xmm1", ALL, FP)
for op in ["psllw", "pslld", "psllq", "psrlw", "psrld", "psrlq", "psraw", "psrad"]:
    form(f"{op} x", ["movdqa %xmm2,%xmm3", f"{op} %xmm3,%xmm1"], ALL, FP)
    form(f"{op} small", ["movd %eax,%xmm3", "pslldq $0,%xmm3", "psrlq $60,%xmm3", f"{op} %xmm3,%xmm1"], ALL, FP)
    for imm in (0, 1, 7, 15, 16, 31, 33, 63, 64, 200):
        form(f"{op} ${imm}", f"{op} ${imm},%xmm1", ALL, FP)
for imm in (0, 1, 7, 15, 16, 200):
    form(f"pslldq ${imm}", f"pslldq ${imm},%xmm1", ALL, FP)
    form(f"psrldq ${imm}", f"psrldq ${imm},%xmm1", ALL, FP)
for i in (0, 3, 7):
    form(f"pinsrw {i} r", f"pinsrw ${i},%eax,%xmm1", ALL, FP)
    form(f"pinsrw {i} m", f"pinsrw ${i},8(%r15),%xmm1", ALL, FP)
    form(f"pextrw {i}", f"pextrw ${i},%xmm1,%eax", ALL, FP)

out = [".text", ".globl _fuzz_forms", ".p2align 4"]
for i, (name, body, mask, kind) in enumerate(forms):
    out.append(f"Lf{i}:")
    out.append("  call _fuzz_load" if kind == "int" else "  call _fuzz_load_fp")
    out.extend("  " + b for b in body)
    out.append("  jmp _fuzz_save")
    out.append(".p2align 2")
out.append(".const_data")
out.append(".globl _fuzz_table")
out.append(".p2align 3")
out.append("_fuzz_table:")
for i, (name, body, mask, kind) in enumerate(forms):
    out.append(f"  .quad Lf{i}, Ln{i}")
    out.append(f"  .long {mask}, {1 if kind == 'fp' else 0}")
out.append("  .quad 0, 0, 0")
out.append(".cstring")
for i, (name, body, mask, kind) in enumerate(forms):
    esc = name.replace('"', '\\"').replace("\\", "\\\\")
    out.append(f'Ln{i}: .asciz "{esc}"')
open(sys.argv[1], "w").write("\n".join(out) + "\n")
print(f"{len(forms)} forms", file=sys.stderr)
