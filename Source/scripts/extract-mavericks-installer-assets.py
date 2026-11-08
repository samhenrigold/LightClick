#!/usr/bin/env python3
"""Extract original image resources from read-only mounted InstallESD and BaseSystem.

Usage: extract-mavericks-installer-assets.py INSTALL_ESD_VOLUME BASE_SYSTEM_VOLUME
Then run prepare-mavericks-installer-assets.py. No executable payload is extracted.
"""
import argparse,hashlib,json,os,plistlib,shutil,subprocess
from pathlib import Path
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('installer',type=Path);parser.add_argument('base_system',type=Path)
args=parser.parse_args();installer=args.installer.resolve();base=args.base_system.resolve()
version=plistlib.loads((base/'System/Library/CoreServices/SystemVersion.plist').read_bytes())
if not version.get('ProductVersion','').startswith('10.9.'):raise SystemExit('Mavericks Base System required')
for volume in (installer,base):
    if not os.statvfs(volume).f_flag&os.ST_RDONLY:raise SystemExit('Read-only source volumes required')
build=Path(__file__).resolve().parents[1]/'Build/mavericks-appearance'
out=build/'original-installer';out.mkdir(parents=True,exist_ok=True)
patterns=['*.icns','*.png','*.tiff','*.tif','*.jpg','*.jpeg','*.pdf','*.gif','*.clr','*/Info.plist','*.ttc','*.ttf','*.otf']
provenance={'version':version,'packages':{}}
for name in ('Essentials','AdditionalEssentials'):
    work=build/('installer-'+name.lower());work.mkdir(exist_ok=True)
    subprocess.run(['xar','-xf',str(installer/'Packages'/(name+'.pkg')),'-C',str(work),'Payload','PackageInfo','Bom'],check=True)
    command=['tar','-xf',str(work/'Payload'),'-C',str(out)]
    for pattern in patterns:command+=['--include',pattern]
    result=subprocess.run(command,capture_output=True,text=True)
    errors=[line for line in result.stderr.splitlines()if 'Not found in archive'not in line and 'Error exit delayed'not in line]
    if result.returncode not in (0,1)or errors:raise RuntimeError(result.stderr)
    provenance['packages'][name]=hashlib.sha256((work/'PackageInfo').read_bytes()).hexdigest()
extensions={'.icns','.png','.tiff','.tif','.jpg','.jpeg','.pdf','.gif','.clr','.ttc','.ttf','.otf'}
for prefix in ('Applications','System/Library','Library/Desktop Pictures'):
    for source in (base/prefix).rglob('*'):
        if not source.is_file()or source.is_symlink():continue
        if source.suffix.lower()not in extensions and source.name not in ('Info.plist','SystemVersion.plist'):continue
        target=out/source.relative_to(base)
        if target.exists():continue
        target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source,target)
provenance['files']=sum(1 for p in out.rglob('*')if p.is_file())
(out/'source.json').write_text(json.dumps(provenance,indent=2)+'\n')
print(json.dumps(provenance))
