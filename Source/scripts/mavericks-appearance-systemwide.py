#!/usr/bin/env python3
"""Deploy shared Mavericks rendering and resources to an owned held Mojave clone.

Prepare local artifacts with the extract/prepare scripts first. No Apple assets
are downloaded or committed. --source-volume consumes an already attached,
read-only Mavericks system disk; --installer-media consumes the read-only asset
disc built from the original installer. Existing guest asset backups remain.
"""
import argparse,json,subprocess,sys,time
from pathlib import Path
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('results',type=Path)
parser.add_argument('--source-volume',action='store_true')
parser.add_argument('--installer-media',action='store_true')
parser.add_argument('--bundle-media',action='store_true',help='Apply the read-only bundle-identity resource disc')
args=parser.parse_args();source=Path(__file__).resolve().parents[1]
root=args.results.resolve();build=source/'Build/mavericks-appearance'
if not root.is_relative_to(build)or not(root/'Appearance Experiment.app').is_dir()or(root/'Finish').exists():raise SystemExit('An owned running appearance clone is required')
required=['assets/native-mojave-SystemAppearance.car','assets/icon-aliases.json','assets/render-art.tar','assets/named-images.tar.gz','assets/isolated-coreui.tar.gz','assets/lucida-modern.patch','original-dock-scene/mavericks-glass@2x.png']
missing=[name for name in required if not(build/name).is_file()]
if missing:raise SystemExit('Prepare local reference assets first: '+', '.join(missing))
steps=[['qualify-systemwide'],['restore-native-catalog'],['guest-script',str(source/'probes/mavericks-restore-signed-metadata.py')],['install-art'],['install-named'],['install-dock-art'],['install-legacy-coreui']]
if args.source_volume:steps.append(['guest-script',str(source/'probes/mavericks-system-assets-apply.py')])
if args.installer_media:steps.append(['install-installer-assets-media'])
if args.bundle_media:steps.append(['install-bundle-assets-media'])
steps += [['install-icon-aliases'],['install-font-alias'],['install-library'],['guest-script',str(source/'probes/mavericks-icon-catalog-apply.py')],['guest-script',str(source/'probes/mavericks-refresh-assets.py')],['guest-script',str(source/'probes/mavericks-desktop-activate.py')],['relaunch-apps']]
report={'started':time.time(),'steps':[],'complete':False}
path=root/'systemwide-install.json'
for step in steps:
    print('Applying '+step[0],flush=True)
    result=subprocess.run([sys.executable,str(source/'scripts/mavericks-appearance-live.py'),str(root)]+step,capture_output=True,text=True)
    report['steps'].append({'command':step,'status':result.returncode,'stdout':result.stdout,'stderr':result.stderr})
    path.write_text(json.dumps(report,indent=2)+'\n')
    if result.returncode:raise SystemExit('Stopped after '+step[0]+'; inspect '+str(path))
report['complete']=True;report['finished']=time.time();path.write_text(json.dumps(report,indent=2)+'\n')
print(path)
