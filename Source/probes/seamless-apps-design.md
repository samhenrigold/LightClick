# Seamless guest apps

Goal: a guest app is indistinguishable from a host app. Its own Dock icon and Cmd-Tab entry, one `NSWindow` per guest window with the
real shadow and alpha, popovers past the window's edge, sheets, menus, gestures, force click, drag and drop, and no visible VM. "It has
to be perfect" is the requirement, and it rules out designs that are only nearly right.

**Mavericks clones have now run the window tree, the hook and a whole session from a proxy; nothing else has run on a guest.** Host claims come from probes on macOS
27.2 (M4 Max, ProMotion, SIP on). Other guest claims come from reading stock Mavericks (13F34) and Mojave (18G103) binaries, read-only,
without Hopper (`nm`, `otool`). No other OS version was inspected. All guest numbers are under TCG on this busy Mac.

Labels: **[measured]** by a probe here. **[read]** seen in code or a binary. **[source]** public documentation or code, linked.
**[inferred]** reasoned, untested. **[memory]** recalled, unchecked; verify before relying on it.

## Try it on your Mac

Open any machine, wait for its desktop, then press **Seamless** in its toolbar, or **Actions > Seamless**. The window goes, and each guest app with a window becomes a host app of its own, with a Dock tile and a Cmd-Tab entry, in the same place on the screen, in the same running machine. Nothing's installed and nothing restarts. To come back: **Show in Light Click Window** in any of those apps' own menu or Dock menu, Quit from one's Dock menu, or a click on Light Click's Dock tile. Quitting an app from its menu or with Cmd-Q quits it in the guest; when the last window's gone, the machine's window returns. So does it if a proxy dies, or the guest's side ends, or the machine stops. The window stays until something's there to take its place, and if nothing is, it says so.

`scripts/seamless-desktop-try <app> <machine>` runs that in a clone and says PASS or FAIL for each step, reading windows by ID. Its log is `$TMPDIR/lc-seamless-<first 8 of the Identifier>.log`, with one more per app. It needs the machine's networking on. Windows keep their guest size, so a machine window showing the guest scaled would put them slightly out of place; that hasn't been tried.

### A saved Dock app

A normal build has this now. **Use a clone: making a Dock app changes the machine.** It adds a library to its WindowServer, in `/System/Library/LaunchDaemons/com.apple.WindowServer.plist`. Mavericks is what's been tested in full, at 2x and 1x, and Mojave at 2x with no drag in. Only 10.9 gets the hook. Nothing yet has been seen on a display.

1. Build, from `Source`:

        Engine/build.sh release
        LC_HVDBT_ENGINE=$PWD/Engine VIM_CODESIGN_IDENTITY=<sha1> Build/venv/bin/python3 scripts/build-app --jobs 10 \
            --configuration Release --output "$PWD/Build/Products/try/Light Click.app"

2. Quit any Light Click that's running this machine. Make the clone, with its own identity, so its Dock app is separate:

        cd ~/Library/Application\ Support/Virtual\ Intel\ Mac/Machines
        cp -c -R Mavericks.vintelmac "Mavericks Try.vintelmac"
        plutil -replace Identifier -string $(uuidgen) "Mavericks Try.vintelmac/Machine.plist"

3. Open the app from step 1, then **File > Open Virtual Mac…** and choose `Mavericks Try.vintelmac`. Wait for its desktop.
4. **Actions > Make Dock App…**, choose TextEdit, then **Make App**. Finder shows it in `~/Applications/Light Click`. Drag it to the Dock if you like.
5. Shut the clone down from **Actions > Shut Down** and quit Light Click. A session can't start while another instance has the machine open.
6. Click the Dock app. It bounces while the clone boots, about a minute, with no VM window. Or drop a `.txt` on it.

Look for: the real shadow and the sheet on quitting; whether the machine's window flashes as it starts; Cmd-Tab and Mission Control; the menu bar; pinch and scroll; dragging a file in and out; the sharpness and frame rate of Safari if you make a Dock app for it too. To see 1x, use **View > Retina Resolution > Scaled** in the clone before step 5, and compare. It defaults to 2x. Quitting the app shuts the clone down.

Its log is `$TMPDIR/lc-<first 8 of the Identifier, lowercase>.log`. To remove it, delete the app from `~/Applications/Light Click`, and delete the clone.

## Cropping windowed mode's frames

**The bar is windowed mode, and this matches it.** `scripts/seamless-compare <app> <machine>` runs the same animated page in Safari, engine on, 2x, in clones of one machine, first windowed, then seamless, and fails below 90%. Frames whose pixels differ, per second, where each path's frames reach the app:

| | Windowed | Seamless, cropped |
| --- | --- | --- |
| Mavericks | 59.9 | 60.0 |
| Mojave | 59.9 | 59.8 |

Capture reached 21 and 10 on the same page. WindowServer now composites once, for the display, as in windowed mode. The tool sends only where windows are, with no capture and no pixels over TCP. In the app's process, `SeamlessSession` puts the frame on one layer per guest window with its own `contentsRect`, and each proxy shows its layer through `CALayerHost`. It takes an `IOSurface` where the display path has one, and on the path that hands over shared memory it copies once, into a surface, on the host. One technique on both generations, needing no backing store and no Mojave hook. Capture remains the fallback (`LC_SEAMLESS_CAPTURE`).

What this measures: frames reaching the app, not photons. The same page's frames arrive; whether Core Animation presents every one wasn't counted, and input-to-photon isn't measured. The proxy's window was checked on the real display, with `screencapture -l` on that window only: correctly cropped on both, once a first attempt showed `contentsRect` counts up from the surface's bottom. One Mojave windowed run came in at 24.7, and a rerun at 59.9; the 24.7 isn't explained.

**Which windows crop.** Opaque, ordinary, titled windows no other window covers. They get the host's shadow and a 5-point corner, which is a shortcut: guest corners differ slightly. Everything else keeps a capture with real alpha and shadow: menus, popovers, sheets, panels, translucent windows, covered windows. So a covered window drops to capture speed, and a sheet's parent stays cropped, since the sheet's in the same place in both. The guest's wallpaper is what's behind a window's corners, under the mask.

**Placement in the composite, tried once on Mavericks.** WindowServer's `redraw_window` keeps an offset at state `+0x70`/`+0x74`, a clip region at `+0x18` and a no-shadow flag at `+0x6b`. An inline hook sets those for one window, behind the flag file `/var/tmp/seamless-ws-placement`. It ran without a crash, and TextEdit's window really did land at its offset (in points) in the display's frame, with its guest coordinates untouched. **It isn't usable yet:** the original stays where it was and the placed copy is partial, without its text, because the update's dirty region, which is in on-screen coordinates, limits what's redrawn and flushed. That's what has to change next: dirtying the slot, not the window's place, and clearing the original. No slot layout, no Mojave equivalent, and nothing else about it has been run.

**How much room there is for slots.** `seamless-try display`, 2x-capable modes offered by the host, selected by the guest:

| | Largest selected | Next |
| --- | --- | --- |
| Mavericks, vmware-svga | 2560x1600 | 3840x2160 refused by CoreGraphics, error 1007 |
| Mojave, PVG | 7680x4320 | 8192x5120 fails, exit 134 |

So Mavericks has a single Retina panel's worth of room, 1280x800 points at 2x, which doesn't hold two large windows apart. Whether vmware-svga can go further wasn't looked into. Slots may only be practical on PVG, or need a larger svga mode first. Compositing cost at these sizes wasn't measured. Guests maximize to the display, which is why slots and the display's size are tied to each other; the windows above stay at their guest positions, at one rigid offset from the host's screen.

## Measured on a Mavericks clone

`scripts/seamless-try hook <app> <machine>` boots one clone, loads the hook, and runs the same demo twice in that boot. Each window arrives
as its own host window with per-pixel alpha: the document window with its full shadow, the popover with its arrow past the window's edge, a
child panel, a translucent window, a real menu at its level, and a sheet with its own shadow window. Popover and sheet animations arrive
frame by frame. A click on a real button and a typed key, sent from the host, changed the guest app's title.

| 22 s, 7 windows over the run, a counter changing at 30 Hz, asked for 30 Hz | By capture | Through the hook |
| --- | --- | --- |
| Frames reaching the host | 13.0/s | 25.5/s |
| Calls to WindowServer for pixels | 42.6/s, 15.7 ms mean, 58 ms worst | 1.3/s, for the shadow, 19.2 ms mean |
| Tool's time in those calls | 67% | 3% |
| Tool's time applying hook rows | | 5.6% |
| Time the hook spends in WindowServer | | 0.56 s of 22, 4,532 passes, 5,590 skipped by flush seed |
| Sent | 3.1 MB/s | 5.1 MB/s |

- **The hook reads the right pixels:** 100% of 36,847 opaque pixels sampled from backing stores matched a capture of the same window.
- **Damage is the flush seed:** window `+0xe0` is the shared state `CGSWindowROStateGetFlushSeed` reads at `+0x1c`. A run showed it moving with the pixels and nothing around it moving. Using it cut
  the hook's time from 2.9 s to 0.56 s. A full compare once a second stays, as a guard.
- **Injection works:** `DYLD_INSERT_LIBRARIES` in WindowServer's launchd plist loads the library, and its `mach_msg` interposer runs on the main thread, though the caller is
  in the shared cache. The desktop stayed up.
- **Offsets confirmed:** window `+0x108` is the backing, and `CGXBackingStoreDataIndexed(b, 1, 0)` gives readable BGRA, premultiplied, top row first, in shared memory at `0x1c0000000` up.
  Window `+0x100` holds the scale as a float. Plane 1 of those accessors is empty for an opaque backing, so plane 0 is the one to read, with its alpha byte ignored when `CGXBackingStoreHasAlpha` says so. Of 31
  windows at a login desktop, only one was accelerated: the Dock (2306x86).
- **One-window TextEdit stream, by capture:** 26 ms at 1310x854 pixels, 51 ms at 2560x1410. A click on the zoom button zoomed it and a typed key entered its text, through `CGEventPost` from the console user.

**Since then, on the same clones:**

- **Window tree from the hook.** It walks `WSGetVisibleWindowArray` every 33 ms and publishes ID, connection, level, alpha, bounds and shadow margin, read where WindowServer keeps them (`+0xe0` is the read-only state `CGSWindowROState*` read). Checked against `CGWindowList` once a second:
  0 to 5 of about 370 to 530 samples differed, always while a window was animating. The walk runs front first. `CGWindowList` is still read for titles. Walking before a session exists crashes WindowServer, as the array is then at address `0x20`; it's guarded by `CGXGetCurrentSessionWindowData`.
- **Shadow by event, not timer.** A hash of the shadow parameters at `+0x134` to `+0x148` says when to recapture, such as on losing focus, and `CGXGetShadowMarginForWindow` gives the exact margin. The pixels still come from a capture, since `CGXWindowShadowGet` returns a cached object nothing here reads yet. A window against the display's edge has its shadow cut there, as the capture is clipped by the display.
- **GL.** A GL view shows correctly, by capture, at the same rate as the rest. Its window has a backing as well, which doesn't hold the GL, and `state + 0xb` says so. A window with any surface is captured at 15 Hz. Plain text views count too, because of their overlay scrollers: **TextEdit is captured at 13 a second for this reason, at 43% of the tool's time.** Knowing when a surface flushed would fix that.
- **Safari**, with an animated page: **no backing store at all**, so capture only: 6.6 captures/s at 2884x1734 pixels, 91 ms each, 60% of the tool's time, and 6.9 frames/s reaching the host. This is the main limit now, for any big or animated window. Only a composite in the server fixes it.
- **Scroll, drag, resize**, sent as a host would, in guest screen points: a scroll of 40 events moved a real text view by about 33 lines, through `SWI_RECORD`. A title-bar drag of (180, 120) moved the window by exactly that, and a corner drag of (160, 110) resized it from 420x282 to 580x390, with the host window following each step. These were scripted over the wire, not with a real host pointer.
- **A real proxy app.** `seamless-try proxy`: a generated, ad-hoc signed `TextEdit (Mavericks).app`, launched with `open`, `type="Foreground"` with its own bundle ID, whose windows hold `CALayerHost`s of layers in the session process, with the VM's app hidden and none of its windows on screen. Its input view's events (real `NSEvent`s made in-process, as nothing may touch this Mac's pointer) reached TextEdit: the click activated it, and a typed "b" appeared in the document. TextEdit's whole menu came through Accessibility in 0.5 to 1.4 s, 15 KB, to the proxy's menu bar, and pressing Edit > Select All through the session selected the document, seen in the frames.
- **Accessibility on 10.9:** `AXIsProcessTrusted` asks TCC about the **responsible process**, which from a daemon is the guest agent, `opengl-install-bootstrap`. A grant to the tool itself does nothing; it took a row for the agent's path. A real agent running as a launch agent in the session wouldn't have this problem [inferred].

All images are composed by the viewer from each window's exact pixels, over gray, and aren't read from the screen: the Mac's display was asleep throughout, and `screencapture` fails then. So **nobody has seen a proxy window on a display**, and whether `CALayerHost` drew there has only the earlier host probe behind it.

**A session from the real app.** `scripts/seamless-session-try <app> <machine>` starts with nothing running, in clones of the app and machine, and all of it ran in one go, with the display asleep:

- `open -a "TextEdit (Mavericks).app" note.txt`, which is what LaunchServices does for a drop on a tile, launches the proxy. It finds no session socket, so it starts its Light Click as a new instance with `--seamless-session`. That app is `type="UIElement"`, with no Dock tile, and runs the machine next to `seamless-viewer`, now in `Contents/Resources/Seamless`, which waits for the guest agent, installs the hook and restarts the guest on a first session, puts the tools in the guest and starts the app. About 2.5 minutes under TCG to the first window, including that restart.
- The file goes into the guest over the session's connection and opens. A "b" typed through the proxy's input view into it marked it Edited. A second, new document was typed into as well.
- `NSRunningApplication.terminate` on the proxy, which is a real quit event, as the Dock's menu sends, reached the guest app as a quit. TextEdit brought up its save sheet. **That sheet is two processes:** its frame is TextEdit's and its contents belong to `com.apple.appkit.xpc.openAndSavePanelService`. Filtering by owner lost the contents, so a session now also shows view services and SecurityAgent. Each came through as its own window in the same group.
- Return, sent as a key, took the default button. TextEdit exited, the proxy was told, the edited file came back to the host with its "b" and replaced the original, the machine shut down through the app's existing path, and the app exited. `SeamlessMakeProxy remove` then left no bundle and no LaunchServices record.

Proxy quits now answer `.terminateCancel` and quit on the session's word. `.terminateLater` holds an app in a modal run loop, while the sheet it's waiting for needs input.

**Then drags, gestures, badge and bounce,** in the same run, with the machine on the engine. All reported by `seamless-session-try`:

- **Drag in:** the host file goes to the guest, a helper's shield takes the press, and a real guest drag ends in a real drop on TextEdit's text view (`drag_ended ... operation 1`), as `seamless-integration.md` planned.
- **Drag out:** with a guest drag live, the session reads `NSDragPboard`, asks the proxy for a host drag, ends the guest's on a sink, and on a promise request copies the file back. It arrived byte for byte.
- **Scroll:** a real `NSEvent` through the input view reached the guest as a gesture. Gestures now go by `CGEventPostToPid` on 10.9, since in a run of `seamless-try input` only that route delivered all of magnify, rotate, swipe, smart magnify and quick look; force click arrives only as an ordinary click at pressure 1. Mojave stays on its agent's route, unrun. **Badge and attention:** "7" and attention came from `_LSCopyApplicationInformationItem`, which AppKit's badge writes to; `lsappinfo` printed nothing here. The JSON the session writes decodes as the proxy's commands in a package test.

But the host's half of both drags was stood in for, with nobody at the Mac and no pointer to move: these events came from the session as the proxy would report them, not from a real `NSDraggingSession`. The proxy's view for them is now an overlay that refuses mouse hits, which nothing has tested against a real drag. The badge test's source is a helper, not TextEdit. Pinch, rotate, swipe and force click have the same route as the scroll but can't be made without a trackpad.

**Then from a real `build-app`,** with `verify-release-build.py` passing and the engine on: `seamless-session-try` made the proxy through the same code as the menu, then ran all of this, 19 checks, at 2x and at 1x. The composed prompt at 2x shows the dropped file as an attachment in the new document, so the drop is real, as far as the guest goes.

Not from a real Dock click: that needs someone at the Mac. Since then this has moved into the app: `SeamlessSession` in the `SeamlessIntegration` package replaces `seamless-viewer` for a session, talking to the machine's agent directly, not through the diagnostics channel; `build-app` adds what it needs to `Contents/Resources/Seamless`, and **Actions > Make Dock App…** makes the proxy and installs the hook, which takes effect at the guest's next start. A session runs by capture until then. `seamless-viewer` stays for the probes in `seamless-try`. The session itself is still `probes/seamless-viewer.m`, moved in, not rewritten. The composed views are made from window pixels with the display asleep, as above; **nobody has seen this on a display**, including whether the machine's window flashes before it's cleared, which it can for up to 0.25 s. AppKit calls the machine's windows ordered out, while WindowServer still lists them as on screen with the display asleep, at alpha 0, so they're cleared as well.

### Per-window composite: tried, and not worth having yet

The question was whether a composite inside WindowServer beats capture for windows the hook can't read. On Mavericks under TCG, it doesn't, as far as these numbers go.

**`CGXRedrawWindowToLayer`**, reached by calling `_windowPluginRenderBitmap` from the hook. It returns at once with nothing drawn outside a display update, since it needs `CGXCurrentDisplayDeviceSurface`, which is set only during one. Standing in a device surface that names `CGXMainDisplayDevice` and has no GL context got it running without a crash: about 30 ms for 2560x1410, for every flag value except 4, which returned at once. It writes the whole buffer, **all zeros, for Safari.** That's the software path, with no composite function, and a window with no backing has nothing it can draw there. The GL path needs the display's own context in the middle of an update, plus a read back. I didn't go further, as the next result says it wouldn't gain anything: the same GL raster does the work.

**`CGSHWCaptureWindowList`**, which is WindowServer running that GL path for a client. In a tight loop on one still window it was 2.4 times cheaper than `CGWindowListCreateImage`:

| 12 captures of a window, ms for one, then ms to read its pixels | Safari 2788x1638 | TextEdit |
| --- | --- | --- |
| `CGWindowListCreateImage`, default | 42.2, 143.2 | 4.0, 45.4 |
| `CGSHWCaptureWindowList`, option `0x1`, with shadow and alpha | 56.8, 18.9 | 17.3, 6.9 |

So I put it in the tool, placing its image inside the frame by the shadow's sides from `CGXGetShadowMarginForWindow` (left is `-side[0]`, top `-side[2]`). Placed that way it agreed with a plain capture for 99.8% of 1.77 million samples on Safari and 100% on the demo's windows. Then the real loop, 22 s each way, in one boot, with the hook on:

| | Safari, animated page | TextEdit, overlay scrollers | Demo with a GL view |
| --- | --- | --- | --- |
| Frames reaching the host, plain / HW | 4.4 / **3.2**/s | 1.9 / 1.9/s | 26.7 / 27.2/s |
| Mean time for a capture and read | 130.5 / 162.6 ms | 39.2 / 31.0 ms | 16.8 / 16.0 ms |
| Tool's CPU | 38 / 33% | 31 / 28% | 31 / 30% |
| WindowServer's CPU | 84 / 82% | 44 / 40% | 56 / 57% |

One run each on a Mac that had other clones on it, so small differences mean nothing, but the large gain isn't there, and Safari got worse. **So it's not adopted.** WindowServer is near a whole core with Safari animating, on TCG, and a cheaper way to ask doesn't change that. The next section's numbers do.

### The engine and a 1x display change the picture

One boot per column, each case 22 s, hook on, four vCPUs, the microphone off, by plain capture. `guest-bench --env LC_HVDBT=1` and `--plist` set them. All one run each, with other clones on this Mac.

| Frames/s reaching the host (capture ms, WindowServer CPU %) | TCG, 2x | TCG, 1x | Engine, 2x | Engine, 1x |
| --- | --- | --- | --- | --- |
| Safari, animated page | 6.0 (104, 74) | 19.2 (36, 57) | 10.8 (43, 40) | **27.7 (14, 29)** |
| TextEdit, overlay scrollers: its content barely changes | 1.9 (34, 39) | 1.9 (14, 21) | 1.9 (15, 14) | 1.9 (8, 9) |
| Demo, a GL view in one of its windows | 26.5 (17, 57) | 37.4 (9, 43) | 37.7 (8, 22) | 39.0 (5, 17) |

So Safari goes up 4.6 times with both, and past that WindowServer has room to spare. These machines already have PassthroughOpenGL, so calling this "software compositing" was wrong: its session log shows contexts on the host's GPU. What limited it on TCG was running the guest. A guest GPU path has less to win than this document assumed, and the question it leaves is whether 2x at 11 frames/s is good enough, or a session should choose 1x for animated windows, which looks soft on a Retina host. Nobody has looked at that on a display.

**Surface flushes:** TextEdit's 13 captures a second bought 1.9 frames. The hook now sees a surface flush as a request arrives at WindowServer, by `msgh_id` in its `mach_msg` interposer, `0x7268` and inline `0x7267` on 13F34, and counts by window; there's no state left behind to read afterward. A window with surfaces gets a capture when one flushes, or once a second. On the engine at 2x, TextEdit went from 13.8 captures/s to 1.0 and WindowServer from 14% to 6%, with its frames still arriving, and the demo's GL view kept its 41 frames/s in all. A scrolling overlay scroller's look with this wasn't checked, and if its surface doesn't flush through these requests it updates once a second.

### Where a frame's time goes, and why the transport didn't change

Before building a new transport, the tool timed its stages, on the engine at 2x, 22 s each, one run each, with other clones on this Mac:

| Share of the tool's time | Mavericks Safari | Mojave Safari |
| --- | --- | --- |
| Getting the image | 1% | 0% |
| Reading its pixels | 46% | 53% |
| Comparing | 2% | 1% |
| Sending, through the guest's network and slirp | 48% | 42% |
| Frames/s, MB/s sent | 10.9, 21 | 6.4, 12.7 |

So sending did cost as much as reading, but they took turns, on a guest with four vCPUs, and each frame sent the whole width of its changed rows. Sending now has its own thread, and only the changed columns go:

| After | Mavericks Safari | Mojave Safari |
| --- | --- | --- |
| Reading its pixels | 86% | 87% |
| The sending thread | 5% | 5% |
| Frames/s, MB/s sent | **21.3**, 3.9 | **10.2**, 2.4 |
| WindowServer's CPU | 66% | 49% |

That doubled Mavericks and took Mojave up by more than half for a few dozen lines, and the network is now 5% of the time. **So there's no shared-memory or host-GPU transport here:** with this test page it has at most that 5% to win, on a guest kernel extension or a new path per guest generation. The page is a small moving box, though, and a full-window video would still send every pixel, so this holds until something shows otherwise. What's left is reading, about 40 ms for 3.6 million pixels on Mavericks and 86 ms on Mojave, which is `CGDataProviderCopyData`, and where the composite happens.

### Mojave: the hook has no backing to read

`Mojave Test`, one boot each way, hook loaded through `DYLD_INSERT_LIBRARIES` and its `mach_msg` interposer reached. Its row in the hook's `builds` table only reports. `+0xf0` is a window's backing, as `release_window` shows, and **TextEdit's and Safari's windows have none**, on samples taken while they were open: only the menu bar's and pre-login windows do. An app linked for 10.14 is composited from its CA layers. So Mavericks' hook, reading backings, has nothing to read here. The tree still comes from the client's window list, so nothing here needs the hook yet.

| Mojave, plain capture at 2x, composed from window pixels | TCG | Engine |
| --- | --- | --- |
| Safari, frames/s (capture ms, WindowServer CPU) | 1.0 (106, 35%) | 6.2 (79, 33%) |
| TextEdit, captures/s | 1.0 | 11.9, for 1.5 frames/s |

The columns aren't only the engine. `CGSGetWindowFlushSeed` doesn't move for a CSS animation here: in the TCG run, 475 of 497 looks were skipped by it while the page changed. So a window's looks are steered by what they find: half as long between them when one finds a change the seed missed, down to 15 Hz, and twice as long when it finds nothing, up to a second. TextEdit, idle but for its caret, went from 11.2 captures/s to 3.2. An animation takes a few looks to climb, which is up to about two seconds. What would replace it is a composite in the server: `WSCompositeWindowToDestination` into an IOSurface, or a client request that says a CA context changed. Both unbuilt, and given Mavericks' result for the first, measure before building.

**A session from a proxy** ran on `Mojave Test`, from a `build-app`, at 2x on the engine, with no hook: the proxy, the hidden machine, the opened document, typing, File > New, the mirrored menu (about 15 KB, 300 to 500 ms), the sheet on quitting with its view service's contents, the edited file coming back, the promised file, badge, attention, shutdown and removal. Accessibility needed a row for `/usr/libexec/AppleQEMUGuestAgent`, where Mojave's agent lives; without it both the menu and posted events silently did nothing. The setup now asks for its parent's path. The drag in failed at first because the helper said it was ready before its shields had reached the screen, so the press went straight through; it now waits half a second. A drop was then taken, though once `drag_ended` came with operation 0, refused, and the same drop was taken on the next launch; not explained. The drag out is checked with a file made for that one drag, so a stale pasteboard can't pass.

**A composite in the server, bounded, not built.** `CGSHWCaptureWindowList` is the path through `WSCompositeWindowToDestination`, by a disassembly of `CaptureSurfaceMetal::Populate`, so its time is a fair stand-in for one, on Mojave on the engine at 2x:

| 12 of them on a still window: ms to get it, then ms to read its pixels | Safari 2480x1418 | TextEdit 1310x854 |
| --- | --- | --- |
| `CGWindowListCreateImage`, no framing | 0.6, 55.2 | 6.0, 31.0 |
| `CGSHWCaptureWindowList` | 16.7, 57.0 | 43.1, 27.8 |

So the composite is about a quarter of Safari's cost, and getting the pixels out is the rest, which an in-server composite would still have to do unless they reach the host without a copy. I didn't call `WSCompositeWindowToDestination` itself: this says it isn't where the time goes, and the transport is the place to look next.

### Each window on the host's GPU, with no read in the guest

**Both generations deliver whole windows at windowed speed this way.** Safari with the animated page, at 2x, on the engine, four vCPUs, with other clones running on this Mac. Rates are over 30 s in one boot per column, read from counters on the host. All images are composed from pixels, not read from the screen.

| Safari, frames/s reaching the host | Windowed | Each window on the GPU |
| --- | --- | --- |
| Mavericks | 60.0 presented, QEMU 19.0%, WindowServer 7.7% | 59.9 into its own IOSurface and to a `CALayer` in another process, every one changed, none dropped; QEMU 21.8%, WindowServer 7.7%, viewer 1.8% |
| Mojave | 60 presented; see the table below | 60 to a `CALayer` in another process, with no composite of the display; see the table below |

By capture over TCP, these were 11 and 6.2.

CPU on Mojave, in one boot, with the hook injected between the two, on a Mac with a load of about 10:

| Share of one core | Windowed, 21 s | Each window, 25 s |
| --- | --- | --- |
| Frames reaching a layer | 60 | 60, 1,612 of 1,624 composites drawing only what changed |
| WindowServer, in the guest | 13.8% | 24.2% |
| QEMU, which includes that | 65% | 58% |
| PVG helper | 12.7% | 13.3% |
| App | 0.7% | 0.1% |
| Viewer, which reads pixels back to hash them, as a real one wouldn't | | 1.8% |
| **All on the host** | **78%** | **73%** |

So the host pays no more, and WindowServer pays more: 1.8 ms a composite here, and the update runs too. One run each, and windowed's QEMU alone was 49 to 65% across runs, so 78 against 73 shows no difference to speak of. Every composite whole, in another such boot, was WindowServer 19%, QEMU 60% and the helper 20%: so drawing only what changed saved the helper's time, and in the guest made no clear difference.

**What each generation can do**

| Generation | What's run | Whole window at windowed rate | Covered | Display off | In a running guest |
| --- | --- | --- | --- | --- | --- |
| Mojave 18G103 | PVG: a guest IOSurface is a host IOSurface | Yes, in a layer, read from the screen | Yes, at 60 | Yes | Yes, injected |
| Mavericks 13F34 | GL replay into host IOSurfaces | Yes, in a layer, read from the screen | At the rate windowed gets there, about 14 frames/s for a page behind TextEdit | Yes | Yes, injected |
| Yosemite to High Sierra | Not run. GL compositor [memory] | Likely with Mavericks' method, per build | | | |
| Catalina, Big Sur | Not run. Metal, PVG | Likely with Mojave's, per build; Big Sur's library symbols are in question | | | |
| Tiger to Mountain Lion | Not inspected | See below | | | |

**A window's own content, with no composite in the guest.** Not reached, and possible on Mojave. CA's render server is in WindowServer on both systems, and a commit reaches `CA::Render::Context` there as decoded changes [read, not run]. CA's remote layers rest on Mach ports, so they can't cross the VM, and the stream's numbering is private to each build, so the host would be fed by a translator to a plain `CALayer` tree, with any window it doesn't understand staying on its composite. See "The layer tree census". On Mavericks a window's contents have no host identity, so it stays with replay in the stream.

**The layer tree census.** Measured with `CARenderUpdatePrintTrees` from the hook, through `CASetMessageFunction`: Safari, TextEdit, Finder and the demo's windows on Mojave, 300 surface updates, 61 distinct trees. Windows' trees are small and plain:

| In 6,035 layers across the distinct trees | Count |
| --- | --- |
| `proxy-layer`, which is a material: number, blend mode, level, selection tint | 140 |
| `gradient-layer` | 111 |
| `layer-host`, another process's content | 46 |
| `backdrop-layer` | 10 |
| Compositing filters | `plusD` 403, `normalBlendMode` 342, `copy` 101, `darkenBlendMode` 10 |
| Other filters | `gaussianBlur` and `colorSaturate`, 10 each |
| Animations | 46 |

No masks, transforms, shadows, shapes, replicators, emitters or portals turned up. Contents are `backingStore`, of an image or a surface, and Safari's page is 1024x1024 surfaces in tiles. So a translator would be small for these windows: layers, geometry, contents, the four subclasses, those filters. What this doesn't say is how close `plusD` and friends look on the host, what a video or a WebGL page has, or what contents cost: on Mojave, about half of large texture binds in a composite have a host IOSurface, and `CA_ACCEL_BACKING=1` hardly moved that. Binds aren't layers.

**What the whole path looks like, from a static read of both WindowServers.** Not run, except where this section says.

- A client's backing goes to a `CA::Render::Context` in WindowServer. An update then asks CA what changed, makes layers for each window, composites them, and presents.
- A window's shadow is its own layers. Its materials are `WSBackdrop`s, which sample what's already been composited, on Mojave. Mavericks has no such thing: its blur is a surface's background radius and a shader.
- Hooks can sit at the composite, as here, at each surface, or at the commit. A whole other compositor is there (`CompositorNoop`), but capture, Spaces and transitions all reach for one, so replacing it globally would break them.
- Window management could move host-side by steps: `CGXMoveWindowList` mirrors a host's move for AppKit, with no composite a guest position only feeds events, and `__XPostEventRecordTo` may take a window. Identity, delivery and focus stay in the guest. None of it is tried.

**Tiger to Mountain Lion, scoped and unrun.** Software backings are shared memory with the app [read on 10.9], so a window with no surfaces is a matter of reading its rows, as the hook does on 10.9. Doing that without a copy means an IOSurface over guest RAM, and fragmented 4K guest pages can't back one on a 16K host: `apple-gfx-legacy-shadow.m`'s notes say Metal refuses those imports. So one copy per damaged rectangle on the host, by its own CPU or GPU, which is `DG_VRAM_PATCH_DRAWABLE`'s kind of work [inferred]. Where a guest has PassthroughOpenGL, Mavericks' method applies if the compositor has the same shape, which isn't read: symbols and offsets are per build.

**Mavericks (`PassthroughOpenGL/seamless-gpu-replay-host.c`).** WindowServer composites through CoreGraphics' own GL context record, one interpreter, and the CA tree of every app runs inside it, so a page's animation is plain draws on the display drawable: 3 draws a frame for this page. Each display update builds layers per window in `redraw_window`, then draws them all in `gl_composite_layer`. The hook patches those two entries, knows a layer by its `new[]` address, and before a window's layers sends its ID and bounds through `glPassThrough`, which reaches the host in order and does nothing in GL, so **neither the guest's GL client nor the wire changes, and no prebuilt is rebuilt.** The host runs each display draw a second time into that window's IOSurface, moving the viewport and scissor by its origin. That cost 1.1% of a thread here. Mismarking is what a first version had, placing draws by where they landed, since the Dock owns a full-screen window; markers fixed it.

**The whole window on Mavericks.** A window's body reaches the display drawable only during its opening effect, so a surface started from what it draws has the toolbar and square and no page. `redraw_window` clips each window to the state's region at +0x18, so the hook sets that to everywhere for one redraw once a window's bounds have held for a second. The window then arrives whole, with its shadow and real alpha [measured, composed from pixels]. `WSRefreshDisplay` gave no large frame, and `CGXInvalidateWindowRegion` with guessed arguments left WindowServer restarting. The same clip should give a covered window and a timed full redraw with `gpu_mode` 2 [inferred, not run]. Mavericks still composites its display as well: nothing yet turns that off, and its CPU is the display's plus 1.1% of a thread for the replay.

**Mojave.** A guest IOSurface is a host IOSurface: `texture.iosurface` on a guest's render target in the helper's `renderCommandEncoderWithDescriptor:` hook is non-nil, for the display's two surfaces and for a composite's. So nothing needs copying. `CGSHWCaptureWindowList` with no read in the guest already renders a window, with its shadow and alpha, into one, and that surface goes to another process by Mach port as it is. A whole Safari window with rounded corners and its shadow arrived that way, by CPU and through Core Image. These surfaces say 1 byte per element, with a row as long as the width in the CPU's view, so a CPU reader works out its own row, and a layer showing them hasn't been tried; Core Image read them correctly.

**The hook, on Mojave (`probes/seamless-ws-mojave.h`).** It leaves the display with no layers, and composites each damaged window to a surface of its own, by the entry points a capture uses. Read and measured on 18G103 only:

- **Display off:** `generate_layers_for_window` returns 0 with no layers during an update, and runs as it does otherwise inside the hook's own composite, which also calls it. The helper stops encoding the display when `<directory>/nodisplay` exists.
- **Damage:** the update's region at +0x50, by intersecting each window's capture shape, and the connections in `add_connection_to_update_contributors`, with a window's own at +0x18. CA's animations come with no connection. A window is damaged when new or moved too.
- **Which window:** the surface's size. The low 8 bits of its width and the low 4 of its height carry the ID, with 0xA0 in the rest of the height's low byte. Past the window it's transparent. Bounds come from the session's window list by the same ID. A real CA surface can have such a size, and one did. Neither a texture's label nor `IOSurfaceSetValue` reaches the host [measured], so size stays, and the marker below keeps such a surface from being sent.
- **One frame per composite:** a composite is several command buffers, so after it the hook clears one point of a small surface, tagged 0xB0, on the same queue, and the helper sends the window's surface when that finishes.
- **What the host's GPU keeps:** WindowServer's passes say "don't care" for what they load, as the guest's GPU keeps what it doesn't draw. An Apple GPU doesn't. So the helper changes that to load for these surfaces, or a composite of part of a window loses the rest.
- **A covered window** with TextEdit over Safari: 60 frames/s, every frame's sampled pixels changing, in an earlier version. The update's region leaves out what's covered, so what's in front of a window, by its real shape, is drawn each frame. Skipped windows count, as the Dock does.
- **A window that's opening** is mid-effect when first drawn, so it's drawn whole again a second later. It needs an update to happen by then.

**Materials on Mojave.** A real host material sits behind a window, and follows what's behind it on the Mac [read from the screen by window ID, with what's below it]. Font Book's sidebar over a host window that changes color reads 228,204,202 over red, 204,203,227 over blue, 204,228,202 over green and 204,203,202 over black, while its white content stays 255,255,255. See `Build/seamless-gpu/v4-guest-light/window-scene-*.png` from the commands below.

No patch to the composite was needed: a `WSBackdrop` samples its destination, and one window alone in an empty one leaves its materials clear, with an alpha of 1. Only crops have the guest's wallpaper in them. The hook publishes each window's raw backdrops, at +0x3b0, as `gpu_backdrops[]`: material, active, and rectangles. An inactive window's aren't in the resolved list at +0x3c0. The numbers read on 18G103, in light appearance: 3 menu and popover, 4 sheet, 5 sidebar, 19 selection, 21 menu bar, 25 title bar and status items, and 26 what vibrant text and icons cut out, which needs nothing. In a composite without its shadow, any alpha at all is the window's real shape, with a popover's arrow and a sidebar's corners, except for 21 and 25, which come out with none. So a window with materials also sends that as a surface, tagged 0xC0, when drawn whole, and the host masks with it. `apply_materials` in `probes/seamless-gpu-viewer.m` is how, with one `NSVisualEffectView` per material and its state following `active`.

Not done: dark appearance, as `defaults` reads back Dark and apps stay light in these runs; how close the host's materials look to Mojave's; a menu and a sheet on their own, as the images catch only some of the demo's timeline; and a gap in Font Book, a column at its list's scroller that's clear in some runs, not understood.

**Guest shadow or host shadow.** Compare `v4-guest-light` with `v4-host-light`. The guest's looks right, on overlap and over a background. The host's, from the surface's alpha, was only a hairline, on windows that are never key, so it hasn't had a fair look. A guest shadow past the guest's display is cut off, as Safari at the display's full width shows.

**Mavericks with the display off**, and the hook injected into the running WindowServer, in one boot:

| Safari | Windowed, 22 s | Each window, display off, 27 s |
| --- | --- | --- |
| Frames/s | 60.5 presented | 60 into its surface and to a layer in another process, read from the screen |
| QEMU, which includes WindowServer | 22.5% | 21.0% |
| WindowServer | 6.2% | 7.4% |
| Safari's own, the app | 5.3% | 5.0% |
| Viewer | | 1.8% |
| Behind TextEdit, frames/s | 13.9 | 13.5 |

So there's no difference to speak of, one run each. A page behind another app's window slows down whether or not this is on. Turning it off brought Safari back on the display whole. With the mode on, the host doesn't run the display's draws, each window gets all of what changed, and every window behind is drawn too, as nothing stops at an opaque one. A window drawn in part has no shadow drawn, and one drawn whole starts clear, or the shadow builds up. On 10.9 the injector borrows zeroed memory as a thread with `_pthread_set_self`, as `pthread_create_from_mach_thread` isn't there, and new[]'s lazy pointer in `CoreGraphics` gives the layers' owners, with no interposing.

Not done there: what uses the display as a source, which is the Dock's and a sheet's blur, sampling a display that's no longer drawn. Mavericks' effects are a surface's background radius at +0x114 and `dock_blur_fbo_texture`'s shader [read], so the host would draw those from the radius and shape. Not read further.

**Injecting safely.** A failure in WindowServer logs the user out. So `seamless-ws-inject` loads the hook in its own process first and has it check the build, every symbol and every entry it would patch, tries at most once per boot, and exits 3 if already tried, 4 if the system isn't known and 5 if the hook refused inside, for the session to use crops. All patches go in together or none do, and no thread may be stopped inside one. Exits 0, 3 and 4 have been seen, 4 from a real mistake in the check. 5 hasn't.

**A real layer.** Safari's window in a `CALayer` in another process was read from the screen with `screencapture -l`, of that one window, and is whole and correct. PVG's odd row bytes don't trouble Core Animation.

**A running guest.** `probes/seamless-ws-inject.c` loads the hook into a running WindowServer, with no restart and the same PID afterward, and windows then arrive at 60 frames/s. It uses `task_for_pid` as root, a bare thread that asks for a real one, and `dlopen`. WindowServer's sandbox refuses a library in `/var/tmp`, so it goes in `/usr/lib`, which needs SIP off in the guest, as these guests have. The log and table it makes itself, ahead of the library. Live patching stops the other threads, and leaves pages executable throughout. Interposing doesn't work in a library loaded this way, so nothing relies on it: the composites run from a patch of `update_display_callback`.

**Mojave's CPU is over the bar with what's been added since the table above.** The same page in one boot, 21 s windowed against 26 s each window: QEMU 49% against 70%, the helper 8% against 25%, viewer 1.7%, so 57% against 97% of a core, at 60 frames/s, 19 of 1,672 composites whole, at 2.1 ms each. That has the shadow, the marker and the load action in it, and this Mac's load varied between runs. Which of them costs what isn't known.

Not done: overlap while moving or resizing, input, a real resize of a surface, the session itself, other builds of 10.14, and any hook but this one on later systems.

To run them, with a built app: `scripts/seamless-gpu prepare`, then `boot`, `desktop` and `run`, and for Mavericks with the hook in the copy's WindowServer plist and `/var/tmp/seamless-ws-gl-tree` present, `scripts/seamless-gpu-safari <app> <copy> <results> replay|windowed`. On Mojave, `VIM_SEAMLESS_PVG_DIR` writes the helper's render passes and `seamless-guest hw-loop --app Safari --hz 60` asks for the composites.

What was wrong before these worked: `launchctl bsexec` only moves the bootstrap port, and prints "bsexec failed: Inappropriate ioctl for device" on 10.9. WindowServer finds a
client's GUI session from its **audit session**, so a tool started by the guest agent stayed in the system's: the connection and display calls worked, but the window list and session
dictionary came back empty. `probes/seamless-session-join.h` now joins Finder's audit session, for every tool that enters the session this way, `probes/gpu-bench.m` and `probes/seamless-integration-guest.m` included. The integration driver adds the agent's TCC row too.

**Not working or not tried:**

- The composed images are made by the viewer from each host window's exact pixels, not read from the screen, because the host's display was asleep and `screencapture` failed. Nobody has yet
  looked at these as real windows on a display, with the real Dock, Mission Control or menu bar.
- The hook delivers backing-store contents and the tree. Shadows, GL, text views with overlay scrollers and whole CA-backed windows such as Safari's still come from a capture, at about 4 frames/s for an animated Safari. See "Per-window composite" for why a composite in the server wasn't the answer.
- The machine still has a window and a library window, cleared and ordered out; and a session has no microphone, since Core Audio can stop answering QEMU's open of it and hang the boot: `AudioQueueStart` returned `268451843`, which is `MACH_RCV_TIMED_OUT`, so `coreaudiod` not answering, and later a boot sat in `AudioQueueDispose` on the same device.
- The proxy's own copy isn't signed for distribution, and nothing here has been through notarization. A session can't start while another instance of the app has the machine open, and what that looks like has not been run.
- A document is copied into the guest and copied back when its modification date changes: plain files only, with the host's copy losing if both change. A guest crash during a session and quitting before the guest is up weren't run. A lost session quits the proxy.
- Second launches, Cancel at the prompt, a folder left at the socket's path and a proxy opened while another app holds the machine are all in `seamless-session-try` now. One Mojave cancel run left the proxy alive after `.terminate`, which then swallowed the next open. It now exits regardless after 15 s, and the test keeps a sample if that happens again; the cause isn't known.
- Only 10.9 has a working hook; see the Mojave section. A hook already in a guest isn't replaced by a newer one.
- Pixels go over TCP through slirp. Nothing is zero-copy yet.
- Full screen wasn't exercised. Tooltips and drag images weren't tried. Host-native dragging isn't done: dragging runs in the guest, with the host window following.
- Mojave: no hook. Its symbols are read, not run. A `tree` run on the Mojave Test clone never ran: no one logged in to its desktop within 300 s, and I didn't look into why.

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
| **A** One surface per window, in order, overlapping | Window tree from `CGWindowListCopyWindowInfo`; pixels from the hook, or capture | `NSWindow` per guest window, ordered and at the guest's level | On Mavericks, through the hook, at 25.5 frames/s for a live window [measured] | Accelerated windows; rate with a big live window |
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
| **A** Battery and idle cost | Guest idle cost is the main term; hook damage instead of polling. The hook costs about 2.5% of one thread with a window changing at 30 Hz, and the tool still polls the window list | | `CGSGetWindowFlushSeed` errors for another process's windows on macOS 27 [measured: `seed_answers 0`], and its code looks windows up in a client-side table on 10.9 too [read]. So damage needs the hook | The VM's idle CPU under TCG; `capture_share` reports the probe's cost |

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
2. **Done on Mavericks: damage**, from the flush seed at `*(window + 0xe0) + 0x1c`.
3. **Done on Mavericks: the window tree** from `WSGetVisibleWindowArray`, and shadow changes as events.
4. **Next: per-window composite in the server**, for what a backing doesn't hold: Safari, GL, overlay scrollers. Mojave `WSCompositeWindowToDestination`, Mavericks `CGXRedrawWindowToLayer`, into an IOSurface per window, on the GPU. Also knowing when a surface flushed.
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
| Now | TCP over slirp to host loopback (`10.0.2.2`) | Capture or hook, kernel, slirp, viewer | Works from Mavericks [measured]: 5.1 MB/s used, limit unknown |
| Next | `guestfwd` into a private Unix socket | Same | Off any host port; needs a launch-plan change; requires shared networking |
| vmware-svga | Hook composites through PassthroughOpenGL, so the texture is **already on the host GPU**. Host exports an IOSurface per window to the app through the existing `VIMSurfaceFrameMessage` capability transport and `presentSurface:` | None | [inferred]; `display-surface-message.h`, `passthrough-opengl-surfaces-host.c` exist. Needs a window identity marked in the GL stream or the guest IOSurface name |
| PVG | Hook composites to a Metal texture in the guest; host sees it inside `apple-gfx` only as commands | Unknown | **Open.** Options: guest-RAM-backed shared buffer that the helper's gather (`gpu-performance-notes.md`) imports without copy; or a blit to a shared buffer, per window, in a region the helper maps. Needs a real read of `apple-gfx-helper.m` |
| Fallback | Shared guest memory: wired pages with a physical list through the driver, host reads them | One | [inferred]; `gather` proves the host half for PVG |

### Who owns a window's surface

Each frame sent carries a Mach send-once right to its buffer's port. Whoever has the frame keeps the right while it's in use. Its going, by letting go or by dying, is what makes the buffer writable again, along with `IOSurfaceIsInUse`. A frame that can't get a free buffer waits or is dropped, and is never written over one that's held.

- Mavericks: a window draws in a private buffer, copied to a free shared one at the end of a frame, so waiting loses nothing.
- Mojave: the guest reuses its surfaces when it likes, so what's sent is a copy, made in the marker's command buffer.
- With a viewer stalling 300 ms every 30 frames, surfaces reused before it took them went from 72 to 0 on Mavericks and from 2682 to 0 on Mojave [measured]. CPU isn't measurably higher.
- shortcut: geometry goes with the frame only on Mavericks. On Mojave the origin is zero and the tool's window says where it is.
- shortcut: with no free buffer, a frame waits for the next update, so a consumer stalled past all of them as the guest goes idle shows the last frame sent until something changes.

### A covered window keeps going

One app with two animated windows, the second under the first (`probes/seamless-two-windows.m`), per second [measured]:

| Guest | Animates by | Side by side: app draws, presented | Covered: app draws, presented |
| --- | --- | --- | --- |
| Mavericks | AppKit | 51, 50 | 53, 55 |
| Mavericks | Core Animation | 0, 60 | 0, 61 |
| Mojave | AppKit | 41, 41 | 60, 59 |
| Mojave | Core Animation | 0, 59 | 0, 63 |

Neither guest throttles or clips a covered window here. Covered in Mavericks' guest, `occlusionState` says so. In Mojave's, with this mode on, it doesn't, and that was checked from the rows: both windows at one place, the second behind.

### What the display still does for a window

With the display off, three things keep a window's surface whole on Mavericks. `gl_prepare_layers` cuts each layer by the opaque ones in front, so it sees one window's layers at a time. `redraw_window` skips what's covered by the region at `state+0x20`, so that starts empty for each window. And a layer that samples what's behind it, such as Safari's address field, reads the drawable, so the drawable gets the window's surface first. shortcut: only that window's, so what's over another window samples clear there.

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
2. Done on Mavericks: the window tree from the hook, GL and Safari exercised, scroll, drag and resize, and a generated proxy with windows, Dock identity, menu and input.
3. Done on Mavericks: a composite in the server, tried and not adopted; a proxy launching a machine with no window, opening a document, quitting with a save prompt and unregistering.
4. Next, once someone can watch: **the whole thing on a display**, with a real Dock click.
5. **Mojave:** a session from a proxy, then whether a composite in the server earns its place.
6. A menu in the app that makes a proxy, and the session in typed Swift.
7. A guest GPU path or zero-copy transport, if a display shows that 11 frames/s at 2x isn't enough.
8. The PVG transport.
9. Snapshot and resume; multiple VMs; AX bridge; then the versions between, one at a time.

## Running with nobody at the guest

`scripts/seamless-try` boots a throwaway clone through `scripts/guest-bench`, staging tools over the guest agent, which re-enter the console session as `probes/gpu-bench.m` does. Results print and go to `Build/seamless/`. From `Source/`:

    M="$HOME/Library/Application Support/Virtual Intel Mac/Machines/Mavericks.vintelmac"
    A="$PWD/Build/Products/Current/Light Click.app"

    scripts/seamless-try proxy "$A" "$M"      # TextEdit as a generated host app: windows, menu, input, VM hidden.
    scripts/seamless-try motion "$A" "$M"     # The demo through the hook, with GL, a scroll, a drag and a resize.
    scripts/seamless-try safari "$A" "$M"     # Safari with an animated page, through the hook.
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
