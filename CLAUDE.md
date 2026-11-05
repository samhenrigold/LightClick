# Working in Light Click

A research fork of Virtual Intel Mac.

## Building

    cd Source
    python3 -m venv Build/venv && Build/venv/bin/pip install meson==1.12.0 ninja==1.13.2   # first time
    VIM_CODESIGN_IDENTITY=<sha1> Build/venv/bin/python3 scripts/build-app --jobs 10 --configuration Release \
        --output "$PWD/Build/Products/<name>/Light Click.app"
    Build/venv/bin/python3 scripts/verify-release-build.py --app "<app>" --source "$PWD" --configuration Release

- Signing: set `VIM_CODESIGN_IDENTITY` to an Apple Development identity for daily builds and a Developer ID
  Application identity for releases.
- QEMU's build needs its source committed first.
- Run in Xcode embeds the runtime from the newest app in `Build/Products`, so run `scripts/build-app` once first. USB
  capture and the networking that needs a privileged helper only work in a packaged app.
- Don't change `compat/PassthroughOpenGLBootPolicy.h`, `scripts/build_signing.py` or the other files listed in
  `inputs()` in `scripts/build-opengl-opencore.py` unless you rebuild the prebuilt OpenCore payload; it pins their bytes.

## Notarizing

`scripts/notarize <release folder>` reads `LTM_NOTARY_KEY`, `LTM_NOTARY_KEY_ID` and `LTM_NOTARY_ISSUER` from the
environment or `~/.config/lighttouch/notary.env` (mode 600). Never commit their values.

## Testing

Test only what a change could actually break, and be sparing: no broad suites or test gates. Prefer one script, then
`scripts/test-launch-plan` and `scripts/test-guest-profile` when those areas change. Never boot the real library;
`scripts/boot-clone` boots an APFS clone in a private home, though preferences stay shared with the real app. In `pgrep`, use `-x`, since `-f` matches its own shell.

## Conventions

- `scripts/format` applies Light Touch's rules. `vendor/` and `prebuilt/` stay as they are.
- Commit and push each change, on a branch. Stage files by name and check `git status` afterward.
- Keep guest-facing names such as `/Library/Application Support/Virtual Intel Mac/GuestTools`,
  `com.mac.virtualintelmac.opengl-agent` and the `org.virtualintelmac` fw_cfg entries: installed guests and prebuilt
  firmware depend on them.
- No compiler version guards. Language mode stays Swift 6.
- macOS 28 and Rosetta's removal are deferred.
