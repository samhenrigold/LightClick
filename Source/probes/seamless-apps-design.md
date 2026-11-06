# Seamless guest apps

Goal: a guest app appears on the host as a normal app, with its own Dock icon, Cmd-Tab entry and one `NSWindow` per guest
window, like Parallels Coherence.

**Nothing here has run on a guest.** No VM was booted. Host claims come from probes on macOS 27.2 (M4 Max, ProMotion,
SIP on). Guest claims come from reading stock Mavericks (13F34) and Mojave (18G103) binaries, read-only. No other OS version
was inspected.

Labels: **[measured]** by a probe here. **[read]** seen in code or a binary. **[source]** public documentation or code,
linked. **[inferred]** reasoned, untested. **[memory]** recalled and not checked here; verify before relying on it.

## Answer

It looks feasible on every generation, and **SIP doesn't block anything the recommended design needs**. SIP stops you
changing other apps' windows, so the design only changes its own. The real risks are in the guest: whether a very large
guest display works, and whether windows can be kept from overlapping there. Phase 2 tests both, and either could force a
compositor hook on some versions.

The recommended design has three parts:

1. **Pixels:** crop each window out of the guest framebuffer that already reaches the host, with no new capture path.
2. **Occlusion:** a guest agent keeps windows apart on an oversized guest display, so a crop is never covered.
3. **Identity:** a generated, ad-hoc-signed `.app` per guest app owns the Dock tile and the `NSWindow`s, and shows layers
   rendered by the VM's process through `CALayerHost`.

Per-window capture in the guest, which is what phase 1 demonstrates, stays as the fallback for windows that can't be placed
that way, and as the source of alpha masks. A WindowServer hook is held in reserve.

| Generation | Display path | Feasible? | What's specific to it |
| --- | --- | --- | --- |
| Tiger (10.4) | vmware-svga | Probably, with less | `CGWindowList` arrived in 10.5 [memory], so listing needs private API or AX. No Retina. Not inspected |
| Leopard to Mountain Lion | vmware-svga, PassthroughOpenGL | Likely | Public window list. No Spaces trouble before Lion's full-screen Spaces [memory]. Not inspected |
| Mavericks to High Sierra | vmware-svga, PassthroughOpenGL | Likely; Mavericks is the demo target | GL compositor with local symbols [read]. SIP is off in the guest where it exists [read] |
| Mojave | PVG | Likely | SIP and AMFI off in guest [read]. Synthetic events need a TCC grant [memory], which the design avoids by using the existing tablet path |
| Catalina, Big Sur | PVG | Likely, least certain | Window titles need Screen Recording from 10.15 [memory]; a root agent can grant it in TCC.db with SIP off [inferred]. Big Sur's sealed volume and shared cache make binary patching harder, so the hook fallback costs more. Not inspected |

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

**Not verified on the host:** I only read `lsappinfo`, and didn't look at the Dock, Cmd-Tab or Mission Control. Stage Manager
is off on this Mac. A `Foreground` app with normal windows should take part in all of them [inferred], but someone needs to
look. Whether AppKit's shadow follows a hosted layer's alpha is also untested.

## Architecture

```
 Guest                                          Host
 ┌────────────────────────────┐   framebuffer   ┌───────────────────────────────┐
 │ Apps ─► WindowServer       ├────────────────►│ Light Click session process   │
 │ (oversized display;        │  (existing path)│  one shared frame             │
 │  windows never overlap)    │                 │  per-window layers, cropped   │
 │                            │   metadata      │  CAContext per window         │
 │ seamless agent             ├────────────────►│                               │
 │  window list, AX, placement│◄────────────────┤  QMP tablet + keyboard        │
 │  menus, launch             │   commands      └───────┬───────────────────────┘
 └────────────────────────────┘                  contextId, events (private socket)
                                                 ┌──────┴───────────────────────┐
                                                 │ TextEdit (Mavericks).app     │
                                                 │  generated, ad-hoc signed    │
                                                 │  Dock tile, NSMenu           │
                                                 │  NSWindow + CALayerHost each │
                                                 └──────────────────────────────┘
```

### Pixels: crop the existing frame

The guest already composites and sends a whole frame: `VIMDisplayConnection` into `VIMMetalView` through a shared buffer
(`installFrameDescriptor:`, 8192x8192x4) or an IOSurface (`presentSurface:`) [read]. Both generations end up there, so a
single host path covers vmware-svga and PVG. Per window, the host either blits a rect into that window's `CAMetalLayer`, or
sets `contentsRect` on a layer over the shared surface, which the probe proved works across processes.

What this gets: no capture cost under TCG, no WindowServer changes, GPU-accelerated guest content (GL, Metal, video) included
automatically, and the same presentation path the rest of the app already measures. It's also the established approach:
VMware Unity sends window metadata over RPC and converts updates to VNC rectangles, with PNG window contents only for
snapshots [source: `unityCommon.h`, linked below, the crop itself inferred], and Parallels' patents describe masking the guest
desktop out of its buffer [source; they don't prove what ships].

### Occlusion: never let guest windows overlap

Cropping's flaw is that a window covered in the guest has no pixels. Syncing z-order, which Unity appears to do, only helps the
front window: two host windows side by side can't both be right if they overlap in the guest.

Instead, the agent gives the guest a display far larger than the host's, and places each new window in its own slot with AX
(`kAXPositionAttribute`), with gaps wider than a shadow. Host position then has nothing to do with guest position:

- **Host drags don't touch the guest.** The title-bar drag runs in the host's window manager, as RDP's
  [local move-resize](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdperp/348a2e91-3ea5-415d-ad67-348d96c3f1bd)
  does [source]. That also gives native tiling and Mission Control behavior. The demo does this already.
- **Input maps trivially:** host point minus window origin, plus slot origin, normalized to the existing tablet's 0-32767
  (`VIMMetalView mouseMoved:`). At 8192 pixels, that's about 0.25 pixel of resolution.
- **Menus, sheets and tooltips** are guest windows too. The agent reports each one, and the host shows it as a child window at
  the same offset from its parent. A menu that would run off the slot stays inside the guest's large display.
- **The guest's Dock, menu bar and wallpaper are never cropped**, so there's no need to kill them. Keep slots away from screen
  edges so nothing triggers auto-hide or hot corners. This also avoids disturbing the session: killing Dock also removes
  Spaces and Mission Control, which live there [memory].

Alpha: crops include whatever is behind a window's rounded corners. Take a one-shot `CGWindowListCreateImage` per window on
each resize and use its alpha as a host mask layer, keeping all capture cost out of the frame path. `CGSCopyWindowShape` is
the cheaper first try: exported on Mavericks, and on Mojave through SkyLight [read].

Shadow: the host draws it, from `hasShadow`. Guest shadows are inside the slot gap and never cropped. The guest's
`kCGSDisableShadowTagBit` exists on both versions [read] but isn't needed.

### Identity: a generated bundle per guest app

Each guest app gets a real `.app` in the library folder, generated from the guest bundle's `Info.plist` and icon, with a stable
bundle ID derived from the machine and the guest bundle ID. Its executable is one small shared host binary, ad-hoc signed
locally. This matches what is publicly visible of Parallels: `~/Applications (Parallels)/…app/Contents/MacOS/WinAppHelper`
[source: a forum crash report; lower confidence] and its patent's "stubs" [source]. WinApps' `.desktop` file per app is the same
idea on Linux [source].

The proxy holds the `NSWindow`s, `NSMenu`, document handling and activation, and forwards everything to the session process
over a private socket. Pixels stay in the session process: the proxy just sets `CALayerHost.contextId`. Key handling is simple
because seamless mode doesn't need the current event tap: Cmd-Tab should go to the host, and a key window gets ordinary keys.

Launching a proxy with no VM running must boot the machine without its window. That's the slowest part of the experience, since
a TCG boot and login isn't quick; phase 4 should look at suspending the VM rather than shutting it down.

### Metadata and control

The agent runs in the Aqua session, reusing the launchd and token pattern of `guest-clipboard`.

| Need | Source | Evidence |
| --- | --- | --- |
| Windows, bounds, layer, owner, title | `CGWindowListCopyWindowInfo` | Works under Rosetta here, and the existing `probes/opengl-window-list.c` uses it on Mavericks [read] |
| Change notifications | `CGSRegisterConnectionNotifyProc`, `CGSRegisterNotifyProc` (`SLS*` on Mojave) | Exported on both [read]; event numbers not determined. Polling at 10 Hz is the fallback |
| Shape | `CGSCopyWindowShape` | Exported on both [read] |
| Spaces | `CGSCopySpacesForWindows`, `SLSCopyManagedDisplaySpaces` | Exported [read] |
| Tags, levels | `CGSGetWindowTags`, `CGSGetWindowLevel` | Both on Mavericks, levels on Mojave; tags not checked there [read] |
| App identity, icon | PID to bundle path to `Info.plist` | Standard |
| Menus | AX `kAXMenuBarAttribute` tree | `probes/ax-menu-response.c` exists [read] |
| Launching and focus | `open`, `SetFrontProcess`, `AXRaise` | Standard; `probes/opengl-window-activate.m` exists [read] |

**Menu bar:** rebuild the app's AX menu tree as an `NSMenu` in the proxy, refreshed in `menuNeedsUpdate:`, with item selection
sent back as `AXPress`. The guest's menu bar is never shown. Injecting `NSMenu` into guest apps isn't needed and wouldn't reach
Carbon apps. AX needs enabling in the guest: `TCC.db` from Mavericks on, and the `.AccessibilityAPIEnabled` file before that
[memory]. The repo doesn't do either today [read]. AX under TCG may be slow, so cache and watch for `AXMenuOpened`-style staleness.

**Transport:** this is low-rate data, so use QEMU slirp's `guestfwd` into a private Unix socket, keeping it off any host TCP port.
It doesn't work when `networkMode` isn't `shared`, since there is no slirp then; pre-Metal guests would then multiplex on the
authenticated clipboard COM port. Metadata and pixels are deliberately not synchronized, which a SPICE reviewer called out as the
source of glitches in its seamless series [source], so tag metadata with a frame sequence, or tolerate one frame of skew.

### Input

The final design uses the existing QMP tablet and USB keyboard, with no `CGEventPost`, so Mojave's event-posting permission never
arises [memory]. Virtual keycodes need no table beyond the existing one.

- **Focus:** when a host window becomes key, the agent raises that guest window and activates its app, and the host waits for
  confirmation before sending keys, or the first keystroke goes astray.
- **Clicks on inactive windows:** `acceptsFirstMouse:` sends them through as a click, which matches guest behavior.
- **Cursor:** already reported by the guest and shown as a native `NSCursor` [read].
- **IME:** phase 1 and 3 send raw keys, so the guest's own IME works and the host's doesn't. Host IME needs
  `NSTextInputClient` on the proxy view, and the agent would post the text with `CGEventKeyboardSetUnicodeString`.
- **Drags:** guest-internal drags between two guest windows need care: during a drag, pointer coordinates are in slot space, so
  crossing into another host window has to map to that window's slot. Doable, as each event is mapped by the window under it.
- **Scroll:** the existing wheel path carries over.

### Other integration

- **Clipboard:** `VIMClipboardBridge` already bridges text. Images and files aren't covered.
- **Opening documents from Finder:** the proxy's `CFBundleDocumentTypes` comes from the guest app's, and `openURLs:` is proven
  above. The file must reach the guest: copy in through the existing staging path, watch it, and copy back on save. SMB in the
  other direction exists only as guest-to-host (`FileSharingPort`) [read]. Write-back races are the hard part.
- **Host-to-guest drag and drop:** copy in and then synthesize a guest drag from the agent. Guest-to-host drag is hard; leave it.
- **Retina:** the guest's 2x mode already exists (`opengl-display-agent.m`), and `contentsScale` handles 1x guests.
- **120 Hz:** the host side is proven above, but the guest's clock is the limit: PVG's mode is a fixed 60 Hz
  (`apple-gfx-helper.m`, per `gpu-performance-notes.md` [read]). Try a mode at the host's rate, as that note already suggests.

## Alternatives rejected

| Alternative | Why not |
| --- | --- |
| Per-window capture as the main path (`CGWindowListCreateImage`, `CGSHWCaptureWindowList`) | Every frame costs emulated CPU plus a guest-to-host copy per window. On PVG, the capture lands in a guest IOSurface that the host can't reach without another copy. Kept as a fallback, and for masks. Its cost needs measuring: phase 1 prints it |
| Sync z-order with crops only | Two visible host windows can't both be correct when they overlap in the guest, and background windows go stale |
| One transparent full-screen host window | SPICE's series did this and the maintainer called the design the obstacle [source]. No per-window Mission Control or Dock |
| WindowServer plug-in | No plug-in interface found: a string search of `CoreGraphics` and `SkyLight` turned up only `WSTouchBarEventPlugin` and CA plugin-layer names, nothing that loads third-party code [read; not exhaustive] |
| QuartzCore or AppKit shim in apps | Doesn't see Carbon or GL-only windows, and needs injection into every app. On Mojave, it also needs library validation handled in each one |
| Reading window backing stores from guest RAM | Fragmented guest pages need a kext for addresses, and it misses GPU-backed windows. Mavericks' `WSWindowGetBackingInfo` and Mojave's `SLSAccessWindowBackingStore` exist [read] |
| A separate headless login session | WindowServer has one console session drawing at a time, and it doesn't address occlusion [inferred] |
| One process with many Dock tiles | No API found. A tile follows a registered process. `_RegisterApplication` exists [measured], but nothing suggests one process can hold two registrations; not tried |
| Renaming one process, bundle-less proxies | Works [measured], but no persistence in the Dock and no document handling, and the Dock tooltip reportedly comes from the bundle's name [source: vphone-cli]. Fine for a demo |
| `LSUIElement` | No Dock tile and no Cmd-Tab, which is the point of the feature |
| IOSurface over Mach ports to proxies | Sound, and Chromium's fallback [source]. `CALayerHost` is less code and carries live `CAMetalLayer`s; keep as the fallback if Apple breaks hosting |
| Host SIP off, or Dock injection | Unneeded, and unshippable |

## In reserve: a compositor hook

If slots fail, WindowServer can render windows separately. This would give true per-window surfaces, which RDP's
[enhanced RemoteApp](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpegfx/e34e1d5e-5682-4ff0-af3f-f4baf697d198)
shows is the eventual clean design [source].

- **Guest permission is available.** Boot policy sets `csr-active-config` 0x67 and `amfi_get_out_of_my_way=0x1`
  (`scripts/qemu-opencore.py`, `scripts/build-opengl-firmware.py`), and `tools/guest-mojave-sky.h` already patches SkyLight with
  symbol and branch validation [read].
- **Mojave:** local symbols include `WSCompositeWindowToDestination`, `WSCompositeDestinationCreateWithIOSurface` and
  `WSRedrawWindowsToDestinationAndRegion`, and strings name `WSCompositorCreateCaptureSurface` and
  `metal_core_animation_detach_layer` [read].
  WindowServer has `library-validation` and a boot sandbox [read]. `PVGMetalCompat` shows compat code already runs in it [read].
- **Mavericks:** `CGXGLAccelComposite`, `CGXGLCreateBackingTexture`, `WSGetVisibleWindowArray`, `CGXRedrawWindowToLayer`,
  `captureWindowList`, all inside `CoreGraphics` with local symbols; `WindowServer` has no library validation flag [read]. No
  function named like `WSCompositeWindowToDestination` exists, so it's a different hook on each generation, and likely on each
  version in between.
- **Mavericks-specific idea:** WindowServer's GL goes to the host through PassthroughOpenGL (`cgs-drawable.c`) [read], so window
  textures may already be in host GL. Marking composite calls in the guest and redirecting those draws host-side could give
  zero-copy per-window surfaces. Untested and invasive.

Cost is high: per-build symbols across a dozen OS versions. Only do it for versions where slots fail.

## Risks

**Could make the recommended design impossible on a version**

| Risk | Versions | Test |
| --- | --- | --- |
| WindowServer or the driver won't take a large mode, or composites badly | All; vmware-svga VRAM and PVG mode limits are unknown | Phase 2's first step. Fallback is overlap-tolerant capture |
| Large frame costs too much: PVG copies the whole frame per update [read] | Mojave up | Measure at 2x the host's size. Rate implies about 1 ms per 100 MB [from measured GPU memcpy rates; inferred], but hops and memory matter more |
| Apps fight AX moves, or refuse them (Carbon, full-screen games, Java) | All; varies by app | Those windows use capture, or full-display mode |
| Full-screen Spaces take a window out of the slot layout | Lion up | Intercept, or disable in the agent. Unknown cost |
| Windows from AX and CGWindowList can't be matched | All | `_AXUIElementGetWindow` [memory]; check it exists per version |
| No window list on Tiger | Tiger | Not inspected. Could fall back to a full-display window there |

**Could break it later on the host:** `CALayerHost`/`CAContext` are private, though Chromium depends on them [source]; IOSurface
hosting is the fallback. Ad-hoc proxies depend on Gatekeeper leaving locally created, unquarantined bundles alone. macOS 28 and
Rosetta's removal are deferred.

**Quality risks that don't stop it**

- Behind-window blur shows the guest's backdrop, not the host's (Mojave up, Yosemite up in theory) [inferred].
- Guest-side animations run at guest speed; minimize and sheet effects would look old, by design.
- Guest apps' assumptions about one small screen: restored window positions, and "center on screen" go to the wrong place. The
  agent re-places new windows regardless.
- Host focus and guest focus can disagree during TCG stalls; dropped first keystrokes are the visible symptom.
- TCG speed: the app itself is still emulated. Seamless windows make slowness look like a slow native app, not a slow VM. This
  may be the biggest perception risk, and it isn't fixable here. See `gpu-performance-notes.md`.

## Plan

**Phase 1 (built): one guest window as its own host window, with clicks.** Uses capture for now, since this needs no app or guest
image change and answers: what does per-window capture cost under TCG, and do the input semantics work? See below.

**Phase 2: crop instead of capture.** In the app, behind a flag.

1. Try a guest display at 2x the host size, on Mavericks and Mojave. If it fails, stop and rethink: this decides the design.
2. Agent places one window in a slot. Host shows it as a `contentsRect` crop in its own `NSWindow`, in-process.
3. Tablet coordinates mapped per window. Mask from one-shot capture.
4. Measure latency against the full-window path using the existing `VIM_DISPLAY_TIMING`.

**Phase 3: real windows.** All of an app's windows, child windows for menus and sheets, resize, close, title, focus handshake,
host drag. AX menu mirror.

**Phase 4: real apps.** Generated proxies with `CALayerHost`. Launching from the Dock boots the machine without a window. Icons,
Cmd-Tab, Mission Control and Stage Manager checked by eye. Document types with copy-in and write-back.

**Phase 5: the rest of the generations and the long tail.** Tiger to Mountain Lion and Catalina to Big Sur, one at a time. Host
IME, file clipboard, drag and drop. Compositor hook only where a version needs it.

## Trying phase 1

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
