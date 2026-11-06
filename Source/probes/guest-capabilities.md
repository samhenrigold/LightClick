# What a stock OS X guest already offers a host

**Short answer: more than "not much".** OS X has no VM guest tools before Mojave, but since Leopard it has shipped a
complete remote-session agent. On Mavericks that agent has drag and drop, file copy, a full pasteboard, cursor
delivery, trackpad gestures and Retina awareness. Mojave adds Apple's own VirtIO drivers, including a 9P shared-folder
filesystem. Neither is switched on or connected in Light Click today.

## How to read this

- **[M]** measured from a stock binary on a disk image. **[I]** inferred, from public sources or from the OS's history,
  and not checked against a binary.
- Disks read: Mavericks 10.9.5 (13F34, RemoteDesktop-499.5, ScreenSharing-481) and Mojave 10.14.6 (18G103,
  RemoteDesktop-525.50). Each was an APFS clone mounted read-only, and I read only `/System`, `/usr`, `/Library` and
  `/Applications`. Host: Screen Sharing 786.5 on Darwin 27.2.
- Nothing was run in a guest. **No RFB behaviour below has been observed live.** The wire details come from reading
  code, so they say what the code does, not that a session succeeds. `rfb-capabilities.py` is the check for that.
- Only 10.9 and 10.14 were measured. Every other version in the tables is [I], so run the probe on each guest before
  relying on it.
- Both disks have been through Light Click, so they aren't pristine: Mavericks has `VMsvga2GA.plugin`, and Mojave has
  a `.virtualintelmac-*/original` copy beside `CoreDisplay`. The components cited here aren't ones we patch.

## Ranking

| # | Capability | OSes | Guest change | User gets | Work | Against what we built |
|---|---|---|---|---|---|---|
| 1 | Drag and drop plus file copy, over a framebuffer-free RFB connection | 10.9, 10.14 [M]; Lion to Big Sur [I] | Stock; enable a service | Drag a file onto the VM window and it lands where dropped; drag out too | 3-5 weeks, wire format unpublished | **Beats it.** We have no drop target or progress UI in a guest |
| 2 | Rich clipboard (RTF, images, file refs) | Whichever guest the agent runs on | Our agent, already installed | Copying more than text | 3-5 days | **Extend `guest-clipboard`, don't replace it** |
| 3 | "Share Screen" toggle: enable the service, forward a port, open `vnc://` | 10.9, 10.14 [M]; Leopard to Big Sur [I] | Stock; enable a service | All of Apple's client features in a second window, at once | 2-3 days | Adds to it; lays the groundwork for 1 |
| 4 | Trackpad gestures: scroll phases, pinch, rotate, swipe | 10.9, 10.14 [M]; Lion to Big Sur [I] | Stock; needs 1's connection | Real gestures, which a USB tablet can't carry | 1-2 weeks after 1 | Beats the wheel events we send |
| 5 | VirtIO 9P shared folder | 10.14 [M]; Big Sur [I]; earlier unknown | Stock; `mount_9p` by agent | Host folder with no network or password | 1 week, needs a QEMU rebuild | Complements SMB, on the newest guests only |
| 6 | Window list and accessibility tree | All [I]; APIs at 10.9, 10.14 [M] | New agent code, TCC grants | Seamless windows, in theory | Months | Nothing to compare; poor return |
| 7 | Virtual displays | 10.14 `CGVirtualDisplay` [M]; 10.9 internal only [M] | Agent code | A second guest display | Weeks, and capture is slow | Worse than `guest-hidpi-policy.h` plus PVG |
| 8 | Embed the host's `ScreenSharing.framework` | Host only | None | Apple's client in our window | Small, then fragile | Avoid: private, changes with each host OS |
| 9 | Curtain mode, virtual-display sessions | 10.9, 10.14 [M] | Stock | Nothing on a VM with no physical screen | n/a | Skip |
| 10 | AFP | Guest yes [M]; **host client gone [M]** | n/a | Nothing: the host has no `afpfs.fs` or `afp.bundle` | n/a | Dead; stay on SMB |
| 11 | Handoff, Universal Clipboard, AirDrop | Handoff 10.10+ [I] | Stock | Needs iCloud, Bluetooth LE and AWDL, which we don't emulate | Very large | Skip |
| 12 | Audio over RFB | None | n/a | Nothing: RFB here has no audio channel [M] | n/a | HDA and `virtio-sound` already do this |

## Build these three

1. **Build first: the Share Screen toggle (#3).** It's the cheapest, it's useful on its own, and it answers the
   questions #1 depends on: can a current host client still talk to a 10.9 server, and how does auth behave?
   - The root agent enables `com.apple.screensharing`, and a generated legacy VNC password keeps user credentials out of
     it, matching `guest-clipboard`'s rule.
   - `hostfwd_add`, sent through QMP's `human-monitor-command`, should add the port with no restart [I].
     `VIMSMBService`'s local DNS-SD pattern can advertise it.
2. **Rich clipboard (#2).** Add typed payloads to protocol 2, keeping `exchangeAllowed`. It needs no RFB, so it has no
   auth, no sharing indicator, and reaches Tiger. It stays useful whatever the probe finds.
3. **The drag and drop sidecar (#1).** The largest prize and the only one nothing else can deliver, but start it only
   after the probe and #3 report back. The first step is to capture a `vnc://` session against a clone and decode
   `0x0e`, `0x20` and `0x22`.

## The probe

`probes/rfb-capabilities.py` needs only Python and works without a boot from me. It reports the banner and security
types with no credentials, then with credentials the command bitmap, flags and the rectangles sent. It changes nothing
in the guest, and prints only the length of any clipboard text it receives. `--self-test` runs it against a loopback
stand-in; that exercises the parser and the crypto, but not Apple's server.

To run it against a clone, with Remote Login enabled on the machine:

```
scripts/boot-clone "<app>" "<machine.vintelmac>"
ssh -p <SSHPort> <user>@127.0.0.1                # in the clone, once it's at the desktop:
sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
    -activate -configure -access -on -users <user> -privs -all \
    -clientopts -setvnclegacy -vnclegacy yes -setvncpw -vncpw <throwaway> -restart -agent

ssh -N -L 5901:127.0.0.1:5900 -p <SSHPort> <user>@127.0.0.1 &
python3 probes/rfb-capabilities.py 127.0.0.1:5901
RFB_PASSWORD=<throwaway> python3 probes/rfb-capabilities.py 127.0.0.1:5901 --auth vnc
RFB_USER=<user> RFB_PASSWORD=<password> python3 probes/rfb-capabilities.py 127.0.0.1:5901 --auth ard
open vnc://127.0.0.1:5901                        # the host's client, for question 1 below
```

Questions it should settle, in the order they affect the plan:

1. Does the current host client connect to a 10.9 server through a loopback port? The Mojave framework has
   `localhostMatchesAddress:`, so a guard against connecting to yourself exists there [M]. A forwarded port may avoid it
   [I]. Try it by hand.
2. Does a legacy VNC password get the same bitmap as an account? If not, #3 and #1 need the user's password, which
   changes their design.
3. What does Mojave's bitmap hold? Unlike Mavericks, it's built at run time [M], so only a live connection can show it.
4. Does the server stay idle with no `FramebufferUpdateRequest` pending? #1 assumes so [I]. If it keeps capturing,
   the sidecar costs guest CPU, which matters under TCG.
5. Does `kickstart` grant control on Mojave and later? It may be limited there [I], which would mean a pref change.

## Evidence

### The RFB server

- **Components [M, both]:** `screensharingd` is socket-activated on `vnc-server` and advertises `_rfb._tcp`, and it's
  `Disabled` by default. `ScreensharingAgent` runs per-session, with `SSPasteboardHelper` and `SSAssistanceCursor`.
  `AppleVNCServer` has `SSDragHelper`, and `screensharingd` has `SSFileCopyReceiver` and `SSFileCopySender`.
- **Protocol [M]:** the banner is `RFB 003.889`. Apple's undocumented `3.889` is also reported publicly [noVNC #58].
- **Capability bitmap [M]:** a viewer can ask the server what it supports.
  - ServerInit's name field holds `u16 0`, `u32 flags`, a 16-byte bitmap, then the name. Those offsets come from
    `screensharingd`'s `SendServerInitialiation`, spelled that way (name at `0x2e`), and the client's `RFBAuthenticateCore`.
  - The client tests a command with `byte[n >> 3] >> (7 - (n & 7)) & 1`.
  - The endianness of `flags` isn't settled: the server stores it natively and the client swaps it.
- **Mavericks's static bitmap [M]:** `bffee703e0` followed by zeroes. `0x0c` is toggled at run time by `SessionOnConsole`.

| Type | Viewer message, from the client's `RFB*` functions [M] | Advertised statically on 10.9 |
|---|---|---|
| `0x08` | SetServerScaling | yes |
| `0x09` | AutoFrameUpdate | yes |
| `0x0a` | SetMode (control or observe) | yes |
| `0x0b` | RequestClipboard | yes |
| `0x0d` | SetDisplay | yes |
| `0x0e` | DragEvent | yes |
| `0x12` | SetEncryptionLevel | yes |
| `0x14` | FastUserSwitch: curtain, virtual display | **no**; the client still checks this bit, so how it's set is unknown |
| `0x15` | SetSharedPasteboard | yes |
| `0x16` | AssistCursor | yes |
| `0x17` | Gesture and scroll, with sub-kinds | yes |
| `0x1f` | SendClipboard | yes |
| `0x20` | DropEvent | yes |
| `0x21` | ViewerInfo | yes |
| `0x22` | FileCopy | yes |

- **Encodings [M]:** the client sends Cursor (-239), DesktopSize (-223), and Apple's 1100, 1101, 1102, 1104 and 1105.
  In the server's `HandleSetEncodingsMessage`, 1101 and 1105 trigger display info (`EncodeDisplayInfo`, and its
  `DisplayInfo2` form), and 1102 is user info. I didn't resolve 1100 or 1104.
- **Pasteboard [M]:** `Clipboard.c` packs every flavor with deflate (`CopyPackedScrapDataForPasteboardByName`), and
  Mojave's has `com.apple.pasteboard.promised-file-url` and a "universal clipboard" toggle.
- **Cursor [M]:** `EncodeCursorImageWithAlpha`, `CGSGetGlobalCursorData`, `CGSCurrentCursorSeed`. Any process can get the
  cursor image with no driver. We already get ours from the display path, so there's no need to switch.
- **Retina and resize [M]:** the server has `hidpi.c`, and the viewer has `RFBSetlocalWindowUIResolution`. In the
  bitmaps I can read there's no client-driven resize, only DesktopSize notifications from the server.
  `guest-display` stays the way to resize.
- **Auth:** public reports give 30, 2 and 35 on the wire, and 33 for RSA [Apple thread, gist]. Mavericks has DH
  and Kerberos [M]. Mojave adds RSA and SRP (`SRP-RFC5054-4096-SHA512-PBKDF2`) [M]. Type 30's framing is taken from
  noVNC's public implementation [I], and only the self-test's stand-in has checked my version of it.

### The host's client

- `Screen Sharing.app` still registers `vnc` [M].
- `ScreenSharing.framework` still exports the whole C API on Darwin 27 [M]: `RFBConnectWithHostName`,
  `RFBFileCopy_CopyToServer`, `RFBPostDropEvent`, `RFBSendClipboard`, `RFBSetSharedPasteboard`, and classes such as
  `SSSession` and `SSSessionView`. The same command names as Mavericks suggest the protocol has lasted [I].
- Whether a third-party app can call it wasn't tried. The app itself holds private entitlements for its IDS and FaceTime
  paths [M]; a plain `vnc` session may not need them [I]. It's private API in the dyld cache and could change with any
  host update, so I'd use it only to read how it behaves.

### VM-aware code

There's little, and nothing that offers a user a feature:

- **Kernel [M]:** both have `cpuid_vmm_present`, `cpuid_vmm_family` and `cpuid_vmm_info`, and log `VMM vendor %u TSC
  frequency %u KHz`. Mojave also knows `Parallels` and has `kern.hv_support`, which is about being a host.
  **`kern.hv_vmm_present` is in neither**, so it arrived after 10.14 [I].
- **`AppleACPIPlatform`, `IOGraphicsFamily`, `AppleSMC`, `IOPCIFamily`:** no VMware or Parallels strings on either OS
  [M]. The hooks the question expected aren't there. (`IOPCIFamily` wasn't searched where it's bundled.)
- **Mavericks has no VM drivers at all [M].**
- **Mojave has real ones [M]:**
  - `AppleVirtIO` 2.1.3: `AppleVirtIOPCITransport`, `AppleVirtIOConsole` (which we already use), `AppleVirtIOBlock`, and
    **`AppleVirtIO9P`/`AppleVirtIO9PVFS` with `/sbin/mount_9p`**.
  - `AppleParavirtGPU`, which we use.
  - `AppleVirtualGraphics`, with framebuffers matching Bochs VGA (`1234:1111`) and Cirrus (`1013:*`).
  - **`AppleQEMUHID`** (`AppleQEMUHIDPointer`), a driver named for QEMU, on `IOHIDInterface`.
  - `/usr/libexec/AppleQEMUGuestAgent`, Apple's own QEMU guest agent, versioned with `AppleVirtIO-2.1.3`. It offers
    `guest-exec`, the `guest-file-*` family, `guest-network-get-interfaces` and `guest-shutdown`, among others. Mavericks
    has none.
  - `OSInstaller` has `isVirtualMachine`.
- **Big Sur** adds `AppleVirtIOSound`, per the note in `VIMLaunchPlan.swift`. The console's `AgentDevice` rename is
  noted in `guest-clipboard.m`.
- **Elsewhere [M]:** `com.vmware.fusion` in AppKit, `org.virtualbox.app.VirtualBox` in CoreFoundation, and
  `com.vmware.vm-package` in `FileStatsAgent`. These look like recognition of those apps as *host* software [I].
  `NVDAResman` mentions VMware and Parallels, and Mavericks's `ptmd` has `VMwareVMware`. I didn't trace either.

### 9P shared folder

- **The driver [M]:** speaks `9P2000`, `.u` and `.L`, and mounts by tag at `/Volumes/<tag>` (`mount_9p [-d] [-r]`).
- **Our QEMU can't offer it yet [M]:** `-device help` on the current runtime lists no `virtio-9p-pci`, and
  `scripts/qemu-build` doesn't pass `--enable-virtfs`. It needs a rebuild, and the flag's behaviour on this source tree
  is untested.
- **Practice:** Quickemu documents a `mount_9p <tag>` flow for macOS guests [I]. I found no public detail on Apple's
  driver.
- **Coverage is its limit:** no 10.9 driver [M], and earlier than Mojave is unmeasured. The SMB we have reaches every
  guest, so this only adds value for the password-free, network-free case.

### Sharing and bridging

- **SMB [M]:** `smbd` and `smbfs` are stock on both, and `VIMSMBService` plus a `hostfwd` to 445 is what we use. It
  stays.
- **NSSharingService [M]:** AppKit lists AirDrop, Mail and others, all acting inside the guest. There's no host-facing
  use.
- **Bonjour:** slirp won't carry mDNS [I], so we'd advertise from the host, as `VIMSMBService` does.
- **AirDrop on Ethernet [M]:** `BrowseAllInterfaces` is in `sharingd` and `Sharing.framework` on both. It still needs a
  multicast-capable network and a peer that speaks an old protocol. Handoff's frameworks (`UserActivity`, `Rapport`) are
  on Mojave only.
- **Windows and input [M]:** `CGWindowListCopyWindowInfo`, `AXIsProcessTrusted`, `AXUIElementCopyElementAtPosition` and
  `CGDisplayStreamCreate` are there on 10.9. On 10.14 `CGWindowList` forwards to SkyLight. Using them needs per-app
  Accessibility consent from Mavericks onward [I].
- **Virtual display [M]:** Mojave exports `CGVirtualDisplay`, with `hiDPI` and `applySettings:`. Mavericks has only
  `CGXVirtualDisplay*`, which isn't exported. Its pixels would still have to be captured and sent to the host from
  inside the guest.

### How others do it

- **Light Touch:** text only, gated on focus and recent input (`ClipboardSharing.swift`). `guest-clipboard` has the same
  model and scope, and #2 goes past both.
- **Parallels and older VMware:** a kit of installed tools provides copy and drag [Parallels docs]. A stock-only approach
  is Light Click's real advantage over this, since these tools don't reach most of the guests we run.
- **Virtualization.framework:** `macOSGuestAutomountTag` mounts a VirtioFS share automatically in macOS guests.
  Its documented clipboard route is the SPICE agent for Linux guests. I found no confirmed clipboard for macOS guests,
  and community reports call it weak [HN]. Treat that as unverified.

## Not checked

- Anything live, on any guest.
- Versions other than 10.9 and 10.14: Tiger through Mountain Lion, Yosemite through High Sierra, Catalina and Big Sur.
- The body layouts of `0x0e`, `0x1f`, `0x20` and `0x22`, past their first bytes.
- Whether a legacy VNC password or `kickstart` is enough on any version.

## Sources

- [noVNC issue 58: Apple's `003.889`](https://github.com/kanaka/noVNC/issues/58)
- [Apple Discussions: ARD protocol, types 30, 2 and 35, encodings 0x44C and 0x44D](https://discussions.apple.com/thread/2676183)
- [Gist: type 33 RSA](https://gist.github.com/barneygale/f5dfcb1dd87a0533aeb13bda798223f2)
- [Suricata RFB keywords: type 30](https://docs.suricata.io/en/suricata-7.0.12/_sources/rules/rfb-keywords.rst.txt)
- [Quickemu: virtio-9p and `mount_9p`](https://git.binarymagic.net/AIR/quickemu/commit/01fca96f283c984d91fe8cabad891b6a40d205f3)
- [`VZVirtioFileSystemDevice`](https://developer.apple.com/documentation/virtualization/vzvirtiofilesystemdevice.md)
- [Parallels Tools overview](https://docs.parallels.com/pdfm-ug-20/parallels-desktop-for-mac-20-users-guide/advanced-topics/installing-and-updating-parallels-tools/parallels-tools-overview)
- [HN thread on macOS guests (community, not authoritative)](https://hn.svelte.dev/item/47951037)
