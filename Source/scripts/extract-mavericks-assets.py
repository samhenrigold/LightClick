#!/usr/bin/env python3
"""Copy appearance resources from a read-only Mavericks volume into the local experiment.

Usage: extract-mavericks-assets.py MOUNT [--verify-existing]
Never mounts or boots an original machine, and never copies executable code.
"""
import argparse
import hashlib
import json
import os
import plistlib
import shutil
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('mount', type=Path)
parser.add_argument('--verify-existing', action='store_true')
args = parser.parse_args()
volume = args.mount.resolve(strict=True)
version = plistlib.loads((volume/'System/Library/CoreServices/SystemVersion.plist').read_bytes())
if not version.get('ProductVersion', '').startswith('10.9.'):
    raise SystemExit('Requires a Mavericks source volume')
if not os.statvfs(volume).f_flag & os.ST_RDONLY:
    raise SystemExit('Source volume must be mounted read-only')
out = Path(__file__).resolve().parents[1]/'Build/mavericks-appearance/original'
out.mkdir(parents=True, exist_ok=True)
extensions = {'.png', '.icns', '.tiff', '.tif', '.jpg', '.pdf', '.ttf', '.ttc', '.otf', '.dfont'}
records = []

def collect(file, relative):
    # Resolve only inside the source volume; absolute resource symlinks must not read the host.
    resolved = file.resolve(strict=True)
    if not resolved.is_relative_to(volume):
        raise RuntimeError('Resource link leaves source volume: '+str(file))
    data = resolved.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    destination = out/relative
    if destination.exists():
        if hashlib.sha256(destination.read_bytes()).hexdigest() != digest:
            raise RuntimeError('Existing extraction differs: '+str(relative))
    elif args.verify_existing:
        raise RuntimeError('Missing extraction: '+str(relative))
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(resolved, destination)
    return {'path': '/'+str(file.relative_to(volume)), 'bytes': len(data), 'sha256': digest}

for directory in ('Applications', 'System', 'Library/Desktop Pictures'):
    for root, dirs, names in os.walk(volume/directory, followlinks=False):
        dirs[:] = sorted(d for d in dirs if not (Path(root)/d).is_symlink())
        for name in sorted(names):
            file = Path(root)/name
            if file.suffix.lower() in extensions and not file.is_symlink():
                records.append(collect(file, file.relative_to(volume)))
archives = []
for name in ('ArtFile.bin', 'ArtFile200.bin', 'SArtFile.bin'):
    file = volume/'System/Library/PrivateFrameworks/CoreUI.framework/Versions/A/Resources'/name
    archives.append(collect(file, Path(name)))
records.sort(key=lambda row: row['path'])
if not args.verify_existing:
    (out/'manifest.json').write_text(json.dumps(records, indent=2)+'\n')
(out/'source.json').write_text(json.dumps({
    'system': version, 'volumeReadOnly': True, 'assetCount': len(records),
    'archives': archives, 'extractorSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
}, indent=2)+'\n')
print(json.dumps({'verified': args.verify_existing, 'assets': len(records), 'archives': len(archives)}))
