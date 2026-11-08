# Python 2.7: apply original installer image deltas to an explicitly cloned Mojave.
import hashlib,json,os,plistlib,shutil,subprocess,sys,tarfile,tempfile,time
if os.getuid()!=0 or not os.uname()[2].startswith('18.'):raise RuntimeError('Mojave experiment required')
archive,manifest_path=sys.argv[1:];manifest=json.load(open(manifest_path))
base='/Library/Application Support/MavericksAppearance';work=tempfile.mkdtemp(prefix='InstallerAssets-',dir=base)
backup=work+'/Backup';os.mkdir(backup,0700);files={};changed=[];unmatched=[];saved=set()
with tarfile.open(archive)as tar:
 for member in tar:
  if not member.isfile() or not member.name.startswith('files/') or not member.name[6:].isdigit():raise RuntimeError('Unexpected installer asset archive member')
  tar.extract(member,work)
def install(row,dst,semantic=False):
 if not dst.startswith(('/Applications/','/System/Library/','/Library/Desktop Pictures/')) or '..' in dst.split('/') or os.path.islink(dst):raise RuntimeError('Unexpected asset destination')
 if not dst.lower().endswith(('.icns','.png','.tiff','.tif','.jpg','.jpeg','.gif','.pdf','.clr')):raise RuntimeError('Only image resources may be installed')
 src=work+'/'+row['payload']
 if hashlib.sha256(open(src,'rb').read()).hexdigest()!=row['sha256']:raise RuntimeError('Source hash mismatch')
 if not os.path.isdir(os.path.dirname(dst)):unmatched.append(dst);return
 parts=dst.split('/')
 for index,part in enumerate(parts):
  if part.endswith(('.app','.bundle','.prefPane','.framework','.menu','.plugin')) and not os.path.isdir('/'.join(parts[:index+1])):unmatched.append(dst);return
 exists=os.path.isfile(dst)
 if exists and hashlib.sha256(open(dst,'rb').read()).hexdigest()==row['sha256']:return
 if exists and dst not in saved:
  path=backup+dst
  if not os.path.isdir(os.path.dirname(path)):os.makedirs(os.path.dirname(path))
  shutil.copyfile(dst,path);saved.add(dst)
 next_file=dst+'.mavericks-installer-next';shutil.copyfile(src,next_file);os.chmod(next_file,0644);os.rename(next_file,dst)
 if hashlib.sha256(open(dst,'rb').read()).hexdigest()!=row['sha256']:raise RuntimeError('Installed hash mismatch')
 record={'path':dst,'sha256':row['sha256'],'replaced':exists,'semanticIcon':semantic};changed.append(record)
 with open(work+'/journal.jsonl','a')as journal:journal.write(json.dumps(record)+'\n')
for row in manifest['files']:files[row['source']]=row;install(row,row['destination'])
for icon in manifest['declaredIcons']:
 path=icon['bundleContents']+'/Info.plist'
 if not os.path.isfile(path):continue
 try:
  data=subprocess.check_output(['/usr/bin/plutil','-convert','xml1','-o','-',path]);info=plistlib.readPlistFromString(data)
  name=info.get('CFBundleIconFile')
  if info.get('CFBundleIdentifier')!=icon['identifier'] or not name or '/' in name:continue
  if not os.path.splitext(name)[1]:name+='.icns'
  install(files[icon['source']],icon['bundleContents']+'/Resources/'+name,True)
 except (ValueError,subprocess.CalledProcessError):continue
json.dump({'source':manifest['source'],'changed':changed,'unmatched':unmatched},open(work+'/report.json','w'),indent=2)
print(json.dumps({'changed':len(changed),'semanticIcons':sum(int(r['semanticIcon'])for r in changed),'unmatched':len(unmatched),'backup':work}))
