# Undo our icon-selector Info.plist edits without altering app executables or entitlements.
import os,glob,json,shutil,tempfile,time,hashlib
if os.getuid()!=0 or not os.uname()[2].startswith('18.'):raise RuntimeError('Mojave experiment root required')
base='/Library/Application Support/MavericksAppearance'
work=tempfile.mkdtemp(prefix='MetadataRepair-',dir=base);changed=[]
for backup in sorted(glob.glob(base+'/IconCatalogBackup-*'),reverse=True):
 report=backup+'/report.json'
 if not os.path.isfile(report):continue
 for path in json.load(open(report)).get('changed',[]):
  if not path.startswith(('/Applications/','/System/Library/'))or not path.endswith('/Contents/Info.plist')or'..'in path.split('/'):raise RuntimeError('Unexpected metadata destination')
  source=backup+path
  if not os.path.isfile(source)or os.path.islink(path):raise RuntimeError('Missing original signed metadata')
  if open(source,'rb').read()==open(path,'rb').read():continue
  saved=work+path
  if not os.path.isdir(os.path.dirname(saved)):os.makedirs(os.path.dirname(saved))
  if not os.path.isfile(saved):shutil.copyfile(path,saved)
  temporary=path+'.mavericks-metadata-repair';shutil.copyfile(source,temporary);os.chmod(temporary,0644);os.rename(temporary,path)
  changed.append({'path':path,'sha256':hashlib.sha256(open(path,'rb').read()).hexdigest()})
json.dump({'restored':changed},open(work+'/report.json','w'),indent=2)
print(json.dumps({'metadataRestored':len(changed),'backup':work}))
