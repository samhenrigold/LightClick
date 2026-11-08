# Refresh registrations after external icon aliases/custom-icon metadata changes.
# Do not edit signed Info.plist icon-selector keys: sandboxed apps reject that.
import glob,json,os,subprocess
if os.getuid()!=0 or not os.uname()[2].startswith('18.'):raise RuntimeError('Mojave clone required')
base='/Library/Application Support/MavericksAppearance';bundles=set()
for path in glob.glob(base+'/CustomIconBackup-*/report.json'):
 for row in json.load(open(path)).get('icons',[]):
  if row.get('set'):bundles.add(row['bundle'])
uid=str(os.stat('/dev/console').st_uid);prefix=['/bin/launchctl','asuser',uid,'/usr/bin/sudo','-n','-u','#'+uid]
register='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister';registered=[]
for bundle in sorted(bundles):
 if not bundle.startswith(('/Applications/','/System/Library/'))or'..'in bundle.split('/'):raise RuntimeError('Unexpected registered bundle')
 if subprocess.call(prefix+[register,'-f',bundle],stdout=open('/dev/null','w'),stderr=subprocess.STDOUT)==0:registered.append(bundle)
print(json.dumps({'registered':len(registered),'signedMetadataModified':False}))
