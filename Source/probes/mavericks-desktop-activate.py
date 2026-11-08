import json,os,plistlib,subprocess,time
if not os.uname()[2].startswith('18.'):raise RuntimeError('Mojave clone required')
uid=str(os.stat('/dev/console').st_uid)
if int(uid)<501:raise RuntimeError('Console user required')
base='/Library/Application Support/MavericksAppearance'
if not os.path.isfile(base+'/MavericksAppearance.dylib'):raise RuntimeError('Appearance library missing')
# Login installs the shared renderer before reopening the user's desktop shell.
activation='''import os,subprocess
if not os.uname()[2].startswith('18.') or os.getuid()<501:raise SystemExit(0)
library='/Library/Application Support/MavericksAppearance/MavericksAppearance.dylib'
if not os.path.isfile(library):raise SystemExit(1)
subprocess.check_call(['/bin/launchctl','setenv','DYLD_INSERT_LIBRARIES',library])
subprocess.call(['/usr/bin/killall','Finder','Dock','SystemUIServer'])
'''
open(base+'/ActivateUser.py','w').write(activation);os.chmod(base+'/ActivateUser.py',0644)
agent='/Library/LaunchAgents/com.lightclick.mavericks-appearance.plist'
plistlib.writePlist({'Label':'com.lightclick.mavericks-appearance','ProgramArguments':['/usr/bin/python',base+'/ActivateUser.py'],'RunAtLoad':True,'LimitLoadToSessionType':'Aqua','ProcessType':'Background'},agent)
os.chmod(agent,0644)
prefix=['/bin/launchctl','asuser',uid,'/usr/bin/sudo','-n','-u','#'+uid]
report={'loginAgent':agent}
for key,args in [('sip',['/usr/bin/csrutil','status']),('setenv',prefix+['/bin/launchctl','setenv','DYLD_INSERT_LIBRARIES',base+'/MavericksAppearance.dylib']),('opaque-menu',prefix+['/usr/bin/defaults','write','-g','AppleEnableMenuBarTransparency','-bool','YES']),('reduce-transparency',prefix+['/usr/bin/defaults','write','com.apple.universalaccess','reduceTransparency','-bool','NO']),('restart',prefix+['/usr/bin/killall','Finder','Dock','SystemUIServer'])]:
 p=subprocess.Popen(args,stdout=subprocess.PIPE,stderr=subprocess.STDOUT);out=p.communicate()[0];report[key]={'status':p.returncode,'output':out}
time.sleep(4)
for name in ('Finder','Dock','SystemUIServer'):
 p=subprocess.Popen(['/usr/bin/pgrep','-x','-U',uid,name],stdout=subprocess.PIPE);pid=p.communicate()[0].strip();report[name]={'pid':pid}
 if pid:
  p=subprocess.Popen(['/usr/bin/vmmap',pid],stdout=subprocess.PIPE,stderr=subprocess.STDOUT);out=p.communicate()[0];report[name]['appearanceLoaded']='MavericksAppearance' in out
print(json.dumps(report))
