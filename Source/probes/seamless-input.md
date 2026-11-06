# Seamless input

How a guest app in a host window gets real trackpad gestures, force click, keys and focus, per guest generation.

**No guest has run this.** `scripts/seamless-try input` is the measurement, and it hasn't been run. What's below comes from
stock Mavericks 10.9.5 (13F34) and Mojave 10.14.6 (18G103) binaries read from clones, plus runs on this host (macOS 27.2).
No other guest version was read.

Labels: **[read]** in a guest binary, by disassembly. **[host]** measured on macOS 27.2, which says the numbers and code are
sound, not that a guest honours them. **[source]** public headers. **[memory]** recalled, unchecked. **[unknown]** the probe
decides.

## Answer

Apple already solved the gesture half. Screen Sharing's guest-side `ScreensharingAgent` turns the client's NSEvents back
into real events, and it's short. So a guest helper does what that agent does, with no RFB server:

| Generation | How the agent posts gestures [read] | What AppKit reads [read] |
| --- | --- | --- |
| Mavericks (RemoteDesktop-499.5) | `CGSPostEventRecord` with a raw record | The record, through `CGEventGetEventRecord`, in `_NSEventTypeFromCGEvent` |
| Mojave (RemoteDesktop-525.50) | `CGEventPost(kCGSessionEventTap)` with private fields | The same fields, through `CGEventGetIntegerValueField` |

The numbers line up across the two: record offset `0x9A` is field 132, `0xA8` is 99, `0xB4` is 123. That correspondence is why
the Mavericks record layout can be trusted, and it's also why a field-based post on Mavericks is worth trying.

## Mechanisms compared

| Mechanism | Mavericks | Mojave | Verdict |
| --- | --- | --- | --- |
| Raw record, `CGSPostEventRecord` / `SLSPostEventRecord` | Apple's route [read]; delivery [unknown] | Exported [read], Apple no longer uses it; layout [unknown] | Use on Mavericks. Built |
| `CGEventPost` session tap with private fields | Field setters exist; honoured [unknown] | Apple's route [read]; delivery [unknown] | Use on Mojave. Built. Every field proven through NSEvent [host] |
| `CGEventPost` HID tap | [unknown] | [unknown] | Built for comparison |
| Post to a process, addressed to a window | PSN form only [read]; [unknown] | `CGEventPostToPid` [read]; [unknown] | Works for all gestures and keys, when the app is active [host]. Needed for routing, see below |
| RFB `0x17` to `screensharingd` | Stock [read] | Stock [read] | **Rejected as the path.** It ends in the calls above, so it adds a server, authentication, a sharing indicator and a framebuffer connection for no extra event. Keep as plan B only if Mojave refuses root's posts and the agent turns out to be exempt [unknown] |
| IOHIDEvent into the event system, `IOHIDEventSystemClientDispatchEvent` | Exported, as are scale, rotation, scroll and dock swipe events [read] | The same, plus `IOHIDEventCreateForceEvent` [read] | Built for magnify and rotate, to measure. Permission and whether anything hears it [unknown] |
| Virtual device, `IOHIDUserDeviceCreate` | Exported [read] | Exported [read] | Not built. The only idea that could produce `supportsForce`, see force click. Large: it'd have to look like Apple's multitouch hardware to `MultitouchSupport` |
| USB tablet and keyboard over QMP (today's path) | Works | Works | Can't carry any of this: wheel clicks only, no phases, no gestures |

## What NSEvent needs

CG event type 29 with subtype in field 110, except scroll (22). The subtype sets NSEvent's type [read, both; host]:

| NSEvent | Subtype | Values | Record offset (10.9) |
| --- | --- | --- | --- |
| `magnify` 30 | 8 | 113 magnification, 132 phase, 133 = 4 | `0xA0` float, `0x9A`, `0x9C` |
| `rotate` 18 | 5 | 114 degrees, 132 phase, 133 = 4 | `0xA0` float, `0x9A`, `0x9C` |
| `swipe` 31 | 16, with 123 < 3 | 123 motion (1 across, 2 up or down), 115 direction (1 up, 2 down, 4 left, 8 right), 134 mask, 124 progress | `0xA4`, `0xA0`, `0xA8`, `0xAC` |
| `smartMagnify` 32 | 22 | 133 = 2 | `0x9C` |
| `beginGesture` 19, `endGesture` 20 | 61, 62 | 117 mask | `0xA0` |
| `pressure` 34 | 32 | 143 stage, 147 transition, 148 pressure, 144 behavior | None: Mojave and up only |
| `quickLook` 33 | System-defined event, type 14 | 83 subtype 6 then 9, 100 `'lkup'`, 121 `0xFFFF`, 122 -1 | `0x8A`, `0x8C`, `0x90`, `0x98`, `0x9A` |
| `scrollWheel` 22 | | 11-13 lines, 93-95 fixed, 96-98 points, 99 phase, 123 momentum, 88 continuous, 137 inverted | `0x88`, `0x90`, `0x9C`, `0xA8`, `0xB4`, `0xB8` bits |

Things that bit, worth keeping:

- **Scroll fields have to go in Apple's order:** lines, fixed, points. Setting lines rewrites the others: points of -25 read back
  as -16 when lines came last [host].
- **A process post needs field 51**, the window number. Without it, nothing arrived [host]. WindowServer fills that in when it
  routes by position.
- **Phases:** field values are `1 began, 2 changed, 4 ended, 8 cancelled, 128 may begin`. NSEvent reports those as 1, 4, 8, 16, 32.
  Momentum fields are `1, 2, 3`, reported as 1, 4, 8 [read, host]. Stationary becomes changed.
- **Point deltas are integers,** so the injector carries fractions: -12.5 a tick arrived as -12, -13, -12 [host].
- **Direction:** the host's `scrollingDelta` already has natural scrolling applied, so it goes through as is, with the inverted
  flag kept. Whether guest WindowServer applies its own preference again on a posted event is [unknown]; the probe's `sy` shows it.
- **Elastic scrolling:** a real `NSScrollView` followed phases and momentum into its overscroll and back, on its own [host].
- **`trackSwipeEventWithOptions:`** (Safari back and forward) runs on the scroll stream with phases, gated by
  `isSwipeTrackingFromScrollEventsEnabled`. The probe prints that. Nothing extra is posted for it.
- **Dock swipes and Mission Control** aren't sent: the host keeps Spaces, per the design.

## Force click

| Guest | Can it express it? | What the host sends |
| --- | --- | --- |
| Mavericks | **No.** AppKit has no `pressureChangeWithEvent:`, `stage`, `NSPressureConfiguration` or `NSImmediateActionGestureRecognizer`: none of those names exists in it [read]. Its `pressure` is only the mouse value | Look Up: `quickLookWithEvent:`, which does exist [read], using the `lkup` event Apple's agent posts for this gesture. Apps that do nothing with that get nothing |
| Yosemite before 10.10.3 | No: the API is marked 10.10.3 [source: SDK `NSEvent.h`]. Binary not read | As Mavericks |
| 10.10.3 to 10.13 | Not read. Expected as Mojave | As Mojave |
| Mojave | **Partly.** Pressure events can carry stage, transition and pressure, and `pressureChangeWithEvent:` takes them [host; on 10.14 unknown]. But AppKit's own force click won't engage: see below | Pressure, plus Look Up once per click at stage 2 |

Why it's only partial: `NSForceClickMonitor` and `NSImmediateActionToQuickLookPresentationAdaptor` ask `[NSEvent associatedEventsMask]`
for the pressure bit, and AppKit answers from the event's device: field 87, then `[NSTouchDevice _touchDeviceFromTrueDeviceID:]`,
then `supportsForce` [read]. A guest has no such device, and a posted event has no such device ID. So in a guest:

- **Works:** apps that read `pressureChangeWithEvent:`, such as drawing tools, assuming the probe confirms delivery.
- **Works through the mapping:** Look Up in text views and anything else that implements `quickLookWithEvent:`.
- **Can't be expressed this way:** immediate actions, link and Dock previews that use `NSImmediateActionGestureRecognizer`, and an
  app's `NSPressureConfiguration` actuations (the guest has nothing to actuate; the haptic would have to be replayed on the host).
- **Would take more:** a virtual force-capable device, or patching `supportsForce` in guest AppKit, as `guest-mojave-sky.h` does for
  SkyLight. Neither is built. `com.apple.trackpad.forceClick` also has to be on in the guest [read]; the probe prints it.

## Keyboard

**Mapping.** The host's virtual keycode is the guest's, on every OS [source: `Events.h`; inferred across versions]. The guest's layout
turns it into characters, so a host layout only has to be mirrored, not translated. `SWM_KEY` carries the code and the flags as
they stand.

This also passes keys the app's QMP table has no entry for, so they're dead in today's windowed mode: `10` (the ISO section key),
`63`, `64`, `71`, `79`, `80`, `81`, `90`, `93`-`95`, `102`, `104`-`107`, `110`, `113`, `114` [read: `VIMMetalView.m`]. That's a live bug for ISO and
JIS keyboards, separate from this work. I left it alone.

**Where keys go.** System hotkeys are taken before any app, so a proxy process never sees them and needs no event tap. Everything an
app does receive is decided in `SWIKeyStaysOnHost`:

| Keys | Goes to | Why |
| --- | --- | --- |
| Cmd-Tab, Cmd-Space, Mission Control, Spaces, screenshots | Host, by the system | `seamless-input-host --hotkeys` lists what this Mac has on, by `CGSIsSymbolicHotKeyEnabled` [host]. It's per-user: Cmd-Space wasn't on here. If one's off on the host it reaches the guest, where the same hotkey may fire |
| Cmd-Q, Cmd-W | **Guest** | Save prompts run there. The proxy quits when the guest app's windows go |
| Cmd-H, Cmd-Opt-H, Cmd-M, Cmd-`` ` ``, Cmd-Shift-`` ` ``, Cmd-Ctrl-F | Host | The window, the app and full-screen Space are the host's. Returns NO so the proxy's menu handles them |
| Everything else with Command | Guest | Via `performKeyEquivalent:`, with the release that AppKit swallows |

Guest copies of system hotkeys should be off, so a forwarded key can't trigger guest Spotlight: `CGSSetSymbolicHotKeyEnabled` exists on
both [read]. **Not built:** add it to the helper once the probe shows keys arrive.

**Repeats:** a posted key has no HID behind it, so the guest won't repeat it. The host forwards its repeats, marked with field 8. The
one posted repeat on the host never reached the view [host], possibly press-and-hold: **[unknown]**, and the `repeat` step decides. If it
fails in guests too, that's a real gap for held keys.

**Modifiers:** `SWM_MODIFIERS` carries device-dependent flags, so left and right survive. Cmd-Tab away never delivers a release, so on
losing key the view releases what's down and clears them, and on gaining key it sends what's held now. The injector turns differences
into real flags-changed key events [host: `flagsChanged code=56`, then `A`].

**Dead keys:** sent as raw keys. On the U.S. layout Option-E then E reached a real `NSTextInputClient` as `setMarkedText [´]`, then
`insertText [é]` [host].

**Layouts:** `SWT_INPUT_SOURCE` sends the host's TIS ID on focus and on change. The guest selects it from the user's own process.
`keylayout` IDs should match across versions [inferred]; the `layout` step checks French on a guest. Physical keyboard type (ANSI, ISO,
JIS): `LMGetKbdType` is logged, not set.

**Input methods:** two routes, chosen per source.

1. Same IME in the guest (the default): raw keys, and the guest's IME composes. Its candidate window is a guest window, so it needs a
   host child window from the windows work. The probe logs what's enabled.
2. Host IME (`hostComposes`): `NSTextInputClient` on the proxy view. Committed text goes as `SWT_INSERT`, and the guest posts it with
   `CGEventKeyboardSetUnicodeString`, split at 20 units. Kanji and emoji arrived intact in one event [host]. No public API gets marked text
   into a guest app, so composition shows in a host field by the pointer, and it won't underline in place.

## Focus and pointer

**First click.** The host says yes to `acceptsFirstMouse:` and leaves the choice to the guest. For that to work, **the click has to get
there before focus does.** If the host raised the guest window first, the click would land on a key window and always act, including
on a button the app meant to protect. So `windowBecameKey:` skips `SWM_FOCUS` when the current event is a mouse-down, and the guest
activates the window through the click as usual. This corrects the design's ordering. The `first-click` step checks it.

**Hover.** The view tracks with `NSTrackingActiveAlways`, so a background window still gets moves, as it does natively. **Cursor shapes:**
the guest has one cursor, and it moves with the pointer, so the existing path already gives each window the right one, as long as moves
reach the guest. No new message is needed.

**Coordinates.** Every message carries window-relative points times 16, so the guest adds that window's origin. With slots, that's the slot.

**Under a compositor hook,** guest windows may stack anywhere and overlap. Posting by position would hit whichever is on top. Two ways:

- Post to the process with the window's number and `CGEventSetWindowLocation`, past ordering. The `route-control` and `route-to-window` steps
  click one point covered by another window, expecting the front window, then the one behind. Both functions exist [read]. **[unknown]**
  whether AppKit acts on it, and hover and cursor rectangles would still follow the real pointer position.
- Raise the window first. Simple, but this breaks the first-click rule above.

This is the thing most worth seeing on a guest before the hook settles on a layout.

## Host capture and latency

`seamless-input-view.h` sends from the event handler, on the main thread, with no timer. `seamless-input-queue.h` keeps it from blocking: bytes
go straight to a non-blocking socket, and only a backlog queues. While backed up, moves replace each other and deltas add, and a phase change
never merges, so a gesture's end can't be lost or dropped into a stale position. The same reasoning as `origin/display-latency`'s
`InputMotionCoalescer`, which only had positions to worry about. That coalescer's branch isn't merged here, so it isn't used directly.

`VIMMetalView.scrollWheel:` rounds into wheel clicks, which is what this replaces in seamless mode. Don't copy `seamless-viewer.m`'s
`MSG_DONTWAIT` send either: it can split a message, and on a full Unix socket here it blocked [host].

**Which stream carries pointer and keys?** The design says QMP. Gestures can't use it, and two channels can't keep a click ordered with the
scroll after it, so I recommend the helper carries everything once it's connected. QMP stays for login and before the agent's up. If Mojave
refuses root's posts, TCC can be written with SIP off [inferred], or keys and pointer stay on QMP. Latency of that stream under TCG is
**[unknown]**.

## Running it

From `Source/`. Boots a throwaway clone, with nobody at the guest. Prints one line per step per mechanism, then the raw log of what the
view got, and saves it in `Build/seamless/`.

    scripts/seamless-try input "$PWD/Build/Products/hvdbt/Light Click.app" \
        "$HOME/Library/Application Support/Virtual Intel Mac/Machines/Mavericks.vintelmac"

    scripts/seamless-try input "$PWD/Build/Products/hvdbt/Light Click.app" \
        "$PWD/Build/create-guest/home/Library/Application Support/Light Click/Machines/Mojave Test.vintelmac"

    # With your own trackpad, in a host window. Needs 10.0.2.2 to reach this Mac; `input` needs no network.
    scripts/seamless-try input-live "$PWD/Build/Products/hvdbt/Light Click.app" <machine> 60

Each gesture step says, per mechanism, `yes`, `NO` with what's missing, or `n/a` where the OS has no such event. Read the lines for
`pressure`, `route-to-window`, `first-click`, `repeat`, and any `injector died` line, which means a private call didn't like its arguments. On
Mojave, `NO` across every mechanism for everything most likely means the event-posting permission (`kTCCServicePostEvent` is in SkyLight
[read]) applies to root after all.

Without a guest, `scripts/test-seamless-input` runs real NSEvents through the host view, then the x86_64 guest tool under Rosetta, posting only
to its own windows. It takes focus for a few seconds, and if you're using the Mac meanwhile, steps vary: gestures need the test app active.
Wire tests are in `scripts/test-seamless-probes`.

## Host results so far

`seamless-input-host --self-test` passes: every gesture type, from the private fields through NSEvent and the view to the wire.
`seamless-input-guest probe --host-test`, x86_64 under Rosetta, posting across processes to a real view, delivered `scrollWheel` with every
phase and momentum, `magnify`, `rotate`, `swipe`, `smartMagnify`, `quickLook` and `pressureChange` through stage 2. Keys, flags, dead keys,
text and ISO and JIS codes too. That's a sound injector, not a sound guest. Runs where the Mac was in use lost the gesture steps. The
repeat never arrived in any run.

`seamless-input-guest` links as a 10.9 binary with no chained fixups, and its 122 imports resolve in both images by listing, apart from `memcpy`, `strcmp` and `strlen`, which `nm` doesn't show on those libraries. It
hasn't been loaded there.

## Not done

- Nothing has run on a guest.
- 10.10 to 10.13, Catalina and Big Sur weren't read. Tiger to Mountain Lion weren't read, and have no reason to share the record layout.
- Not wired into the viewer or the app: `SeamlessInputView` is standalone, since the windows work owns those.
- A real trackpad hasn't been through `input-live`.
- RFB's sub-kind numbering wasn't mapped, since it's not the path.
