#!/usr/bin/env python3
"""Map original application icons by bundle identity, independently of renamed icon resources."""
import hashlib
import json
import plistlib
import sys
import tarfile
from pathlib import Path

volume = Path(sys.argv[1]).resolve(strict=True)
version = plistlib.loads((volume/'System/Library/CoreServices/SystemVersion.plist').read_bytes())
if not version.get('ProductVersion', '').startswith('10.9.'):
    raise SystemExit('Requires the original Mavericks volume')
out = Path(__file__).resolve().parents[1]/'Build/mavericks-appearance/assets'
out.mkdir(exist_ok=True)
apps = ['App Store', 'Safari', 'Mail', 'Calendar', 'Contacts', 'Notes', 'Reminders', 'Maps',
        'System Preferences', 'TextEdit', 'Preview', 'Calculator', 'Messages', 'FaceTime',
        'Photo Booth', 'QuickTime Player', 'Automator', 'Dictionary', 'Font Book', 'iTunes', 'iBooks']
rows = []
with tarfile.open(out/'shell-icons.tar', 'w') as archive:
    for app in apps:
        bundle = volume/'Applications'/(app+'.app')
        info = plistlib.loads((bundle/'Contents/Info.plist').read_bytes())
        icon = info.get('CFBundleIconFile')
        if not icon:
            continue
        if not Path(icon).suffix:
            icon += '.icns'
        file = bundle/'Contents/Resources'/icon
        if not file.is_file() or not file.resolve().is_relative_to(volume):
            raise RuntimeError('Missing original declared icon: '+str(file))
        payload = 'icons/'+str(len(rows))+'.icns'
        archive.add(file, arcname=payload, recursive=False)
        rows.append({'app': '/Applications/'+('Books' if app=='iBooks' else app)+'.app',
                     'bundleID': info['CFBundleIdentifier'], 'source': str(file.relative_to(volume)),
                     'payload': payload, 'sha256': hashlib.sha256(file.read_bytes()).hexdigest()})
manifest = {'sourceSystem': version, 'icons': rows}
(out/'shell-icons.json').write_text(json.dumps(manifest, indent=2)+'\n')
print(json.dumps({'icons': len(rows), 'archiveBytes': (out/'shell-icons.tar').stat().st_size}))
