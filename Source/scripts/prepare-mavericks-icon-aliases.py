#!/usr/bin/env python3
"""Map original application icons by unique bundle identity, including case changes."""
import hashlib,json,plistlib
from pathlib import Path
base=Path(__file__).resolve().parents[1]/'Build/mavericks-appearance'
source=base/'original-installer';targets={};originals={}
for row in json.loads((base/'bundle-inventory.json').read_text()):targets.setdefault(row['identifier'].casefold(),[]).append(row)
for info in sorted(source.rglob('Contents/Info.plist')):
    try:data=plistlib.loads(info.read_bytes())
    except Exception:continue
    identifier=data.get('CFBundleIdentifier');name=data.get('CFBundleIconFile')
    if not identifier or not isinstance(name,str)or '/'in name:continue
    if not Path(name).suffix:name+='.icns'
    icon=info.parent/'Resources'/name
    if icon.is_file()and not icon.is_symlink():originals.setdefault(identifier.casefold(),[]).append((icon,data))
rows=[]
for identifier,items in sorted(originals.items()):
    candidates=targets.get(identifier,[])
    if len(items)!=1 or len(candidates)!=1:continue
    icon,data=items[0];target=candidates[0];name=target.get('icon')
    if not name or '/'in name:continue
    if not Path(name).suffix:name+='.icns'
    rows.append({'identifier':target['identifier'],'canonicalIdentifier':identifier,'contents':target['contents'],'sourceName':icon.name,'targetName':name,'sha256':hashlib.sha256(icon.read_bytes()).hexdigest(),'extension':icon.suffix})
p=base/'assets/icon-aliases.json';p.write_text(json.dumps({'icons':rows},indent=2)+'\n')
print(len(rows),'original icons mapped',p)
