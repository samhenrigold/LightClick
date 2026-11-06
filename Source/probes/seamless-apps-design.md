# Seamless guest apps

Goal: a guest app is indistinguishable from a host app. Its own Dock icon and Cmd-Tab entry, one `NSWindow` per guest window with the
real shadow and alpha, popovers past the window's edge, sheets, menus, gestures, force click, drag and drop, and no visible VM. "It has
to be perfect" is the requirement, and it rules out designs that are only nearly right.

**Mavericks clones have now run the window tree and the hook; nothing else has run on a guest.** Host claims come from probes on macOS
27.2 (M4 Max, ProMotion, SIP on). Other guest claims come from reading stock Mavericks (13F34) and Mojave (18G103) binaries, read-only,
without Hopper (`nm`, `otool`). No other OS version was inspected. All guest numbers are under TCG on this busy Mac.

Labels: **[measured]** by a probe here. **[read]** seen in code or a binary. **[source]** public documentation or code, linked.
**[inferred]** reasoned, untested. **[memory]** recalled, unchecked; verify before relying on it.

## Measured on a Mavericks clone

`scripts/seamless-try hook <app> <machine>` boots one clone, loads the hook, and runs the same demo twice in that boot. Each window arrives
as its own host window with per-pixel alpha: the document window with its full shadow, the popover with its arrow past the window's edge, a
child panel, a translucent window, a real menu at its level, and a sheet with its own shadow window. Popover and sheet animations arrive
frame by frame. A click on a real button and a typed key, sent from the host, changed the guest app's title.

| 22 s, 7 windows over the run, a counter changing at 30 Hz, asked for 30 Hz | By capture | Through the hook |
| --- | --- | --- |
| Frames reaching the host | 13.5/s | 23.6/s |
| Window server calls for pixels | 45.1/s, 15.1 ms mean, 56 ms worst | 19.1/s, 12.1 ms mean, 49 ms worst |
| Tool's time in those calls | 68% | 23% (5 s refresh of each window, for the shadow and GL) |
| Tool's time applying hook rows | | 5.2% |
| Time the hook spends in WindowServer | | 2.87 s, about 13%, 4,815 passes at 0.6 ms |
| Sent | 3.5 MB/s | 4.8 MB/s |

- **The hook reads the right pixels:** with no animation running, 100% of 69,331 opaque pixels sampled from backing stores matched a capture of the same window. With the
  counter it's 99.7% of 31,519, as the two are read at different moments.
- **Injection works:** `DYLD_INSERT_LIBRARIES` in WindowServer's launchd plist loads the library, and its `mach_msg` interposer runs on the main thread, though the caller is
  in the shared cache. The desktop stayed up.
- **Offsets confirmed:** window `+0x108` is the backing, and `CGXBackingStoreDataIndexed(b, 1, 0)` gives readable BGRA, premultiplied, top row first, in shared memory at `0x1c0000000` up.
  Window `+0x100` holds the scale as a float. Of 31 windows at a login desktop, only one was accelerated: the Dock (2306x86).
- **One-window TextEdit stream, by capture:** 26 ms at 1310x854 pixels, 52 ms at 2560x1410, with a click on the zoom button working through `CGEventPost` from the console user.

What was wrong before these worked: `launchctl bsexec` only moves the bootstrap port, and prints "bsexec failed: Inappropriate ioctl for device" on 10.9. WindowServer finds a
client's GUI session from its **audit session**, so a tool started by the guest agent stayed in the system's: the connection and display calls worked, but the window list and session
dictionary came back empty. `probes/seamless-console.h` now joins Finder's audit session. **Anything else using bsexec this way on 10.9 has the same problem**
(`probes/gpu-bench.m`, `probes/seamless-integration-guest.m`) if it needs session queries.

**Not working or not tried:**

- The composed images are made by the viewer from each host window's exact pixels, not read from the screen, because the host's display was asleep and `screencapture` failed. Nobody has yet
  looked at these as real windows on a display, with the real Dock, Mission Control or menu bar.
- The hook only delivers window contents. The shadow still comes from a capture, which is refreshed every 5 s and on resize. So it's also still needed for accelerated windows and GL views, which the
  hook skips. A window's order, bounds, alpha and title also still come from `CGWindowList`, polled.
- The hook compares every wanted window's rows on each pass, rather than knowing what changed. That 13% is the cost to remove.
- Pixels go over TCP through slirp. Nothing is zero-copy yet. No GPU composite, and nothing headless.
- Dragging a window, resizing, scrolling and full-screen weren't exercised in the tree. Tooltips and drag images weren't tried.
- Mojave: no hook. Its symbols are read, not run.

## Answer

Feasible as far as can be seen without a boot, and the guest's own window tree is the design, not the framebuffer.

1. **The guest's window tree goes to the host as separate surfaces with alpha**, in display order, with level, group, shape and shadow.
   Every window kind then works the same way: a popover is just a window. This now runs on real windows on this Mac: a real shadow, the
   popover's shape with its arrow, a child panel, a translucent window, a real menu and a sheet each arrived as their own host window with
   per-pixel alpha, and the popover's opening animation came through live [measured].
2. **WindowServer is the source.** First through its client interface, which needs no patch and works today; then a hook inside it for
   damage, GPU-side per-window composites and running headless. Both generations have the internal function that this needs: Mission
   Control's live thumbnails use it [read].
3. **A generated `.app` per guest app** owns the Dock tile, the windows and the menu, showing layers rendered by the VM's process through
   `CALayerHost`, which works across processes at 120 Hz with SIP on [measured].

SIP doesn't block anything this needs on the host, because each proxy only changes its own windows. The largest unknowns: the cost of
per-window capture under emulation, which `scripts/seamless-try tree` measures; and how a composite in the guest reaches the host without a
CPU copy, which is different for vmware-svga and PVG. Cropping the framebuffer into slots is kept only as a possible quick path; it can't
do real shadows, overlap or alpha, so it can't be the end state.

| Generation | Display path | Feasible? | What's specific to it |
| --- | --- | --- | --- |
| Tiger | vmware-svga | Unknown, least likely to be perfect | `CGWindowList` arrived in 10.5 [memory]. Not inspected |
| Leopard to Mountain Lion | vmware-svga | Likely | Not inspected. Client interface expected to work; hook per version |
| Mavericks to High Sierra | vmware-svga, PassthroughOpenGL | Likely; Mavericks is the prototype | GL compositor, local symbols present. Its GL already runs on the host GPU |
| Mojave | PVG | Likely | `WSCompositeWindowToDestination` exists; SIP and AMFI off in the guest, SkyLight already patched [read] |
| Catalina, Big Sur | PVG | Likely, least certain | Titles need Screen Recording from 10.15 [memory]. Big Sur's shared cache makes the hook much costlier. Not inspected |

## Requirements

**Status words:** *proven* means measured on this host through the real code; nothing is proven on a guest. "A" marks what changes the
architecture now. "Input" and "Integration" name the parallel work; see [Interfaces](#interfaces-for-the-parallel-work).

### Windows and pixels

| Requirement | Mechanism | Host API | Proven | Unknown |
| --- | --- | --- | --- | --- |
| **A** One surface per window, in order, overlapping | Window tree from `CGWindowListCopyWindowInfo`; pixels from the hook, or capture | `NSWindow` per guest window, ordered and at the guest's level | On Mavericks, through the hook, at 23.6 frames/s for a live window [measured] | Accelerated windows; rate with a big live window |
| **A** Drop shadows, real alpha | `CGWindowListCreateImage` of the bounds grown by a margin includes the shadow, on transparent, and backing rows are laid over it. Host `hasShadow` off | Non-opaque window; `SLSSetWindowEventShape` so the shadow doesn't take clicks | Real 10.9 shadows on Mavericks [measured]. A 48-point margin clipped an active window's; 96 doesn't | Taking the shadow from `CGXWindowShadowGet` instead of a capture; an active-to-inactive change between refreshes |
| **A** Popovers, sheets, menus, tooltips, panels, drag images | All are guest windows with the same owner; `CGSCopyAssociatedWindows` groups them with their parent. Host places them by guest position, so they extend past the parent by themselves | Same; `addChildWindow:` once a proxy moves groups | Popover, panel, menu (layer 101), sheet on Mavericks [measured]. Tooltips and drag images not tried | Drag images may be owned by another process. A popup menu's group didn't include its parent, so grouping isn't only `CGSCopyAssociatedWindows` |
| Window animations | Bounds and alpha sent as they change; the popover's growth arrived frame by frame [measured]. Transforms: `CGSGetWindowTransform` | Frame, alpha, layer transform | Size and alpha only | Genie and Mission-style transforms under capture; hook composites them |
| Vibrancy | Guest material samples the guest's backdrop | `NSVisualEffectView` behind a punched-out region, if the hook can separate it | No | Mojave `WSBackdrop*` layers exist [read]; separating them needs the hook |
| Resize at 120 Hz | Host resizes first and stretches the last frame, guest follows; host present path can do 120 Hz | `CAMetalLayer`, `CALayerHost` | Present rate only, 8.33 ms median [measured] | Guest redraw rate, 60 Hz modes (`gpu-performance-notes.md`) |
| Retina, 1x apps | Per-window scale: pixel size against point size; a 1x window is scaled by the layer | `contentsScale` | 400x240 pixels for 200x120 points [measured] | Filter choice for 1x on 2x |
| **A** Multi-monitor, mixed DPI, moving between screens | Windows are independent, so a host window can sit anywhere. A guest window's backing scale stays what the guest made | `NSWindow` | No | Guest has one scale; a window on a 1x and 2x pair is resampled |
| **A** Color management | Guest sRGB or display profile to host. `CGSCopyWindowColorSpace` per window [read]; tag the surface | `CAMetalLayer.colorspace`, IOSurface color tags | No. The probe saw magenta converted to display color, so the path isn't neutral | Which space WindowServer's composite is in |
| Full screen, Spaces, Mission Control | Host owns these; proxies are normal windows. A guest full-screen request becomes a host full-screen window | `collectionBehavior` | `Foreground` type in `lsappinfo` only [measured] | Must be looked at by eye. Guest full-screen Spaces (Lion on) take windows off the list |
| **A** Host screenshots and capture of proxy windows | Normal windows capture normally. `CALayerHost` content was read back by ScreenCaptureKit in the proxy [measured] | | Own-process SCK [measured] | Whole-screen `screencapture` by eye |

### Input (parallel work)

| Requirement | Mechanism | Host API | Proven | Unknown |
| --- | --- | --- | --- | --- |
| Pointer | Guest screen points, `window = 0` on the wire; host window position maps host to guest | `NSEvent` | A real button clicked and text typed on Mavericks, through `CGEventPost` from the console user [measured] | Host-side `NSEvent` to these points, by hand |
| Trackpad gestures, force click, pressure stages, momentum | Input work: Apple's RFB `0x17` per `guest-capabilities.md`, or direct injection | `NSEvent` phases, `pressure`, `stage` | No | Whole area, per OS |
| Cmd-Tab, Cmd-Q, Cmd-W, IME, dead keys | Host keeps Cmd-Tab. Proxy's menu takes Cmd-Q and Cmd-W and acts on the guest app. No event tap needed | `NSTextInputClient`, proxy `NSMenu` | No | Input work |
| Focus | Host key window to guest raise and activate; first key waits for confirmation | `windowDidBecomeKey` | `SWM_FOCUS` sent | Stalls under TCG |

### Life of the VM (architecture changes now)

| Requirement | Mechanism | Host API | Proven | Unknown |
| --- | --- | --- | --- | --- |
| **A** Invisible VM: launch boots or resumes, suspend on last quit, host sleep and wake | A session process that owns QEMU with no window. A fast resume needs a snapshot (`savevm`/`loadvm` to fast storage, or a mapped RAM file) rather than a 40 s boot | `NSWorkspace` sleep notifications | No | Whether QEMU snapshots work across PVG and passthrough GL state; probably not without device work. **Largest lifecycle risk** |
| **A** Windows with no owning app: SecurityAgent, Keychain, crash reports, Software Update, loginwindow, assistants | The tree is "everything except an exclusion list" (`--all`: not Dock, Window Server, SystemUIServer). A window with no matching proxy gets a generic "Mac OS X" proxy | Fallback proxy | `--all` filter written, not tried | Secure-input windows may refuse capture; `CGSSetWindowSharingState` blocks (tag `kCGSWindowSharingNone`); the hook bypasses this |
| **A** Guest crash, panic or reboot with apps open | Session sees the agent or QEMU go; proxies stay with their last frames and a dialog, and are told "relaunch" or "close" | | No | State across reboot |
| **A** Several VMs at once | Each proxy bound to a machine by bundle ID; each session has its own offset and socket | Identity carries machine ID | No | RAM and battery; ports already clash (`boot-clone` knows) |
| **A** Fallback when no hook for a build | Layered: hook, else client interface, else a plain windowed VM. Chosen by build at start | Existing window | Client interface runs with no hook | Which builds lack which client calls |
| **A** Battery and idle cost | Guest idle cost is the main term; hook damage instead of polling. The hook now costs about 13% of WindowServer's time while comparing rows | | `CGSGetWindowFlushSeed` errors for another process's windows on macOS 27 [measured: `seed_answers 0`], and its code looks windows up in a client-side table on 10.9 too [read]. So damage needs the hook | The VM's idle CPU under TCG; `capture_share` reports the probe's cost |

### App identity and integration (parallel work)

| Requirement | Mechanism | Host API | Proven | Unknown |
| --- | --- | --- | --- | --- |
| Dock tile, Cmd-Tab identity | Generated `.app` from the guest's `Info.plist` and icon | LaunchServices | Ad-hoc bundle, `Foreground`, own bundle ID [measured] | By eye |
| Badges, bouncing, Dock menus | Integration work: `NSDockTile`, `requestUserAttention`; source in guest unknown | | No | Guest Dock's data |
| Host menu bar | AX menu tree to `NSMenu`; item selection to `AXPress` | `NSMenu`, `menuNeedsUpdate:` | `ax-menu-response.c` exists | AX cost under TCG; root's AX grant |
| File drag in, drag onto icon, drag out, Open With | Integration work, `guest-capabilities.md`. Document types from guest `Info.plist` | `application:openURLs:`, `NSDraggingDestination` | `openURLs:` on a generated bundle [measured] | Write-back; drag out |
| Notifications, Services, Quick Look | Integration work | | No | |
| **A** VoiceOver and Accessibility | Guest AX tree bridged: proxy exposes an `NSAccessibilityElement` tree mirrored from guest AX | `NSAccessibility` | No | Cost; this is a big piece of its own, name a separate owner |
| Clipboard | `VIMClipboardBridge`: text only | | Existing | Images, files |

## What SIP blocks

Everything below ran unprivileged with SIP on, using `probes/seamless-host-capabilities.m`. This shell holds Accessibility
and Screen Recording grants, which may have affected the reading of another process's title and possibly activation. The
window operations and layer hosting don't depend on those grants as far as I can tell, but I didn't rerun without them.

| Operation | On this process's own window | On another process's window |
| --- | --- | --- |
| `SLSSetWindowLevel` | Works; `kCGWindowLayer` reads 25 | **No effect, no error.** `kCGWindowLayer` stays 0, although `SLSGetWindowLevel` reports 25 |
| `SLSSetWindowAlpha` | Works; alpha reads 0.5 | No effect, error 0 |
| `SLSMoveWindow` | Works; bounds move | No effect, error 0 |
| `SLSOrderWindow` | Works | Error 1000 |
| `SLSSetWindowEventShape` | Works: WindowServer's hit test passes through the hole to the window behind | Not tried |
| `SLSSetWindowShadowParameters`, `SLSSetWindowTags` | Error 0, effect not verified | Error 0, effect not verified |
| `SLSCopySpacesForWindows`, `SLSCopyWindowProperty` | Work | Work |
| `SLSMoveWindowsToManagedSpace` to the same Space | Returns; it has no error channel | Same; meaningless without a check |

**So: don't trust the error code or `SLSGet*`. Read back through `CGWindowListCopyWindowInfo`.**

What needs SIP partly off is any change to windows you don't own, and Dock-owned operations: per
[yabai's documentation](https://github.com/koekeishiya/yabai/wiki/Disabling-System-Integrity-Protection), creating and
moving Spaces, stripping shadows, transparency, layers, sticky and picture-in-picture all go through a Dock scripting
addition [source]. Because each proxy owns its own windows, this design never needs that. `SLSSetUniversalOwner` exists, but
I deliberately didn't call it, as it could take ownership from the real Dock.

Also works with SIP on [measured]:

- **Generated bundle:** an ad-hoc signed `.app` written at runtime, then `LSRegisterURL`, is found by bundle ID and shows in
  `lsappinfo` as `type="Foreground"` with its own name and bundle ID.
- **File association:** the bundle is offered as the handler for a `CFBundleDocumentTypes` extension, and receives
  `application:openURLs:`. LaunchServices ignored the bundle under the temporary directory (no handler, no lookup by bundle
  ID) but found it under `~/Library/Application Support`, so generated proxies must live outside the temp folder.
- **A bundle-less foreground process:** `setActivationPolicy:` plus `_LSSetApplicationInformationItem` shows as
  `type="Foreground"` under the new name, with no `.app`.
- **Activation:** `-[NSRunningApplication activateWithOptions:]` from a non-frontmost process brought the child to the front.
- **Cross-process layers:** a `CAContext` in one process, shown through `CALayerHost` in another's window, with no
  entitlement. A `contentsRect` crop of one IOSurface arrived correctly: the child's window read magenta from the right half
  of a half-green, half-magenta surface, confirmed through ScreenCaptureKit's own-process filter, which needs no grant.
- **120 Hz through that path:** a `CAMetalLayer` presented through `CALayerHost` matched one in the process's own window.

| Path, 3 s, 320x360 | Frames presented | Gap median | Gap p99 |
| --- | --- | --- | --- |
| Hosted cross-process | 354 | 8.33 ms | 16.67 ms |
| In-process window | 350 | 8.33 ms | 16.67 ms |

**Not verified on the host:** this only read `lsappinfo`, and didn't look at the Dock, Cmd-Tab or Mission Control. Stage Manager
is off on this Mac. A `Foreground` app with normal windows should take part in all of them [inferred], but someone needs to
look. Whether AppKit's shadow follows a hosted layer's alpha is also untested.

## Architecture

```
 Guest                                                       Host
 ┌─────────────────────────────────────┐                     ┌─────────────────────────────────────┐
 │ Apps ─► WindowServer                │                     │ Session process (no window)         │
 │          │ window tree, surfaces    │  surfaces, order,   │  owns QEMU                          │
 │          ▼                          ├────────────────────►│  a CAContext + layer per surface    │
 │ seamless agent                      │  metadata           │  maps host points to guest points   │
 │  source: client API, or hook inside │◄────────────────────┤  input to QMP or agent              │
 │  WindowServer                       │  focus, input       └───────┬─────────────────────────────┘
 │                                     │                  contextId, │ events, on a private socket
 │  AX menus, launch, activation       │                             ▼
 └─────────────────────────────────────┘                     ┌─────────────────────────────────────┐
                                                             │ TextEdit (Mavericks).app            │
                                                             │  generated, ad-hoc signed           │
                                                             │  Dock tile, NSMenu, document types  │
                                                             │  NSWindow + CALayerHost per window  │
                                                             └─────────────────────────────────────┘
```

**Geometry.** One offset per VM maps guest screen to host screen, so everything lands where the guest would put it, and popovers and menus
need no special handling: this is what `--tree` does. Pointer coordinates are guest screen points, and there's no feedback loop in guest
title-bar drags, unlike window-relative coordinates [measured in the design of the viewer; not run on a guest]. Host-native drag comes
later: moving a group changes only that group's offset, which needs the guest to know, or windows are moved in the guest to match. Which of
those is open.

**Occlusion** no longer matters: capture and the hook read a window whether or not it's covered.

**The desktop.** Exclude it, don't kill it: Dock also owns Mission Control and Spaces [memory]. Only the tree is shown, so wallpaper and
menu bar are never seen. Headless means not paying to composite them; see below.

## WindowServer, per generation

### Mavericks (13F34): `CoreGraphics`, GL compositor

WindowServer is a 2-symbol executable calling `CGXServer` in `CoreGraphics` [read]. `CoreGraphics` keeps its local symbols: 16,242 in `nm`.
No library validation, no `__RESTRICT`, no sandbox noticed, so `DYLD_INSERT_LIBRARIES` from the launchd plist should load [read, not run].

- **Main loop:** `CGXServer` → `CGXRunOneServicesPass` → `mach_msg`. No run loop, so a timer can't reach its thread. `WSRunMainThreadTimerPass`
  runs from the pass, and `CGXUpdateDisplay` is called from it.
- **A window's backing:** `CGXWindow+0x108` is the backing store [read: `__CGXAccessWindowBackingStore`, `CGXWindowBackingGet`]. Backing `+0x74` is row
  bytes, `+0x88` is non-null if accelerated. `CGXBackingStoreDataAccess`, `CGXBackingStoreDataCopy`, `CGXBackingStoreShmemID`, `CGXGetShmemSize`,
  `CGSBackingROStateGetSynchronizeSeedPtr` read it. Software backing is shared memory with the app.
- **Shadow:** `CGXWindow+0x9d` non-zero means no shadow; `+0x134`, `+0x13c` feed the margin. `CGXWindowShadowGet` returns a cached object,
  `CGXGetShadowMarginForWindow` its margin, `insertWindowShadowLayers` adds it as a layer. `CGXGLCreateShadowTexture` uploads it.
- **Composite:** `CGXUpdateDisplay` → `get_update_display_region`, `WSGetVisibleWindowArray`, `CGXWindowArraySubArray`, then per window
  `redraw_window` (shape, motion, tracking) and `redraw_window_surfaces`/`CGXNextSurface` for GL and CA surfaces, building layers, then
  `CGLayerComposite` → `CGXGLAccelComposite` → `gl_prepare_layers`, `gl_composite_layers`. `CGXGLAccelComposite` has no direct callers: it's reached
  through a table (`CGLayerKitGetVTable`).
- **One window to one destination, already there:** `CGXRedrawWindowToLayer(...)` → `redraw_window` + `CGLayerComposite`, called by `windowPluginRender`,
  which backs a CA plug-in layer of type `com.apple.WindowServer.CGSWindow`. That's how a live window appears inside another layer tree [read]. Many
  windows to one destination: `WSRedrawSpecifiedWindowsToDisplayAndRegion`, used by capture passes and Magic Zoom, adding shadows.
- **Capture inside the server:** `CGXHWCaptureWindowList` → `CGXConstructVirtualFramebufferFromDevice`, `WSRedrawCapturedWindows`, `mach_vm_remap` to the client.
- **To an IOSurface:** `CGXGLCaptureDeviceToIOSurface`, `CGXGLAccelCaptureIOSurface`, `cglsTexImageIOSurface2D` exist.
- **Headless:** `WSCurrentSessionDrawsToFramebuffer`, `WSDisplayUpdatesAreDisabled` are checked by `CGXUpdateDisplay`.

**Client interface already gives more than the public API**, with no injection [read: `T` in `nm`]: `CGSWindowDirtyRegionSeed`, `CGSCopyWindowAlphaShape`, `CGSCopyAssociatedWindows`,
`CGSGetParentWindowList`, `CGSCopyWindowGroup`, `CGSGetWindowTransform`, `CGSGetCatenatedWindowTransform`, `CGSGetWindowShadowAndRimParameters`,
`CGSCopyWindowColorSpace`, `CGSGetWindowSharingState`. `CGSGetWindowFlushSeed` is exported too, but reads a client-side window table, so it answers for this process's own windows only [read; measured on macOS 27]: damage for other apps needs the hook. Also `__CGXCopyWindowBackingStore` looks up any window by ID with no owner check in the part read,
returning its backing as out-of-line VM; its client stub is a local symbol. Copy-on-write per-window pixels with no compositor, for windows without
surfaces [read, not run].

### Mojave (18G103): `SkyLight`, Metal compositor

`SkyLight` has 5,514 local text symbols and 1,395 exports, `CoreGraphics` re-exports CGS names to it [read]. WindowServer has `library-validation` and a boot
sandbox denying `/tmp` [read], and the guest boots with `amfi_get_out_of_my_way=1`, csr 0x67 [read]. `tools/guest-mojave-sky.h` already patches `SkyLight` with
symbol and branch validation, and `PVGMetalCompat` runs inside WindowServer [read].

- **Update:** `update_display_callback` → `CGXUpdateDisplay` → `generate_layers_for_window(CGXRedrawState*, CGXWindow*)`, composited through `Compositor`.
- **One window to one destination:** `WSCompositeWindowToDestination`, called by `CaptureSurfaceMetal::Populate(CGXWindow*, region)`, `CaptureSurfaceGL::Populate`, and
  `windowPluginRenderMetal`, using `generate_layers_for_window`. This is the hook's target: it takes one window and a destination.
- **Destinations:** `WSCompositeDestinationCreateWithMetalTexture`, `WSCompositeDestinationCreateWithIOSurface`.
- **Shadow:** `insertWindowShadowLayers`, `WSShadowGetCache`, `WSWindowShadowRadius`, `WSWindowShadowWantsRenderAbove`.
- **Backing:** `MetalBacking` C++ class; `WSCALayerBacking*`; `metal_core_animation_detach_layer` for direct layers.
- **Backdrops:** `WSBackdrop*`, `process_layer_backdrops`, `MetalCompositeBackdrops`: vibrancy is separable here.
- Same client exports under `SLS*`, including `SLSGetWindowFlushSeed`, `SLSCopyWindowAlphaShape`, `SLSHWCaptureWindowListInRect`, `SLSAccessWindowBackingStore`.

`SLSGetWindowFlushSeed` reads `+0xcc` of a structure on Mojave, where Mavericks goes through `+0x40` and an accessor: layouts move, so offsets must not be hard-coded.

### The hook, in order

1. **Done on Mavericks: injection and backing stores** (`probes/seamless-ws-hook.c`, `seamless-ws-table.h`). Loads by `DYLD_INSERT_LIBRARIES`, interposes `mach_msg` to run between requests
   on the main thread, resolves local symbols from the on-disk `CoreGraphics`, comparing each function's bytes with memory since the file's `LC_UUID` needn't match the shared cache,
   and publishes wanted windows' changed rows through a shared file. It changes nothing WindowServer does.
2. **Next: damage.** Replace the row compare with the seeds the server already keeps. A window's state is reached through the shared-memory references at `+0xd8` to `+0xf8`, and the client bumps a flush
   seed in it (`CGSWindowRWStateIncrementFlushSeed`); which field is which still needs working out.
3. **Next: the window tree and shadow from inside**, with `WSGetVisibleWindowArray` and `CGXWindowShadowGet`, which removes the remaining captures. Then per-window composite in the server for accelerated
   windows, Mojave `WSCompositeWindowToDestination`, Mavericks `CGXRedrawWindowToLayer`, into an IOSurface per window, on the GPU.
4. **Hand that surface to the host** without a CPU copy (below).
5. **Headless:** skip the framebuffer composite with `WSDisplayUpdatesAreDisabled` or by returning early once all windows are delivered.

### A CA plug-in layer may need no hook

`com.apple.WindowServer.CGSWindow` is a CA plug-in type [read]. A client layer of that type shows a live window, wherever it's placed, whether covered or not; WindowServer composites it
with its own surfaces. An agent with one top-level window could lay out plug-in layers for every guest window and let the existing framebuffer carry them, and the host crops. Opaque framebuffer
loses alpha, so it'd need a second pass on another background to recover it. Untried; it's the cheapest way to fix capture cost if capture turns out slow, and needs no per-build
offsets. Whether a normal client may make that layer is unknown.

### Surviving several builds

- **Names, not addresses:** local symbols exist on both generations inspected. Offsets are per-build, so derive them from accessor code at load (`movq 0x108(%rax), %rdi` in
  `__CGXAccessWindowBackingStore`) and refuse if the pattern is missing. `tools/guest-mojave-core.h` has that matching.
- **A manifest per `LC_UUID`** generated by a tool from a disk image, as `guest-mojave-sky.h` does. The set of guest builds is finite: what the installers ship.
- **Three layers at runtime:** hook; else client interface; else a plain windowed VM. An unknown build loses speed, not function.
- **Worst case:** Big Sur moves system libraries into the shared cache and strips locals [memory]. Client interface only, unless someone extracts them.
- **Effort:** the tree source and host don't change per build. Only the hook does, and probably one family per compositor generation: GL (up to about 10.13), Metal (10.14 up). Not
  verified for any version between.

## Transport

| Stage | Path | Copies | Status |
| --- | --- | --- | --- |
| Now | TCP over slirp to host loopback (`10.0.2.2`) | Capture or hook, kernel, slirp, viewer | Works from Mavericks [measured]: 4.8 MB/s used, limit unknown |
| Next | `guestfwd` into a private Unix socket | Same | Off any host port; needs a launch-plan change; requires shared networking |
| vmware-svga | Hook composites through PassthroughOpenGL, so the texture is **already on the host GPU**. Host exports an IOSurface per window to the app through the existing `VIMSurfaceFrameMessage` capability transport and `presentSurface:` | None | [inferred]; `display-surface-message.h`, `passthrough-opengl-surfaces-host.c` exist. Needs a window identity marked in the GL stream or the guest IOSurface name |
| PVG | Hook composites to a Metal texture in the guest; host sees it inside `apple-gfx` only as commands | Unknown | **Open.** Options: guest-RAM-backed shared buffer that the helper's gather (`gpu-performance-notes.md`) imports without copy; or a blit to a shared buffer, per window, in a region the helper maps. Needs a real read of `apple-gfx-helper.m` |
| Fallback | Shared guest memory: wired pages with a physical list through the driver, host reads them | One | [inferred]; `gather` proves the host half for PVG |

## Rejected, now

| Alternative | Why not |
| --- | --- |
| Framebuffer crop into slots as the end state | No real alpha or shadow, needs huge guest displays and windows held apart. Kept only as a quick path; `seamless-try display` still measures its limit |
| One transparent full-screen host window | SPICE tried, and its maintainer called the design the obstacle [source]. No per-window Mission Control or Dock |
| QuartzCore or AppKit shim in apps | Misses Carbon and GL, and is per-app. Hook is one place |
| A separate headless login session | One console session draws at a time [inferred] |
| One process with many Dock tiles, `LSUIElement`, bundle-less proxies | No API for the first, no tile for the second; the third works [measured] but has no Dock persistence or document handling |
| Host SIP off, Dock injection | Unneeded and unshippable |

## Interfaces for the parallel work

Stable now: `probes/seamless-wire.h`. Numbers 32-47 are reserved for input, 48-63 for integration; add a case in `swm_parse` and a test in `seamless-wire-test.c`.

- **Input** adds host-to-guest messages (gesture, pressure, scroll). Addressing: guest screen points times 16 with `window = 0`, as `SWMPointer`. Guest side lands in `drain_input` in `seamless-guest.c`; host side
  in `GuestView` in `seamless-viewer.m`, which sees every `NSEvent` for a window, so gesture and pressure handlers go beside `sendKind:`.
- **Integration** gets from `SWM_WINDOW`: `window`, `pid`, `owner`, `title`, `layer`, `order`, `group`. Each app is identified by `pid` and `owner` until a proxy exists. Proxy-to-session control isn't defined; I'll define
  it when proxies arrive, and until then a message from the host to the guest for "open this file in this app" belongs in 48-63.
- **Both:** the design has one session process and one proxy per app. `GuestView` is the stand-in for a proxy's window.

## Plan

1. Done: capture measured, injection and offsets proven, backing stores delivered on Mavericks. See [above](#measured-on-a-mavericks-clone).
2. Next: **hook damage, window tree and shadow** on Mavericks, removing polling and capture.
3. **Accelerated windows:** per-window composite for them, and a Safari or GL app in the demo.
4. **Zero-copy for vmware-svga**, through PassthroughOpenGL.
5. **Proxies:** `CALayerHost`, generated bundles, session process, invisible VM.
6. **Mojave hook**, and the PVG transport.
7. **Real integration and input** from the parallel work; snapshot and resume; multiple VMs; AX bridge; then the versions between, one at a time.

## Running with nobody at the guest

`scripts/seamless-try` boots a throwaway clone through `scripts/guest-bench`, staging tools over the guest agent, which re-enter the console session as `probes/gpu-bench.m` does. Results print and go to `Build/seamless/`. From `Source/`:

    M="$HOME/Library/Application Support/Virtual Intel Mac/Machines/Mavericks.vintelmac"
    A="$PWD/Build/Products/Current/Light Click.app"

    scripts/seamless-try hook "$A" "$M"       # The demo, by capture and then through the hook. Reboots the clone.
    scripts/seamless-try tree "$A" "$M"       # The demo by capture only.
    scripts/seamless-try stream "$A" "$M"     # One TextEdit window, with a test click and key.
    scripts/seamless-try display <app> "$M"   # Largest guest display. Needs an app built from this branch.

**`tree`:** the guest prints each window as it appears, `capture_mean`, `capture_rate`, `capture_share`, `captures_skipped_by_seed` and `seed_answers`. Host windows appear live, and the viewer saves each to
`Build/seamless/seamless-tree-window-<id>.png` with its alpha statistics, and every 3 s a composed view of them all in `seamless-tree-screen-<n>.png`. Look for: the document window's shadow, the popover's arrow past its edge at 3 s, the panel and translucent square at 6 s, the menu at 9 s, the sheet at 13 s.

**`display`** walks up to 8192x8192: the host offers a size, the guest selects it, moves TextEdit to the far corner by Accessibility, and the host saves its frame. `seamless-guest place` is slot placement (`probes/seamless-slots.h`).

**Unverified:** `display` hasn't run on a guest, and `place` assumes root in the session needs no Accessibility grant [memory].

## Trying phase 1 by hand

What's there:

- `probes/seamless-wire.h`: the format, used by both sides.
- `probes/seamless-wire-test.c`: round trips, every truncation, lying lengths, and 2 million fuzz rounds under ASan and UBSan.
- `probes/seamless-guest.c`: `list`, `stream`. Public CoreGraphics only.
- `probes/seamless-viewer.m`: one borderless `NSWindow` per guest window, with shadow; sends pointer and keys back.
- `scripts/test-seamless-probes`: the wire test, then the whole loop on this host (below).
- `scripts/build-seamless-probes`, and `probes/seamless-host-capabilities.m` for the tables above.

Proven without a guest [measured]:

- The whole loop: the x86_64 guest tool under Rosetta streams a test pattern over TCP to a real window. A synthetic click and then
  a key go back and return as different pixels, read from the screen through ScreenCaptureKit. 96 frames at 26.8 fps. That proves
  the wire, the viewer and the event path, not `CGEventPost`.
- Real `CGWindowListCreateImage` capture under Rosetta, of a real 200x120 window, is delivered at Retina size (400x240). A mean of
  31 ms there says nothing about Mavericks.
- The guest binary loads as a 10.9 binary as far as can be checked statically: `LC_VERSION_MIN_MACOSX` 10.9, no chained fixups, all
  four libraries exist in the 13F34 image, and all 79 imports resolve there, apart from `__darwin_check_fd_set_overflow`, which is
  weak and checked at runtime by the SDK's `FD_SET`.

Not proven: that it runs on Mavericks at all, capture speed there, `CGEventPost` reaching a guest app, or `10.0.2.2` reaching host
loopback under this QEMU, which is standard slirp behavior [memory] with no `restrict` set in `VIMLaunchPlan.swift` [read].

Steps, from `Source/` on this branch, with a built app:

    # 1. Self-check. Shows a test window for a few seconds.
    scripts/test-seamless-probes

    # 2. Build, and start the host side. Leave it running.
    scripts/build-seamless-probes "$PWD/Build/seamless"
    Build/seamless/seamless-viewer

    # 3. In another terminal, serve the guest tool to the guest, on loopback only.
    python3 -m http.server 7655 --bind 127.0.0.1 --directory Build/seamless

    # 4. In a third, boot a clone. Never the real library.
    scripts/boot-clone "$PWD/Build/Products/Current/Light Click.app" \
        "$HOME/Library/Application Support/Virtual Intel Mac/Machines/Mavericks.vintelmac"

Then, in the guest window titled "Clone of Mavericks", open TextEdit and Terminal, and in Terminal:

    curl -o /tmp/seamless-guest http://10.0.2.2:7655/seamless-guest
    chmod +x /tmp/seamless-guest
    /tmp/seamless-guest list
    /tmp/seamless-guest stream --app TextEdit

A host window should appear with TextEdit in it. Click in the document and type. Drag it by its title bar: it moves on the host only.
Click the traffic lights. Guest stderr prints capture time every 5 s; **please send me that line**, as it's the number the
"capture is too slow to be the main path" claim rests on.

If it goes wrong:

- **`Can't connect`:** `10.0.2.2` isn't reaching loopback. Use the clone's SSH port instead, which is 2222 on this machine: from the
  host `ssh -p 2222 -R 7654:127.0.0.1:7654 <guest user>@127.0.0.1`, then stream with `--host 127.0.0.1`.
- **Window appears but clicks do nothing:** `CGEventPost` may be refused for a normal user. Rerun with `sudo`. If still nothing, enable
  assistive access in System Preferences > Security & Privacy for Terminal.
- **`No window list`:** it isn't running in the Aqua session. Use Terminal in the guest, not ssh.
- **Another VM is running:** `boot-clone` refuses. Set `BOOT_CLONE_ALLOW_RUNNING=1` only if forwarded ports won't clash.

Stop with Ctrl-C in each terminal, kill the PIDs `boot-clone` printed, and delete `Build/clone`.

Known limits of the demo: one window per run. Clicks land at that window's guest position after activating its app, so if the app has
another window covering it, the covering window gets the click. No scrolling. No menu bar: use the guest's. Any local
process can connect to the viewer's port while it runs. Dirty detection is by whole rows.

## Prior art

No public project was found showing macOS guest windows natively on a macOS host. Parallels says Coherence is
[Windows-only](https://docs.parallels.com/landing/pdfm-ug/parallels-desktop-for-mac-26-users-guide/use-windows-on-your-mac/setting-how-windows-works-with-macos/merging-windows-and-macos),
and I found no stated technical reason. This may be new, and some of its risks may be ones nobody has hit yet.

- **VMware Unity:** [`unityCommon.h`](https://github.com/vmware/open-vm-tools/blob/e08b5f4c0dc2dc83ce662c827fad16253b8e9fd8/open-vm-tools/lib/include/unityCommon.h):
  RPC metadata, VNC rectangles, PNG snapshots. Dropped from open-vm-tools on a [cost-benefit call](https://github.com/vmware/open-vm-tools/commit/8fd3fde9d38f4be48957cdde9d7b9f0a2e9aeed9),
  and from [Fusion 13.6](https://techdocs.broadcom.com/us/en/vmware-cis/desktop-hypervisors/fusion-pro/13-0/release-notes/vmware-fusion-136-release-notes.html) with no reason given.
- **Parallels:** patents [US7788593](https://patents.google.com/patent/US7788593) and [US9317195](https://patents.google.com/patent/US9317195): masked desktop, stub apps, Dock icons, file types.
- **RDP RemoteApp:** [MS-RDPERP](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdperp/485e6f6d-2401-4a9c-9330-46454f0c5aba) is the best public specification of this problem, and worth copying for its [window order](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdperp/2d36758d-3fb5-4823-8c4b-9b81a9c8ff3e) fields. FreeRDP's [`xf_window.c`](https://github.com/FreeRDP/FreeRDP/blob/master/client/X11/xf_window.c) documents the flash of the hidden desktop from the shared-image path.
- **WinApps:** [`setup.sh`](https://github.com/winapps-org/winapps/blob/main/setup.sh): per-app launcher, FreeRDP `/app`.
- **SPICE:** a [2017 series](https://lists.freedesktop.org/archives/spice-devel/2017-August/039252.html) and [2021 thread](https://lists.freedesktop.org/archives/spice-devel/2021-January/052123.html); I found no evidence it merged.
- **Apple:** Virtualization's [GUI Linux sample](https://sosumi.ai/documentation/virtualization/running-gui-linux-in-a-virtual-machine-on-a-mac) shows the guest in one window, and [Containerization](https://github.com/apple/containerization) mentions no GUI. No per-window path found, which is absence rather than a stated limit.
- **Private API users:** [Chromium's `remote_layer_api.h`](https://chromium.googlesource.com/chromium/src/+/main/ui/base/cocoa/remote_layer_api.h) for `CALayerHost`; [AltTab](https://github.com/lwouis/alt-tab-macos/blob/master/src/events/WindowCaptureEventsSpecs.md) and [WebKit](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/PAL/pal/spi/cg/CoreGraphicsSPI.h) for `CGSHWCaptureWindowList`; [libuv](https://github.com/libuv/libuv/blob/v1.x/src/unix/darwin-proctitle.c) for `_LSSetApplicationInformationItem`.
- **Light Touch:** nothing for windows on a host display. `CanvasCapture.swift` has the own-process ScreenCaptureKit approach used in these probes.

Several forum and old-doc items came from search excerpts rather than full pages, and closed VMware and Parallels binaries weren't examined.
