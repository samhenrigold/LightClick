#!/usr/bin/env python3
"""Package image differences between the original installer and the updated reference.

The source trees contain locally extracted Apple assets; only the tooling is committed.
Bundle metadata is used to map renamed application icons in the destination OS.
"""
import hashlib,json,plistlib,tarfile
from pathlib import Path
base=Path(__file__).resolve().parents[1]/'Build/mavericks-appearance'
original=base/'original-installer';reference=base/'original'
extensions={'.icns','.png','.tiff','.tif','.jpg','.jpeg','.gif','.pdf','.clr'}
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
files=[];icons=[];by_source={}
for path in sorted(original.rglob('*')):
    if not path.is_file() or path.is_symlink():continue
    rel=path.relative_to(original);name=str(rel)
    if path.suffix.lower() not in extensions:continue
    if not name.startswith(('Applications/','System/Library/','Library/Desktop Pictures/')):continue
    if '/Resources/' not in name and not name.startswith('Library/Desktop Pictures/'):continue
    old=reference/rel
    sha=digest(path)
    if old.is_file() and digest(old)==sha:continue
    row={'source':name,'destination':'/'+name,'sha256':sha,'bytes':path.stat().st_size,'payload':'files/'+str(len(files))}
    files.append(row);by_source[name]=row
for info in sorted(original.rglob('Contents/Info.plist')):
    try:metadata=plistlib.loads(info.read_bytes())
    except Exception:continue
    icon=metadata.get('CFBundleIconFile');identifier=metadata.get('CFBundleIdentifier')
    if not isinstance(icon,str) or not identifier or '/' in icon:continue
    if not Path(icon).suffix:icon+='.icns'
    source=str((info.parent/'Resources'/icon).relative_to(original))
    if source in by_source:icons.append({'bundleContents':'/'+str(info.parent.relative_to(original)),'identifier':identifier,'source':source})
manifest={'source':'Mavericks 10.9.5 installer Essentials.pkg','files':files,'declaredIcons':icons}
out=base/'assets';out.mkdir(exist_ok=True)
(out/'installer-assets.json').write_text(json.dumps(manifest,indent=2)+'\n')
with tarfile.open(out/'installer-assets.tar.gz','w:gz')as archive:
    for row in files:archive.add(original/row['source'],arcname=row['payload'],recursive=False)
print(json.dumps({'files':len(files),'declaredIcons':len(icons),'bytes':(out/'installer-assets.tar.gz').stat().st_size}))
