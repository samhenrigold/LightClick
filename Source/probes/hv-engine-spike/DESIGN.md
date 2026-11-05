# HV engine spike: x86-64 translated code inside an HVF VM

Run: `build.sh <out>`, then `<out>/spike bench|fill|cr3|litmus <out>/flat.bin`, `<out>/driver-x86`, `<out>/driver-arm64`.
Env: `SPIKE_IPA16` (16 KB stage 2), `SPIKE_NO_TSO`, `SPIKE_BLOCK` (2 MB stage-1 blocks on the 64 MB buffer).

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

No x86 kernel mode, IDT delivery or guest-visible #PF. No MMIO or interrupts. No segments, i386, SSE, x87, `lock`, rep,
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
EL1 monitor. Guest-visible #PF needs precise state: an RMW whose store faults has already changed NZCV, so RMW must emit
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

1. Trap rate in a real macOS guest: CR3, invlpg, page-table writes, MMIO, IPIs per second. At 1-3 us each, 100k/s would
   consume 10-30% of a vCPU. This decides the project.
2. Whether an EL1 monitor can run enough of it in-guest. The 55 ns vs 984 ns gap says it must, for the hot ones.
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

Before writing any kernel-mode code: measure unknown 1. Under TCG on an existing clone boot, count CR3 writes, invlpg, page
table writes (needs a hook), MMIO and interrupts per second during boot and a desktop workload; `probes/tcg-tlb-sources.d`
already covers part of it. Multiply by the 1-3 us above. If the projected exit overhead on a busy guest stays under about
10%, build a freestanding x86-64 test kernel with IDT, syscall, timer and fork-like page-table churn in this spike, and
measure that. If not, stop: the hardware-TLB gain would go back into exits.
