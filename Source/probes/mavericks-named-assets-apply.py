# Install the original AppKit image catalog as a transaction in the Mojave clone.
import json,os,subprocess,sys,tarfile,tempfile
if os.getuid()!=0 or not os.uname()[2].startswith('18.'):raise RuntimeError('Mojave clone root required')
uid=os.stat('/dev/console').st_uid
if uid<501:raise RuntimeError('A logged-in console user is required')
base='/Library/Application Support/MavericksAppearance'
work=tempfile.mkdtemp(prefix='NamedImages-',dir=base);os.chmod(work,0755)
staged=work+'/Next';os.mkdir(staged,0755)
with tarfile.open(sys.argv[1])as archive:
 for member in archive:
  name=member.name
  while name.startswith('./'):name=name[2:]
  if member.isdir()and name in ('','.'):continue
  if not member.isfile()or '/'in name or name in ('','..')or not(name.endswith('.png')or name=='manifest.json'):raise RuntimeError('Unexpected named-image archive member')
  with open(staged+'/'+name,'wb')as output:output.write(archive.extractfile(member).read())
  os.chmod(staged+'/'+name,0644)
# Verify as the actual GUI account. Archive usernames can map to a different UID
# on the destination even when their original numeric UID was the same.
verify='''import os,json,sys
base=sys.argv[1];manifest=json.load(open(base+"/manifest.json"))
files=[f for row in manifest["images"]for f in row["files"]]
assert files,"Empty original catalog"
for name in files:
 assert "/"not in name and name not in ("",".."),"Invalid catalog filename"
 assert os.access(base+"/"+name,os.R_OK),"Unreadable original image: "+name
print(json.dumps({"consoleUID":os.getuid(),"readableOriginalImages":len(files)}))
'''
result=json.loads(subprocess.check_output(['/usr/bin/sudo','-n','-u','#'+str(uid),'/usr/bin/python','-c',verify,staged]))
target=base+'/NamedImages'
if os.path.isdir(target):os.rename(target,work+'/Previous')
os.rename(staged,target)
result['backup']=work if os.path.isdir(work+'/Previous')else None
if not result['backup']:os.rmdir(work)
print(json.dumps(result))
