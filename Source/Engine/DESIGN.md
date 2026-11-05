# HV engine: x86-64 translated code inside an HVF VM

A library for running x86-64 guests on Apple silicon: an x86-to-AArch64 translator whose output runs inside a Hypervisor.framework VM, with
hardware 4 KB stage-1 translation, EnTSO, and a small EL1 monitor. QEMU is meant to keep the devices and machine.

Build: `Source/Engine/build.sh` (monitor blob, x86 test images, Swift package, signing). Test: `Tests/run-all.sh`. Numbers: `Tests/bench.py`,
`engine-run --kernel .build/images/kernel`, `engine-run .build/images/t_callret`, `t_rep`, `t_smc`.

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
| 1. Translator coverage | Done: integer ISA, flags, LSE, bl/ret, per-site indirect, SSE, SSE2, SSE3, SSSE3, MXCSR, rep, SMC. x87, MMX, SSE4 and 32-bit code stop with a clear error |
| 2. Differential testing | Done: fuzz, QEMU test-i386, a compiled corpus, lc-bench arithmetic, all matching Rosetta |
| 3. Kernel model | Done: shadow paging, CR3 and PCID, IDT, syscall, iret, exceptions, in the monitor, passing a test kernel |
| 4. APIC and device interface | Done: in-VM APIC hot paths; `engine_api.h`, exercised by a harness |
| 5. QEMU accel | Hybrid with TCG written; never built into QEMU or booted. XNU has never run. See "Hybrid with TCG" |

## Measured: correctness

Each is a transcript or self-check, run by `Tests/run-all.sh`.

- **Fuzz.** 2511 instruction forms (`gen_fuzz.py`), 64 rounds each with random registers, flags, memory, rounding modes, FTZ and DAZ, and FP patterns
  (NaNs, SNaNs, denormals, infinities). Hash of all registers, masked flags, XMM, MXCSR and 8 KB of memory. Identical to Rosetta, in both flag modes.
- **QEMU `tests/tcg/i386/test-i386.c`** in 64-bit mode, unmodified but for a Mach-O section name, assembler spellings and Linux-only register names: 9200 transcript lines
  identical. Out of it: `test_floats` (x87), `test_enter` (Rosetta raises SIGILL on `enter`, so ours is unchecked against any reference), and 16-bit shld/shrd with
  counts above 16 (undefined; results match, Rosetta's CF does not).
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
- **Devices.** MMIO completes the faulting ARM load or store, so every x86 form of a move or read-modify-write works. Pairs, SIMD and atomics on a device stop, except `rep movs` and `stos`, which fall back to the per-element loop.

## Hybrid with TCG

The first contact with a real guest, built to find out what is missing rather than to be fast. One vCPU. `-Dhvdbt_engine=<Source/Engine>` builds it into QEMU, `LC_HVDBT=1` turns it on, `LC_HVDBT_TALLY=<file>` writes the tally. Without them no behaviour changes: the hooks are a null pointer test on slow paths (TB miss, kick, notdirty, DMA).

- **Hand-off.** TCG runs firmware and boot loaders. The first TB miss in 64-bit mode at a high-half address is XNU's `vstart`: the engine takes the state from `CPUX86State` and runs on TCG's vCPU thread.
- **Fallback.** Anything the engine can't do returns `ENGINE_RUN_FALLBACK` with the state precise at that instruction, as for an x86 fault. TCG runs that one instruction (`CF_NOIRQ`, count 1) and the next TB miss returns control. No normal TB is ever generated for a state the engine accepts, so a miss always comes. An instruction leaving 64-bit mode, or setting TF, means TCG keeps going until the state is acceptable: 32-bit processes run this way, slowly and correctly, as far as reading goes.
- **What goes back by design**, as its state stays QEMU's: `hlt`, `fxsave` and `fxrstor` (x87 is in `CPUX86State`), `mov cr8`, every MSR but the syscall family, all #UD (SSE4 and AES are advertised, and only TCG knows them), popcnt (below). The monitor's `stop` is the mechanism, so each old "stops with a clear error" with a known rip now falls back. Stops with no rip are about the engine's limits and stay final, with a register dump and the VM paused.
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

The split-store fix took 40 boots' 20 halts to 0 of 32, with no FIPS failures, fsck signals or user faults in 30 s runs. On a longer run, userland reached the guest agent and its first commands ran at about 176 s, then staging timed out because, from about 180 s, one kernel-extension pixel loop of nine MMX instructions held the vCPU for at least 50 s at about 119 us per pass. Measured from the tally: 9 fallbacks and about 6.4 device accesses per pass, and no CR3 writes for long stretches. That is the reason MMX is now translated. Everything but maskmovq is, and 358 forms match Rosetta. x87, fxsave and the MMX forms of cvtpi, movq2dq and SSSE3 remain with TCG. Not measured: the loop's cost now, or whether staging succeeds.

Frames that stopped being tables no longer trap (measured in a test, 271,673 stores down to about 15,700). How much of a boot's 256,000 stores a second that explains is not measured. The tally's `why blocks died` section answers the invalidation question. Direct cost so far: translation was 8.3 s of a 232 s run.

The boots on 2c7c5e1d measured: 8 of 8 clean, staging in 29 to 37 s, and page-table stores down from 256,559/s to 2,245/s (different runs and workloads, so the size is rough). lc-bench then sat in its `rep movsb` test past guest-bench's 900 s. The likely reason: the rep stub used NEON, which traps under CR0.TS, once per byte, with nothing in a plain copy to clear TS. A test measured a megabyte at about 2,100 times the cost. Not measured: that this was what lc-bench hit, as that needs a boot.

### Translated blocks: what the numbers say, and a proposal

From that 1,109 s run: 13.57M cold blocks, 16.65 s translating, so translation itself is 1.5% of the run. Blocks died: 6,900,496 in 9,714 view evictions (about 710 each), 3,490,815 in 205,657 stores higher in the tables (about 17 each), 234,246 from leaf stores, 30,489 from flood. Only 170 of the higher-table kills had the page still on the same frame, so a check for an unchanged mapping would save almost nothing there: those mappings really went, as when a process exits. (The count only sees entries valid at the time, so it runs low.) At least 5.56M cold blocks, 41%, repeated a rip and frame some other block had covered, 3.54M of them live in another view at the time.

Proposal, in order, each to be justified by the tally before the next:

1. More views. 64 views is 32 address spaces, against 367 process rows in that run, which is what makes evictions a steady 9/s. Hash tables take 1 MB per view and fill 128 to 192 MB of the private layout, and the return stacks fill 126 to 128 MB. With tables of 2^14 entries, 256 views need 64 MB of hash and 8 MB of return stacks, so the stacks have to move. Cost: a layout change, and more collisions per view. Gain: no eviction of live processes while under 128 address spaces. Bound: part of 1.5% for translation, plus refills and return-stack misses, which nothing here measures.
2. User translations shared by rip and frame, as kernel-half blocks already are by domain. Block validity is then per view but the code is shared, so a direct link between blocks on different pages is only valid in a view whose mapping of both pages matches. Either links stay within a page, with others through the view's table, or each view keeps its own links. Removing a view's mapping takes the block out of that view's table without killing it. Gain bound: the same 41% of 1.5%, so this is not worth building until something shows the indirect cost is large.

Larger costs show in that run. Device accesses at 25,315/s: 15.4M of 28.1M are two 4-byte writes by one kext to 0xa0000000, at rips 0x...4c2c and 0x...4c3b, about 7.7M each, and rep movs reads frame memory at 0x90000000 one element per exit. Device-specific fast paths would come before any of the above. Not measured: their cost per access.

Not measured: the rest of a boot, real device traffic, the TLB, TB and dirty-bitmap interplay beyond those few fallbacks. Cost per fallback is unknown; the tally's `tcg_ms` column gives it. Writes by a separate process into guest RAM (the OOP graphics helper) are not noted. Reset after hand-off is unexamined: firmware in 64-bit mode would run on the engine.

## Not exact, known

- **The private window.** Private memory lives at a non-canonical VA (bit 47 set, top bits clear), 2 TB slots at `0xF000_0000_0000` and `0xF100_0000_0000`. Other non-canonical addresses fault and become #GP, tested. A guest access inside the window instead reads the lookup table or context, or writes context or return stacks. A compatibility risk; stage 2
  still bounds the guest. The monitor and shadow tables are out of reach (EL1 only), and code is execute-only.
- Saved RFLAGS after a straddling RMW with lock: not tested. x86 reserved-bit #PF is not modelled: a PTE with reserved bits set is treated as valid.
- Unmasked SSE exceptions stop, since FP traps cannot be taken here. So do TF single-step, CR0.WP off, CR4.SMAP, and non-flat fs or gs loads by selector.
- A split locked access, across 16 bytes, stops rather than taking a bus lock.
- APIC: x2APIC is absent, LVT error and thermal never fire, ESR reads 0.

## What is left to boot XNU

Honest order of risk, none of it started except as noted.

1. **Multi-vCPU.** Everything here ran on one vCPU. Monitor statics must split per vCPU, shadow tables and block maps need locks, invalidation needs IPIs (a killed block's return-stack entries on another vCPU), and the host's translator needs a lock. EnTSO was only proved on two vCPUs in the spike's litmus.
2. **Compatibility mode and 32-bit code.** 32-bit apps, kernels up to 10.7 or so, and `sysenter`. The decoder and emitters assume 64-bit mode. Real mode and firmware stay on TCG, using `EngineX86State` as the hand-off; whether QEMU tolerates two engines on one vCPU is still untested on a real boot.
3. **x87 and MMX.** Stop today. Needs 80-bit helpers in the monitor, since a host exit per operation would be 1 us. Real apps use them; test-i386's `test_floats` is ready as the check.
4. **Far control flow and system odds:** `lretq`, far calls, mov to CS (the test kernel avoids them, starting with CS already set), `ins`/`outs`, debug registers, TF, NMI, machine checks, `xsave` family, `invpcid`, and proper MSR routing. SSE4 is unadvertised.
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
