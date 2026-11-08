#!/usr/bin/env python3
"""Package decoded original artwork, with hashes and semantic state tags, for the cloned guest.

Run extract-mavericks-assets.py and decode-mavericks-art.py first. Apple assets stay in Build/.
"""
import hashlib
import json
import struct
import tarfile
from pathlib import Path

base = Path(__file__).resolve().parents[1]/'Build/mavericks-appearance'
original = base/'original'
decoded = original/'decoded-art'
records = json.loads((decoded/'manifest.json').read_text())
retina = {row['base']: row['retina'] for row in json.loads((decoded/'retina-manifest.json').read_text())}
provenance = json.loads((decoded/'provenance.json').read_text())
for name, expected in provenance['sources'].items():
    if hashlib.sha256((original/name).read_bytes()).hexdigest() != expected:
        raise RuntimeError('Original archive changed: '+name)
files = []
for record in records:
    for scale, name in ((1, record['file']), (2, retina.get(record['file']))):
        if name is None:
            continue
        file = decoded/name
        data = file.read_bytes()
        if data[:8] != b'\x89PNG\r\n\x1a\n':
            raise RuntimeError('Invalid PNG: '+name)
        if struct.unpack_from('>II', data, 16) != (record['width']*scale, record['height']*scale):
            raise RuntimeError('Invalid rendition dimensions: '+name)
        files.append({'file': name, 'scale': scale, 'tags': record['tags'],
                      'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
out = base/'assets'
out.mkdir(exist_ok=True)
manifest = out/'render-art-manifest.json'
manifest.write_text(json.dumps({'source': provenance, 'files': files}, indent=2)+'\n')
with tarfile.open(out/'render-art.tar', 'w') as archive:
    for row in files:
        archive.add(decoded/row['file'], arcname=row['file'], recursive=False)
    archive.add(manifest, arcname='manifest.json', recursive=False)
print(json.dumps({'renditions': len(files), 'archive': str(out/'render-art.tar'),
                  'sha256': hashlib.sha256((out/'render-art.tar').read_bytes()).hexdigest()}))
