# Python 2.7 in the disposable Mojave guest. System-wide aliases complement the process-local font hooks.
import glob,hashlib,json,os,subprocess,sys
if os.getuid()!=0 or not os.uname()[2].startswith('18.'):raise RuntimeError('Mojave experiment required')
patch=sys.argv[1]
expected='8fd8b90cfab02bae6f905d2cea334962'
files=glob.glob('/Library/Application Support/MavericksAppearance/SystemAssetBackup-*/System/Library/Fonts/LucidaGrande.ttc')+['/System/Library/Fonts/LucidaGrande.ttc']
source=next((p for p in files if hashlib.md5(open(p,'rb').read()).hexdigest()==expected),None)
if not source:raise RuntimeError('No matching original Mojave font base; do not patch a different font')
target='/Library/Fonts/LucidaGrande_modsysfonths.ttc'
if os.path.lexists(target):raise RuntimeError('Font alias already present; inspect it instead of overwriting')
subprocess.check_call(['/usr/bin/bspatch',source,target+'.next',patch])
if open(target+'.next','rb').read(4)!='ttcf':raise RuntimeError('Font patch did not produce a collection')
os.chmod(target+'.next',0644);os.rename(target+'.next',target)
uid=str(os.stat('/dev/console').st_uid)
prefix=['/bin/launchctl','asuser',uid,'/usr/bin/sudo','-n','-u','#'+uid]
refresh=subprocess.Popen(prefix+['/usr/bin/atsutil','databases','-removeUser'],stdout=subprocess.PIPE,stderr=subprocess.STDOUT);out=refresh.communicate()[0]
print(json.dumps({'source':source,'sourceMD5':expected,'font':target,'sha256':hashlib.sha256(open(target,'rb').read()).hexdigest(),'patchSHA256':hashlib.sha256(open(patch,'rb').read()).hexdigest(),'refreshStatus':refresh.returncode,'refreshOutput':out}))
