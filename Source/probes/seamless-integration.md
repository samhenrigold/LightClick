# Seamless guest apps: integration with the host

The other half of `seamless-apps-design.md`: everything that makes a guest app behave like a Mac app on this Mac, apart from
window pixels and input, which `seamless-apps` and `seamless-input` own.

**No guest has run any of this.** No VM was booted. `scripts/seamless-integration-try` runs what needs a guest, and every **[guest?]**
below is a question it answers or that a later run must.

Labels, as in the design doc: **[measured]** by a probe on this host, macOS 27.2, M4 Max, SIP on, with synthetic events.
**[read]** in stock binaries of Mavericks 13F34 and Mojave 18G103, read-only. **[memory]** recalled, unchecked. **[inferred]**
reasoned. **[guest?]** only a guest run can settle it. **Now** and **Later** mark whether a decision has to be made before building on
it. Nothing is read from any other guest version, so Tiger through Mountain Lion and Catalina and Big Sur are **[memory]** throughout.

## Run it

    # Nothing booted. About a minute; leave the Mac alone.
    scripts/test-seamless-integration --guest-root <read-only mount of a guest disk>

    # Boots a throwaway clone, with nobody at the guest. Prints what it measured, then a table.
    scripts/seamless-integration-try "$PWD/Build/Products/Current/Light Click.app" \
        "$HOME/Library/Application Support/Virtual Intel Mac/Machines/Mavericks.vintelmac"

What's here:

- `Packages/SeamlessIntegration`: generating proxies, converting icons, the menu mirror, the proxy's two-way messages, which guest
  runs what, and what a guest may ask of the host. The `SeamlessProxy` binary is the executable of every generated `.app`.
- `probes/seamless-integration-guest.m`: the guest's half. Imports nothing newer than 10.9, resolves all 146 imports against
  both images (`probes/check-guest-imports.py`), and runs on this host under Rosetta.
- `probes/nfs3-server.py`: a host folder served over NFSv3, to measure file identity.

## Top of the table

| # | What | Proven | Unknown | Decide |
| --- | --- | --- | --- | --- |
| 1 | Real guest drag from a host drag | Both backends make a real drop on another process's view, here [measured] | That on 10.9 and 10.14, with a real app's highlight [guest?] | Now: `NSDraggingSession` |
| 2 | Dock tile, Cmd-Tab, Mission Control, Spotlight | Seen in screenshots and read from the Dock [measured] | Nothing on the host | Now: where proxies live |
| 3 | Menu bar pass-through | The whole path on the host, with a real 301-item menu [measured] | AX cost under TCG, and what Mavericks' AX shows [guest?] | Now: pass-through is primary |
| 4 | Guest's menu bar over the host's | Hides, takes clicks, restores itself [measured] | Multiple displays, full screen | Later: fallback |
| 5 | File identity, Save in place | Server, confinement and policy; not yet any guest client | Everything on a guest [guest?] | **Now:** see below |
| 6 | Drag out as promised files | Host half lands in Finder; guest half reads the drag [measured] | Finder as a real source in a guest [guest?] | Now: the sink |

## Drag in

**Apple's stack, read from `SSDragHelper` on both versions [read]:** it's a small `LSUIElement` helper with no AppKit dragging. `ReceiveDrag` covers the
screen with "shield" windows at the status level, so the mouse down that starts the drag clicks nothing, then tells `screensharingd`
to post it. Told to go, it closes the shields so they don't catch the drop, and calls:

    CoreDragRegisterClient(CGSMainConnectionID());
    CoreDragCreateWithPasteboardRef(pasteboard, &drag);
    CoreDragSetDropActions(drag, 5);
    CoreDragSetAllowableActions(drag, 1, 1);
    CoreDragSetInputProc(drag, proc, NULL);    // SIGTERM sets a flag; proc then calls CoreDragCancelDrag.
    CoreDragStartDragging(drag, 6, 0, CGPointZero);   // Blocks until the drop.

On Mojave it adds `CoreDragSetCGImageWithScale`. Mavericks passes no image at all. `SendDrag` is the other direction: shields, then `CoreDragInstallTrackingHandler`,
jiggling the pointer with `CGPostMouseEvent` until the handler runs, then `CoreDragGetDragWindow` for its image. Files arrive as promises and
`CoreDragGetDropLocation` says where to transfer them: that's RFB `0x20` and `0x22`.

So the RFB route adds a service to enable, a password or account question, and Apple's framing, to reach something a small helper of our own can do.

| Route | Guest | Image | Files | Verdict |
| --- | --- | --- | --- | --- |
| RFB `0x0e`, `0x20`, `0x22` | Lion up, stock [memory], 10.9 and 10.14 [read] | From the viewer on 10.14; none on 10.9 [read] | Promises, copied over RFB | No. Needs Screen Sharing on, wire format undocumented, and a copy for each file |
| Our helper, `NSDraggingSession` | 10.7 up [memory] | Real, public API | Real `file://`, or anything | **Use.** Public on every guest that has it, and it works here |
| Our helper, CoreDrag | Both [read]; exports go back further [memory] | Private, per version | Same | Fallback for before 10.7, where `dragImage:` is the other choice |

**What's proven [measured]:** `seamless-integration-guest drag-in`, an x86_64 10.9 binary under Rosetta on macOS 27.2. Shield, mouse down, shield gone, drag, drop: a separate process's
`NSView` received `draggingEntered`, `performDragOperation` and the file's real path, by both `ns` and `coredrag`. CoreDrag still works on this host, called with exactly `SSDragHelper`'s
arguments. `ns` took 8.7 ms from mouse down to dragging. Nothing here is under TCG, so that says nothing about guest speed. On Mavericks and Mojave, whether Finder and TextEdit take the drop and draw their
highlight is [guest?]: `seamless-integration-try` drives both with the real tablet through the `input` diagnostic, saves a hover frame, and checks that the file arrived.

**Flow** (`ProxyDropView`, in the proxy; the session's side is still to write):

1. Host drag enters a proxy window: `dragEntered(paths, window, x, y)`. The session makes the file reachable and starts the helper: **shield up**.
2. Session sends a tablet move and press to the mapped slot point. The press lands on the shield, and the helper starts its drag. Moves carry on: `draggingUpdated` to `dragMoved` to the tablet.
3. The real guest target highlights in the guest's frame, and because that's the window's crop, the host shows it. No extra path.
4. `performDragOperation` to `dragDropped`: tablet release, a real drop. Exit: `dragExited`, so cancel by Escape, or by `SIGTERM` for CoreDrag.

**The image [Now]:** the host's own drag image already follows the pointer, and is the real one. A guest drag image would be a second one inside the crop, so the helper takes `--no-image` and draws one point in seamless mode.
Full-window mode uses the real icon.

**The operation shown on the host [Later]:** a guest's accept or reject doesn't reach the source until the drop, so the host's cursor always says copy, even over something that won't take it. A CoreDrag tracking handler might see it; untested.

## Getting files there

| Path | Reach | Cost | Copy or mapped | Status |
| --- | --- | --- | --- | --- |
| Guest agent | All | Base64 and an acknowledgement per chunk: 384 KiB on VirtIO, **256 bytes on the UART, so every pre-Metal guest** [read `GuestAgent.swift`] | Copy | Small files only before Mojave. Run prints the rate |
| `FileSharingPort` SMB | Everything with `smbd` | Wrong way round: **the guest is the server**, with the host connecting over `hostfwd` to 445 [read `VIMLaunchPlan`, `VIMSMBService`] | Copy into the guest | Slirp's rate. Needs sharing on, and credentials |
| The host's own SMB | Mavericks up, for SMB2 [memory]; not Leopard | User must turn on File Sharing, and set an account's SMB password | Mapped | Fails "no setup" |
| QEMU `smb=` | Option exists [measured], needs a host `smbd` that we'd have to ship | Slirp | Mapped | Rejected |
| 9P | Mojave [read], Big Sur [memory]; none on Mavericks [read] | Virtqueue | Mapped | **No `virtio-9p` in the current runtime [measured]**; QEMU rebuild with `--enable-virtfs`, untested. The driver has no xattr strings [read], so forks are likely AppleDouble |
| NFSv3 served by the session | `mount_nfs` on both [read], Tiger up [memory] | Slirp, over `guestfwd` | **Mapped**: nothing copied until read, and the guest writes the host's file | Prototype. **Recommended** |

`nfs3-server.py` serves one folder on one port, MOUNT included, so it never touches `rpcbind`. Its self-test confirms the guest can't get out: `..`, names with slashes, unknown handles, symlinks already there or planted by the guest, and handles
for those from a listing. It found one real hole on the way, a `REMOVE ../secret`, which is fixed and covered. No guest client has mounted it yet [guest?]. Options, from `mount_nfs` on both [read]: `vers=3,tcp,port=N,mountport=N,nolocks`. Root in the guest does the mount.

A guest's drop usually needs only the path. Reading is lazy over NFS, so a 50 GB drag costs nothing until the app reads it, and an app that wants a local copy does its own. For the rare guest with no NFS client, or with shared networking off, fall back to a copy through the agent. Drag-out stops being a transfer too, when the file is already on the share.

## Top decision: file identity

**The goal:** the guest app has the host's real document open, and Save goes back in place. Only a live mount of the host's folder does that; staging, watching and copying back is the design doc's earlier idea, and its write-back races are the hard part. That idea should go.

**Decide now.** Three questions, in order of how much they change:

| Question | Recommendation | Why |
| --- | --- | --- |
| What does the guest see? | **A shared root, session-served NFS, at `/Volumes/<Mac name>`**. Per-document grants first | The mapped path is the only design where Open and Save panels agree with the host. Whole-home sharing is the opt-in: an old OS shouldn't read `~/.ssh` for a user who dragged in one file |
| How does a path map? | `SharedFolderMapping`: host `~/Documents/x.rtf` to guest `/Volumes/<Mac>/Users/<you>/Documents/x.rtf`, the host's real path under the mount | A Finder document gets a path someone can recognize, and that a save panel can show. Refuses anything outside, including a symlink to a file about to be created |
| Are ownership and modes real? | Server answers as the logged-in guest user, so no permission denied on open | `nfs3-server.py` already reports every file as its own user. On a real multi-user guest it needs the requesting uid [Later] |

**What's unknown or weak** [guest?], in order of risk:

1. **Locking.** `nolocks` gives no lock between guest and host, and `locallocks` is only inside the guest [read option names]. If a guest and a host app open one file, last save wins. Real NLM needs another protocol, and macOS itself doesn't lock SMB files from old apps reliably [memory]. Mitigate: warn when a document is open on both sides, via the proxy, and treat as known.
2. **Forks and type/creator.** With no named attributes on NFSv3, the guest's VFS should fall back to `._name` AppleDouble files on the server [memory]. That leaves litter in the host folder, unless the server does the fold: **it can translate `._name` to `com.apple.ResourceFork` and `FinderInfo` xattrs on the real file**, which keeps a host's copy native and is a real reason to own the server. Not built. The run prints what really lands. `namedattr` is an NFSv4 option, also in `mount_nfs` [read], not tried.
3. **Safe save.** `NSDocument` writes a temp file and renames, so `save_kept_inode` is probably false, as on a local disk. Bookmarks and host apps holding the file then see the replacement. Fine if rename over NFS works; `exchangedata` won't exist. The run checks.
4. **Host TCC.** The session serves the folder, and the session isn't the app the user dropped on. Reading `~/Documents` from it may prompt, once, naming Light Click. Dataless iCloud files will block in `read` until they download, so run the server off the main thread. Not tested.
5. **Case.** Old apps assume case-insensitive; APFS default is too, an external volume needn't be.
6. **Rate** through slirp, which the run measures with plain TCP and with a 256 MiB read of the mount.
7. **Network off.** `guestfwd` needs `networkMode == shared` [read]. Without it, no mount, and the copy fallback applies.

**Why not 9P where it exists:** one path that reaches every guest beats a second path for two, and the server stays in our hands. Revisit it on Mojave only if the rate there is bad. **A Swift server replaces the Python prototype** if the run goes well: it needs to live in the session process.

## Dock icon and proxy `.app`

All [measured] with a real Mavericks plist and icon, unless noted. Screenshots looked at by eye, not just `lsappinfo`:

| Mechanism | Result |
| --- | --- |
| Generated, ad-hoc signed `.app` from a guest plist | **89 to 245 ms**; launches with no prompt or quarantine issue. Unknown when the parent is a notarized download [Later] |
| Dock tile | Real, right title, in the Dock's own AX tree. Tooltip reads `TextEdit (Mavericks)` |
| Cmd-Tab | Real entry with the guest icon, seen in the screenshot and in the Dock's AX list |
| Mission Control | The placeholder window appears as a real window. Its identity comes from the owning process, also `kCGWindowOwnerName` |
| Icon | All 48 of Mavericks' apps' icons convert, at 19 to 182 ms each. Largest native: 43 at 1024, 5 at 512 |
| **Icon on current macOS** | From the bundle, **the Dock puts it in a grey rounded tile**, as it does any icon it considers legacy. Set at run time with `applicationIconImage`, **it shows bare**, as on the guest. Seen in both screenshots. The proxy does that at launch, so a kept-in-Dock proxy that isn't running likely shows the grey tile [inferred] |
| Document opened with VM not running | Launches, queues, and delivers once the session is up: 2.3 s, mostly the proxy's 1 s retry |
| `application:openFiles:` | Yes, from `open -a` |
| **File dropped on the tile** | Yes, but passed in 3 of 5 tries on a busy desktop, and only once a hover jiggle was added: the Dock wants movement to arm a tile. Drag with real hands should be fine [inferred]; the failures aren't explained |
| Drop on a window | Yes, real paths and 34 moves over 25 steps |
| Badge | `NSDockTile` shows; read back as `AXStatusLabel` 7 |
| Dock menu | Mirrored items show through `applicationDockMenu`, read through `AXShownMenuUIElement`. Dock's own Options, Show All Windows, Quit too |
| Recent documents | Noting one puts it at the top of the Dock menu by itself |
| Bounce | Requested with no error, but **not confirmed**: one still frame can't show it, and `lsappinfo` has no such key on this host |
| Notification | Ad-hoc proxy posted a provisional one with no prompt and no error. Whether it reached the Center's list, not checked |
| Quit | Cmd-Q reaches the session first, and the proxy leaves only when told. So a guest save prompt gets its chance |

### Keeping it out of the way

- **Open With and defaults [measured]:** `LSHandlerRank = Alternate` lists the proxy under Open With without changing `.rtf`'s default; rank `None` isn't listed at all. A type only the guest knows did go to a proxy as default, which is what you'd want. **Proxies declare no URL schemes**, so none can take over `http`.
- **Pollution risk [Now]:** one Alternate per guest app multiplies quickly: Open With on `.txt` would list TextEdit, Stickies and more, per machine. Recommend **`None` for everything except apps the user has added**, which also still takes drops and `open -a`.
- **Spotlight [measured]:** finds a proxy in `~/Applications` **and** in `~/Library/Application Support` once `mdimport` has been run. Launchpad's successor wasn't looked at. Put proxies in `~/Applications/Light Click/<Machine>/`: users expect to find them there, and a user can remove one by trashing it. Only those the user chose [Now]; a generated folder of 48 apps per machine would pollute Spotlight just like Open With.
- **Identity across regeneration:** the bundle ID depends on the machine and the guest's, so it's stable [inferred from how LaunchServices works; a regenerated tile keeping its Dock place not checked].

### Which app is which

`displayName` is `TextEdit (Mavericks)` to separate it from the host's TextEdit. Two machines' TextEdits don't collide, in Dock or Spotlight. Drop the suffix for apps the host doesn't have [Later].

### From guest to tile

| Signal | Mechanism | Status |
| --- | --- | --- |
| Badge | `AppKit` writes `StatusLabel` through `_LSSetApplicationInformationItem` on both [read]. So `lsappinfo info -only StatusLabel` from a guest agent needs no injection. `lsappinfo listen` gives change notifications | [guest?]: `badge-self` checks. On this host it reads empty even though the Dock shows the badge, so the key may have moved here, but that doesn't bear on old guests. Fallback: guest Dock's AX `AXStatusLabel` |
| Bounce | `kLSApplicationDesiresAttentionKey`, `kLSNotifyApplicationWantsAttentionChanged` in `lsappinfo` on both [read] | [guest?] |
| Dock menu | Guest apps' `applicationDockMenu` only exists when the guest Dock asks; AX `AXShowMenu` on the guest's tile opens it on the guest. It would need to run in a corner and be read. | [Later], with a real menu cost. Recents and proxy actions cover most uses |
| Launch and quit | `NSWorkspace` notifications in the agent; launch via `open`, quit via AX File menu or `terminate` | Standard; [guest?] |

## Menu bar

The user's call: it has to work normally. **A, pass-through, is primary, and B, the guest's own bar in place, is the fallback.**

### A. Pass-through

**Proven on this host, against a proxy [measured]:**

| Need | Result |
| --- | --- |
| Whole real menu | The guest tool, x86_64, read Finder's 301 items in **66 to 112 ms**, 609 ms once under load. The proxy showed them **in 10 to 23 ms**. `Apple Finder File Edit View Go Window Help` in the bar |
| Menu open is instant | The menu is local AppKit: **51 to 54 ms from a posted click to `menuWillOpen`**, regardless of the guest, and that's mostly event delivery |
| Live updates while open | A tree sent while a menu is open changes it in place: Revert enabled and a new item, read back from the open menu. Dispatches run during menu tracking |
| Enabled, checked, mixed | Mapped, read back: `AXEnabled`, `AXMenuItemMarkChar`, and `.mixed` for `-` |
| Keys and modifiers | Shown and read back: Cmd, Shift, Control, no-Command (bit 8). Virtual keys and arrows map via `AXMenuItemCmdVirtualKey`; glyphs aren't read yet |
| Alternates | A real Finder bar has them, `AXMenuItemPrimaryUIElement` differing from itself. An alternate with only modifiers is hidden and **swaps in when Option is held**: seen in two screenshots |
| Help search | Setting `NSApp.helpMenu` gets AppKit's real search field in the mirrored menu, and it covers the whole bar. Seen in a screenshot |
| App menu | The first menu draws as the app, in bold, seen with a matching title; a differing guest title wasn't looked at. Quit, Hide and so on stay guest items. Only the guest's Apple menu is dropped; the host's stays |
| Invoke | Choosing sends the path; `AXPress` flips Calculator's real View > Scientific check mark and back, read back by the guest tool, in 0.1 to 15 ms to issue. **The press returns before the app acts**: the new mark could take up to about a second to read back on this host, so refreshing after a press has to retry |

**A correction to the brief: AX notifications can't drive the cache.** Registered on Calculator for `AXMenuOpened`, `AXMenuClosed`, `AXMenuItemSelected`, `AXTitleChanged`, `AXCreated`, `AXValueChanged` and focus, with all registrations returning success: **pressing an item that changed its check mark fired nothing** [measured, on one app here; the guest run reprints it]. AppKit validates items when they're read, so reading is what's live: it's a pull API.

**So the design:**

1. Keep the whole tree in the proxy. Opening is local, so it's instant and never waits on the guest.
2. Reread the whole bar on app activation, on focused-window changes, and after any click or key sent to that app, debounced. That costs an emulated AX walk; the run measures how much.
3. On `menuWillOpen`, reread **just that menu** (`menu --top File`) and apply it in place. Since the menu's already open, it corrects itself within its read time, instead of blocking. Enabled state can flicker there. If the walk costs more than a frame or two, a stale Paste is the visible result, briefly.
4. `menuNeedsUpdate`-populated submenus (Open Recent, History): read their subtree on the same trigger, as AX forces the guest's own update [guest?]. If a guest app builds a submenu only when really opened, press it open off-screen, or fall back to B for that app.

**Key equivalents [Now]:** AppKit takes a key equivalent before the view does. `menuChosen(path, viaKey: true)` tells the session to **send the keystroke to the guest, not to AXPress it**: the guest's first responder chain knows what Cmd-S means in that field, as with a normal app, and pressing the item would bypass what a text field would do with Cmd-V. Coordinate with `seamless-input`.

**What AX can't give:**

| Gap | Handling | Status |
| --- | --- | --- |
| Item icons | No image attribute read yet; `AXImage` strings exist in AppKit [read], not necessarily here. Text only until a guest injection | [guest?] |
| Custom views in menus | Not reported, or empty titles | Fall back to B, per app |
| Carbon apps | `HIToolbox` has its own `AXMenuItemCmdChar` family, including glyph and primary element [read] | Likely good; [guest?] |
| Java, Qt, Electron-era | Variable. Usually real `NSMenu`s [memory] | App list, then B |
| Tiger's AX | Not inspected [memory: AX has been around since 10.2] | Per version |
| Permissions | **No root exemption**: `_isProcessTrustedAndRegisterAccess` and `_hasAuthorizationForControlComputer` go straight to `TCCAccessCheckAuditToken` for the responsible process, with no `geteuid` check on either version [read]. So the assumption in `seamless-guest.c` that root needs no grant looks wrong. The agent writes `TCC.db`'s row, with SIP off in guests | [guest?] |
| Status items | `AXExtrasMenuBar` exists in AppKit on both [read]. **Empty from `SystemUIServer` on this host**; `Menu Extras/*.menu` are there on both guests [read]. Guest Wi-Fi and clock aren't wanted anyway: only an app's own would mirror, to `NSStatusItem` [Later] |
| Accessory windows of menus | Guest's menu windows are never shown in A | Fine |

### B. The guest's own bar over the host's

For apps where A fails. A borderless window at `mainMenu + 1` holds the crop of the guest's bar, and clicks go through the tablet; the guest's menus appear as ordinary reported windows, per the design doc.

**[measured] on this notched 14" display, with a placeholder bar:**

| Mode | Options | Top of screen | Dock |
| --- | --- | --- | --- |
| `hideMenuBar` | `0xa`, needing `.hideDock` too: AppKit requires it | Host's bar gone, and doesn't come back at `y = 1`. Click at `y = 1` lands in our window | **Gone** while this app is active |
| `autoHideMenuBar` | `0x5` | The host's bar reports `bar_visible` true on reaching the top, but **our window stays above it**. Click still lands in ours | Reachable, auto-hiding |

**Use `autoHide`**: losing the Dock on every focus of a guest window isn't normal, and the overlay wins the top edge either way. When another app comes forward, AppKit restores the host's bar without help; the probe found **the overlay must order itself out**, since it would otherwise sit over Finder's bar, and now does, in `applicationDidResignActive`. Seen in a screenshot.

**Notch [measured]:** bar 33 points, safe top 32, `auxiliaryTopLeftArea` ending at 663.5 and the right one starting at 848.5, of 1512. **The notch sits in the middle of the row** where a long guest bar runs, and pixels under it are simply lost. A guest bar passing x = 663 needs help: an app with many menus or a wide language. Options: draw only the left region and scroll the rest with a chevron, or shift the bar below the notch at the cost of content height. A's menu bar has none of this, since macOS lays it out. A real reason it's primary.

Height: guest bar is 22 points against 33 here [memory for the guest's]. Letterbox it in the row, rather than scale.

**Unknown:**

- **Multiple displays.** `presentationOptions` apply per process [memory], so a second display's bar may hide too, and the window covers only the first screen as written (`shortcut:` comment in the proxy). This host has one display. Must test.
- **Full screen.** Added `.fullScreenAuxiliary` so it should follow; not tested. A host full-screen window already hides the bar.
- **Spaces and Stage Manager:** not tested. Overlay's `canJoinAllSpaces` may look wrong next to a proxy window on one Space.
- **Menu Extras and Control Center** are hidden too, as they are in any full-screen app. Unavoidable.

### Per version

| Guest | Primary | Note |
| --- | --- | --- |
| Mavericks to Mojave | A | Reading on both, [guest?] for speed. If a full read is slow under TCG, the menu-open path holds and step 2 does less |
| Lion, Mountain Lion, Yosemite to High Sierra | A | Same frameworks [inferred], unread |
| Catalina, Big Sur | A | Screen Recording doesn't apply to AX. TCC schema changes per version [memory], and Big Sur's `TCC.db` may need more than a row [memory] |
| Leopard, Snow Leopard | A | `.AccessibilityAPIEnabled` instead of a row [memory] |
| Tiger | A if AX suffices, else B | Unread. Carbon-heavy; good sign, but unverified |
| Any app with custom menus | B, per app | User override, stored by bundle ID |

## Drag out

`seamless-apps-design.md` called this hard and left it. It looks manageable. All the host half is [measured]; the guest half is below.

1. The user drags in a guest window. Pointer leaves the proxy window with the button down: `pointerLeftWithButtonDown`.
2. Session asks the guest tool whether a drag is live: **`NSDragPboard` is readable by any process**, types and files both, and its `changeCount` jumps when a drag starts [measured: another process read types and paths during an `ns` drag. A `coredrag` drag didn't change it, as it uses its own pasteboard, so a guest app dragging through Carbon may not show here].
3. The host's drag starts: `beginDragOut(names)` makes a real `NSFilePromiseProvider` drag. **It worked starting from the window's existing mouse down, after the drag began, with a real Finder window as the target**, and the file landed.
4. To end the guest's drag, the session moves the guest pointer into a **sink**, a screen-sized guest window at the helper's level, registered for all types, and releases. The source gets a completed copy, so it doesn't slide back, and doesn't delete: `drag-sink` reads the files and completes on this host. Its `performDragOperation` also calls `namesOfPromisedFilesDropped` where a guest app's drag is only a promise.
5. `writePromiseTo` becomes `promiseRequested(id, destination)`. If the file's on the share, it's a host-side clone. If not, it's a copy over SMB or NFS, or a guest's file written to the mount. `promiseFulfilled` finishes it. **A guest name is `hostFileName`d first**, so `../../` in a guest filename can't step out of where Finder asked.

**Drag image [guest?]:** `CoreDragGetDragWindow` then `CGWindowListCreateImage`, as `SSDragHelper` does. On this host it returned error 29823 from a third party's perspective. On guests, Apple's own tool relies on it, so it should work there. Failing that, the host shows the file's icon, which is what happens today.

**Unknown [guest?]:** Finder as a source, which the guest run doesn't do yet: the source there is the tool. Timing, since the button is down throughout an emulated round trip: if the guest takes a second to answer, the host's drag starts late. A drag from a window whose app runs its own Carbon tracking might not touch `NSDragPboard`.

## Other integration, ranked

**Decide now** means it changes how the above gets built.

| # | Feature | Mechanism | Status | When |
| --- | --- | --- | --- | --- |
| 1 | **Security: what a guest app can reach** | See below | Partly built | **Now** |
| 2 | **Links out** | Agent registers a small guest `.app` as `http`, `https`, `mailto` handler with `LSSetDefaultHandlerForURLScheme` (exported on both [read]); it forwards to the host, which checks `HostPolicy.openableURL` and opens the default app. Tested policy only | [guest?] | **Now**: policy. Later: per-guest choice, since some want the old Safari |
| 3 | **Links in** | Host URL schemes are never claimed by proxies. A web clip to guest is a menu action. Host-to-guest `x-light-click://` not needed yet | Design | Later |
| 4 | **Which guest runs what** | `GuestPicker`: from `MachOArchitectures` and `LSMinimumSystemVersion`. Newest guest that can. PowerPC only on 10.4 to 10.6 with Rosetta; i386 stops at 10.14. Tested as a pure function | Built; **Rosetta in guests not verified**, no flag in `VIMGuestProfile` [read]. It'd have to be detected from `/Library/Receipts` or `oah` | **Now**: rule |
| 5 | **Installing** | Double-clicking a `.dmg`, `.pkg` or `.app` on the host goes to the host's own handlers, and a proxy can't and shouldn't take those. Offer **Open in Light Click** via Open With on the main app's `Alternate` types, and drop on its Dock icon. Attach dmg by `hdiutil` over the share, or the `insert-disc` path, and let the guest's `DiskImageMounter` and `Installer` run. Then discovery sees a new app | Design | Later |
| 6 | **Clipboard** | `origin/guest-services` carries RTF and images. Seamless adds nothing to that but **focus**: exchange is gated on focus, so a proxy being frontmost needs to count. File references become share paths | Depends on 5 above | Later |
| 7 | **App discovery** | Agent `apps` lists bundles, types and schemes. `GuestApp.discover(root:)` reads the same from a mounted disk | Host part measured, 48 apps; guest [guest?] | Now: offer a picker, not all |
| 8 | **VM not running** | Proxy starts, queues, and asks for the machine with `--open-vm`, which shows its window: **a headless launch doesn't exist**. Bounce the tile until a window | Queue measured; boot **not** run by design | **Now**: needs headless launch from session owners |
| 9 | **Notifications** | Host side proven. Guest side, least certain: reading `usernoted`'s database from the agent (`NotificationCenter/*.db` Mavericks, `com.apple.notificationcenter/db2/` Mojave [read]), or AX on the banner window. Injection last | [guest?] | Later |
| 10 | **Time zone, locale, language, keyboard, appearance** | At boot and on host change, agent writes `.GlobalPreferences` and runs `systemsetup` (present on both [read]). Mojave has `AppleInterfaceThemeChangedNotification` [read]; Mavericks has no dark mode. Layout: guest gets scancodes, so **its layout must match the host's**; coordinate with `seamless-input` | Design | Later; keyboard Now with input |
| 11 | **Printing** | A guest CUPS queue (`lpadmin` on both [read]), backend hands a PDF to the agent (`cgpdftopdf` on both [read]), and the host shows `NSPrintOperation`. Better than host IPP, which needs Printer Sharing | Design | Later |
| 12 | **Services, Dictionary, emoji** | Dictionary: host `showDefinition` from AX `AXSelectedText`. Emoji: host palette into `NSTextInputClient`, with `CGEventKeyboardSetUnicodeString`; **old fonts lack new emoji**. Services: proxy's `validRequestor` over AX selection for send; guest services copy to host `NSServices` poorly, so skip | Design | Later |
| 13 | **Quick Look, Share** | `qlgenerator` is gone from current macOS [memory], so only a Preview Extension in a sandboxed `.appex`, which can't reach a guest without a shared store. Low value; a host-side converter from the guest's `qlmanage -t` (on both [read]) is the path. Share is a promise from the app menu | Skip for now | Later |
| 14 | **AppleScript** | Proxy copies the guest's `.sdef` as `OSAScriptingDefinition` and wild-card forwards Apple events; serializing them is real work. Simple form: `osascript` passthrough | Unknown | Later |
| 15 | **Shortcuts** | App Intents needs compile-time metadata, so proxies can't declare them. One generic "Run in guest" on the main app | Inferred | Later |
| 16 | **Audio** | Guest mixes first, one stream through HDA or `virtio-sound`: **no per-app attribution possible** without a guest driver. Host sees one process. Fine | Answered | Later |
| 17 | **Now Playing, media keys** | `MPNowPlayingInfoCenter` in the proxy, fed by AX. Mojave has `MediaPlayer` [read], Mavericks doesn't. Keys become guest keys | Design | Later |
| 18 | **Mic, camera** | TCC sees the VM's process, not the proxy: one prompt naming Light Click. Per-app wording isn't possible | Inferred | Later |
| 19 | **USB** | `usb-connect` per device already exists [read]; route a device on an app's launch via the proxy | Design | Later |
| 20 | **MIDI** | No QEMU device. Network MIDI through slirp, unverified | Unknown | Later |

## Security

The guest is an old, unpatched OS, running old apps on the host's files, and everything from it is untrusted. **Decide now**, since they're defaults that get harder to tighten:

- **Proxy channel:** a `0600` Unix socket; 16 MiB line cap; anything undecodable is dropped. Guest strings are only titles and filenames: `hostFileName` strips separators and dots, and proxies don't run or open anything named in a message.
- **Host folder:** per-document or chosen roots by default, not home. Server refuses escapes (tested); loopback only.
- **Links:** allowlist of `http`, `https`, `mailto`. No `file:`, no custom schemes, length-capped. A guest page can still open a host browser to a chosen URL; consider a rate limit, and a prompt on the first per app.
- **Old OSes on a network:** `restrict=on` on slirp for seamless-only machines, leaving only `guestfwd` for the share and channel, would stop a 2013 Safari and a dead TLS stack reaching the internet, at the cost of breaking apps that need it. **Default for pre-Sierra guests, recommended, with a toggle** [Now, a user-visible decision]. Nothing else here depends on it.
- **What a guest can do through input:** mapped tablet and keys go only to the guest. Nothing goes host-ward.
- **No URL handlers, no default roles on proxies**, so guest metadata can't hijack host behavior.

## Other things the probe found

- **Dropping on a shared desktop is risky for a probe.** An early run dropped its test file's path into a window the probe didn't expect, because another window had come forward. It now reads what's frontmost at the drop point first, and cancels with Escape if it isn't the target. The Mac must be left alone for clean numbers; other processes moving windows cause `SKIP`s and flakes.
- **`resolvingSymlinksInPath` doesn't resolve through a missing leaf**, so a new file through a symlink would escape a share. The mapping uses `realpath` on the part that exists, and it's tested.
- A press posted without a preceding move can go to the window last under the pointer. Not relevant to the tablet, but `seamless-input` may hit it in tests.

## Not done

- **Session side:** nothing in `VIMSession` talks to proxies yet; the probe's fake session is the only one. Generating proxies from a real guest list, and a headless launch, need to land with `seamless-apps`.
- **No guest run,** so every drag, AX and NFS claim about Mavericks and Mojave stands untested, as above. Tiger to Mountain Lion and Catalina to Big Sur are unread.
- **Not built:** the `._` translation, links-out helper app, notifications guest side, printing, host-to-guest sync, AppleScript.
- **Not measured here:** real user's Dock drop, Stage Manager, Launchpad's successor, a second display.
