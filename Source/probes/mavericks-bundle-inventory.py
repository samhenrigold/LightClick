# Read-only Python 2.7 inventory inside an owned Mojave experiment.
import json,os
from Foundation import NSDictionary
if os.getuid()!=0 or not os.uname()[2].startswith('18.'):raise RuntimeError('Mojave experiment required')
rows=[]
for prefix in ['/Applications','/System/Library']:
 for root,dirs,files in os.walk(prefix):
  dirs[:]=[d for d in dirs if not os.path.islink(root+'/'+d)]
  if root.endswith('/Contents')and'Info.plist'in files:
   info=NSDictionary.dictionaryWithContentsOfFile_(root+'/Info.plist')
   if info and info.get('CFBundleIdentifier'):
    rows.append({'identifier':info['CFBundleIdentifier'],'contents':root,'icon':info.get('CFBundleIconFile'),'catalogIcon':info.get('CFBundleIconName')})
path='/tmp/MavericksBundleInventory.json'
json.dump(rows,open(path,'w'))
print(json.dumps({'bundles':len(rows),'path':path}))
