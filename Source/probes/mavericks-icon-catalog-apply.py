# Prefer original loose bundle icons over newer asset-catalog icons, then refresh
# their LaunchServices registrations. Original metadata is backed up per bundle.
import glob,json,os,plistlib,shutil,subprocess,time
if os.getuid()!=0 or not os.uname()[2].startswith('18.'):raise RuntimeError('Mojave clone required')
base='/Library/Application Support/MavericksAppearance';icons=set()
for path in glob.glob(base+'/SystemAssetBackup-*/report.json'):
 try:icons.update(json.load(open(path)).get('semanticIcons',[]))
 except (IOError,ValueError):pass
backup=base+'/IconCatalogBackup-'+str(int(time.time()));os.mkdir(backup,0700)
uid=str(os.stat('/dev/console').st_uid);prefix=['/bin/launchctl','asuser',uid,'/usr/bin/sudo','-n','-u','#'+uid]
register='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
changed=[];registered=[];seen=set()
for icon in sorted(icons):
 if '/Contents/Resources/'not in icon:continue
 contents=icon.split('/Contents/Resources/')[0]+'/Contents';info_path=contents+'/Info.plist';bundle=os.path.dirname(contents)
 if info_path in seen or not os.path.isfile(info_path):continue
 seen.add(info_path)
 info=plistlib.readPlistFromString(subprocess.check_output(['/usr/bin/plutil','-convert','xml1','-o','-',info_path]))
 name=info.get('CFBundleIconFile','')
 if not name or '/'in name:continue
 if not os.path.splitext(name)[1]:name+='.icns'
 if not os.path.isfile(contents+'/Resources/'+name):continue
 if 'CFBundleIconName'in info:
  saved=backup+info_path;os.makedirs(os.path.dirname(saved));shutil.copyfile(info_path,saved)
  del info['CFBundleIconName'];temporary=info_path+'.mavericks-icon-next';plistlib.writePlist(info,temporary);os.chmod(temporary,0644);os.rename(temporary,info_path);changed.append(info_path)
 os.utime(bundle,None)
 if os.path.isfile(register):
  if subprocess.call(prefix+[register,'-f',bundle],stdout=open('/dev/null','w'),stderr=subprocess.STDOUT)==0:registered.append(bundle)
json.dump({'changed':changed,'registered':registered},open(backup+'/report.json','w'),indent=2)
print(json.dumps({'catalogOverridesRemoved':len(changed),'registered':len(registered),'backup':backup}))
