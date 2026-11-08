#!/usr/bin/env python3
"""Map original installer artwork to Mojave bundles by identity, including renamed apps.

The inventory is read from an owned Mojave experiment; Apple images remain local
Build artifacts. Exact identity is required, and ambiguous identities are skipped.
"""
import argparse,hashlib,json,plistlib,tarfile
from pathlib import Path
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('inventory',type=Path)
args=parser.parse_args()
base=Path(__file__).resolve().parents[1]/'Build/mavericks-appearance'
original=base/'original-installer';targets={};sources={}
for row in json.loads(args.inventory.read_text()):targets.setdefault(row['identifier'],[]).append(row)
for info in sorted(original.rglob('Contents/Info.plist')):
    try:metadata=plistlib.loads(info.read_bytes())
    except Exception:continue
    identifier=metadata.get('CFBundleIdentifier')
    if identifier:sources.setdefault(identifier,[]).append((info.parent,metadata))
files=[];icons=[];mapped=[];ambiguous=[];destinations=set()
extensions={'.icns','.png','.tiff','.tif','.jpg','.jpeg','.gif','.pdf','.clr'}
def add(path,destination,contents,identifier):
    if destination in destinations:return
    destinations.add(destination)
    data=path.read_bytes();files.append({'source':str(path.relative_to(original)),'destination':destination,'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data),'payload':'files/'+str(len(files)),'bundleContents':contents,'identifier':identifier})
for identifier,candidates in sorted(sources.items()):
    destinations_for_id=targets.get(identifier,[])
    if not destinations_for_id:continue
    if len(candidates)!=1 or len(destinations_for_id)!=1:ambiguous.append(identifier);continue
    contents,metadata=candidates[0];target=destinations_for_id[0];destination=target['contents']
    if not destination.startswith(('/Applications/','/System/Library/')) or '..'in destination.split('/'):raise ValueError('Invalid inventory destination')
    source_contents='/'+str(contents.relative_to(original))
    old_icon=metadata.get('CFBundleIconFile');new_icon=target.get('icon')
    if isinstance(old_icon,str)and isinstance(new_icon,str)and'/'not in old_icon and'/'not in new_icon:
        if not Path(old_icon).suffix:old_icon+='.icns'
        if not Path(new_icon).suffix:new_icon+='.icns'
        source=contents/'Resources'/old_icon
        if source.is_file()and not source.is_symlink():
            dst=destination+'/Resources/'+new_icon
            add(source,dst,destination,identifier)
            icons.append({'bundleContents':destination,'identifier':identifier,'source':str(source.relative_to(original))})
    # Existing same-path resources were already installed by the full volume pass.
    if destination==source_contents:continue
    count=0
    for path in sorted((contents/'Resources').rglob('*')):
        if not path.is_file()or path.is_symlink()or path.suffix.lower()not in extensions:continue
        rel=path.relative_to(contents/'Resources')
        if any(part.endswith(('.app','.bundle','.framework','.plugin','.prefPane'))for part in rel.parts):continue
        add(path,destination+'/Resources/'+str(rel),destination,identifier);count+=1
    mapped.append({'identifier':identifier,'source':source_contents,'target':destination,'images':count})
manifest={'source':'Mavericks 10.9.5 installer, bundle-identity mapping','files':files,'declaredIcons':icons,'mappedBundles':mapped,'ambiguous':ambiguous}
out=base/'assets';out.mkdir(exist_ok=True)
(out/'bundle-assets.json').write_text(json.dumps(manifest,indent=2)+'\n')
with tarfile.open(out/'bundle-assets.tar.gz','w:gz')as archive:
    for row in files:archive.add(original/row['source'],arcname=row['payload'],recursive=False)
print(json.dumps({'files':len(files),'mappedBundles':len(mapped),'bundlesWithArtwork':sum(int(r['images']>0)for r in mapped),'ambiguous':len(ambiguous),'bytes':(out/'bundle-assets.tar.gz').stat().st_size}))
