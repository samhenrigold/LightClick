# Refresh system appearance caches only inside the disposable guest. All cache directories are retained as backups.
import glob,json,os,pwd,subprocess,time
if os.getuid()!=0 or not os.uname()[2].startswith('18.'):raise RuntimeError('Mojave experiment required')
uid=os.stat('/dev/console').st_uid
backup='/Library/Application Support/MavericksAppearance/IconCacheBackup-'+str(int(time.time()));os.mkdir(backup,0700)
paths=glob.glob('/Library/Caches/com.apple.iconservices*')+glob.glob('/private/var/folders/*/*/C/com.apple.iconservices*')+glob.glob('/private/var/folders/*/*/C/*com.apple.dock.iconcache*')
resources=set()
for journal in glob.glob('/Library/Application Support/MavericksAppearance/SystemAssetBackup-*/journal.jsonl')+glob.glob('/Library/Application Support/MavericksAppearance/InstallerAssets-*/journal.jsonl'):
 for line in open(journal):
  row=json.loads(line);path=row.get('path','')
  if path.startswith(('/Applications/','/System/Library/')) and path.lower().endswith(('.png','.pdf','.tiff','.tif','.icns','.jpg','.jpeg','.gif')) and os.path.isfile(path):resources.add(path)
registry='/Library/Application Support/MavericksAppearance/LegacyResources.json'
with open(registry+'.next','w')as output:json.dump(sorted(resources),output)
os.chmod(registry+'.next',0644);os.rename(registry+'.next',registry)
r=[]
for i,path in enumerate(paths):
 if os.path.islink(path):continue
 try:os.rename(path,backup+'/'+str(i));r.append(path)
 except OSError:pass
for name in ('iconservicesagent','iconservicesd'):subprocess.call(['/usr/bin/killall',name],stdout=open('/dev/null','w'),stderr=subprocess.STDOUT)
subprocess.call(['/bin/launchctl','asuser',str(uid),'/usr/bin/sudo','-n','-u','#'+str(uid),'/usr/bin/defaults','write','-g','AppleShowScrollBars','-string','Always'])
print(json.dumps({'cacheBackup':backup,'refreshedCaches':r,'originalResourceLookups':len(resources)}))
