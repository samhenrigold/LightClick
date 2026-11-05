# HV engine spike: x86-64 translated code inside an HVF VM

Run: `build.sh <out>`, then `<out>/spike bench|fill|cr3|litmus <out>/flat.bin`, `<out>/driver-x86`, `<out>/driver-arm64`.
Env: `SPIKE_IPA16` (16 KB stage 2), `SPIKE_NO_TSO`, `SPIKE_BLOCK` (2 MB stage-1 blocks on the 64 MB buffer), `SPIKE_EL2`
(translated code over a guest stage 2 with a stub virtual EL2).
Trap costs: `<out>/el2 plain|el2|hcr|chase|litmus|irq|irq-gic|irq-gic-wfi|ipi-gic|ipi-gic-wfi|ipi-host`; `chase`, `litmus`
and the GIC modes take a second argument `el2`. Guest code is `el2guest.s`.

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

## What the spike did not do

No x86 kernel mode, IDT delivery or guest-visible #PF in translated code (the trap-cost rows above are hand-written). No MMIO or interrupts in `spike.c`. No segments, i386, SSE, x87, `lock`, rep,
PF/AF consumers, or SMC handling. Only one vCPU ran translated code; the litmus is hand-written ARM. 128/64 div, flags
after CL shifts and flags after imul stop with an error. Translation runs on the host, so every cold block costs an exit.
TCG was not run. These are loops, not an OS: nothing about the speed of a booting Mac follows from this table.

## Design, as guesses from here down except where marked

### AccelOps
Add `accel/hvdbt` alongside `accel/hvf` (`accel/hvf/hvf-accel-ops.c` shows the shape): `create_vcpu_thread` owning one
`hv_vcpu_t`, `kick_vcpu_thread` calling `hv_vcpus_exit`, `generic_handle_interrupt`, and `synchronize_*` copying x0-x15,
NZCV and pinned state to `CPUX86State`. QEMU's devices, memory API and machine stay unchanged. CONFIG_HVF on arm64 only
builds `target/arm/hvf`, so this is a new accel for the i386 target, with TCG also built for fallback.

### MMIO (measured basis: stage 1 faults work, 1 us exit)
The host walker finds a GPA outside RAM and leaves the shadow PTE invalid, so stage 2 can stay 16 KB (measured faster)
and 4 KB holes need no 4 KB stage 2. On fault: ARM PC to x86 rip through a per-block side table, decode with
`target/i386/emulate/x86_decode.c`, complete through `address_space_rw`. Frequent framebuffer or PVG traffic needs testing.

### Interrupts
`hv_vcpus_exit` from the I/O thread can stop at any ARM instruction. x86 needs an instruction boundary. Almost all x86
instructions commit at their last ARM instruction, so: look up the PC, finish to the boundary by unlinking the current
block's exits, deliver through the x86 IDT. A polled flag at back edges is the simple alternative, costing a load and
branch per loop. QEMU's APIC timer drives kicks.

### x86 kernel mode
CPL0 translated code at EL1, CPL3 at EL0. U/S maps to AP, SMAP to PAN, and SMEP is natural since guest pages never execute
as ARM. Syscall and iret become translated sequences. The fallback is both rings at EL0 with an ASID each, adding about
55 ns per transition (measured for the swap). `hlt`, `invlpg`, CR writes, MSRs, cpuid and port I/O exit or run in a small
EL1 monitor (measured: EL1 is about 60x cheaper than vEL2, so vEL2 is out). Guest-visible #PF needs precise state: an RMW whose store faults has already changed NZCV, so RMW must emit
the store before the flag-setting op, or snapshot flags.

### Segments
Flat except GS/FS bases: pin a base register, add on prefixed accesses. Other non-zero bases or limits fall back to TCG.

### i386 guests
Registers hold 32-bit values; addresses use a 32-bit add and `uxtw` to wrap, at most one extra instruction. PAE and 2-level
tables are a different host walker. The shadow stays 4-level, and the 32-bit space sits at low VA. The 4G/4G kernels
that reload CR3 on each trap would be the worst case; ASID retention is mandatory there.

### SSE and x87
Pin xmm0-15 to v0-v15. Most SSE2 maps to NEON 1:1; FEAT_AFP (present) covers FP corner cases; `hv_vcpu_get_simd_fp_reg`
syncs state. x87 and MMX go to QEMU's softfloat helpers, which means a host exit each until a monitor can run them in the
guest; x87-heavy apps are a fallback risk.

### Self-modifying code
Translations are keyed by GPA with a page-to-block reverse map. Shadow PTEs for code pages are read-only. A write fault
invalidates that page's blocks and unlinks chains, reusing the rules QEMU's `tb_invalidate_phys_page` encodes. Code and
data sharing a page would ping-pong at 1-3 us, so such pages need checksum validation or TCG. Hole-private pages are
read-only to guest code but readable: see unknowns.

### 4 KB shadow invalidation
Roots per CR3 or PCID, tagged with ASIDs; the guest's G bit maps to nG=0. Evict with `tlbi aside1is`. `invlpg` becomes
`tlbi vale1is` in the monitor. Guest writes to its page tables: write-protect (1-3 us each, measured path) with KVM-style
unsync for leaf tables, resyncing on `invlpg` or CR3 reload. A and D are set host-side as in the spike. Full invalidate at
33 us is ruled out for any kernel that reloads CR3 often. x86 PS=1 can use stage-1 blocks (measured 13% gain at 64 MB).

### Multi-vCPU
One thread per `hv_vcpu_t`, EnTSO per vCPU (litmus measured two). Shadow tables and the block map shared under a lock;
`b` patches are atomic under the ARM cross-modification rule; 16-byte hash entries rely on LSE2 LDP atomicity (FEAT
present, reliance untested). Locked x86 RMW maps to LSE; unaligned locked ops across 16 bytes need an emulated split lock.
Shootdowns stay the guest's IPIs, plus `is` TLBI.

### Fallback to TCG
Keep CPUX86State as the switch format. The vCPU thread runs TCG's `cpu_exec` for real mode, firmware, SMM, x87-heavy
code, non-flat segments, then returns on a flat long-mode or protected-mode boundary. RAM is already shared. TCG blocks
keep barriers, so a mixed VM remains correctly ordered. Whether QEMU tolerates two engines on one vCPU thread is untested.

## Biggest unknowns

1. Page-table write rate and shadow fill rate in a real macOS guest. Other trap rates are now known, and cost about 11% of one
   vCPU with an EL1 monitor. Write-protect at 250 ns tolerates a high rate, but a fill still goes to the host unless the walker
   also moves in-guest.
2. MMIO: 83% of the remaining trap cost, and device model time on top is unmeasured. Whether hot registers can be served in-VM.
3. Return prediction. `br` via the cache is 2.3-4x native and up to 1.3x Rosetta. A shadow return stack with real `bl`/`ret`
   should help on call-heavy code; kernels are call-heavy.
4. Non-canonical isolation. A guest load at the hole address (bit 47 set, canonical bits clear) hits private memory instead
   of #GP. Execute-only stage 2, or an indirect table placed in code, may solve it. Not a host-safety issue; stage 2 still
   bounds the guest. Compatibility risk only.
5. Platform durability. `ACTLR_EL1.EnTSO` from HVF is undocumented as far as I know, and hardware TSO could leave future
   Apple silicon when Rosetta goes. The app's deployment target is 15.0: `ACTLR_EL1` exists there, and default 16 KB stage 2
   needs no 26.0 API, but only macOS 27.2 was tested.
6. Translation on the host for cold code: 1 us plus translate per block during boot and app launch.

## Next experiment

Plain EL1 monitor: go. Guest EL2: no-go on this OS and hardware. Build the freestanding x86-64 test kernel with IDT, syscall, timer
and fork-like page-table churn in this spike, translated at EL1 and EL0, and replace the hand-written rows with translated ones.
Separately, count page-table writes and per-register MMIO in a real guest, as neither is known; that decides how much of the
walker and device paths must also move into the VM.
