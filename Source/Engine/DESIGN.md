# HV engine: x86-64 translated code inside an HVF VM

A library for running x86-64 guests on Apple silicon: an x86-to-AArch64 translator whose output runs inside a Hypervisor.framework VM, with
hardware 4 KB stage-1 translation, EnTSO, and a small EL1 monitor. QEMU is meant to keep the devices and machine.

Build: `Source/Engine/build.sh` (monitor blob, x86 test images, Swift package, signing). Test: `Tests/run-all.sh`. Numbers: `Tests/bench.py`,
`engine-run --kernel .build/images/kernel`, `engine-run --smp 4 .build/images/smp`, `Tests/smp-probe/run.sh`, `engine-run .build/images/t_callret`, `t_rep`, `t_smc`.

| Path | What |
|---|---|
| `Monitor/` | EL1 monitor in freestanding C, vectors and EL0 stubs in assembly |
| `Sources/CEngine/` | Decoder, block builder and emitters (C), ABI shared with the monitor, `engine_api.h` for QEMU |
| `Sources/Engine/` | Control plane (Swift): VM setup, run loop, guests, the C API |
| `Tests/x86/` | Flat test images, the fuzz generator, the test kernel |
| `vendor/qemu/target/i386/tcg/system/hvdbt.c` | The QEMU side: hand-off from TCG, state both ways, device callbacks. See "Hybrid with TCG" |

Everything below separates **measured** from **not measured**. Measured means on this machine: M4 Max, macOS 27.2, other work running (load 8), so
numbers are best of N and move 10-20% between runs. No Intel hardware was used: Rosetta is the reference, and where it disagrees with the SDM that is noted.

## Status against the ladder

| Rung | State |
|---|---|
| 1. Translator coverage | Done: integer ISA, flags, LSE, bl/ret, per-site indirect, SSE, SSE2, SSE3, SSSE3, MXCSR, rep, SMC, MMX, x87 but for the forms listed below. 32-bit user code runs in compatibility mode: see "Compatibility mode" |
| 2. Differential testing | Done: fuzz, QEMU test-i386, a compiled corpus, lc-bench arithmetic, all matching Rosetta |
| 3. Kernel model | Done: shadow paging, CR3 and PCID, IDT, syscall, iret, exceptions, in the monitor, passing a test kernel |
| 4. APIC and device interface | Done: in-VM APIC hot paths; `engine_api.h`, exercised by a harness |
| 5. QEMU accel | Hybrid with TCG written; never built into QEMU or booted. XNU has never run. See "Hybrid with TCG" |

## Measured: correctness

Each is a transcript or self-check, run by `Tests/run-all.sh`.

- **Fuzz.** 3836 instruction forms (`gen_fuzz.py`), 64 rounds each with random registers, flags, memory, rounding modes, FTZ and DAZ, and FP patterns
  (NaNs, SNaNs, denormals, infinities). Hash of all registers, masked flags, XMM, MXCSR and 8 KB of memory. Identical to Rosetta, in both flag modes.
  494 forms are x87, 256 rounds each: every register encoding with four ST(i) choices and every memory encoding, from a random stack depth, control word and operand, taking in the FXSAVE image (the first run at 5000 rounds found two more corner cases, fixed).
  Half of them also get pseudo-denormals, unnormals, pseudo-NaNs and pseudo-infinities.
- **QEMU `tests/tcg/i386/test-i386.c`** in 64-bit mode, unmodified but for a Mach-O section name, assembler spellings and Linux-only register names: 9505 transcript lines
  identical, `test_floats` among them. Its libm calls are short long double series here, since `fsin` and friends stay on TCG; `fmod`, `sqrt` and `rint` are the instructions. Out of it: test_fenv's two status lines from data16 images (below), `test_enter` (Rosetta raises SIGILL on `enter`, so ours is unchecked against any reference), and 16-bit shld/shrd with
  counts above 16 (undefined; results match, Rosetta's CF does not).
- **`t_x87`.** Compiled long double code: Mandelbrot, conversions in every width, arithmetic under each rounding and precision mode. Same hash as Rosetta.
- **Compiled corpus.** SHA-256, an LZ codec, sorting, a jump-table interpreter, bignum, FP matrices, MXCSR modes, varargs, struct returns, at -O0, -O1, -O2, -O3, -Os and -mssse3 -O3.
- **SMC.** Patch and call, patching the next instruction in the same block, rewriting a return target. Never stale, same output as Rosetta.
- **Test kernel** (`Tests/x86/kernel/`), ring 0 and ring 3, high-half kernel. Checks: syscall and sysret, #PF with CR2 and error codes, #GP, #UD, #DE, int3, int n, fetch faults, NX,
  demand paging, copy on write, precise frames (flags before a faulting load; `add` to a read-only page changes nothing), `rep movsb` faulting across pages and resuming,
  straddling loads and stores, PCID address spaces with the same VA holding different data and code, code remapped under running translations, 80 address spaces with
  LRU eviction of views, #DF on an IST stack, timer interrupts through ring 3 spin loops, sti shadow, TPR masking, level and edge vectors from the host.
- **The same kernel through `engine_api.h`**, with a thread forcing an x86-boundary stop every 2 ms and a full CPU state read and write-back each time: about 1000 stops, all checks pass.

Findings about the reference:
- Rosetta computes a failing `cmpxchg` as dest - acc. The SDM, and QEMU, have acc - dest. Only ZF is compared there; the engine follows the SDM.
- Rosetta raises SIGILL on `enter`.
- One form, `stmxcsr`/`ldmxcsr` round trip through the stack, gives a varying result from run to run under Rosetta. It is out of the fuzz set; the engine gives one answer.
- `rcpps` and `rsqrtps` stop: Intel's approximation tables are not reproduced, so they could not be exact.
- Rosetta's x87 values and flags match this monitor on every comparable form, down to denormal and NaN corners, so where it differs from the SDM these checks follow the SDM and `hybrid.c` tests that, the fuzz masking it:
  - FXSAVE and FNSAVE images show empty registers as the indefinite. A CPU keeps what they held.
  - FIP, FDP and FOP are zero or stale bytes, in every image. The reserved words of an FNSTENV image are zero where, from memory of real dumps, a CPU writes ones. Nothing here was checked on Intel hardware.
  - After a stack fault, an empty operand acts as a NaN under the NaN rules; the SDM's masked response is the indefinite.
  - data16 FNSTENV and FNSAVE write the 32-bit layout, not the 14-byte one.
  - `fbld` onto a full stack loads the value with no fault.
  - MMX instructions don't change TOP or the tags in its FXSAVE image, and don't set exponents to ones. The SDM has TOP 0, all valid, exponent all ones.
  - A denormal divided by zero reports #Z and not #D. The SDM's priority list suggests both; followed here, unverified.

Hardware facts measured on the way:
- HVF accepts only `ACTLR_EL1` bit 1 (EnTSO); every other bit is refused. So PF and AF cannot come from hardware here and stay lazy: `R_PF` holds the last result, `R_AF ^ R_PF` bit 4 is AF.
- FEAT_AFP works in the guest. With FPCR.AH and NEP: `fmax` returns the second operand, default NaN is `ffc00000`, scalar ops keep upper lanes. So SSE is near 1:1, and FP flags matched the fuzz.
- EL0 software step traps to EL1 with no host exit. MDSCR_EL1.SS with SPSR.SS clear traps at once, so it is toggled only while stepping.
- `hv_vcpu_set_pending_interrupt` is forgotten at every exit: the run loop reasserts it until the monitor takes it.
- A stage-1 data abort taken at EL1 has no valid ISV here, so MMIO and page-table stores are emulated by decoding the ARM word.
- EnTSO has a cost on exceptions: syscall round trip 106 ns off vs 137 ns on, nothing visible on plain code.
- A store straddling into an unmapped page left the first page unchanged, the one case tested. CR2 was right.
- Execute-only stage-1 mappings work: EL0 runs the code cache and cannot read it.

## Measured: speed

`Tests/bench.py 3 25`, best of 3, load 8. The flat image holds lc-bench's arithmetic; "rosetta-flat" is the same bytes under Rosetta, so same memcpy, no AOT. "engine-fast" drops
flag precision at faulting instructions.

| test | unit | engine | engine-fast | rosetta-flat | native | rosetta-full | engine/rosetta-flat | engine/native |
|---|---|---|---|---|---|---|---|---|
| alu | ns/iter | 2.235 | 2.233 | 2.182 | 1.758 | 2.191 | 1.02 | 1.27 |
| branchy | ns/iter | 12.296 | 12.269 | 11.637 | 8.107 | 12.738 | 1.06 | 1.52 |
| chase_16k | ns/load | 0.752 | 0.752 | 0.753 | 0.753 | 0.758 | 1.00 | 1.00 |
| chase_1m | ns/load | 7.743 | 7.778 | 7.897 | 6.744 | 8.002 | 0.98 | 1.15 |
| chase_64m | ns/load | 102.030 | 102.007 | 81.312 | 89.090 | 78.882 | 1.25 | 1.15 |
| memcpy | MB/s | 49488 | 52746 | 53220 | 82225 | 42091 | 1.08 | 1.66 |
| sse_float | ns/iter | 2.760 | 2.759 | 2.558 | 2.762 | 2.761 | 1.08 | 1.00 |
| scalar_double | ns/iter | 3.260 | 3.065 | 3.259 | 3.275 | 3.265 | 1.00 | 1.00 |
| cas_uncontended | ns/op | 0.816 | 0.815 | 1.152 | 1.052 | 1.152 | 0.71 | 0.78 |
| largecode_cold | ns/function | 2371 | 2383 | 4696 | 24 | 224 | 0.50 | 98 |
| largecode_warm | ns/call | 19.5 | 19.6 | 19.9 | 10.2 | 26.7 | 0.98 | 1.91 |

Reading it: steady-state parity with Rosetta. Exact flags at every faulting instruction cost nothing measurable, so they stay on. The 64 MB chase is 1.25x (4 KB stage 1 under 16 KB stage 2; the spike
saw 13% from 2 MB stage-1 blocks, not built). Cold code is 2.4 us per function, a host exit per block: better than Rosetta's JIT on the same image, 10x its AOT. `lc-bench`'s TCG baseline in earlier notes was alu 2.98, branchy 20.6,
chase_16k 2.73, sse_float 10.7, cas 4.27, largecode_warm 399 (112 with tail dispatch), in VM clones, so conditions differ.

Call and return, `t_callret`, ns:

| Sites or depth | Engine | Rosetta |
|---|---|---|
| ret, 1 / 16 / 256 / 4096 / 16384 sites | 0.71 / 0.50 / 0.80 / 0.80 / 0.90 | 0.74 / 0.51 / 0.80 / 0.83 / 4.30 |
| pop + jmp*, same sites | 1.26 / 1.29 / 1.64 / 10.6 / 17.4 | 3.67 / 3.22 / 3.88 / 16.3 / 21.8 |
| recursion, depth 8 / 48 / 64 / 1000 / 100000 | 0.84 / 0.74 / 4.32 / 4.35 / 1.79 | 0.81 / 0.78 / 4.29 / 4.36 / 2.92 |

Strings, `t_rep`, 256 KB: `rep movsb` 48 GB/s vs Rosetta 3.9; `rep movsq` 48 vs 30; `rep stosq` 77 vs 31.
SMC, `t_smc`: patch and call 5.2 us vs Rosetta 14.1; data write in a code page and call 4.8 vs 14.0; next page 1.1 ns on both.

Kernel model, translated code in `engine-run --kernel`, ranges over runs, ns. The guest clock is a 24 MHz counter shown as 1 GHz, so figures are means over long loops.

| Path | ns |
|---|---|
| syscall + sysret round trip, stack swap, kernel stub | 122-147 (106 with EnTSO off) |
| int from ring 0, 15 pushes, C handler, iret | 203-227 |
| CR3 write with PCID, kept shadows | 81-97 |
| Shadow fill, fault to resumed guest (walk included, no x86 event) | 115-141 |
| Page-table store, slot empty (trap, decode, store, mirror lookup) | 55-78 |
| Page-table `lock cmpxchg`, slot empty | 47-56 |
| Page-table store dropping a live entry with TLBI | 280-950, few samples, TLBI under load |
| Dirty upgrade, no x86 fault | 470-700 |
| Demand fault: x86 #PF, handler, PTE store, fill, iret; kernel zeroes 4 KB with a byte loop | 1170-1340 |
| In-VM APIC read / TPR write / EOI | 84-102 / 99-115 / 98-115 |
| Self IPI: trap, delivery, handler with register save, EOI, iret | 1055-1203 |
| Device MMIO through the host, no device model, Swift dictionary as device | 790-930 |
| Port write through the host | 730-840 |
| New address space, first run in a loop | 67-85 us, 1 block translated (user code); kernel code is shared |
| Return to an evicted address space | 23-36 us |

Overhead estimate from these, at the real-guest rates in the brief (4 vCPU totals). Translated kernel work and device models are not counted, nor are cold translation and IPIs between vCPUs, as nothing measured them.

| Event | Rate/s | Cost | ms per second |
|---|---|---|---|
| Syscall + return | 50,000 | 140 ns | 7 |
| Exception + iret | 32,000 | 220 ns | 7 |
| MMIO, APIC half | 57,000 | 110 ns | 6 |
| MMIO, the rest | 57,000 | 900 ns | 51 |
| Interrupt delivery | 10,000 | 1200 ns | 12 |
| CR3 write | 9,000 | 95 ns | 1 |
| **Total** | | | **84** (2% of 4 vCPUs) |
| Each 100,000 page-table stores/s | | 60-300 ns | 6-30 |

## How it works

- **Registers.** x86 GPRs in x0-x15, XMM in v0-v15, as in Rosetta. x18 context, x19 lookup table, x21 and x25 lazy PF and AF, x26 return stack, x27 and x28 GS and FS bases. NZCV holds CF inverted, ZF, SF, OF.
- **Both x86 rings run at EL0.** A view is an address space seen from one CPL: its own shadow roots, ASID, lookup table and return stack. A CPL change is a TTBR swap in the monitor, about 9 ns (spike). This differs from the earlier
  plan of CPL0 at EL1: guest kernel code then never holds EL1, so a stray store cannot reach monitor state, and there is one fault path. Not measured against the EL1 alternative, which would share kernel TLB entries across processes.
- **The monitor** is entered by svc and faults. It stays out of translation, which runs on the host through `hvc`, about 1 us plus translation per block.
- **Precise state.** Nothing guest-visible changes before an instruction's last access that can fault: read-modify-writes compute with non-flag instructions, store, then set flags. A PC map per block gives the x86 rip.
- **Interrupts** arrive at any ARM word. The monitor single-steps to the next x86 boundary, at one trap per word while one waits, and costs nothing otherwise. Timer ticks in the kernel test needed a few steps each; the self-IPI loop needed none, since its interrupt arrives right after an emulated store.
- **Control flow.** Direct branches chain once a stub has fired. `call` pushes the guest return, pushes {x86, arm} on a shadow stack, and uses `bl`; `ret` compares and uses `ret`. A mismatch resets the stack, and the guest's value stays authoritative. Overflow hits a guard page. Indirect branches do
  a hash lookup in a shared stub and `br` at the site.
- **Translation scope.** Block maps are per view, except ring-0 code in the high half, which is shared by every address space reaching it through the same PML4 target. Links only join blocks of one domain.
- **SMC.** A frame with code is mapped read-only. A store kills the frame's blocks (their entries become traps), drops return stacks, runs the store from a one-off block, and leaves the page writable until code runs from it again.
- **Shadow paging.** Shadow tables mirror guest tables one to one, per view, and every guest table frame is write-protected. A guest write drops the mirroring entries; the next access refills. Since the shadow never holds a stale entry, CR3 reload, `invlpg` and PCID flushes need no work. A table written 64 times with no walk through it is
  unshadowed, so a freed table reused as data stops trapping. A and D are set by the walker; a clean page stays read-only until written.
- **APIC.** Register page in the monitor, by ARM word decode. Timer on the virtual counter: the compare's exit raises the IRQ line, the monitor rearms, then the host unmasks. Anything for other CPUs or level-triggered EOIs goes to the host.
- **x87.** `Monitor/x87.c`, integer arithmetic on 80-bit values, exact at 24, 53 and 64 bits under each RC. State is in `EngineCtx` beside the MMX registers: significands in `mm`, physical order, and exponents, TOP, tags, status, control and pointers next to them. Every operation is one `svc` with its opcode and rip as a literal. A memory operand moves in translated code, so a fault, a device, a tracked frame or a split takes the path any move does. For a store the monitor returns the value and the new TOP, tags and status as one word; translated code writes memory, then that word, so state is precise at a fault. An 80-bit store first writes its low eight bytes back, so that neither page changes if either faults.
  Every masked response follows the SDM. An operation with an exception unmasked or pending goes to TCG before it changes anything, as only TCG raises #MF. `fnstenv`, `fnsave` and `fxsave` write through the monitor's walker after translated code probes both ends; a device or tracked frame there goes to TCG, whose writes are noted.
  What stays on TCG, by name in the tally: `f2xm1 fyl2x fptan fpatan fyl2xp1 fsincos fsin fcos` (TCG's own are only approximations, through host doubles for some, and nothing has shown them hot), reserved encodings and undocumented aliases, the 287 no-ops, unmasked or pending exceptions, and fxsave or fxrstor with an unmasked MXCSR, no OSFXSR or FFXSE.
- **Devices.** MMIO completes the faulting ARM load or store, so every x86 form of a move or read-modify-write works. Pairs, SIMD and atomics on a device stop, except `rep movs` and `stos`, which fall back to the per-element loop.

## Hybrid with TCG

The first contact with a real guest, built to find out what is missing rather than to be fast. One vCPU. `-Dhvdbt_engine=<Source/Engine>` builds it into QEMU, `LC_HVDBT=1` turns it on, `LC_HVDBT_TALLY=<file>` writes the tally. Without them no behaviour changes: the hooks are a null pointer test on slow paths (TB miss, kick, notdirty, DMA).

- **Hand-off.** TCG runs firmware and boot loaders. The first TB miss in 64-bit mode at a high-half address is XNU's `vstart`: the engine takes the state from `CPUX86State` and runs on TCG's vCPU thread.
- **Fallback.** Anything the engine can't do returns `ENGINE_RUN_FALLBACK` with the state precise at that instruction, as for an x86 fault. TCG runs that one instruction (`CF_NOIRQ`, count 1) and the next TB miss returns control. No normal TB is ever generated for a state the engine accepts, so a miss always comes. An instruction leaving 64-bit mode, or setting TF, means TCG keeps going until the state is acceptable: 32-bit processes run this way, slowly and correctly, as far as reading goes.
- **What goes back by design**, as its state stays QEMU's: `hlt`, `mov cr8`, every MSR but the syscall family, all #UD (SSE4 and AES are advertised, and only TCG knows them), popcnt (below). The monitor's `stop` is the mechanism, so each old "stops with a clear error" with a known rip now falls back. Stops with no rip are about the engine's limits and stay final, with a register dump and the VM paused.
- **The APIC is QEMU's**, in both halves. The in-VM APIC is off, each access is a host exit, and the rates above don't apply. Interrupts are level-triggered as QEMU sees them: `irq_line` says one may wait, and the monitor acknowledges only when IF allows, since an acknowledged vector has left the APIC.
- **RAM.** One host block, GPA 0 up to `ram_below_4g` and 4 GB upward, with `PI_RAM` per frame for holes inside that: anything else reaches the device callbacks. The map is read once at hand-off.
- **Writes behind the monitor.** DMA (`invalidate_and_set_dirty`) and TCG (`notdirty_write`, with every RAM page kept clean so each first write hits it) put frames holding code or page tables on a ring. The monitor drains it on every exit and treats them as trapped stores. TCG sees engine writes differently: the stepped page's TBs are dropped each fallback, and all TBs after any run of normal TBs.
- **CR0.TS** now traps EL0 SIMD through FPEN and gives #NM, in all modes. XNU's lazy FP depends on it. Integer emitters that used NEON can't run under it: popcnt falls back in hybrid mode, `rep stos` skips its bulk stub, and `rep movs` backs out of its stub to the plain loop.
- **TSC.** Same steps as `cpu_get_tsc` from the same clock, so TCG and the engine agree.

Measured (`engine-run --hybrid`, `Tests/x86/kernel/hybrid.c`, which plays TCG by hand, not TCG itself): RAM split at 1 GB with the rest at 4 GB, mapped as `memory-backend-shm` does it, tables, code and data above 4 GB; a hole and a marked low page reaching device callbacks; state preserved across each fallback kind with the host changing registers, CR3, CR0.TS and CS; notes for code and tables, with ring overflow; #NM; no acknowledge with IF clear; 1.2 GHz TSC; about 10 boundary stops per run. Also: QEMU's configure accepts the option, and `libEngine.a` links into a C program at QEMU's deployment target and creates a hybrid engine.

First real boot, Mavericks: it builds and links, the hand-off fires, and the engine runs 3699 x86 instructions and 28 fallbacks, MSRs and one CR4 write. The value 0x60 sets MCE, which neither the monitor nor the accelerator allowed, so TCG kept the vCPU from then on and every engine counter froze. Whether the guest went on under TCG was not observed. The same run showed page walks counted as stores: 114 table frames noted in 28 fallbacks, about four levels each, and 221 of 224 blocks invalidated as a result. Both are fixed; the fixes have not been booted.

A watchdog thread reports to the session log after 5 s with no progress: registers, bytes at rip and rsp, APIC, interrupt state, whether the vCPU is in `hv_vcpu_run`. The tally's top lines now say when the vCPU is on TCG and why, and rip samples are marked engine or tcg.

Second and third boots, the same build, 174 s and longer: on the engine throughout, with 34078 cold blocks and 865651 cold x86 instructions in 50 ms of translation, 197 page-table stores/s. Both runs reached the same 5777 page faults and 102 syscalls and stayed there, at about 175,000 iret/s and two CR3 writes per iret, with no stop reason and no disk writes. The vector table and event ring added for this named it in a fourth boot: `sidt [rbp-0x40]` at CPL 3, `0f 01 4d c0`, taking #GP 168,000 times a second. The emitter treated all of `0F 01` /0-/3 as privileged, but sgdt and sidt are not, without UMIP. XNU was doing nothing wrong. Disassembling the dumped kernel shows `user_trap` mapping it to EXC_BAD_ACCESS, code 13, and into `exception_triage`, and the two CR3 writes are in `pmap_pcid_activate`, a switch to a kernel-task thread and back. Fixed and tested from ring 3.

Fifth boot: real userland for 17 s, the disk written, 39,200 syscalls, 25,153 page faults, 437,837 cold blocks and 9.6M cold x86 instructions in 533 ms of translation, 1.9M page-table stores (about 110,000/s). Then an EL1 instruction abort, translation fault level 0, at the entry of `translate_here`. The dump's registers were the monitor's: x9 holds a TTBR0 value with ASID 59, x10 that view's hash table, x13 an rmap node, so it had just evicted a view, built view 58 and activated it. Its rip was only the last fallback, a clts with nothing to do with it. Nothing but a walk that saw the root's private slot unwritten fits: no barrier stood between building a root and the first fetch through it. That is inferred, and a test of the same shape never reproduced it; the barrier is now there, and a stomped root would stop by name.

Fallbacks in that run, totals and time on TCG, of 17 s: unknown opcode 44,889, 445 ms, of which pclmulqdq 37,727; clts 16,752, 144 ms, now done in the monitor; fxsave and fxrstor 13,249, 151 ms; `wrmsr 0x6e0` 12,784, 122 ms; x87 8,132, 79 ms; hlt 847, 170 ms, mostly waiting; split store on a page table 64, 194 ms. About 1.3 s in all. 396,297 of 437,837 blocks were invalidated, and each process retranslates its shared libraries, so sharing user translations looks larger than any fallback; that has not been measured. MMIO was 25,000/s, nearly all a 33-page rectangle in the framebuffer BAR redrawn at a steady rate. A BAR is never `pc.ram`, so it reaches the host per access whatever the map says; mapping VRAM in stage 2 would be new work, and at this rate is not what limits the boot.

Later boots halted cleanly at 6 to 10 s. The guest asked: `reboot` from user space, through the ACPI kext's write of SLP_EN, after `fsck_hfs` ran on a page that failed its code-signing hash. The kernel counted 1 bad hash in 939 validations, at file offset 0x2c000, so SHA-1 mostly works and either that page or that one hash was wrong. Which, and why, is open. A two-task lazy FP test through clts, #NM, fxsave, fxrstor, interrupts and fallbacks passes, so that path is not shown to be at fault, though the harness plays fxsave rather than TCG. A bulk `rep movs` into a page-table frame was left stale past the first slots; that was a real bug, now fixed, and not shown to be this one. `LC_HVDBT_CLTS_TCG=1` runs clts on TCG for comparison, and `LC_HVDBT_RAM` writes guest RAM at shutdown.

More runs: the halt is intermittent, and comes with or without a bad hash. Reading a halted run's RAM, the caller of `reboot` is launchctl, pid 2, and its image holds "fsck failed! Shutting down in 3 seconds", so `fsck` failing looks like the trigger and the hash like a separate symptom. Nothing yet says why `fsck` failed. A 300 s run that didn't halt also shows 198 user #GP and 41 int3, both in dyld by their bytes (its fatal-error int3 at +0x109c, a load through a non-canonical r13 at +0xdb7c), and never touches the UART ports the guest agent uses, while its boot spinner still runs. A later run names the trigger: `cc_fips_test -P` exits 255 and launchctl halts. Its log shows no AES or PCLMUL fallback in user mode before that, and one halted run's RAM holds a lone second copy of "Integrity test failed", so the failing step looks like a hash over the library's text, not those instructions. The tally now logs spawns, exits, wait4 results and user faults with registers, and `LC_HVDBT_NO_BULK`, `LC_HVDBT_NO_RETURN_PREDICTION` and `LC_HVDBT_ALL_FLAGS` each drop one optimisation for comparison.

Split stores, measured in the hybrid test: when only the second page of a split store refuses it, FAR is that page's start, and the page-table path then wrote every byte at the start of the frame. An 8-byte store one byte before the boundary left the whole value in the frame's first slot. A pair or SIMD store across two tracked frames left the first one writable, so later writes through it were unseen. Both now go to TCG, as does a split device access. Not known: whether this caused the corrupt files seen in boots. Diffs of the RAM kept from one batch found no wrong bytes, though the run with the damaged prologue kept none; the tally's rows `split store on a page table` and `split access across a device page` show whether it fires in a boot.

The split-store fix took 40 boots' 20 halts to 0 of 32, with no FIPS failures, fsck signals or user faults in 30 s runs. On a longer run, userland reached the guest agent and its first commands ran at about 176 s, then staging timed out because, from about 180 s, one kernel-extension pixel loop of nine MMX instructions held the vCPU for at least 50 s at about 119 us per pass. Measured from the tally: 9 fallbacks and about 6.4 device accesses per pass, and no CR3 writes for long stretches. That is the reason MMX is now translated. Everything but maskmovq is, and 358 forms match Rosetta. The MMX forms of cvtpi, movq2dq and SSSE3 remain with TCG. Not measured: the loop's cost now, or whether staging succeeds.

Frames that stopped being tables no longer trap (measured in a test, 271,673 stores down to about 15,700). How much of a boot's 256,000 stores a second that explains is not measured. The tally's `why blocks died` section answers the invalidation question. Direct cost so far: translation was 8.3 s of a 232 s run.

The boots on 2c7c5e1d measured: 8 of 8 clean, staging in 29 to 37 s, and page-table stores down from 256,559/s to 2,245/s (different runs and workloads, so the size is rough). lc-bench then sat in its `rep movsb` test past guest-bench's 900 s. The likely reason: the rep stub used NEON, which traps under CR0.TS, once per byte, with nothing in a plain copy to clear TS. A test measured a megabyte at about 2,100 times the cost. Not measured: that this was what lc-bench hit, as that needs a boot.

### Translated blocks: what the numbers say, and a proposal

From that 1,109 s run: 13.57M cold blocks, 16.65 s translating, so translation itself is 1.5% of the run. Blocks died: 6,900,496 in 9,714 view evictions (about 710 each), 3,490,815 in 205,657 stores higher in the tables (about 17 each), 234,246 from leaf stores, 30,489 from flood. Only 170 of the higher-table kills had the page still on the same frame, so a check for an unchanged mapping would save almost nothing there: those mappings really went, as when a process exits. (The count only sees entries valid at the time, so it runs low.) At least 5.56M cold blocks, 41%, repeated a rip and frame some other block had covered, 3.54M of them live in another view at the time.

Proposal, in order, each to be justified by the tally before the next:

1. More views. 64 views is 32 address spaces, against 367 process rows in that run, which is what makes evictions a steady 9/s. Hash tables take 1 MB per view and fill 128 to 192 MB of the private layout, and the return stacks fill 126 to 128 MB. With tables of 2^14 entries, 256 views need 64 MB of hash and 8 MB of return stacks, so the stacks have to move. Cost: a layout change, and more collisions per view. Gain: no eviction of live processes while under 128 address spaces. Bound: part of 1.5% for translation, plus refills and return-stack misses, which nothing here measures.
2. User translations shared by rip and frame, as kernel-half blocks already are by domain. Block validity is then per view but the code is shared, so a direct link between blocks on different pages is only valid in a view whose mapping of both pages matches. Either links stay within a page, with others through the view's table, or each view keeps its own links. Removing a view's mapping takes the block out of that view's table without killing it. Gain bound: the same 41% of 1.5%, so this is not worth building until something shows the indirect cost is large.

Larger costs show in that run. Device accesses at 25,315/s: 15.4M of 28.1M are two 4-byte writes by one kext to 0xa0000000, at rips 0x...4c2c and 0x...4c3b, about 7.7M each, and rep movs reads frame memory at 0x90000000 one element per exit. Device-specific fast paths would come before any of the above. Not measured: their cost per access.

An instruction leaving what the engine takes (16-bit code, or segments with a base) means TCG keeps going until the state is acceptable again.
Device memory: `vga.vram` (512 MB at 0x80000000) and `vmsvga.fifo` (64 KB at 0xa0060000) are plain RAM to QEMU, and they took most of a boot's device exits. They now go straight into the VM, by name, with a `log_sync` listener marking them dirty for legacy VGA. vmsvga in SVGA mode reads both through pointers, from reading its code, so it needs no log. Measured in a test: each side sees the other's bytes with no exit, and the device answers again once the mapping is gone. Not measured: the exits saved in a boot, or that the display updates. `LC_HVDBT_NO_DIRECT=1` turns it off. Machines whose RAM stops below these addresses are refused, and keep the device path.

Fork, from a 60 s loop of 6,575 forks at 9.1 ms each: 2,430 cold blocks, 53,204 cold instructions and 2.84 ms translating per fork, 697 page-table stores, 38.8 CR3 writes. In that run HC_TRANSLATE was 57.8M calls and 46.4 s of host time, against 27.9M cold blocks, so about half the calls only link an existing block. Each also costs a round trip out of the VM, not separated here. At least 56% of those cold blocks repeated a rip and frame some block already covered. That changes the proposal above: sharing translations of the shared region is now where the largest measured cost goes.

Inlined in translated code, measured in the test kernel, per operation: cr3, segment and sidt reads from 45 ns to about 0; rdtsc to about 0.5 ns; narrow shifts with dead flags to under 1 ns; `cli; sti` from 90 to 50 ns (the non-hybrid sti still traps). The monitor links to a block its view already knows without leaving the VM. Not measured: XNU's syscall, ctxsw and fork after this.

### Sharing user translations

Why: per fork in the 6,575-fork run, 2,430 cold blocks and 53,204 cold instructions, 2.84 ms translating of 9.1 ms, before exits; at least 56% of all cold blocks repeated a rip and frame already covered. A child runs the same library code as its parent and retranslates it.

The check held: on a boot, 8,594,881 cold user blocks sat under one page directory frame, seen by 124 address spaces, at rips 0x7fff812f784e to 0x7fff8eccfae6. The next largest frame had 182,921, with one space.

How it works, extending the kernel domains in `block_key`. `LC_HVDBT_NO_SHARE=1` turns it off.

1. Key. In the gigabyte at SHARED_USER_BASE, CPL 3, once a second address space reaches a page directory, blocks under it take KEY_DOMAIN plus its frame. A process that has not nested keeps blocks of its view.
2. Links stay within a domain, as tr_link and link_here already insist, so chains survive into the next child. Between keys it takes the view's table, a monitor lookup with no host exit once the block is known. A domain has one directory, so every page a chain reaches maps alike wherever the chain runs.
3. What changes for everyone: a store to the directory or below it, or to the code. Code is write-protected per frame as ever. Stores below reach mirrors of those tables, but any given view's can go away with its process. So code marks go only on one keeper view per directory, the first process to reach it, which eviction leaves alone. Its zap kills the blocks.
4. What changes for one view: its own slot above the directory, as unnesting and exit do. Blocks are only reached through a view's lookup table, its return stack, or a chain already inside the domain. So a view that has looked up shared blocks has its table emptied and return stacks reset when the shadow entry for that slot goes, through any path to zap_entry. No block dies. A process leaving for its own directory then has another key.
5. The keeper leaving is that same zap, on a view with the marks: everything it marked dies, safely, at the cost of retranslating. The next translation elects the requester. It walks the old keeper's tables, which may be freed and poisoned, so that walk tolerates anything.

Tested in hybrid.c: spaces sharing a directory with the page moved, code written, the directory's slot rewritten, one space unnesting and coming back, another space at the same address with its own directory, the keeper leaving and its tables poisoned, a newcomer, 90 short-lived processes past the view limit with a change at each step, and a return across an unnest. Not tested: real unnesting in XNU, which only boots do.

Measured on a boot: `shared user blocks: 561663 translated, 878365 found by another view, under 1 directories`, and the desktop up by 40 s, from 100 s. Fork barely moved, at 12.3 ms under load against 13.7, because user code was not most of it. In that fork loop about 1.3M of 15.8M cold blocks were user code at all. The rest were kernel blocks, killed when an exiting process's root was written: 13.3M by "a store higher in the tables". The kernel domains now follow the same rule: only the keeper's marks kill, and a view whose kernel slot changes only forgets. In a test of 300 exiting processes those kills fell from 747 calls to about 50. Not measured: a boot with this.

A lookup ends at an empty slot, so a view's table must keep some. Filling one froze a boot, with the monitor searching forever at EL1 where kicks can't reach it. The table is a cache of the block map, and is now emptied at three quarters full.

Not measured: the rest of a boot, real device traffic, the TLB, TB and dirty-bitmap interplay beyond those few fallbacks. Cost per fallback is unknown; the tally's `tcg_ms` column gives it. Writes by a separate process into guest RAM (the OOP graphics helper) are not noted. Reset after hand-off is unexamined: firmware in 64-bit mode would run on the engine.

## Compatibility mode

32-bit user code on a 64-bit kernel runs on the engine, for the processes of Tiger through Snow Leopard and Final Cut-era apps. Ring 3, flat CS, DS, ES and SS, 32-bit CS and stack. Real mode, 16-bit code, 32-bit kernels and any segment with a base stay on TCG, and `hvdbt_want_engine` says which with a `refused:` row in the tally. XNU's layout is from memory, as it was never run: user CS, DS and the cthread GS in an LDT at 0x17, 0x1f and 0x37, reached from IA32_SYSENTER_CS 7, sysenter on the way in, sysexit or iretq on the way out, segments reloaded from the LDT in 64-bit mode just before.

- **A view of its own.** A view is an address space seen from one CPL and mode, so the same rip can hold 32-bit and 64-bit code, each with its blocks, lookup table and return stack. A 32-bit process uses two views, as a 64-bit one does. A mode change costs what a CPL change does.
- **Decoder and emitters.** One global, `tr_compat`, read from the context per block: operand and stack sizes, no REX, 40-4F are inc and dec, moffs, pushad and popad, `ret` and `call` at four bytes, 16-bit addressing, `sidt` storing six bytes. Nothing in the 64-bit paths looks at it at run time.
- **Registers.** The low eight GPRs have clear top halves throughout: every 32-bit write does it, and the monitor clears them on entry and after TCG. So `[reg]` is one word, as in 64-bit mode. A sum wraps by a W add: `[reg+disp]` is two words where 64-bit code has one. Bulk `rep` checks that the run won't pass 4 GB, or takes the plain loop.
- **Monitor.** sysenter, sysexit and the SYSENTER MSRs; iret, sysret and far transfers into and out of 32-bit code; 32-bit iret at ring 3; segment loads with their checks; `lldt` reading its descriptor. Frames from 32-bit code are the 64-bit frames a CPU pushes, through the same `deliver`.
- **Segments.** `seg_bad` records, at each load, whether es, ds, fs or gs keeps compatibility mode off the engine. Fs and gs need no flat base, since translated code adds it, and their limits aren't checked: XNU's cthread segment is, from memory, 8 KB.
- **Falls back, one instruction:** BCD adjusts, salc, bound, into, arpl, les and lds, 16-bit near branches, strings and xlat with a segment override or 67h, far transfers through gates, 16-bit operands in far transfers, ins and outs. x87 in 32-bit code runs in the monitor, as in 64-bit, and the forms it sends to TCG go there here too.

Measured: `Tests/diff-compat.sh` runs one image, `Tests/x86/compat/`, under the engine and under QEMU's TCG, since Rosetta on this macOS doesn't run i386. Reset vector and long mode under QEMU, then the same kernel: self checks through both, 2489 fuzz forms at 64 rounds, no x87 among them, and QEMU's `test-i386.c` built -m32, `test_floats` with its 32-bit fsave and fxsave formats included, without BCD, signals or `modify_ldt`. 7145 lines, identical. `run-all.sh` compares the engine with TCG's hash, runs the kernel through `engine_api.h` with boundary stops every 2 ms, and `hybrid.c` takes a BCD fallback in 32-bit code with the host moving the vCPU to 64-bit mode. No QEMU is needed but for `--update`.

What TCG can't say. It stores pushad from the lowest address and leaves registers changed when popad faults, and a CPU doesn't, so CR2 there isn't compared and the registers are checked on the engine alone. It takes the x87 rule for two NaNs in SSE arithmetic where the SDM gives the first source, returns a denormal from min and max under DAZ where the engine gives zero, as Rosetta does, and raises MXCSR.DE by other rules; those inputs and that bit are left out of the 32-bit run, and the 64-bit fuzz holds the same emitters to Rosetta. Its `#GP` for a software int through an empty gate has the vector times 16, not 8, so only the low bits are compared. Agreement with TCG says nothing where TCG and the engine both have a thing wrong, about real CPUs where TCG differs from them, or about XNU, which has never run this.

Not exact: esp wraps in `pop`, `ret` and `call` near 4 GB (the commpage holds that end), an element straddling 4 GB in strings, the limit of fs and gs, a null fs or gs used for an access (a CPU gives #GP, this reads at base 0), CR2 for a faulting popad within the page, `push sreg` writing four bytes as TCG does.

### Cold code: a persistent translation cache?

The idea: keep translations on disk, keyed by the content hash of the x86 they came from, and load them instead of translating. Cold code in `lc-bench` is 3.2 us per function against about 0.2 for Rosetta's AOT. Not built, because the numbers below don't justify it yet.

Measured, from tallies of a boot and then `lc-bench`, with sharing on. The desktop arrives by about 40 s, and translation is the host's time inside the translator:

| vCPUs | cold blocks by 40 s | translating by 40 s | share of those 40 s | busiest 10 s, of one core | whole run | HC_TRANSLATE, us per call on vCPU 0 |
|---|---|---|---|---|---|---|
| 1 | 1.57M | 2.45 s | 6.1% | 11.9% | 2.83 s of 191 s | 1.11 |
| 2 | 2.05M | 3.76 s | 9.4% | 19.4% | 4.21 s of 179 s | 1.90 |
| 4 | 2.41M | 4.64 s | 11.6% | 21.9% | 5.16 s of 185 s | 3.76 |

The share is an upper bound on what translation costs a boot: it assumes each second of translating delays the desktop by a second. With several vCPUs some of it runs alongside other work, and much of a boot waits on the disk. Each block also costs an exit, which those seconds leave out: an exit's cost isn't separated in the tally, so at a guessed 1 us each, about 1.6 to 2.4 s by 40 s.

Of the cold blocks in the whole run, at least 319,571 of 1.78M at one vCPU (18%) and 767,216 of about 2.7M at four (29%) were already in the cache, live in another view or dead with their frame unchanged. Reusing those takes no disk. The cost per call also grows with vCPUs, about 3.4 times from one to four, which is probably the translator lock, though nothing here separates waiting from work.

Estimated, not measured:
- **What a cache could save on a boot.** At a 70% hit rate and about 0.3 us for a lookup against 1.6 to 1.9 us for a translation, it saves about 60% of the translating: 1.5 s at one vCPU and 2.8 s at four, of 40 s, so 4 to 7% at best. Saving the exits as well needs a whole page loaded per exit, for up to 1 to 2 s more.
- **App launch.** No tally isolates one. As a bound, 500,000 cold blocks, a guess at a large app, is about 1 s translating and 0.5 s of exits, and the busiest 10 s of a boot suggests translation stays under a quarter of a core during launch-like work. To measure it: run `guest-bench --workload` launching one large app twice, and take the two launches' differences in blocks and translate ms from the tally timeline. The second launch shows the cost without the cold blocks, as sharing keeps them for the rest of the boot; the disk cache also differs between the two, so the first is an upper bound.
- **Size.** 67 ARM words per block is 268 bytes, so 480 MB for that run's 1.78M blocks, and maybe two thirds of that once repeats are gone (a guess).

What it would take:
1. **Relocatable output.** Kernel and shared-region slides differ per boot, as the tallies' `slide` lines show, and blocks hold absolute x86 addresses, in their stub literals and in rip-relative operands, which load an immediate. Each needs a fixup record and patching at load, through every path in the emitters.
2. **Keys.** Hash the page, then look up by offset in the page, mode (CPL, compatibility), and the translator's flags and version. A block crossing a page hashes both, and its bytes are read under protection as today.
3. **Liveness.** A block's code also depends on what follows it, as `flags_needed_at` reads ahead, but only within the same page, so the page hash covers that.
4. **Writing it.** A background thread, off the translator lock, with a file per guest OS build. Loading maps it and copies a block into the code cache, as links and kills work on the live copy.

Cheaper first, in this order, each on its own measurement:
1. Reuse a dead block whose frame hasn't changed, by comparing bytes: 16% or more of cold blocks, no disk, no relocation.
2. Translate more per exit: when a block's direct successors are on the same protected page, translate them in the same call. This addresses the 1 us per block that a disk cache doesn't touch without page loading, and most of what `largecode_cold` shows beyond translation.
3. Hold the translator lock for less at several vCPUs, if the per-call growth is lock waiting.

The first is built, and `LC_HVDBT_NO_REUSE=1` turns it off.

- **Reuse.** A block is a function of its address, the bytes translating it read, its CPL and code size, and settings fixed for the run. So each keeps a copy of what it read, look-ahead included, and a kill leaves it there. A translation for the same key and rip on the same frame compares, and if they match puts the entry word back. As with any translation, the frame is protected first. Only a block on one frame comes back, and with several vCPUs only one that starts with a nop. Sites that link compare-and-swap from an `svc`, or a call's `bl`, as a dead block's entry may have come back meanwhile. `test_reuse` in `hybrid.c` fails with the byte compare, the look-ahead or the frame check removed. No test tells whether the CPL and code size checks matter: it takes a view number reused in the other mode.
- **Translating ahead**, the second, was built and removed. Up to 3 successors per exit came to half of all cold blocks, and `largecode_cold` didn't move beyond its noise. A wasted translation costs more than the exit a used one saves.

Build the disk cache if the app launch measurement shows translation is more than about 20% of a first launch after these. Below that, it is a large change to every emitter for a few percent.

### Cold code per exec, and the code cache

Measured on a Mavericks exec loop at 4 vCPUs: 9.5M cold blocks in 89 s, of which 8.3M in high user memory outside the shared region, and 99.8% of those were a frame and offset already translated at some other rip. That is dyld, which each process maps at its own slide. A block holds absolute x86 addresses, so sharing them across slides needs the relocatable output described above, in every emitter. The gain is bounded: translating is about 1.6 ms of about 7 ms per exec of a program as small as `/usr/bin/true`, and a real application's launch runs dyld once. Not built. Mojave has the same shape in low user memory: 4.2M cold blocks in 174 s, 94% seen before.

Code cache resets were the larger cost on Mojave: 19 in 174 s of launching six applications, each dropping the kernel and system libraries, with 2.6 GB of code generated through a 118 MB cache. 81 to 88% of cold kernel and shared blocks had been translated before. Halving the cache took resets to about 70 and slowed launches, so size matters.

So the cache has a second part, with 118 MB for each. Shared domains go in the first, blocks of one view in the second. Links join blocks of one key, so none crosses between them, and the second needs only its own copy of the stubs in reach and its own tables. It can reset alone, which keeps the kernel and libraries. Splitting the old 118 MB in two had not helped, as the shared half filled by itself.

On Mojave at 4 vCPUs, with the launch timer below, two boots of each build alternating: full resets from 22 to 3 or 4, with 7 to 9 of the second part alone; cold blocks from 9.5M and 9.8M to 5.7M; translating from 17.6 and 19.3 s to 10.9 and 11.4 s. Mean cold launch across six applications from 2.10 and 2.47 s to 1.94 and 2.06 s; mean warm from 0.97 and 1.24 s to 0.98 and 1.10 s. Single applications vary either way by more than that, so the launch figures only hold as means.

Direct calls between keys, such as from a program into a shared library, can't link, so each took a trip through the monitor: 300,000 to 480,000 a second on Mojave's first vCPU. The first such trip now sends the call to a few words that do the lookup an indirect call does, which is always right, so it risks no staleness. On Mojave running six apps at 4 vCPUs, one boot each: those trips on the first vCPU from 55M to under 3M, and its time in the VM from 58.6 to 50.8 s.

### What stops mmap_touch scaling

`mmap_touch` at 8 vCPUs on Mavericks: 452 Kpages/s at N=1, 619 at N=2, 436 at N=4, 386 at N=8. A `dtrace` kernel profile in the guest, 4 s at 997 Hz per CPU, counts samples by function:

| N | `hw_lock_to` | `ml_set_interrupts_enabled` | `pmap_enter_options` | `pmap_remove_range_options` | `lck_rw_*` | `pmap_flush_tlbs` | idle |
|---|---|---|---|---|---|---|---|
| 1 | 14 | 133 | 573 | 533 | 0 | 39 | 15,404 |
| 2 | 521 | 377 | 755 | 649 | 94 | 26 | 15,036 |
| 4 | 1,295 | 1,716 | 682 | 528 | 125 | 84 | 12,683 |
| 8 | 3,687 | 3,037 | 731 | 363 | 356 | 75 | 9,736 |

So it is the guest's own spinlock, taken in `vm_fault`, not TLB shootdowns. Stacks at N=4 put most of `hw_lock_to` under `vm_fault`, with samples on single instructions in `pmap_enter_options` and `pmap_remove_range_options`, which looks like the return from a trapped PTE store. `ml_set_interrupts_enabled` is probably skid: a profile tick held off until interrupts open again. The monitor's own lock is not it: at 4 vCPUs the first vCPU waited 1.3 s for it of 27 s in the VM. That a PTE store's trap stretches the guest's critical section is inferred from those stacks, not measured directly. Rosetta shows the same lock with shorter sections, at a ratio of 2.42 at N=4 against 1.1 here. Nothing cheap fixes it: the store has to trap while the table is shadowed.

### How long an application takes to start

`probes/app-launch.sh`: `open -a` to a first window, cold being the first launch in a boot, warm the best of two more. 4 vCPUs, on 256 views and both parts of the code cache. Engine: the median of 3 boots on Mojave and 2 on Mavericks, range in brackets. TCG: one boot each, so its numbers carry less. Mavericks clones join Finder's audit session to get a window list.

| Mojave, to a window | TCG cold | Engine cold | TCG warm | Engine warm |
|---|---|---|---|---|
| Calculator | 4.93 | 1.77 (1.70-1.77) | 2.19 | 0.66 (0.63-0.67) |
| TextEdit | 4.98 | 1.32 (1.28-1.48) | 2.34 | 0.77 (0.75-0.77) |
| Notes | 5.69 | 2.04 (1.78-2.11) | 3.39 | 0.95 (0.93-0.99) |
| Maps | 5.45 | 1.55 (1.54-1.61) | 3.20 | 0.90 (0.79-0.93) |
| Safari | 7.69 | 1.90 (1.78-1.91) | 2.97 | 0.97 (0.92-0.99) |
| System Preferences | 4.74 | 1.14 (1.11-1.24) | 2.39 | 0.74 (0.73-0.76) |

| Mavericks, to a window | TCG cold | Engine cold | TCG warm | Engine warm |
|---|---|---|---|---|
| Calculator | 3.82 | 0.83 (0.79-0.88) | 0.99 | 0.35 (0.34-0.37) |
| TextEdit | 5.78 | 1.52 (1.45-1.58) | 1.32 | 0.51 (0.50-0.52) |
| Notes | 4.56 | 1.09 (1.07-1.11) | 1.02 | 0.38 (0.37-0.38) |
| Maps | 5.01 | 1.48 (1.46-1.49) | 1.39 | 0.82 (0.79-0.86) |
| Safari | 1.69 | 0.56 (0.55-0.57) | 1.66 | 0.61 (0.60-0.62) |
| System Preferences | 1.13 | 0.39 (0.38-0.40) | 1.03 | 0.34 (0.33-0.34) |
| Keynote (i386) | 5.76 | 1.88 (1.87-1.88) | 2.64 | 1.29 (1.24-1.35) |

Safari on Mavericks has run before the probe reaches it, so its cold is not cold.

**Where a launch goes.** Measured with `probes/launch-profile.sh` and the tally's timeline, whose 2 s rows blur launches together:
- Disk is not the gap between cold and warm on Mojave: reading the shared cache, the frameworks and the applications beforehand left cold launches where they were (1.45 to 2.04 s, one boot). dtrace's `io` probes showed nothing in either guest, so there is no disk latency figure.
- Most of the guest's CPUs sit idle. Samples outside `kernel_task` over a 4 s window around a 2 s Calculator launch come to about 1.9 CPU seconds, so a launch is close to one thread's work at a time.
- Translating: about 300 ms and 150k blocks over a Keynote launch of 1.4 to 2 s, cold or warm, and 100 to 500 ms per 2 s row around Mojave's. About 2 us a block, one vCPU at a time, plus an exit and a link per block whose cost isn't separated. Not measured: how long translated code takes against native. That is probably the largest remainder.
- Inferred, not tried: warm Keynote translates as much as cold because i386 blocks aren't shared (the i386 shared region isn't in `SHARED_USER_BASE`) and die with their process. Reuse across views would need a dead block's own links undone, since they were made under another view's mappings.

**How many views.** At 64, Mojave evicted 135 views a second and 2.8 of 3.2 million dead blocks died that way. Two boots of each build, alternating, launching seven applications (six on Mojave):

| | Mojave, 64 views | Mojave, 256 | Mavericks, 64 | Mavericks, 256 |
|---|---|---|---|---|
| Blocks translated | 6.2M, 6.0M | 3.9M, 3.7M | 3.8M, 3.5M | 2.7M (one boot) |
| Translation time, s | 11.3, 11.3 | 7.8, 7.0 | 7.1, 6.6 | 5.0 |
| Second cache part resets | 8, 7 | 2, 2 | 6, 7 | 5 |

Launches gain less than that: summed over Mojave's apps, 20.2 s cold before and 20.5 s after in that alternation, 10.7 s warm before and 10.4 s after, which is within the noise. Mavericks warm gains more (Calculator 0.45 to 0.35, Notes 0.50 to 0.38), but those two weren't alternated. So views are kept for the work they save and for sustained use, not for a launch number.

### A long session

`probes/soak.sh`, 4 vCPUs on a clone: 3 to 6 applications at a time opened and closed, i386 included, Safari's JIT at work, memory past the guest's 8 GB every eighth cycle, and arithmetic, file and memory contents checked throughout.

Boots with the `sti` shadow fixed, except where noted:

| Guest, length asked | How it ended | Checks, wrong | Reclaims, full resets, part 2 resets |
|---|---|---|---|
| Mavericks, 2400 s (before the `sti` fix) | ran out | about 10,800, 0 | 5658, 5, 415 |
| Mojave, 200 s, 6 boots | ran out | 0 wrong in the boots read | not read |
| Mojave, 2400 s | QEMU exited at 880 s, nothing logged, no fault in the tally | no output | not read |
| Mojave, 2400 s | ran out | 4866, 0 | 1361, 43, 69 |
| Mojave, 2000 s | guest reset at 1300 s, cause not found | no output | not read |
| Mojave, 2000 s | ran out | 7776, 0 | 2285, 60, 105 |
| Mojave, 2000 s | control connection ended at 1149 s, guest still running | no output | not read |
| Mojave, 2000 s | ran out | 7288, 0 | 2822, 56, 101 |

Three of six long Mojave boots ended early. The user stopped some of the long soaks themselves, because of the load on their laptop, so these can't be read as engine failures: the QEMU exit and the lost connection probably, the reset possibly. Before the `sti` fix, 5 of 8 Mojave boots wedged within minutes, which is an engine failure, seen in the event ring.

A guest reset did happen in a normal short boot, 15.7 s after hand-off, with one vCPU parked in `cpu_signal_handler`. QEMU's log of it gave a reset on vCPU 2, but its register dump is the last fallback's, not the moment's, and NVRAM has no panic text. QEMU now looks for panic text in RAM at a reset. Cause unknown.

**Memory.** RSS and `phys_footprint` of 17 to 18 GB with an 8 GB guest are mostly counting: a test VM touching 2 GB the host had touched raised both, in step, and left host free memory alone. vmmap's regions came to 8.6 to 9.4 GB from 300 s to 1300 s, of which guest RAM is 7.7 GB, in a boot where only about 170 MB was malloc. TCG, with no stage 2, shows 9.1 GB in both counts. No memory kill was in the host's log.

Launches held steady through the two later completed Mojave boots, in a further 1519 s boot that finished cleanly, and on Mavericks. In the third they and memory pressure slowed 2 to 3 times, with host calls about 8 times slower than in a short boot. Inferred, not shown: load on the host, as the others didn't repeat it.

A TCG baseline, same probe and 1380 s on Mojave and 300 s on Mavericks, one boot of each: no early end, no wrong result, Chess killed every time, and Keynote killed every time. So those two are the guest's. Launches there ran at 4 to 7 s against the engine's 1 to 2 s, under the same load.

### Against Rosetta

`lc-bench` in a clone at 4 vCPUs, on a host under load, against the same binary under Rosetta on the host, speed relative to Rosetta. One run each.

| Test | Mojave | Mavericks |
|---|---|---|
| alu | 0.96 | 1.10 |
| branchy | 1.02 | 1.15 |
| largecode_warm | 1.02 | 1.13 |
| sse_float | 0.98 | 0.98 |
| sse_int_shuffle | 0.68 | 0.70 |
| chase_16k | 0.81 | 0.97 |
| chase_512m | 0.68 | 0.68 |
| memcpy | 0.55 | 0.56 |
| syscall | 0.33 | 0.83 |
| pagefault | 0.20 | 0.42 |
| ctxsw | 0.19 | 0.44 |
| fork_wait | 0.65 | 1.59 |
| largecode_cold | 0.07 | 0.08 |

Those hot rows above 1 were noise: 0.2 s slices, one run, with Rosetta not niced on a busy host. At fixed counts, about 14 s a phase, four rounds alternating with Rosetta niced the same, one vCPU:

| ns per iteration | alu | branchy |
|---|---|---|
| Rosetta | 2.20 to 2.25 | 12.14 to 12.58 |
| Mavericks, later rounds | 2.32 to 2.37 | 12.83 to 13.07 |
| Mojave, later rounds | 2.36 to 2.57 | 12.84 to 13.77 |

So about 5% behind Rosetta on Mavericks and up to 10% on Mojave, whose first rounds, at 1 vCPU, also carry what's left of its boot. The guest's clock isn't slow: its 110.6 s total against the host's 106.5 s between the first and last 2 s timeline rows in those loops, which can miss 4 s. `alu`'s loop is 29 ARM words for 29 x86 instructions with no flags kept, and `branchy` keeps flags only for the `andl` before its indirect call, as a call makes all of them live. Rosetta's code wasn't read: `/var/db/oah` isn't readable.

Hot code is close to parity, so code generation isn't where a launch goes. What's slow is crossing into the kernel, faults, and code seen for the first time. Rosetta's kernel is the host's, so those rows also compare kernels. Mojave's crossings cost about twice Mavericks' or more: it changes page tables at each. Its kernel reads `IA32_ARCH_CAPABILITIES` only in what look like its MDS paths, so this search found no way to tell it not to.

Making every flag live, `LC_HVDBT_ALL_FLAGS=1`, costs `alu` 5%, `branchy` 2%, and adds 4% to the code, with no visible effect on launches in one boot of each. In a launch profile no hot function stands out: `cache_fill` is 75 of 916 user samples. So no code generation work was done.

`pcmpistri` and `moffs`, alternating, two Mavericks boots of each: 108,000 fallbacks and 3.5 s on TCG gone per seven-app run. Warm launches other than Keynote 6% faster (3.16 to 2.96 s summed), cold unchanged. Keynote 8% slower in those boots, which is inside the 1.13 to 1.41 s it has moved between other boots.

### What limits exec past 2 vCPUs

`lc-scale`'s `exec_per_s`, N=1, 2, 4 at 4 vCPUs, with a kernel profile in the guest and the tally's counters over each. Niced clones, and a host with a load of 6 to 20 from other work, so these move by a quarter from run to run.

Mojave ran down past 2: 69, 126, 101. At N=4 the first vCPU took 750,000 page table stores a second, all vCPUs together spent 1.5 cores waiting for the monitor lock, and the kernel's `memset` was the top function. Dropping tables of address spaces nobody is in didn't change it. What did was roots: they have no flood limit, so a reused root frame being cleared takes one trap per slot, and with 256 views a dead process's root stays tracked. A view whose root's user half goes to zero with nobody in it is now dropped.

| Mojave, alternating | N=1 | N=2 | N=4 | stores/s at N=4 |
|---|---|---|---|---|
| before | 69, 63 | 113, 91 | 115, 99 | 754,000, 634,000 |
| after | 98, 71 | 178, 142 | 194, 104 | 82,000, 43,000 |

Four later boots of the same code: 84 to 103, 140 to 173, 163 to 202. `memset` went from 4,620 samples to 91. Mavericks had no such traps and is unchanged within noise: 102, 146 to 182, 176 to 230 after, 102 to 104, 170 to 176, 156 to 192 before.

What's left at N=4 is mostly still the monitor lock: about 1.1 cores waiting on Mojave and 1 on Mavericks. On Mojave at 190 exec/s that is about 6 of the 11 ms of CPU an exec costs beyond N=1. Over a whole boot, Mavericks: 17.5 s holding it for table stores, 5.8 s for faults, 1.4 s after translating, 1.7 s switching views. Translation itself is 15 to 30% of a core, and waiting for its lock is small.

Tried and dropped: doing a table store's TLB invalidates after letting go of the lock. The time held for table stores stayed at 14 to 16 s and rates didn't move, so it's the number of stores, at about a microsecond each, and not the invalidates. A second kernel pin for the crossing between a process's tables and the kernel's is in, with no clean measurement.

Not tried, and the next things to try: not taking the lock for a store to a slot no shadow holds, which needs fills to look again; or filling the shadow at the store, so that a new page costs one trip rather than two.

### mmap_touch again

At N=4 it waits only 10% of a core for the monitor lock on Mavericks and 35% on Mojave, with about two trapped stores per page. So the guest's own spinlock, stretched by those traps, is what's left, as above. A lower flood limit, 16 writes rather than 64, was the cheapest thing to try, as `munmap` writes 64 slots with no walk between. Alternating, two boots each at N=4: Mavericks 813, 596 against 412, 650 Kpages/s; Mojave 416, 470 against 414, 487; stores per page on Mavericks down from about 1.6 to 2 to about 1.2 to 1.5. No clear gain under this load, so it stays at 64.

Tables out of sync with the guest until the next flush, as KVM does it, would remove most of these traps. That is a large change to how shadows stay correct, and the guest's `invlpg` and CR3 writes would stop being no-ops. No figure for what it would save: the tally has the time a store holds the lock, not the whole trap.

### A fast hidden start: resuming a snapshot under the engine

The goal is a guest that is at its desktop 1 to 2 s after the app asks, with no boot, for seamless apps. Nothing here has been run. What the code says, and what has to be found out:

**What the engine would have to save: nothing.** Whenever a vCPU is off the engine, all its state is in `CPUX86State`: `hvdbt_get_state` copies registers, x87, MXCSR and the ICR copy back, the APIC is QEMU's, and the TSC is `cpu_get_tsc` with QEMU's offset. `vm_stop` kicks each vCPU, which stops at a boundary. So QEMU's migration stream sees a TCG machine. Shadow tables, views, blocks, the code cache, `page_info`, rmap and lookup tables are all derived, and RAM is QEMU's, mapped into the VM.

**Two ways to resume.**
1. A new process with `-incoming` or `-loadvm`. No engine exists yet, so loading has nothing to tell it. The first high-half TB miss makes one as at a boot's hand-off, the others join, and a vCPU in user mode stays on TCG until it next enters the kernel. Device mappings come from the listener at creation. This is what a hidden start wants, and needs no engine change that the code shows.
2. `loadvm` in a running process. RAM changes behind the engine, so it must forget everything, and `hvdbt_reset` does that on the reset a load starts with. Nothing has run this in a guest: the app's QEMU ends on a guest reboot and the app starts another, so a reboot is a first boot to the engine (measured: back at the desktop in 42 s at 4 vCPUs), and the machine's disks are raw, which `savevm` can't use. The app also holds the one QMP connection.

**Getting to 1 to 2 s is not the engine's problem first.** These are the unknowns, largest first:
- **Device state outside QEMU.** `PassthroughOpenGL` logs contexts from early in a boot, and they live in the host. Nothing here has looked at whether that device can save or recreate them, and a guest whose GL contexts vanish may not recover. The rest: virtio-serial and COM2 chardev peers reconnecting, `virtio-sound` with `x-apple-reconfigure`, USB, and `-drive ...,snapshot=on` media. Any migration blocker will name itself when a save is tried.
- **RAM.** Reading 8 GB eagerly takes seconds, at a guess 3. Loading in time needs RAM mapped from the saved file, faulted on demand. The guest's RAM is the `pvg-ram` backend, imported as shared anonymous memory (`Shared anonymous RAM import ... regions=3` in session logs), which may have to stay anonymous. Whether `hv_vm_map` takes a private file mapping, and what faulting costs, is unmeasured.
- **Disk.** It must match the RAM: an APFS clone taken at the save, as `scripts/boot-clone` makes.
- **Clocks.** The TSC continues from the save, so the guest's wall clock is wrong until something corrects it. The guest agent can.

**Cold code again.** Every resume starts with an empty code cache, since nothing translated survives. That is the case for the disk cache, in "Cold code" above, that a boot's numbers did not make: a boot translates 1.6M blocks in about 40 s, at most 6 to 12% of it, but a resumed desktop's first second could be mostly translating. Measure before building: the blocks and translate ms of the first 5 s after a resume.

**First experiment**, needing no code: on a booted hybrid guest, QMP `migrate` to `file:` and then a new process with `-incoming`, watching for blockers. Then the same with TCG alone, to separate what is the engine's.

## Multi-vCPU

One vCPU is the largest gap to a usable guest. This is the design, what it costs, and how far it is built. **Measured** means on this machine by `Tests/smp-probe/run.sh` (EL1 code in a VM set up as the engine sets one up, EnTSO on) or `engine-run --smp 2|4 .build/images/smp` (the engine itself, `Tests/x86/kernel/smp.c`), under other work at load 5 to 8, so 10-20% between runs. Everything else is labelled.

### Decisions

**State.** x18 picks the vCPU: an `EngineCtx` per vCPU, 64 KB apart. EngineCtx is reachable from EL0, so what the monitor keeps for itself (`MonCpu`) sits at a fixed distance from it in EL1 memory, with that vCPU's stack at the top of the slot. Reaching it is a constant add. Each view has a return stack per vCPU, because two vCPUs can run one address space and a shared stack would just mismatch; x26 was always per vCPU. Shared by design: views, the shadow pool, rmap, mirrors, `page_info`, the code cache, block table, hash tables. The rule for the monitor: a `static` is shared, so it either moves to `MonCpu` or sits under the lock.

**One monitor lock.** A test-and-swap spinlock over views, shadow pool, rmap, mirrors and `page_info`, skipped by a load and a branch at one vCPU. Not per-table locks and not lock-free: every operation here touches several of these structures at once, and the measurements below say one lock is cheap at the rates a guest has shown. A ticket lock is no better uncontended and worse under contention, so no fairness until something needs it.

**One translator lock**, on the host, around `HC_TRANSLATE`, `HC_SMC`, `HC_VIEW_INVALIDATE_VA` and `HC_VIEW_DROP`. `os_unfair_lock` in a path that already costs an exit. Order is monitor lock then translator lock, and the translator never takes the other, so holding the monitor lock over a kill is safe, if not fast.

**Nothing shared on the hottest paths.** Translated code changes in no way. Syscall, sysret, iret, exceptions, in-VM APIC and the indirect lookup take no lock and write nothing shared. A CPL change finds its view through a per-vCPU pin: a pinned view can't be evicted, so the pin needs no lock. Only leaving an address space takes it. LRU stamps move from every view switch to the unpin. `lookup` reads the per-view hash table, whose inserts already publish value before key.

**One view per root.** A view's key is the page table root and mode, not the PCID: shadows are always in step, so a PCID separates nothing, and XNU gives an address space a PCID per CPU. Keying by PCID cost a view per vCPU per process: at 4 vCPUs, evictions fell from 11,862 to 1,096 in an exec run without it, and `exec_per_s` rose 10 to 20%.

**Validate after marking, under the lock.** The monitor's single-vCPU order has races that matter now, all with one shape: something was read, then something was protected. Each is handled the same way: protect first, then look again.
- A fill walks and installs under the lock, and every trapped page-table store takes the lock, so a store can't fall between them. The unlocked walk before it only sorts faults and devices from RAM.
- A fill that starts tracking a new table drops what it installed and refaults: a peer may have written that table, unseen, before the protection took effect.
- A translation reads code and tables on the host with nothing protected. Afterwards, under the lock, it marks frames and leaf slots and then walks again. If the mapping moved, or a frame had not been protected when read, it kills what it made and translates again.
- A and D bits use compare-and-swap against the value the walk read, as hardware does, so a slot that has become data isn't touched.

**Invalidation.** Shadow entries: nothing beyond today's `tlbi ...is`, as it reaches peers (below) and page tables never hold a stale entry. Block kill: today's entry word patched to `svc`, seen by peers without any IPI. Return stacks are the one thing that needs each peer's help: they hold pointers into dead blocks' bodies, in registers and memory the killer can't touch. A kill bumps a shared epoch; every way out of the monitor compares it and drops that vCPU's stacks on a change. Until then a peer may return into a dead block, whose body is intact and only stale (the cache never reuses memory short of a full reset). x86 allows that, as it must first have serialised (cross-modifying code) or taken the shootdown (a remap), and every serialising instruction and interrupt passes through the monitor. So no IPIs in the VM of our own.

**TLB shootdown.** Stricter than x86: the shadow entry goes at the guest's store, with a broadcast invalidate, before the store is done. So `invlpg`, CR3 reloads and PCID flushes stay no-ops, and a guest's shootdown IPIs are only overhead. They can't be skipped, as the guest waits for its acks.

**APIC and IPIs.** The in-VM APIC is per vCPU already. An ICR write for another vCPU exits with `HC_APIC_ICR`; the machine sets the target's host IRR and kicks it with `hv_vcpus_exit`. In hybrid mode the APIC is QEMU's, as it is today: an ICR write is device MMIO under the BQL, and the kick already exists as `hvdbt_kick`.

**x86 memory order** is EnTSO in hardware on each vCPU, and needs no code. `mfence` is `dmb ish`, and locked forms are LSE. Not atomic where x86 is: an unlocked access crossing 16 bytes inside a cache line. A locked access across 16 bytes already stops.

**SMC across vCPUs.** The translator reads a frame only once it is marked and write-protected, and otherwise refuses and the monitor marks it first: a block is found by other vCPUs the moment it exists, so validating it afterwards is too late for a third vCPU that has seen a later store. `Tests/x86/kernel/smp.c` caught this at 4 vCPUs and never at 2. Otherwise as today, with two additions. The validation above covers a store landing during a translation. And a writer needs forward progress: its one-off store block takes a few microseconds to arrive, and a peer calling into that frame re-protected it first, every time, so the test hung until a vCPU writing a code frame was allowed to finish first (`smc_held`, let go at its next monitor entry). Code and data sharing a frame now costs one trap and kill per store while another vCPU runs that code. The one-step path for odd atomics on a page table opens the page to every vCPU in the view, so with several vCPUs it stops instead (falls back in hybrid).

**Full code cache reset** stays a stop: `tr_flush_all` aborts with several vCPUs. It needs every vCPU at an x86 boundary, for which `requestBoundary` exists; each then resumes through `translate_here`, which holds no pointer into the old cache. Not built. How often a real guest fills the 118 MB cache is **not measured** here, so a boot with several vCPUs may hit this abort.

**QEMU hand-off, per vCPU** (not built, nothing here touches `hvdbt.c`). TCG keeps INIT, SIPI and everything up to long mode on each AP, since QEMU's `apic_startup` and TCG's real mode work today. An AP's first TB miss in 64-bit mode at a high-half address creates its `Engine(secondaryOf:)` on that vCPU's own thread, which HVF requires. `prepareCount` must be `max_cpus` before the BSP's first run, as the monitor's lock turns on from that. What changes in `hvdbt.c`: `hv` splits per CPU (`in_engine`, `engine`, `refused`, `tcg_ran`), the `-smp 1` check goes, the tally and watchdog go per vCPU.

**One vCPU on TCG while others run here.** A fallback already has precise state and returns; the new part is others running meanwhile.
- *Memory order.* TCG on arm64 emits barriers for an x86 guest, and its atomics are host atomics, so the two agree. Read, not run.
- *Shared user translations* (hybrid only, so off in `--smp`). `shared_dirs` is per context and `shared_row` runs before the lock takes effect. Both must move: the list to the first context, the decision under the lock. Not built.
- *TCG's stores to code and tables.* The notes ring moves to the first context and any vCPU drains it, on every way out of the monitor, under the lock. A guest can't act on a TCG store without an interrupt or a serialising instruction reaching the monitor. `notes_drain` is not safe yet with several vCPUs: it isn't locked, and the ring is per context.
- *TCG's own TBs.* An engine store to code isn't seen by a TCG vCPU in a normal TB. A single stepped instruction regenerates from memory, but a long stay on TCG (firmware, a 32-bit process) can run stale code past a store by another vCPU. Today's flush "after any run of normal TBs" is per vCPU.
- *Exclusive sections.* `tcg_handoff->run` is called outside `cpu_exec_start`/`cpu_exec_end`, so `start_exclusive` doesn't wait for an engine vCPU, and `cpu_exec_step_atomic` isn't atomic against one. Fixing it means bracketing `engine_run` and stopping engine vCPUs at a boundary for exclusive work, but `queue_tb_flush` is exclusive and frequent, and would stop them all. TB flushes must then go, or stop being exclusive here. This is the design's largest open part in QEMU.

### Costs, measured

| Operation | Cost | From |
|---|---|---|
| Lock and unlock, line already here | 0.4 ns over a 0.8 ns loop (ticket 1.1) | probe |
| Lock and unlock, line last held by another vCPU, no waiting | 44 ns (one-way line transfer alone: 42) | probe |
| Each acquire, 120 ns held, 1.7M / 3.4M locks/s in all (2 / 4 vCPUs) | under noise, at most +25 ns (ticket +15 to +32) | probe |
| Each acquire, 120 ns held, no gap at all, 2 / 4 vCPUs | +120 / +360 ns (ticket +200 / +600) | probe |
| Epoch check on each monitor exit | 0.00 ns; 0.02 with the line written once per microsecond | probe |
| A or D bit, atomic | 1.3 ns | probe |
| `tlbi vae1is` + `dsb` + `isb`: peers out of the VM / spinning / loading through 512 pages / three doing so | 210 / 270 / 254 / 256 ns | probe |
| `tlbi aside1is`, same four | 180 / 186 / 302 / 493 ns | probe |
| Block kill: host store and `sys_icache_invalidate`, to a running peer trapping | median 208 ns, 99% 2.3 us, max 8.1 us | probe |

The engine itself, `--smp`, three runs each at load 10 to 29, ns. "Alone" is one vCPU working while the others wait in a spin; "together" is all of them at it, every vCPU in one address space or one leaf table. Together, table stores and fills run at about 1 to 2M per vCPU per second, far above any guest rate seen, so those columns are the lock saturated and not a forecast.

| Path | 2 vCPUs, alone | 2, together | 4, alone | 4, together |
|---|---|---|---|---|
| Syscall + sysret | 149 | 148-149 | 149 | 153-154 |
| Call and return, 40 deep and back, ring 3 | 28 | 28 | 28-29 | 27-28 |
| CR3 write between two address spaces (takes the lock) | 122-127 | 198-221 | 122-129 | 707-929 |
| Table store dropping a live entry, with TLBI (holds the lock throughout) | 270-301 | 518-588 | 222-260 | 1095-1246 |
| Shadow fill after it, load included | 175-180 | 313-386 | 153-179 | 1011-1305 |

| Path, ns | 2 vCPUs | 4 vCPUs |
|---|---|---|
| IPI, peer busy, one way: ICR trap, host, kick, exit, IRQ, `HC_IRQ`, delivery, handler with an APIC read and EOI | 3868-4080 | 4222-4309 |
| IPI, peer in `hlt`, one way, about 2 us of spinning per round still in the figure | 4949-7388 | 6783-6959 |
| Full shootdown: table store, `invlpg`, IPI to all others, each one's `invlpg`, ack | 3326-3911 | 5439-5682 |
| `lock add`, both vCPUs on one line | 11-12 | not read |

At one vCPU, against the `hv-accel` it branched from, alternating the two builds, best of 7, load up to 38: syscall 143 to 147, int and iret 221 to 227, fill 136 to 140, CR3 write 89 to 92, in-VM APIC and device paths unchanged, and flat `lc-bench` within 1% but for the noisy 64 MB chase and cold code. So 3 or 4 ns per trip through the monitor at the top end of noise here, which I attribute to the pins and the slot arithmetic without having separated them. `Tests/bench.py 3 25`'s table on the merge shows engine/rosetta-flat of 1.02, 1.04, 1.00, 0.97, 1.15, 1.07, 1.00, 1.00, 0.70, 0.63 and 1.11. The last is `largecode_warm`, whose 23 ns is the same on `hv-accel`'s own build in that comparison, so it did not come from this work.

The lock at guest rates, reasoning from those: a boot's worst page-table store rate, 256,559/s across 4 vCPUs, at 44 ns per acquire plus at most 25 ns waiting is about 18 ms per 4000 ms of vCPU time. Holds there are short, 60 to 550 ns. CR3 writes at 9,000/s cost under 1 ms. Fill rates are **not measured** in any real guest, and would have to pass 1M/s to matter. IPIs: at the earlier profile's 10,000 interrupts/s, were every one an IPI at 4.3 us, about 43 ms per 4000, or 1%. Those rates came from a 4-vCPU TCG profile of system-heavy work.

Translator lock, from the 1,109 s run on one vCPU: 16.65 s translating is 1.5% busy, and a boot's peak was about 3%, so waits should be rare. Not measured with several vCPUs. A first block on a frame is now translated twice.

What the hardware does, measured:
- `tlbi vae1is` reaches a peer: 0 stale of 226M reads with the peer running, 0 of 58M with it exiting to the host every 256 reads, 0 of 468K with it asleep in the host every 1K. A control with no invalidate saw 108M stale of 216M, so the peer's TLB really held the entry.
- A *local* `tlbi vae1` also reached the peer: 0 stale of 226M. So the hypervisor, or the hardware, appears to broadcast it (HCR_EL2.FB, inferred). There is nothing to gain from a local form here.
- `CTR_EL0` is `9444c004`: IDC 1, DIC 0. Patching `add` to `svc` and back under a peer with no context-synchronising event in its loop, 20,000 rounds, 261M executions: every patch arrived, at worst 8.1 us after the store, and no other exception class appeared. In one round the old word still ran 5 to 10 us after restoring.
- x86 litmus through the engine: with EnTSO on, message passing reordered 0 of 3M reads, through movs and through `movdqa`; store buffering, which x86 allows, seen 15 to 266 of 400K, and with `mfence` or `xchg` 0 of 400K; load buffering 0 and 2+2W 0 of 400K; IRIW on 4 vCPUs 0 of 300K. With EnTSO off (`ENGINE_NO_TSO=1`), the control, message passing reordered 1.28M and 1.84M of 3M. Load buffering, 2+2W and store buffering with a barrier also showed 0 with EnTSO off, so here they prove little: those windows are hard to hit. IRIW has no control run.
- The clock: a counter offset copied from the first vCPU keeps the TSC in step, 0 of 2M reads over a microsecond behind another vCPU's.

### Risks that would make it no-go

1. **EnTSO itself**, as in "What is left": undocumented from HVF, and it could go when Rosetta does. With several vCPUs nothing replaces it short of barriers on every access. Measured to hold here, on these litmus shapes, on this machine.
2. **Patching a block's entry word under a running peer.** Moving between arbitrary instructions and `svc` is outside what the architecture promises for concurrent modification (from memory of the Arm ARM, whose list covers forms like `b`, `nop` and `svc`, and not checked against it just now). The promise for other cases is only "some behaviour at the same exception level", so EL0, which can't reach the monitor, though it could damage the guest. Measured clean, but a sample of one instruction pair on one chip. The fix is a `nop` as each block's first word: this is built, on with several vCPUs only. Alternating builds with a `nop` on every block: alu 2.31 to 2.25, branchy 12.76 to 12.53, `largecode_warm` 23.25 to 23.24, syscall 147 to 148, so nothing measurable. `tr_link` and `link_here` also retarget a `b.cond`, which that list may or may not cover. Whether the hardware cared about any of this was never seen, so the patching figure above is for the old form and the fix is unproven in the sense that matters.
3. **A spinning vCPU when the lock holder's thread loses its core.** No way to see it from EL1. Bounded by the host's scheduler quantum, and worse the fuller the machine. **Not measured.** The fix is a spin limit and then an `hvc` to yield; not built. Would matter if the host is short of cores. The runs above passed at load 10 to 29 with no collapse visible in the means, which is not the same as a measurement of the worst case.
4. **IPI rate.** At 4.3 us one way, IPIs reach 10% of four vCPUs at about 90,000/s. A real guest's rate under load is **not measured**. In hybrid mode each is MMIO through the BQL on top, also **not measured**, and BQL contention may be the real limit: every device access takes it.
5. **QEMU's exclusive sections and TB flushes**, above. **Not tested**, and nothing here runs QEMU.
6. **Evictions under the lock.** Each evicts about 710 blocks and holds both locks. Returning to an evicted space is 23-36 us end to end, which bounds it loosely, at 9/s on one vCPU. **Not measured** with several; 64 views is 32 address spaces, of which 4 vCPUs pin up to 8 views.
7. A real guest's use of what stops here: odd atomics on page tables stop with several vCPUs, and locked accesses across 16 bytes go to TCG, not atomically against other vCPUs (5). Their rate in a real guest is **not measured**; the tally counts both.

### Built

`engine-run --smp <n> <image>` with `SMPGuest.swift`, `Engine(secondaryOf:index:)`, the state split, both locks, pins, the epoch, validation, `smc_held`. Each vCPU enters at the kernel's entry in long mode.
`Tests/x86/kernel/smp.c`, on 2 and 4 vCPUs, in `run-all.sh`: every locked form (with an unlocked add as a control that must lose updates); litmus shapes; TSC agreement; IPIs (busy, `hlt`, masked, all-but-self); shootdowns with readers checking for old frames; patch and call, patching during translation, return into patched code, code remapped; page-table stores and fills by all vCPUs in one leaf table; CR3 writes; ring 3 syscall and call/return in one address space.

To check that the tests can fail, one safeguard at a time was removed by hand: no return-stack epoch gave 5000 of 5000 stale returns; no validation after translating gave 30 to 44 stale of 20,000 in each of three runs; no monitor lock gave 12,437 stale reads and then a hang; no second walk under the lock gave 1,150 stale reads; and with no `smc_held`, the writer hung. Not put to this test: the refault on a newly tracked table, compare-and-swap for A and D, and eviction skipping pinned views, as the test kernel evicts nothing. Those three are reasoning. Per-vCPU return stacks only show in speed, and the run with a shared one was not made.

### Hybrid: first steps built

`hvdbt.c` is per vCPU, and each application processor joins through `engine_create_secondary` on its own thread at its first high-half TB miss, after TCG has taken it through INIT, SIPI and real mode. Exclusive sections take option A, the simple exact one: `engine_run` sits between `cpu_exec_start` and `cpu_exec_end`, and a kick while one is pending stops the vCPU at a boundary. The tally counts those stops, to say whether TB flushes need something better. The notes ring and shared directories are one for the VM, under the lock. A full code cache gets every vCPU out, at a boundary or asleep, and holds them out until it is reset.

Measured here: 93 resets under two and four vCPUs in `--smp`; a second vCPU joining the hybrid test through the C API, 30 runs in a row. That test found a retry for ever on direct-mapped device memory in the SMP fill path. Not measured: any of this under QEMU, which has only been compiled. The first boot, `-smp 2` on Mavericks: desktop by the 40 s capture, both vCPUs doing real work, 434 exclusive stops, no FAULT rows.

Stress at two vCPUs under heavy host load stopped on a monitor fault, twice and identically, in `view_find`, on a value that was never a view index. It was a stack `Walk` lying over `pin[0]`: the monitor's stack had grown down through 64 KB into its vCPU's own state. `translate_here` called itself each time another vCPU's store invalidated what it had just translated, and `exit_check` called itself after each stop or delivery. Measured in `--smp`, with code and busy data on one page: the stack ran out in both of two runs, under a guard added for this. Both are loops now, and after 8 failed tries translation runs one instruction from a one-off block, so a busy writer can't hold it up. Measured: 864 bytes deepest in 37 runs at 40 busy host processes, with up to 85 million stores to the page. The tally reports the deepest stack, and a guard stops with `esr 0x57acc` before it reaches that state again.

A monitor lock held a long time now yields the host thread, as with more vCPUs than free cores the holder may be waiting for this core. A stay on TCG flushes its TBs once a second, which only bounds how long it can run code another vCPU has rewritten: exact would be TCG hearing of engine stores. An application processor's trampoline needs nothing more, as TBs are flushed after each stay. `probes/smp-stress.c` checks atomics, memory order, shootdowns, map storms, fork and exec, self-modifying code, registers across switches, and wakeups. All pass under Rosetta. Not measured: any of it on the engine.

### Not built, in order

1. The notes ring shared and locked, then `hvdbt.c` per vCPU, then a boot with `-smp 2`. Only a boot can answer risks 3 to 7.
2. Emulated LSE atomics on page tables, in place of the stop. Only if the tally shows them.
3. Spin limit and yield. Eviction under several vCPUs in a test. The code cache rendezvous. Marking a block's first frame before translating, if double translation shows up in a profile. Avoiding the second exit on IPI receipt (`HC_IRQ`), about 0.8 us, by looking at the host IRR first.

## Not exact, known

- **The private window.** Private memory lives at a non-canonical VA (bit 47 set, top bits clear), 2 TB slots at `0xF000_0000_0000` and `0xF100_0000_0000`. Other non-canonical addresses fault and become #GP, tested. A guest access inside the window instead reads the lookup table or context, or writes context or return stacks. A compatibility risk; stage 2
  still bounds the guest. The monitor and shadow tables are out of reach (EL1 only), and code is execute-only.
- Saved RFLAGS after a straddling RMW with lock: not tested. x86 reserved-bit #PF is not modelled: a PTE with reserved bits set is treated as valid.
- Unmasked SSE exceptions stop, since FP traps cannot be taken here. So do TF single-step, CR0.WP off and CR4.SMAP.
- A split locked access, across 16 bytes, stops rather than taking a bus lock.
- APIC: x2APIC is absent, LVT error and thermal never fire, ESR reads 0.

## What is left to boot XNU

Honest order of risk, none of it started except as noted.

1. **Multi-vCPU.** Everything here ran on one vCPU. Monitor statics must split per vCPU, shadow tables and block maps need locks, invalidation needs IPIs (a killed block's return-stack entries on another vCPU), and the host's translator needs a lock. EnTSO was only proved on two vCPUs in the spike's litmus.
2. **32-bit kernels,** up to 10.7 or so, stay on TCG, as do real mode and firmware. 32-bit user code: see "Compatibility mode", not yet run under XNU.

1. **Multi-vCPU.** Designed, and running a test kernel on 4 vCPUs: see "Multi-vCPU". QEMU still has one, and nothing here has booted with more.
2. **Compatibility mode and 32-bit code.** 32-bit apps, kernels up to 10.7 or so, and `sysenter`. The decoder and emitters assume 64-bit mode. Real mode and firmware stay on TCG, using `EngineX86State` as the hand-off; whether QEMU tolerates two engines on one vCPU is still untested on a real boot.
3. **x87 and MMX.** In the monitor, at about 50 ns an operation against Rosetta's 9 (`t_x87`), and test-i386's `test_floats` passes. Not booted. If the tally shows x87 still hot, inline `fld` and `fstp` come first; if it shows `fsin` and friends, they would need porting.
4. **Far control flow and system odds:** ring 0's `lretq` and far calls, mov to CS (the test kernel avoids them, starting with CS already set), `ins`/`outs`, debug registers, TF, NMI, machine checks, `xsave` family, `invpcid`, and proper MSR routing. SSE4 is unadvertised.
5. **QEMU integration.** Written, unproven: see "Hybrid with TCG", whose tally ranks the rest of this list.
   Device model time and BQL contention are unmeasured. MMIO in a real kext may also use forms that stop (SIMD to a device outside `rep`); those now fall back, and the tally counts them.
6. **Limits to lift.** Kernel domains are capped at 16, and the code cache is 118 MB with a whole-cache reset. `Tests/stress-limits.sh` runs everything with a tiny cache and shadow pool, so the reset and reclaim paths are exercised, though never on a real guest's working set.
7. **Unknown rates.** Page-table write rate in a real macOS guest. At these costs even 1M writes/s would be 60-300 ms of 4000. Cold translation during boot: 2.4 us per function, and how much code a boot touches is unmeasured.
8. **Platform durability.** `ACTLR_EL1.EnTSO` from HVF is undocumented as far as I know, and hardware TSO could go when Rosetta does.

## Go or no-go

Go for the next phase. Translated code matches Rosetta in steady state and passes every differential check available, and in-VM kernel paths cost about 2% of four vCPUs at real-guest rates with the x86 kernel model proven only on a test kernel of our own. That is not evidence about a booting Mac: nothing here has run XNU, one vCPU, 64-bit only.
Stop and reconsider if multi-vCPU shadow locking costs far more than the numbers here, or if a real guest's page-table write rate is above several million per second.

## Earlier spike measurements

The probe in `Source/probes/hv-engine-spike` came first. These are its figures, kept because they decided the design: trap costs by privilege level, and why guest EL2 was dropped.

## Measured (M4 Max, macOS 27.2, release build running, load 10-13; best of 5, several runs)

ns per iteration. Spike uses 4 KB stage 1 over 16 KB stage 2, EL0, EnTSO on. Checksums agree in all three columns.

| Workload | Spike | Rosetta | Native arm64 | Spike/Rosetta | Spike/native |
|---|---|---|---|---|---|
| int loop | 1.59 | 1.60 | 1.08 | 0.99 | 1.47 |
| load+add+store, 16 KB | 0.260 | 0.257 | 0.258 | 1.01 | 1.01 |
| chase 16 KB | 0.763 | 0.768 | 0.769 | 0.99 | 0.99 |
| chase 64 MB | 110 | 83 | 84 | 1.32 | 1.31 |
| call/ret, 3 per iter | 4.19 | 3.19 | 1.79 | 1.31 | 2.34 |
| call/ret, random site | 6.32 | 6.23 | 1.58 | 1.01 | 4.0 |
| compiled flag mix | 6.16 | 5.73 | 2.65 | 1.08 | 2.32 |

The 64 MB row is the noisiest: spike 105-125, Rosetta 83-112, native 84-94 across runs.

Other measurements:
- A timed run makes one VM exit, the final `hlt`. x86 averages 1.77 AArch64 words, stubs included.
- Chase 64 MB by stage 2 granule: 4 KB 115-125 ns, 16 KB 105-112 ns. Adding 2 MB stage-1 blocks: 94-97 ns.
- EnTSO cost single-threaded: none visible (same numbers within noise, EnTSO off vs on).
- EnTSO works at EL0 in the VM: message-passing litmus on two vCPUs, 94M violations in 200M reads off, 0 on.
- Exit round trip through SVC, EL1 vector, HVC, host, ERET, including sys-reg reads: about 0.98 us.
- CR3 reload, sweeping 32 pages (8.3 ns baseline):
  ASID switch in the EL1 vector 55 ns; ASID switch through the host 0.98 us; full invalidate plus 33 refills 32.8 us.
- Page fault to shadow fill: about 1 us refilling touched memory, 2.1-3.6 us on first touch (host demand-zero and
  table allocation included). Dirty-bit upgrade with `tlbi vale1`: 1.5-3.2 us.
- `hv_vm_protect` on one 4 KB IPA page: accepted with the 4 KB granule, refused with 16 KB, as expected.
- Clean stops were exercised for cpuid, a privileged 0F 01 opcode, an fs: override and an unmapped page.

Flag correctness: a hand-written x86 check (`w_flagasm`) reads CF, OF, SF, ZF after add, sub, cmp, test, logic, neg,
inc/dec (CF kept via `rmif`), narrow forms, shifts (CF via `rmif`), memory RMW and across an indirect branch. Its checksum
matches Rosetta, which stands in for real x86 here; no Intel hardware was used.

## Can it stay inside the VM? Trap costs, plain EL1 vs guest EL2 (measured)

M4 Max, macOS 27.2, other benchmarks running, load 3-8. Each cell is best of 5, shown as the range over two or more
process runs; expect 15% run-to-run. `el2guest.s` is hand-written: it has the instruction shape the translator would emit
(register mapping and hash lookup from `spike.c`), but the translator has no syscall, and the kernel body is empty.

| Path, round trip unless noted | Plain EL1 runtime, ns | Through virtual EL2, ns | Exit to host, ns |
|---|---|---|---|
| Bare trap and return: EL0 svc/eret; EL0 trapped mrs; EL1 hvc | 31-34 (EL0-EL1) | 2480-2540 (EL0); 2230-2570 (EL1) | 640-730 (EL1 hvc) |
| Translated `syscall`, stack swap, hash lookup, `sysret` | 35-40 | 2310-2560 | not run |
| Translated fault: CR2, six-word frame, `iret` | 36-41 | not run; bare trap above is the floor | not run |
| Write-protect fault, emulate the store only | not run | 3400-3540 (stage-2 fault) | 735-840 |
| Page-table write: fault, emulate, shadow PTE, TLBI, later refill | 194-256 | 3730-4200 | 920-1110 |
| `tlbi vale1is`, `dsb`, `isb` (15 baseline) | 150-184 | 700-800 | not applicable |
| `tlbi aside1is` / `vmalle1is` | 98-148 / 106-148 | not run / 700-800 (`vmalls12e1is`) | not applicable |
| ASID switch: `msr ttbr0_el1` + `isb`, one way | 8.4-9.7 | 10-11 at vEL2 | not applicable |
| Device-style load from an unmapped IPA, no device model | not possible in-VM | 760-880 (from EL1 under EL2) | 710-820 |

The same EL0/EL1 rows with a guest stage 2 live and vEL2 idle: svc 30-34, syscall 35-41, fault 36-41, page-table write
249-388, TLBI at EL1 150-280, ASID switch 8.5-9.8. So guest EL2 costs nothing while unused, and about 2.5 us per entry when
used.

| Interrupts and IPIs | ns |
|---|---|
| Shared-memory poll, one way | 39-41 |
| IPI via in-kernel GIC SGI, peer busy, one way (no user-space exit) | 1830-2030; 3340 with EL2 enabled |
| IPI via GIC SGI, peer in WFI, one way | 2400-3250 |
| IPI carried by the host (hv_vcpus_exit, pending IRQ), one way | 2050-2170 |
| Inject from another host thread, busy guest: hv_vcpus_exit, re-entry, to IRQ vector | 1260-1400 |
| Same, `hv_gic_set_spi` to a busy guest (no user-space exit) | 1380-1540; 2540 with EL2 enabled |
| Wake a WFI guest: without a GIC, WFI exits to the host; semaphore, inject, re-entry | 6100-7100, fastest event 3000 |
| Wake a WFI guest with `hv_gic_set_spi`; WFI stays in the kernel (0 exits) | 6700-7200, fastest event 3000 |

Memory and ordering with EL2 on:
- Translated workloads over a guest stage 2 and stub vEL2 (`SPIKE_EL2`, 1 GB blocks), checksums identical: int 1.57,
  mem 0.255, chase 16 KB 0.765, chase 64 MB 112, call 4.18, random call 6.13, flags 6.00. Same as the table above.
- Hand-written chase 64 MB at EL0, 4 KB stage 1. Host 4 KB IPA: VM=0 122, guest S2 2 MB 122, guest S2 4 KB 125, no EL2 107-124.
  Host 16 KB IPA: 97, 92, 104, no EL2 107. No walk penalty is visible through the noise.
- First touch under a 4 KB guest stage 2 costs about 54 us per page (1M-line warm pass: 1030 vs 145 ns per load, 16 K
  pages); with 2 MB guest blocks nothing visible. Presumably the host builds a merged stage 2 on faults.
- EnTSO survives at EL0, EL1 and vEL2 under guest stage 2: litmus 14-15M violations in 30M reads off, 0 on, set through
  `ACTLR_EL1` from the host. 4 KB stage 1, 4 KB guest stage 2 and `hv_vm_protect` of one 4 KB page all work.

What the numbers mean:
- The timings show an emulated EL2, inferred, not read from any source. `ERET` at vEL2 alone costs 780 ns; TLBI at vEL2 traps at 700-800 ns. vEL2 system registers
  do not trap (`elr_el2` round trip 4-6 ns), FEAT_NV2 style. So a vEL2 entry is over 3x an exit to user space.
- ID registers: `VH=0`, `NV=2`, no FGT. E2H and TGE are not honoured: writes read back from vEL2, but the host read drops
  them and EL0's SVC still goes to EL1. Nothing routes `syscall` to vEL2 except a trapped instruction or a stage-2 fault.
- HVC at vEL2 re-enters vEL2; SMC reaches the host.
- `hv_gic`: the API has no GICR_WAKER, so the guest clears it itself; SPI routing written before a vCPU exists does not take
  effect, and the SPI then stays pending and undelivered. IROUTER is written after vCPU creation here.

### Revised vCPU overhead, ms of vCPU time per second, whole guest

Rates are the measured 4-vCPU system-heavy ones, assumed to be guest totals. Host MMIO is exit only: no x86 decode or
device model, neither measured. Interrupt cost is latency, an upper bound on vCPU time. Translated kernel work is not a trap
cost and is not counted. Shadow fills, IPIs beyond the 10k, and page-table write counts are unmeasured.

| Event | Rate/s | All exit, at prior 1-3 us | Plain EL1 monitor | Monitor at vEL2 |
|---|---|---|---|---|
| Syscall + return | 50,000 | 50-150 | 2.0 (40 ns) | 128 (2.55 us) |
| Exception + iret | 32,000 | 32-96 | 1.3 (41 ns) | 82 (2.55 us) |
| MMIO | 114,000 | 114-342 | 94 (820 ns, host) | 100 (880 ns, host) |
| Interrupt | 10,000 | 10-30 | 15 (1.54 us) | 25 (2.54 us) |
| CR3 write | 9,000 | 9-27 | 0.5 (55 ns, earlier) | 23 (2.55 us) |
| **Total, no page-table writes** | | **215-645** | **113** | **358** |
| Each 100,000 page-table writes/s | | 100-300 | 25 (250 ns) | 420 (4.2 us) |

So a plain EL1 monitor costs about 11% of one vCPU, 3% of four, before page-table writes. The budget of 10% across four
vCPUs (400 ms) would still leave room for about 1.1M page-table writes/s. EL2 makes every row worse. MMIO is 83% of what
remains and is the next target, whether through in-VM fast paths for the hottest registers (a trapped access costs about
40 ns plus emulation, if it needs no host) or paravirtual rings.

## The softmmu load, from `prepare_host_addr` (read, not run)

| x86 access | Instructions | Extra loads | Barrier |
|---|---|---|---|
| 8-byte load, unaligned allowed | 10: ldp, and, add, ldr, ldr, add, and, cmp, b.ne, ldr | 3 | `dmb ishld` |
| 1-byte load | 9: as above without the addr_adj add | 3 | `dmb ishld` |
| 8-byte store | 10 | 3 | `dmb ish` (LD_ST and ST_ST have no narrower `sync[]` entry) |
| Spike load or store | 1, or 2 with a complex address | 0 | none |

`PVG_TCG_TSO=1` drops the barriers via `thread_set_x86_64_compat`. This fork's opt-in hashed TLB adds one `eor`. TCG's
register spills at block ends are not counted.

Reasoning, not measured: the spike's 16 KB loop does 2 accesses in about 1.2 cycles per word (assuming 4.5 GHz). Adding
20 instructions and 6 loads puts it at several cycles before barriers. **I did not measure TCG**, so the hypothesis has support, not proof:
hardware translation really is native speed here, but no number says what fraction of a real guest's time softmmu takes.
