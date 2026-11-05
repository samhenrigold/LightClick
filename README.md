# Light Click

Light Click is a research fork of [Virtual Intel Mac](https://github.com/nfzerox/VirtualIntelMacOnAppleSilicon) by [nfzerox](https://github.com/nfzerox). Most of what is described here is the original project's work; see [Credits](#credits).

![Screenshot of Light Click](Source/screenshots/Virtual_Intel_Mac.png)

Light Click runs Intel versions of macOS, from Mac OS X Tiger 10.4 to macOS Big Sur 11, on Apple silicon with graphics acceleration. That lets you run older 32-bit and 64-bit Intel apps like iWork ’09, iLife ’11, Aperture, Final Cut Pro 7, and Front Row, or PowerPC apps like AppleWorks.

<p align="center">
  <a href="https://github.com/samhenrigold/LightClick/releases"><img width="250" src="Source/screenshots/assets/download.svg" alt="Download Light Click"></a>
</p>

It supports Metal and OpenGL acceleration, Retina resolution, live resizing, automatic setup, USB and audio passthrough, shared and bridged networking, file sharing, remote login, and clipboard sync.

Light Click is not affiliated with UTM, VirtualBuddy, Parallels Desktop, or Apple. It is released under the [MIT License](LICENSE).

## Status

Light Click is a research project. Only some of the guests listed below have been tested recently, so that list is what the project is meant to support, not a tested matrix. Support for macOS 28 and later, where Rosetta 2 is removed, is deferred.

## Building

You need Xcode for macOS 27 and Python 3.12 or later as `python3`. Set `<sha1>` to your own code signing identity.

```sh
cd Source
python3 -m venv Build/venv && Build/venv/bin/pip install meson==1.12.0 ninja==1.13.2   # first time
VIM_CODESIGN_IDENTITY=<sha1> Build/venv/bin/python3 scripts/build-app --jobs 10 --configuration Release \
    --output "$PWD/Build/Products/<name>/Light Click.app"
Build/venv/bin/python3 scripts/verify-release-build.py --app "<app>" --source "$PWD" --configuration Release
```

QEMU's build needs its source committed first. See [CLAUDE.md](CLAUDE.md) for more build and testing notes.

The Xcode project is [Source/LightClick.xcodeproj](Source/LightClick.xcodeproj). The app source is still in [Source/VirtualIntelMac](Source/VirtualIntelMac), and some internal and guest-facing names still say Virtual Intel Mac because installed guests and prebuilt firmware depend on them.

## Frequently Asked Questions

### Which versions of macOS guests can I run?

Mac OS X Tiger 10.4, Mac OS X Leopard 10.5, Mac OS X Snow Leopard 10.6, Mac OS X Lion 10.7, OS X Mountain Lion 10.8, OS X Mavericks 10.9, OS X Yosemite 10.10, OS X El Capitan 10.11, macOS Sierra 10.12, macOS High Sierra 10.13, macOS Mojave 10.14, macOS Catalina 10.15, and macOS Big Sur 11.

OpenGL acceleration is available in Tiger 10.4 up to High Sierra 10.13 guests for 32-bit and 64-bit apps. Metal and OpenGL acceleration are available in Mojave 10.14, Catalina 10.15, and Big Sur 11 guests for 64-bit apps. On Mojave, 32-bit apps currently run with software-based OpenGL.

To avoid potential account lockouts, signing into iCloud or an Apple Account is not supported. You can download apps from the web.

### Which versions of macOS do I need as the host?

macOS 27 Golden Gate, macOS Tahoe 26, or macOS Sequoia 15. Light Click is a Universal app, so it runs on both Apple silicon and Intel hosts.

### What kind of performance does Light Click offer?

These figures come from the original project and have not been re-measured for this fork.

On Apple silicon hosts, it uses hardware-accelerated graphics for GPU workloads and TCG emulation for CPU workloads. With the M4 chip, the original project reports roughly the same class of GPU performance as a MacBook Pro (15-inch, 2016) and CPU performance of a MacBook Air (11-inch, Late 2010). On Intel hosts, it reports near-native CPU and GPU performance.

### How long does it take to install macOS?

These estimates also come from the original project. Installing macOS generally takes about an hour, and may take up to 2 hours. Light Click then installs graphics drivers to enable Metal and OpenGL acceleration, which generally takes about 15 minutes, and may take up to 30 minutes.

The installer itself runs without Metal or OpenGL acceleration.

### What if I encounter crashes, bugs, or other issues?

First, [update to the latest version of Light Click](https://github.com/samhenrigold/LightClick/releases). If the issue remains, [open a GitHub issue on this fork](https://github.com/samhenrigold/LightClick/issues), not the original project, with clear reproduction steps, a screenshot or screen recording, and a diagnostics file from the in-app Settings > Export Diagnostics. If you find a fix, please [open a pull request](https://github.com/samhenrigold/LightClick/pulls).

## Screenshots

<p align="center">
  <a href="Source/screenshots/Virtual_Intel_Mac_Multi_Window.png"><img src="Source/screenshots/Virtual_Intel_Mac_Multi_Window.png" alt="Multiple virtual Mac windows" width="32%"></a>
  <a href="Source/screenshots/Virtual_Intel_Mac_Create_Version_Select.png"><img src="Source/screenshots/Virtual_Intel_Mac_Create_Version_Select.png" alt="Choose a macOS version" width="32%"></a>
  <a href="Source/screenshots/Virtual_Intel_Mac_Create_Configure.png"><img src="Source/screenshots/Virtual_Intel_Mac_Create_Configure.png" alt="Configure a new virtual Mac" width="32%"></a>
</p>
<p align="center">
  <a href="Source/screenshots/Virtual_Intel_Mac_Create_Download.png"><img src="Source/screenshots/Virtual_Intel_Mac_Create_Download.png" alt="Download and prepare macOS" width="32%"></a>
  <a href="Source/screenshots/Virtual_Intel_Mac_Library_Expanded.png"><img src="Source/screenshots/Virtual_Intel_Mac_Library_Expanded.png" alt="Expanded library view" width="32%"></a>
  <a href="Source/screenshots/Virtual_Intel_Mac_Library_Compact.png"><img src="Source/screenshots/Virtual_Intel_Mac_Library_Compact.png" alt="Compact library view" width="32%"></a>
</p>
<p align="center">
  <a href="Source/screenshots/Virtual_Intel_Mac_Mojave_Aperture.png"><img src="Source/screenshots/Virtual_Intel_Mac_Mojave_Aperture.png" alt="Aperture running in Mojave" width="32%"></a>
  <a href="Source/screenshots/Virtual_Intel_Mac_Mojave_iTunes.png"><img src="Source/screenshots/Virtual_Intel_Mac_Mojave_iTunes.png" alt="iTunes running in Mojave" width="32%"></a>
  <a href="Source/screenshots/Virtual_Intel_Mac_Mojave_Xcode_Carbon.png"><img src="Source/screenshots/Virtual_Intel_Mac_Mojave_Xcode_Carbon.png" alt="Building a 32-bit Carbon app with Xcode in Mojave" width="32%"></a>
</p>
<p align="center">
  <a href="Source/screenshots/Virtual_Intel_Mac_Catalina_Pages_Preview.png"><img src="Source/screenshots/Virtual_Intel_Mac_Catalina_Pages_Preview.png" alt="Pages and Preview running in Catalina" width="32%"></a>
  <a href="Source/screenshots/Virtual_Intel_Mac_Big_Sur_Keynote.png"><img src="Source/screenshots/Virtual_Intel_Mac_Big_Sur_Keynote.png" alt="Keynote running in Big Sur" width="32%"></a>
  <a href="Source/screenshots/Virtual_Intel_Mac_Configure_General.png"><img src="Source/screenshots/Virtual_Intel_Mac_Configure_General.png" alt="General virtual Mac configuration" width="32%"></a>
</p>
<p align="center">
  <a href="Source/screenshots/Virtual_Intel_Mac_Configure_Hardware.png"><img src="Source/screenshots/Virtual_Intel_Mac_Configure_Hardware.png" alt="Virtual Mac hardware configuration" width="32%"></a>
  <a href="Source/screenshots/Virtual_Intel_Mac_Configure_Sharing.png"><img src="Source/screenshots/Virtual_Intel_Mac_Configure_Sharing.png" alt="Virtual Mac sharing configuration" width="32%"></a>
  <a href="Source/screenshots/Virtual_Intel_Mac_Settings.png"><img src="Source/screenshots/Virtual_Intel_Mac_Settings.png" alt="Light Click settings" width="32%"></a>
</p>

## Technical Overview

Most of this design comes from the original project. For Tiger up to High Sierra guests, the [PassthroughOpenGL](Source/PassthroughOpenGL) implementation connects a compiled [GLD engine](Source/PassthroughOpenGL/passthrough-opengl-gli.c) to the host's [native hardware OpenGL executor](Source/PassthroughOpenGL/passthrough-opengl-host.c). [Generated dispatch marshalling](Source/scripts/generate-passthrough-opengl.py) carries the guest's OpenGL calls, while [shared-memory render targets](Source/PassthroughOpenGL/direct-vram-render-target-host.c) and [surface publication](Source/PassthroughOpenGL/direct-iosurface-writes.h) route graphics to the host. The [VMsvga2-derived guest drivers](Source/vendor/source/VMsvga2) supply framebuffer and surface integration.

Because the ParavirtualizedGraphics stack was first introduced in macOS Big Sur, enabling Metal in macOS Catalina and macOS Mojave guests means backporting its guest side support. Since AppleParavirtGPU depends on Big Sur's changes to surface cache ownership and release, it is transplanted together with IOSurface, IOAcceleratorFamily2 and IOGraphicsFamily, with newer kernel APIs shimmed using [`PVGKernelCompat`](Source/compat/PVGKernelCompat/PVGKernelCompat.cpp). Guest-side [IOSurface and accelerator ABI translations](Source/compat/PVGIOSurfaceABI/PVGIOSurfaceABI.cpp), [surface-limit fixes](Source/compat/PVGIOSurfaceABI/PVGSurfaceLimits.h), and [framebuffer initialization](Source/compat/PVGFramebufferBootstrap/PVGFramebufferBootstrap.cpp) bridge the older display stack. [MetalSerializer is then extracted](Source/scripts/build-metalserializer) from Big Sur's dyld shared cache using [dsce](Source/vendor/source/dsce), and rebuilt for the [older Objective-C runtime](Source/compat/PVGMojaveObjC.m), including [Mojave's pipeline descriptor serialization](Source/compat/PVGMojavePipelineSerialization.m).

Big Sur's compiler plugin is built against LLVM 31001, whose C++ layouts differ from the LLVM 3902 in Mojave and Catalina. To bridge them, [`PVGCompilerPluginBridge`](Source/compat/PVGCompilerPluginBridge/PVGCompilerPluginBridge.c) has the guest's LLVM serialize each shader as bitcode and Big Sur's LLVM parse it back, so both compilers run side by side in one process. The [Metal compatibility layer](Source/compat/PVGMetalCompat/PVGMetalCompat.m) adapts command encoding and library loading, with [completion-layout recognition](Source/compat/PVGMetalCompat/PVGCompletionSite.h) and a [shader cache](Source/compat/PVGMetalCompat/PVGShaderCache.h) for the older guest stack.

OpenGL acceleration comes from Big Sur's Metal-based OpenGL renderer, with [`PVGOpenGLMetal`](Source/compat/PVGOpenGLProbe/PVGOpenGLMetal.m) filling in the Metal and IOSurface APIs it expects and a [small registration driver](Source/compat/PVGOpenGLProbe/PVGOpenGLProbe.cpp) connecting it to the virtual accelerator. On Mojave, it pairs with Catalina's 64-bit OpenGL frontend, [merged](Source/scripts/stage-opengl-universal.py) with Mojave's 32-bit slice to enable acceleration in 64-bit apps while also retaining software rendering for 32-bit apps. Its built-in shaders are [downgraded](Source/scripts/opengl-downgrade-builtins) to Mojave's AIR 2.1, while [pixel-buffer lifetime compatibility](Source/compat/PVGOpenGLProbe/PVGCGLPBufferCompat.m) handles older CGL clients.

On Apple silicon, the arm64e slice of ParavirtualizedGraphics uses a different wire protocol compared to the x86_64 slice; therefore, the Intel slice is run through an [x86_64 helper](Source/vendor/qemu/hw/display/apple-gfx-helper.m) under Rosetta 2 while [sharing guest memory](Source/vendor/qemu/hw/display/apple-gfx.m) with arm64 QEMU. Since Metal rejects buffers spanning fragmented 4 KB guest pages on a 16 KB page host, the helper [shadows them with GPU scatter and gather blits](Source/vendor/qemu/hw/display/apple-gfx-legacy-shadow.m). This helper depends on Rosetta 2, so it will need replacing for macOS 28 and later.

To make x86 emulation faster and improve guest UI responsiveness, changes are also made to QEMU to [keep translations and page table lookups across guest context switches](Source/vendor/qemu/accel/tcg/cputlb.c) and [cache indirect jump targets inline](Source/vendor/qemu/tcg/aarch64/tcg-target.c.inc). It also [executes packed SSE arithmetic natively](Source/vendor/qemu/target/i386/tcg/emit.c.inc) on Apple silicon. Additional QEMU optimizations are made to reduce [audio skips and crackling](Source/vendor/qemu/hw/audio/hda-codec.c), as well as improve [USB passthrough](Source/USBHelper/main.m) and [networking support](Source/NetworkHelper/main.m).

## Credits

Light Click is a fork of [Virtual Intel Mac](https://github.com/nfzerox/VirtualIntelMacOnAppleSilicon) by [nfzerox](https://github.com/nfzerox), who wrote the original project. Virtual Intel Mac was made possible by learnings from building [Virtual Mac on iPad](https://github.com/nfzerox/VirtualMacOniPad), advances in agentic coding, and these open source projects:

- [QEMU](https://www.qemu.org) provides x86_64 emulation and the `apple-gfx-pci` device that connects Intel guests to Apple's paravirtualized graphics framework.
- [dsce](https://github.com/moraea/dsce) makes it possible to extract loadable x86_64 libraries from Big Sur's and macOS 26's dyld shared caches.
- [reims-vgpu](https://github.com/steelbrain/reims-vgpu) provides a reference for the paravirtualized graphics protocol.
- [Lilu](https://github.com/acidanthera/Lilu) and [MacKernelSDK](https://github.com/acidanthera/MacKernelSDK) underpin this project's kernel compatibility extensions.
- [OpenCore](https://github.com/acidanthera/OpenCorePkg) and [OpenCore-ISO](https://github.com/LongQT-sea/OpenCore-ISO) boot macOS in QEMU.
- [macos-iso-builder](https://github.com/LongQT-sea/macos-iso-builder) informs this project's installer media assembly.
- [VoodooHDA](https://sourceforge.net/projects/voodoohda/) brings sound to Tiger through Catalina guests.
- [EDK II](https://github.com/tianocore/edk2) provides the UEFI firmware and libraries used by the boot-policy driver.
- [UTM](https://github.com/utmapp/UTM) provides references for split process graphics, networking and USB integration on macOS.
- [OpenSSH Portable](https://www.openssh.org/portable.html) and [LibreSSL](https://www.libressl.org) provide the isolated SSH client for older OS X guests, without changing the host's SSH security policy.
- [JSONKit](https://github.com/johnezang/JSONKit) provides JSON serialization for Snow Leopard's guest-control tools, outside the graphics hot path.
- [Samba](https://www.samba.org) supplies SMB compatibility components for older guests.
- The native SMB client backports include software developed by [Boris Popov](https://github.com/apple-oss-distributions/smb), with Apple's Darwin8/9 filesystem interfaces preserved.
- [libusb](https://libusb.info) and [usbredir](https://www.spice-space.org/usbredir.html) provide the USB capture and redirection libraries used by the USB helper.
- [XZ Utils](https://tukaani.org/xz/) provides compression for the bundled guest payloads.
- [VMsvga2](https://sourceforge.net/projects/vmsvga2/) by Zenith432 provides the framebuffer and surface-driver foundation for PassthroughOpenGL.
- [gfxCardStatus](https://github.com/codykrieger/gfxCardStatus) informs the physical-reference-only Intel GPU selection probe, not the shipped VM runtime.
