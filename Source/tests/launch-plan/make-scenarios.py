#!/usr/bin/env python3
"""Write scenarios.json, the launch matrix shared by the baseline and the test."""
import json
from pathlib import Path

GUESTS = ['tiger', 'leopard', 'snowleopard', 'lion', 'mountainlion', 'mavericks', 'yosemite',
          'elcapitan', 'sierra', 'highsierra', 'mojave', 'catalina', 'bigsur']
PRE_METAL = GUESTS[:10]
ID = '7F3A1C52-9B1E-4D6A-8C37-0A1B2C3D4E5F'


def scenario(name, guest, silicon=True, config=None, **fields):
    base = {'Guest': guest, 'Identifier': ID, 'CPUCount': 4, 'MemoryMiB': 4096, 'InstallState': 'installed',
            'Disk': 'Disk.qcow2', 'NVRAM': 'NVRAM.fd'}
    return {'name': name, 'guest': guest, 'appleSilicon': silicon, 'machineName': 'Test Mac',
            'machinePath': '/Fixture/Library/Test.virtualmac', 'config': {**base, **(config or {})},
            'argv': [], 'inherited': {'HOME': '/Fixture/Home'}, 'displayMode': 'scaled', 'backingScale': 2.0,
            'supportsRetina': True, 'refreshMS': 0, 'research': False, 'installerDisplay': False,
            'hasGraphics': False, 'signatureOnly': False, 'inprocessLibrary': None, 'setupMedia': None,
            'audioOut': 'default', 'audioIn': 'default', 'audioDevices': {}, **fields}


INSTALLING = {'InstallState': 'installing', 'InstallerMedia': 'Installer.iso'}
OPENGL = {'LegacyDisplayAdapter': 'vmware', 'PassthroughOpenGLEnabled': True}
scenarios = []
for guest in GUESTS:
    for silicon, host in ((True, 'arm'), (False, 'intel')):
        scenarios.append(scenario(f'{guest}-{host}-installed', guest, silicon))
        scenarios.append(scenario(f'{guest}-{host}-installing', guest, silicon, INSTALLING, installerDisplay=True))
        if guest in PRE_METAL:
            scenarios.append(scenario(f'{guest}-{host}-opengl', guest, silicon, OPENGL, installerDisplay=True,
                                      inprocessLibrary='/Fixture/libHost.dylib', displayMode='retina'))
            scenarios.append(scenario(f'{guest}-{host}-setup-media', guest, silicon, {**INSTALLING, **OPENGL},
                                      installerDisplay=True, setupMedia='/Fixture/Setup Media.iso'))

for guest in ('tiger', 'mavericks', 'catalina', 'bigsur'):
    def variant(name, config=None, **fields):
        scenarios.append(scenario(f'{guest}-{name}', guest, fields.pop('silicon', True), config, **fields))
    variant('sharing', {'SSHEnabled': True, 'SSHPort': 2222, 'FileSharingEnabled': True, 'FileSharingPort': 4450})
    variant('host-network', {'SSHEnabled': True, 'SSHPort': 2222}, networkMode='host')
    variant('unplugged', {'NetworkConnected': False})
    variant('plugged', {'NetworkConnected': True})
    variant('no-audio', {'AudioEnabled': False})
    variant('audio-on', {'AudioEnabled': True})
    variant('mic-off', audioIn='disabled')
    variant('speaker-off', audioOut='disabled')
    variant('devices', audioOut='uid-out', audioIn='uid-in', audioDevices={'uid-out': 'Studio Display', 'uid-in': 'USB Mic'})
    variant('optical-iso', {'OpticalMedia': '/Media/Disc, One.iso'})
    variant('optical-dmg', {'OpticalMedia': '/Media/Tools.dmg'})
    variant('optical-missing', {'OpticalMedia': '/Media/missing.iso'})
    variant('images', {'AdditionalMedia': ['/Media/A.dmg', '', '/Media/B, two.iso']})
    variant('images-missing', {'OpticalMedia': '/Media/C.iso', 'AdditionalMedia': ['/Media/missing.dmg', '/Media/D.dmg']})
    variant('installer-disk', {**INSTALLING, 'InstallerMediaKind': 'disk'})
    variant('installer-shared', {**INSTALLING, 'InstallerMedia': '/Shared/Install, Mac.iso', 'InstallerMediaShared': True})
    variant('diagnostics', argv=['--trace-network', '--trace-cursor', '--trace-image-enumeration',
                                 '--firmware-diagnostics', '--trace-hda-codec', '--record-network-history'])
    variant('development-tcg', silicon=False, argv=['--development-tcg'])
    variant('guest-efi', argv=['--guest-efi', '/Fixture/Override.img'])
    variant('disk-nvme', argv=['--system-disk-interface', 'nvme'])
    variant('disk-sata', argv=['--system-disk-interface', 'sata'])
    variant('expose-x2apic', argv=['--expose-x2apic'])
    variant('signature-only', signatureOnly=True)
    variant('published-graphics', hasGraphics=True)
    variant('import-prepared', {'InstallState': 'imported-prepared'})
    variant('research-gdb', {'LegacyGDBPort': 1234}, research=True)
    variant('gdb-not-research', {'LegacyGDBPort': 1234})
    variant('commas', machineName='Mac, Old', machinePath='/Fixture/Lib, rary/Test.virtualmac')
    variant('commas-diagnostics', machinePath='/Fixture/Lib, rary/Test.virtualmac', argv=['--firmware-diagnostics'])
    variant('engine-on', {'ExecutionEngine': 'on'})
    variant('engine-off', {'ExecutionEngine': 'off'})
    variant('engine-on-nine-cpus', {'ExecutionEngine': 'on', 'CPUCount': 9})
    variant('engine-meltdown-on', {'ExecutionEngine': 'on', 'MeltdownProtection': 'on'})
    variant('engine-meltdown-off', {'ExecutionEngine': 'on', 'MeltdownProtection': 'off'})
    variant('engine-meltdown-on-intel', {'ExecutionEngine': 'on', 'MeltdownProtection': 'on'}, silicon=False)
    variant('engine-on-intel', {'ExecutionEngine': 'on'}, silicon=False)
    variant('engine-env-wins', {'ExecutionEngine': 'on'}, inherited={'HOME': '/Fixture/Home', 'LC_HVDBT': '0'})
    variant('engine-env-only', inherited={'HOME': '/Fixture/Home', 'LC_HVDBT': '1', 'LC_HVDBT_TALLY': '/tally'})
    variant('leaked-environment', inherited={
        'HOME': '/Fixture/Home', 'PVG_TCG_TSO': '1', 'PVG_STALE': '1', 'DYLD_INSERT_LIBRARIES': '/evil.dylib',
        'VIM_AUDIO_OUTPUT_DEVICE': 'Stale', 'VIM_AUDIO_INPUT_DEVICE': 'Stale', 'VIM_E1000_LINK_HISTORY': '1',
        'VIM_INSTALLER_DISPLAY_SOCKET': '/stale', 'VIM_DISPLAY_REFRESH_MS': '99'})

SCREEN = {'ScreenSharingEnabled': True, 'ScreenSharingPort': 5901}
for guest in ('leopard', 'mavericks', 'mojave', 'bigsur'):
    scenarios.append(scenario(f'{guest}-screen-sharing', guest, config=SCREEN))
    scenarios.append(scenario(f'{guest}-screen-sharing-off', guest, config={**SCREEN, 'ScreenSharingEnabled': False}))
    scenarios.append(scenario(f'{guest}-screen-sharing-host-network', guest, config=SCREEN, networkMode='host'))
    scenarios.append(scenario(f'{guest}-screen-sharing-all-forwards', guest, config={
        **SCREEN, 'SSHEnabled': True, 'SSHPort': 2222, 'FileSharingEnabled': True, 'FileSharingPort': 4450}))

for guest in ('tiger', 'mavericks', 'highsierra'):
    for mode, scale, explicit in (('retina', 1.0, True), ('retina', 1.0, False), ('scaled', 2.0, False), ('scaled', 1.0, False)):
        config = {**OPENGL, **({'DisplayMode': mode} if explicit else {})}
        scenarios.append(scenario(f'{guest}-panel-{mode}-{scale:g}x-{"explicit" if explicit else "implicit"}', guest, True, config,
                                  installerDisplay=True, inprocessLibrary='/Fixture/libHost.dylib', displayMode=mode, backingScale=scale))
    scenarios.append(scenario(f'{guest}-panel-unsupported', guest, True, OPENGL, installerDisplay=True, supportsRetina=False, displayMode='retina'))
    scenarios.append(scenario(f'{guest}-opengl-not-inprocess', guest, True, OPENGL, installerDisplay=True, refreshMS=8))
    scenarios.append(scenario(f'{guest}-refresh-out-of-range', guest, True, OPENGL, installerDisplay=True, refreshMS=2000))
    scenarios.append(scenario(f'{guest}-installer-std-display', guest, True, {'LegacyDisplayAdapter': 'std'}, installerDisplay=True))
    scenarios.append(scenario(f'{guest}-inprocess-environment', guest, True, OPENGL, installerDisplay=True, inprocessLibrary='/Fixture/libHost.dylib',
                              inherited={'VIM_PASSTHROUGH_OPENGL_INLINE': '0', 'VIM_OPENGL_VRAM_SERVICE': 'kept', 'VIM_OPENGL_VRAM_ENDPOINT': ''}))
    scenarios.append(scenario(f'{guest}-research-firmware', guest, True, {'FirmwareSource': 'package', 'BootMedia': 'EFI.img', 'Firmware': 'CODE.fd'}, research=True))
    scenarios.append(scenario(f'{guest}-research-haswell', guest, False, research=True, argv=['--opengl-cpu-model', 'haswell']))
    scenarios.append(scenario(f'{guest}-research-penryn', guest, False, research=True, argv=['--opengl-cpu-model', 'penryn']))

for item in scenarios:
    if item['research']:
        item['config'].setdefault('FirmwareSource', 'application')
Path(__file__).with_name('scenarios.json').write_text(json.dumps(scenarios, indent=1, sort_keys=True)+'\n')
print(len(scenarios), 'scenarios')
