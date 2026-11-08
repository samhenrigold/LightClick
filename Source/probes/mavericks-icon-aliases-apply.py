# Keep original icon bytes outside signed bundles, and preserve signed Info.plist bytes.
import hashlib,json,os,plistlib,shutil,struct,subprocess,sys,tempfile
from AppKit import NSImage,NSWorkspace
if os.getuid()!=0 or not os.uname()[2].startswith('18.'):raise RuntimeError('Mojave experiment root required')
base='/Library/Application Support/MavericksAppearance';store=base+'/ApplicationIcons'
if not os.path.isdir(store):os.mkdir(store,0755)
work=tempfile.mkdtemp(prefix='CustomIconBackup-',dir=base);aliases={};changed=[];missing=[]
for row in json.load(open(sys.argv[1]))['icons']:
 contents=row['contents'];identifier=row['canonicalIdentifier'];bundle=os.path.dirname(contents)
 if not contents.startswith(('/Applications/','/System/Library/'))or'..'in contents.split('/'):raise RuntimeError('Unexpected bundle path')
 info_path=contents+'/Info.plist'
 if not os.path.isfile(info_path):continue
 info_bytes=open(info_path,'rb').read();info=plistlib.readPlistFromString(subprocess.check_output(['/usr/bin/plutil','-convert','xml1','-o','-',info_path]))
 if info.get('CFBundleIdentifier','').lower()!=identifier:raise RuntimeError('Target icon identity changed')
 candidates=[]
 for name in [row['sourceName'],row['targetName']]:
  if '/'in name or name in ('','..'):raise RuntimeError('Unexpected icon filename')
  candidate=contents+'/Resources/'+name
  if os.path.isfile(candidate)and not os.path.islink(candidate)and hashlib.sha256(open(candidate,'rb').read()).hexdigest()==row['sha256']:candidates.append(candidate)
 if not candidates:missing.append(bundle);continue
 filename=hashlib.sha256(identifier.encode('utf-8')).hexdigest()+row['extension'];target=store+'/'+filename
 shutil.copyfile(candidates[0],target);os.chmod(target,0644)
 names=['NSApplicationIcon']
 for value in [info.get('CFBundleIconFile'),info.get('CFBundleIconName')]:
  if value:names.append(os.path.splitext(value)[0])
 aliases[identifier]={'file':target,'names':names,'sha256':row['sha256']}
 # Public custom-icon metadata avoids modifying the signed icon-selector fields.
 # Retain previous custom icons for rollback; stock icons restore with setIcon:nil.
 previous=False
 p=subprocess.Popen(['/usr/bin/xattr','-px','com.apple.FinderInfo',bundle],stdout=subprocess.PIPE,stderr=subprocess.PIPE);data=p.communicate()[0]
 if p.returncode==0:
  raw=data.replace(' ','').replace('\n','').decode('hex');previous=len(raw)>=10 and bool(struct.unpack('>H',raw[8:10])[0]&0x400)
 if previous:
  old=NSWorkspace.sharedWorkspace().iconForFile_(bundle);old.TIFFRepresentation().writeToFile_atomically_(work+'/'+str(len(changed))+'.tiff',True)
 image=NSImage.alloc().initWithContentsOfFile_(target)
 success=bool(image and NSWorkspace.sharedWorkspace().setIcon_forFile_options_(image,bundle,0))
 if open(info_path,'rb').read()!=info_bytes:raise RuntimeError('Signed application metadata changed')
 changed.append({'bundle':bundle,'source':target,'set':success,'previousCustom':previous})
registry=base+'/LegacyIconAliases.json'
with open(registry+'.next','w')as output:json.dump(aliases,output)
os.chmod(registry+'.next',0644);os.rename(registry+'.next',registry)
json.dump({'icons':changed,'missing':missing},open(work+'/report.json','w'),indent=2)
print(json.dumps({'aliases':len(aliases),'customIconsSet':sum(int(r['set'])for r in changed),'missing':len(missing),'backup':work}))
