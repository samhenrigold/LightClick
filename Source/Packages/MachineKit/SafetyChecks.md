# MachineKit's safety and consistency checks

Each check ported from `VIMMachine.m`, `VIMGuestTransactionEvidence.h`, `VIMOpenGLRestartEvidence.h`, `VIMSession.m` and
`VIMNetworkDefaults.m`, or left in Objective-C. Tests are in `Tests/MachineKitTests`.

## Evidence comparison

- Two missing values never match: `[nil isEqual:nil]` is NO, and `Optional.isEqual` keeps that where `==` wouldn't.
- Equality is `isEqual:`. `true`, `1` and `1.0` compare equal; strings compare literally, not canonically.
- JSON null in a report is present and not true, so it fails a check that a missing key passes.

## Machine.plist (`validate(package:)`, `hasValidSettings`)

- `FormatVersion` is 1; `Guest` is supported; `Identifier` is a UUID; `Name` and the package name are valid.
- `CPUCount` is 1 to 64 and `MemoryMiB` is 1024 to 1048576, both whole numbers.
- `BootMediaKind` and `InstallerMediaKind` are known values.
- `InstallerMedia` needs `installing` or `patching`, and is either `Installation/Installer.iso` or absolute with
  `InstallerMediaShared` exactly true. A shared installer must be a regular file, not a link.
- `Disk`, `NVRAM`, `InstallerMedia`, and with non-application firmware `Firmware` and `BootMedia`, are non-empty,
  relative, regular files that stay inside the package after `..` and symlinks resolve.
- `State` is a real folder, not a link.
- Ports are whole numbers from 1024 to 65535, required when enabled, distinct when both are enabled.
- Booleans are numbers equal to 0 or 1. `NetworkMode`, `DisplayMode`, `DisplayScalingFilter` and
  `ExecutionEngine` are known values.
- Lengths in UTF-16 units: `BridgeInterface` 64, `Description` 4096, audio devices 1024.
- `OpticalMedia` and each `AdditionalMedia` are empty or absolute, with fewer than `imageSlotCount` additional images.
- `MACAddress` has the exact shape, so nothing can be injected into emulator arguments, and is unicast and non-zero.

## Names and paths

- A name is 1 to 128 UTF-16 units with something besides whitespace.
- A rename has no slash, colon, newline or leading dot. Package names replace those characters, avoid a leading dot, and
  never collide.
- Prepared media can be deleted only under `<UUID>/Media`, in `Downloads/Preparation` or in this library's `Installers`.

## Pending edits

- Only the 20 editable keys can be queued. `Disk`, `InstallerMedia` and the like can't be redirected through an edit.
- Publishing refuses a whole file with an unsupported key. A settings window ignores those keys and shows the launch
  snapshot if the result is invalid.
- A malformed rename request doesn't fall back to a legacy `Name`.

## Install state

- A classic restart retires installer routing before restarting. Classic completion is refused with an installer
  attached.
- Shared media is detached and all three keys are removed. Owned media keeps its original `InstallerMediaShared`
  handling.
- Installer ownership: identifier and media must match the record, and owned cleanup needs the exact `Installer.iso`
  record.

## Guest evidence

- Automatic installation: PVG guest, `installing`, installer attached, same guest, live desktop, live root, matching
  kernel, complete identity.
- Update repair: same guest, live installed system, complete identity, and a build usable as a filename (128 units,
  no path or leading dot). It deliberately doesn't require a desktop.
- A verified installation is superseded only with every one of: format 1; UUID transaction; a terminal phase, or
  `outcome-unknown` with a recorded read error; published, reboot-required result; transaction IDs agreeing in all three
  records; post-reboot and Metal proof; PVG guest matching preparation; a new build; the old build agreeing in all three
  records; the same volume in all three; a different boot.
- Repair recovery: read-failure journal, claim still `claimed`, matching machine, transaction, build, volume and target.
- Published graphics: transaction agreeing across records, matching guest, build and volume, files published.
- Updater display hold: released only by a new-build, same-volume publish in a different transaction. The baseline is
  recorded only from verified evidence.
- Native Big Sur display: all report evidence, a UUID volume and boot, a 40-unit alphanumeric build, once per volume. It
  never marks graphics or installation complete.
- Installer cleanup: `graphics-verified`, post-reboot and Metal proof for this transaction, live system, same guest,
  volume and build. Previous verification doesn't count.
- OpenGL setup: pre-Metal guest, ownership verified, matching kernel, machine, volume, build; a UUID boot; `installed`
  phase; pixels for completion but not restart; Tiger's file verification; first-login handoff when enabled.
- OpenGL resume: never after an explicit authorization failure. Bundled support needs both hashes, and the restart
  evidence version except on Tiger. A restart record satisfies only the exact pair, build, machine and volume.
- Session: completion report staleness, live installed system, boot policy admission, repair restart of only the
  repaired boot, preparation and reconciliation admission, reconciliation of this boot, console user at least 501 and
  the expected UID.

## Left in Objective-C

These stay in `VIMMachine.m` because they need the file system: `flock` on `Session.lock` and `Configuration.lock`,
refusing links (`O_NOFOLLOW`, one hard link), exclusive claim creation, journal-before-config ordering, media size
against its record, references from other machines, the installer path's symlink check, disk creation and import checks,
and `saveAutomaticSetup:`'s validation with `VIMAutomaticSetup`.

## Not wired yet

Ported and tested, but the app still uses its own copy:

- `VIMSession.m`: only completion staleness, live installed system and preparation admission call MachineKit, to keep
  that file's diff small. Boot policy, reconciliation and console user checks are unchanged there.
- `VIMHostAudio.h` display mode, `VIMNetworkDefaults.m` MAC checks and forwarding defaults, and `VIMLibraryLocation`:
  they have other callers and weren't needed to shrink `VIMMachine.m`.
- `machine.configuration` remains an `NSDictionary` for its Objective-C callers.

## Behavior differences

- A value of the wrong type nested inside a report or journal, such as a string for `GuestResult`, now refuses. It was
  an unrecognized-selector exception.
- `saveSettings:` checks for an unsupported key under the configuration lock, so a held lock reports first.
- `Codable` reads `<real>4</real>` as an integer. `init(propertyList:)` and `propertyList()` are exact and are what
  files should use.
