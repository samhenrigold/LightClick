/* Generated from machine-options.json by scripts/generate-machine-options, and the build fails while this differs. */
#ifndef QEMU_MACHINE_OPTIONS_H
#define QEMU_MACHINE_OPTIONS_H

/* Set by the app (MachineOptions). */
/* LC_HVDBT (enum, default off): Run the guest's 64-bit code in the hypervisor engine, with TCG as its other half. Needs a QEMU configured with -Dhvdbt_engine. Apple silicon only. */
#define LC_OPTION_LC_HVDBT "LC_HVDBT"
/* LC_HVDBT_KEEP_KPTI (enum, default off): Keep XNU's Meltdown page table switch in code the engine translates. Off skips it, for faster system calls, and the guest loses Meltdown protection. Only the engine reads it. */
#define LC_OPTION_LC_HVDBT_KEEP_KPTI "LC_HVDBT_KEEP_KPTI"
/* VIM_PASSTHROUGH_OPENGL_INPROCESS_LIBRARY (path, default unset: no in-process renderer): The OpenGL host library QEMU loads into its own process. */
#define LC_OPTION_VIM_PASSTHROUGH_OPENGL_INPROCESS_LIBRARY "VIM_PASSTHROUGH_OPENGL_INPROCESS_LIBRARY"
/* VIM_PASSTHROUGH_OPENGL_INLINE (flag, default off): Have the in-process OpenGL host serve inline. */
#define LC_OPTION_VIM_PASSTHROUGH_OPENGL_INLINE "VIM_PASSTHROUGH_OPENGL_INLINE"
/* VIM_PASSTHROUGH_OPENGL_SURFACE_IMPORT (presence, default off): Let the OpenGL host import guest surfaces directly. */
#define LC_OPTION_VIM_PASSTHROUGH_OPENGL_SURFACE_IMPORT "VIM_PASSTHROUGH_OPENGL_SURFACE_IMPORT"
/* VIM_DISPLAY_EVENT_DRIVEN (flag, default off): Scan the display out on events rather than on a poll. */
#define LC_OPTION_VIM_DISPLAY_EVENT_DRIVEN "VIM_DISPLAY_EVENT_DRIVEN"
/* VIM_OPENGL_VRAM_SERVICE (string, default unset: VRAM not exported): The service name QEMU exports guest VRAM under. */
#define LC_OPTION_VIM_OPENGL_VRAM_SERVICE "VIM_OPENGL_VRAM_SERVICE"
/* VIM_OPENGL_VRAM_ENDPOINT (path, default unset): Where the OpenGL host publishes its VRAM endpoint. */
#define LC_OPTION_VIM_OPENGL_VRAM_ENDPOINT "VIM_OPENGL_VRAM_ENDPOINT"
/* VIM_OPENGL_DISPLAY_ENDPOINT (path, default unset): Where the OpenGL host publishes its display endpoint. */
#define LC_OPTION_VIM_OPENGL_DISPLAY_ENDPOINT "VIM_OPENGL_DISPLAY_ENDPOINT"
/* VIM_AUDIO_OUTPUT_DEVICE (string, default unset: SDL's default device): The SDL output device. A named device that's missing fails rather than rerouting. */
#define LC_OPTION_VIM_AUDIO_OUTPUT_DEVICE "VIM_AUDIO_OUTPUT_DEVICE"
/* VIM_AUDIO_INPUT_DEVICE (string, default unset: SDL's default device): The SDL input device. A named device that's missing fails rather than rerouting. */
#define LC_OPTION_VIM_AUDIO_INPUT_DEVICE "VIM_AUDIO_INPUT_DEVICE"
/* VIM_INPUT_BACKPRESSURE (flag, default off): Refuse a whole input batch before dispatch when the guest can't take it, so the app can retry it without duplicates. */
#define LC_OPTION_VIM_INPUT_BACKPRESSURE "VIM_INPUT_BACKPRESSURE"
/* VIM_E1000_LINK_HISTORY (flag, default off): Record the e1000's link history, for --record-network-history. */
#define LC_OPTION_VIM_E1000_LINK_HISTORY "VIM_E1000_LINK_HISTORY"
/* VIM_INSTALLER_DISPLAY_SOCKET (path, default unset: no installer display): The app's socket for the installer display. */
#define LC_OPTION_VIM_INSTALLER_DISPLAY_SOCKET "VIM_INSTALLER_DISPLAY_SOCKET"
/* VIM_DISPLAY_REFRESH_MS (int, default unset: the display's 30 ms poll): The installer display's poll interval, in milliseconds. */
#define LC_OPTION_VIM_DISPLAY_REFRESH_MS "VIM_DISPLAY_REFRESH_MS"
/* PVG_OOP_HELPER (path, default unset: PVG in process): The out-of-process PVG helper. Apple silicon only. */
#define LC_OPTION_PVG_OOP_HELPER "PVG_OOP_HELPER"
/* PVG_OOP_DONOR (path, default unset): The donor ParavirtualizedGraphics framework the helper loads. */
#define LC_OPTION_PVG_OOP_DONOR "PVG_OOP_DONOR"
/* PVG_APP_DISPLAY_SOCKET (path, default unset: no app display): The app's socket for the PVG display. */
#define LC_OPTION_PVG_APP_DISPLAY_SOCKET "PVG_APP_DISPLAY_SOCKET"
/* PVG_OOP_SCALE_FACTOR (int, default unset: the framework's): The helper's panel scale: 1 or 2, and anything else stops the helper. */
#define LC_OPTION_PVG_OOP_SCALE_FACTOR "PVG_OOP_SCALE_FACTOR"
/* PVG_APP_DISPLAY_SCALE (int, default unset: follows the host display): The panel is Retina when this is 2. A capability, not the current mode. */
#define LC_OPTION_PVG_APP_DISPLAY_SCALE "PVG_APP_DISPLAY_SCALE"
/* PVG_PRESERVE_IOSURFACE (flag, default off): Preserve IOSurface contents for the legacy shadow. */
#define LC_OPTION_PVG_PRESERVE_IOSURFACE "PVG_PRESERVE_IOSURFACE"
/* PVG_SHADOW_COALESCE (presence, default off): Coalesce the legacy shadow's page copies. */
#define LC_OPTION_PVG_SHADOW_COALESCE "PVG_SHADOW_COALESCE"
/* PVG_SHADOW_MAX_CHUNK (int, default 65536): The largest coalesced copy: a power of two from 4096 to 1048576. */
#define LC_OPTION_PVG_SHADOW_MAX_CHUNK "PVG_SHADOW_MAX_CHUNK"
/* PVG_SHADOW_TEXTURE_PAGING (presence, default off): Hook texture paging in the legacy shadow. */
#define LC_OPTION_PVG_SHADOW_TEXTURE_PAGING "PVG_SHADOW_TEXTURE_PAGING"
/* PVG_TEST_MSAA_TRANSFER (presence, default off): The ordered transfer for packed multisample depth/stencil. Intel only, despite the name. */
#define LC_OPTION_PVG_TEST_MSAA_TRANSFER "PVG_TEST_MSAA_TRANSFER"
/* PVG_HOST_AIR_LLVM (path, default unset: no repair): The LLVM library for Mojave's host AIR shader repair. */
#define LC_OPTION_PVG_HOST_AIR_LLVM "PVG_HOST_AIR_LLVM"

/* Testing flags, which stay environment variables. The app drops inherited PVG_ ones. */
/* LC_HVDBT_TALLY (path, default unset): Where the engine writes its tally. boot-matrix reads it. */
#define LC_OPTION_LC_HVDBT_TALLY "LC_HVDBT_TALLY"
/* LC_HVDBT_KERNEL (path, default unset): Where to dump the guest kernel. */
#define LC_OPTION_LC_HVDBT_KERNEL "LC_HVDBT_KERNEL"
/* LC_HVDBT_RAM (path, default unset): Where to dump guest RAM at shutdown or reset. */
#define LC_OPTION_LC_HVDBT_RAM "LC_HVDBT_RAM"
/* LC_HVDBT_SCREEN (path, default unset): Where to dump the guest's screen. */
#define LC_OPTION_LC_HVDBT_SCREEN "LC_HVDBT_SCREEN"
/* LC_HVDBT_NO_DIRECT (presence, default off): Don't register the engine's direct memory listener. */
#define LC_OPTION_LC_HVDBT_NO_DIRECT "LC_HVDBT_NO_DIRECT"
/* VIM_DISPLAY_TIMING (flag, default off): Log the installer display's timing. */
#define LC_OPTION_VIM_DISPLAY_TIMING "VIM_DISPLAY_TIMING"
/* VIM_HVF_IO_LATENCY_PORT (int, default unset): HVF: the I/O port whose exit latency to time. */
#define LC_OPTION_VIM_HVF_IO_LATENCY_PORT "VIM_HVF_IO_LATENCY_PORT"
/* VIM_HVF_IO_LATENCY_MASK (int, default unset): HVF: widens the timed port to a range. Requires VIM_HVF_IO_LATENCY_PORT. */
#define LC_OPTION_VIM_HVF_IO_LATENCY_MASK "VIM_HVF_IO_LATENCY_MASK"
/* VIM_OPENGL_RENDERER_PID (int, default unset): An external OpenGL renderer's process, authenticated instead of the in-process library. */
#define LC_OPTION_VIM_OPENGL_RENDERER_PID "VIM_OPENGL_RENDERER_PID"
/* PVG_CAPTURE_LIBRARIES (path, default unset): A folder to save submitted Metal libraries in. */
#define LC_OPTION_PVG_CAPTURE_LIBRARIES "PVG_CAPTURE_LIBRARIES"
/* PVG_HVF_FAST_CPUID0 (presence, default off): HVF: answer CPUID leaf 0 without the device-model lock. A Mojave experiment. */
#define LC_OPTION_PVG_HVF_FAST_CPUID0 "PVG_HVF_FAST_CPUID0"
/* PVG_INTEL_PAGE_WALKER (presence, default off): Install the Intel page-table iterator hook. */
#define LC_OPTION_PVG_INTEL_PAGE_WALKER "PVG_INTEL_PAGE_WALKER"
/* PVG_LEGACY_SHADOW (presence, default on in the helper, which sets it): Install the legacy shadow. */
#define LC_OPTION_PVG_LEGACY_SHADOW "PVG_LEGACY_SHADOW"
/* PVG_SHADOW_PRIVATE_PAGING (presence, default on in the helper, which sets it): Hook private buffer paging in the legacy shadow. */
#define LC_OPTION_PVG_SHADOW_PRIVATE_PAGING "PVG_SHADOW_PRIVATE_PAGING"
/* PVG_NATIVE_INTEL_GEOMETRY (presence, default off): The local ARM26 donor's Intel geometry experiment. */
#define LC_OPTION_PVG_NATIVE_INTEL_GEOMETRY "PVG_NATIVE_INTEL_GEOMETRY"
/* PVG_OOP_CHECK_HELPER (path, default unset): With PVG_OOP_CHECK_RAM, a helper to try bootstrapping. */
#define LC_OPTION_PVG_OOP_CHECK_HELPER "PVG_OOP_CHECK_HELPER"
/* PVG_OOP_CHECK_MAPPINGS (presence, default off): Have the helper check its guest RAM mappings. */
#define LC_OPTION_PVG_OOP_CHECK_MAPPINGS "PVG_OOP_CHECK_MAPPINGS"
/* PVG_OOP_CHECK_RAM (presence, default off): Check that guest RAM can be shared with the helper. */
#define LC_OPTION_PVG_OOP_CHECK_RAM "PVG_OOP_CHECK_RAM"
/* PVG_OOP_TIMING (presence, default off): Time the helper's frames and acknowledgements. */
#define LC_OPTION_PVG_OOP_TIMING "PVG_OOP_TIMING"
/* PVG_TEST_SKIP_MSAA_UPLOAD (presence, default off): Skip multisample uploads. Never a production fix. */
#define LC_OPTION_PVG_TEST_SKIP_MSAA_UPLOAD "PVG_TEST_SKIP_MSAA_UPLOAD"
/* PVG_TRACE_PAGING (presence, default off): Trace PVG's paging. */
#define LC_OPTION_PVG_TRACE_PAGING "PVG_TRACE_PAGING"
/* PVG_TRACE_UI (presence, default off): Trace the Cocoa UI's view sizes. */
#define LC_OPTION_PVG_TRACE_UI "PVG_TRACE_UI"
/* PVG_TCG_EVENTS (path, default unset): Where TCG writes its event counts. guest-bench sets it. */
#define LC_OPTION_PVG_TCG_EVENTS "PVG_TCG_EVENTS"
/* PVG_TCG_LOOKUP_DIAGNOSTICS (flag, default off): Count TB lookups. */
#define LC_OPTION_PVG_TCG_LOOKUP_DIAGNOSTICS "PVG_TCG_LOOKUP_DIAGNOSTICS"
/* PVG_TCG_TSO (flag, default off): Run MTTCG threads under the host's hardware TSO. */
#define LC_OPTION_PVG_TCG_TSO "PVG_TCG_TSO"
/* PVG_TCG_NATIVE_FP_FLAGS (flag, default off): Use AArch64's FP flags for softfloat's. */
#define LC_OPTION_PVG_TCG_NATIVE_FP_FLAGS "PVG_TCG_NATIVE_FP_FLAGS"
/* PVG_TCG_DISPATCH_ACQUIRE (flag, default off): Add an acquire barrier to inline dispatch. */
#define LC_OPTION_PVG_TCG_DISPATCH_ACQUIRE "PVG_TCG_DISPATCH_ACQUIRE"
/* PVG_TCG_SHARED_DISPATCH (flag, default off): Share one out-of-line dispatch sequence. */
#define LC_OPTION_PVG_TCG_SHARED_DISPATCH "PVG_TCG_SHARED_DISPATCH"
/* PVG_TCG_TAIL_DISPATCH (flag, default off): Dispatch through a tail routine. Apple silicon only. */
#define LC_OPTION_PVG_TCG_TAIL_DISPATCH "PVG_TCG_TAIL_DISPATCH"
/* PVG_TCG_HASHED_TLB (flag, default off): The hashed softmmu TLB experiment. arm64 only. */
#define LC_OPTION_PVG_TCG_HASHED_TLB "PVG_TCG_HASHED_TLB"
/* PVG_TCG_TB_ALIGN (string, default native): Translation block alignment: native, 32 or 64. Apple silicon only. */
#define LC_OPTION_PVG_TCG_TB_ALIGN "PVG_TCG_TB_ALIGN"
/* PVG_TCG_TLB_FLOOR_BITS (int, default 12): The dynamic TLB's smallest size in bits, 6 to 14. arm64 only. */
#define LC_OPTION_PVG_TCG_TLB_FLOOR_BITS "PVG_TCG_TLB_FLOOR_BITS"
/* PVG_TCG_TLB_FLOOR_MASK (int, default 4): The MMU modes the TLB floor applies to. arm64 only. */
#define LC_OPTION_PVG_TCG_TLB_FLOOR_MASK "PVG_TCG_TLB_FLOOR_MASK"
/* PVG_TCG_ALTERNATE_LOOKUP (fastPath, default on for arm64): The jump cache's alternate entries. */
#define LC_OPTION_PVG_TCG_ALTERNATE_LOOKUP "PVG_TCG_ALTERNATE_LOOKUP"
/* PVG_TCG_BULK_REP (fastPath, default on for arm64): Bulk REP string operations. */
#define LC_OPTION_PVG_TCG_BULK_REP "PVG_TCG_BULK_REP"
/* PVG_TCG_CHAIN_SYS_RETURN (fastPath, default on for arm64): Chain translation blocks across system returns. */
#define LC_OPTION_PVG_TCG_CHAIN_SYS_RETURN "PVG_TCG_CHAIN_SYS_RETURN"
/* PVG_TCG_CONTEXT_JMP_CACHE (fastPath, default on for arm64): Keep jump caches per address-space context. */
#define LC_OPTION_PVG_TCG_CONTEXT_JMP_CACHE "PVG_TCG_CONTEXT_JMP_CACHE"
/* PVG_TCG_DISPATCH_RELAXED (fastPath, default on for arm64): Relaxed loads in inline dispatch. */
#define LC_OPTION_PVG_TCG_DISPATCH_RELAXED "PVG_TCG_DISPATCH_RELAXED"
/* PVG_TCG_FAST_PTW (fastPath, default on for arm64): The fast x86 page-table walk. */
#define LC_OPTION_PVG_TCG_FAST_PTW "PVG_TCG_FAST_PTW"
/* PVG_TCG_INLINE_FP (fastPath, default on for arm64): Inline scalar floating point. */
#define LC_OPTION_PVG_TCG_INLINE_FP "PVG_TCG_INLINE_FP"
/* PVG_TCG_INLINE_JMP_CACHE (fastPath, default on for arm64): Inline jump cache lookups. */
#define LC_OPTION_PVG_TCG_INLINE_JMP_CACHE "PVG_TCG_INLINE_JMP_CACHE"
/* PVG_TCG_INLINE_JMP_CACHE_32 (fastPath, default on for arm64): Inline jump cache lookups for 32-bit code. */
#define LC_OPTION_PVG_TCG_INLINE_JMP_CACHE_32 "PVG_TCG_INLINE_JMP_CACHE_32"
/* PVG_TCG_INLINE_JMP_CACHE_CPL0 (fastPath, default on for arm64): Inline jump cache lookups in the kernel. */
#define LC_OPTION_PVG_TCG_INLINE_JMP_CACHE_CPL0 "PVG_TCG_INLINE_JMP_CACHE_CPL0"
/* PVG_TCG_INLINE_SSE_PACKED (fastPath, default on for arm64): Inline packed SSE. */
#define LC_OPTION_PVG_TCG_INLINE_SSE_PACKED "PVG_TCG_INLINE_SSE_PACKED"
/* PVG_TCG_INLINE_TRIM (fastPath, default on for arm64): Trim the inline dispatch sequence, except while logging TBs. */
#define LC_OPTION_PVG_TCG_INLINE_TRIM "PVG_TCG_INLINE_TRIM"
/* PVG_TCG_KEEP_PHYS_TLB (fastPath, default on for arm64): Keep the physical MMU index's TLB entries across CR3 writes. */
#define LC_OPTION_PVG_TCG_KEEP_PHYS_TLB "PVG_TCG_KEEP_PHYS_TLB"
/* PVG_TCG_LAZY_JMP_CACHE (fastPath, default on for arm64): Flush the jump cache lazily. */
#define LC_OPTION_PVG_TCG_LAZY_JMP_CACHE "PVG_TCG_LAZY_JMP_CACHE"
/* PVG_TCG_NATIVE_EXACT_FP (fastPath, default on for arm64): Native floating point where results are exact. */
#define LC_OPTION_PVG_TCG_NATIVE_EXACT_FP "PVG_TCG_NATIVE_EXACT_FP"
/* PVG_TCG_NATIVE_PACKED_FP (fastPath, default on for arm64): Native packed floating point. */
#define LC_OPTION_PVG_TCG_NATIVE_PACKED_FP "PVG_TCG_NATIVE_PACKED_FP"
/* PVG_TCG_PCID_CONTEXTS (fastPath, default on for arm64): Keep translations per PCID. */
#define LC_OPTION_PVG_TCG_PCID_CONTEXTS "PVG_TCG_PCID_CONTEXTS"
/* PVG_TCG_RET_MISS_TAIL (fastPath, default on for Apple silicon): A tail routine for return-stack misses. */
#define LC_OPTION_PVG_TCG_RET_MISS_TAIL "PVG_TCG_RET_MISS_TAIL"
/* PVG_TCG_RET_STACK (fastPath, default on for Apple silicon): Predict returns with a return stack. */
#define LC_OPTION_PVG_TCG_RET_STACK "PVG_TCG_RET_STACK"
/* PVG_TCG_SSE_DIRECT_LOAD (fastPath, default on for arm64): Direct SSE loads. */
#define LC_OPTION_PVG_TCG_SSE_DIRECT_LOAD "PVG_TCG_SSE_DIRECT_LOAD"
/* VIM_PVG_EXACT_RUNS (flag, default on): Build shadow runs from the exact pages used. */
#define LC_OPTION_VIM_PVG_EXACT_RUNS "VIM_PVG_EXACT_RUNS"
/* VIM_PVG_GATHER (flag, default on): Gather shadow uploads through RAM windows. */
#define LC_OPTION_VIM_PVG_GATHER "VIM_PVG_GATHER"
/* VIM_PVG_POSTED_MMIO (flag, default off): Post allow-listed MMIO writes to PVG without waiting. */
#define LC_OPTION_VIM_PVG_POSTED_MMIO "VIM_PVG_POSTED_MMIO"
/* VIM_PVG_SCATTER (flag, default on): Scatter shadow downloads through RAM windows. */
#define LC_OPTION_VIM_PVG_SCATTER "VIM_PVG_SCATTER"
/* VIM_PVG_SLAB (flag, default on): Keep shadow baselines in a slab. */
#define LC_OPTION_VIM_PVG_SLAB "VIM_PVG_SLAB"
/* VIM_PVG_TIMING (flag, default off): Print PVG timing lines, at most every 5 s per metric. */
#define LC_OPTION_VIM_PVG_TIMING "VIM_PVG_TIMING"
/* VIM_SEAMLESS_PVG_DIR (path, default unset): Research, for seamless: directory of the per-window PVG surface files, including nodisplay. */
#define LC_OPTION_VIM_SEAMLESS_PVG_DIR "VIM_SEAMLESS_PVG_DIR"
/* VIM_SEAMLESS_PVG_SERVICE (string, default unset): Research, for seamless: Mach service that receives per-window PVG surfaces. */
#define LC_OPTION_VIM_SEAMLESS_PVG_SERVICE "VIM_SEAMLESS_PVG_SERVICE"
/* VIM_SEAMLESS_PVG_SAMPLED (flag, default off): Research, for seamless: log how sampled textures are backed, for sizing the layer-tree work. */
#define LC_OPTION_VIM_SEAMLESS_PVG_SAMPLED "VIM_SEAMLESS_PVG_SAMPLED"

#endif
