#!/usr/bin/env python3
"""Package original Mavericks appearance assets extracted into Build/mavericks-appearance/original.
Creates a manifest and tar for an explicitly cloned Mojave guest. Unmatched files are retained as references.
No executables, nibs, preference files, app data or frameworks are transplanted.
"""
import hashlib,json,tarfile
from pathlib import Path
source=Path(__file__).resolve().parents[1]
original=source/'Build/mavericks-appearance/original'
output=source/'Build/mavericks-appearance/assets';output.mkdir(exist_ok=True)
apps={'Safari','Mail','Reminders','Notes','Messages','Calendar','Contacts','Preview','TextEdit','Calculator','System Preferences','App Store','Automator','Dictionary','Font Book','QuickTime Player','Photo Booth','iTunes','iBooks','Maps','FaceTime','Launchpad','Mission Control','Dashboard'}
items=[]
for file in sorted(original.rglob('*')):
    if not file.is_file():continue
    rel=file.relative_to(original);name=str(rel);dest='/'+name;reason=None
    if name.startswith('System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/') and file.suffix=='.icns':reason='system icon'
    if name.startswith('System/Library/CoreServices/Finder.app/Contents/Resources/') and file.suffix=='.icns':reason='Finder icon'
    if name.startswith('Applications/') and len(rel.parts)==5 and rel.parts[1].removesuffix('.app') in apps and file.suffix=='.icns':reason='application icon'
    if name.startswith('System/Library/CoreServices/Dock.app/Contents/Resources/') and file.suffix in ('.icns','.png'):reason='Dock artwork'
    if name.startswith('System/Library/Frameworks/ApplicationServices.framework/') and '/cursors/' in name and file.suffix in ('.tiff','.png','.pdf'):reason='cursor artwork'
    if name=='System/Library/Fonts/LucidaGrande.ttc':dest='/Library/Application Support/MavericksAppearance/Fonts/LucidaGrande.ttc';reason='original UI font'
    if name=='Library/Desktop Pictures/Wave.jpg':dest='/Library/Desktop Pictures/Mavericks Wave.jpg';reason='wallpaper'
    if not reason:continue
    items.append({'source':name,'destination':dest,'kind':reason,'bytes':file.stat().st_size,'sha256':hashlib.sha256(file.read_bytes()).hexdigest()})
with tarfile.open(output/'original-assets.tar','w') as tar:
    for i,row in enumerate(items):
        row['payload']='files/'+str(i)
        tar.add(original/row['source'],arcname=row['payload'],recursive=False)
manifest={'source_system':'Mavericks 10.9.5 13F1911','files':items}
(output/'manifest.json').write_text(json.dumps(manifest,indent=2))
print(len(items),'mapped original assets',sum(i['bytes'] for i in items),'bytes')
