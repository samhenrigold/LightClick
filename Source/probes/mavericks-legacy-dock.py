# Python 2.7: bounded genuine Mavericks Dock test, with automatic restoration of Mojave's Dock on failure.
import json,os,plistlib,subprocess,time
if os.getuid()!=0 or not os.uname()[2].startswith('18.'):raise RuntimeError('Mojave experiment required')
source=None
for name in os.listdir('/Volumes'):
 path='/Volumes/'+name;info=path+'/System/Library/CoreServices/SystemVersion.plist'
 if os.path.isfile(info) and plistlib.readPlist(info).get('ProductVersion','').startswith('10.9.') and os.statvfs(path).f_flag&1:source=path
base='/Library/Application Support/MavericksAppearance';app=base+'/MavericksDock.app'
if not os.path.isdir(app):
 if not source:raise RuntimeError('Read-only Mavericks source required for initial copy')
 subprocess.check_call(['/usr/bin/ditto',source+'/System/Library/CoreServices/Dock.app',app])
uid=str(os.stat('/dev/console').st_uid)
if int(uid)<501:raise RuntimeError('No console user')
prefix=['/bin/launchctl','asuser',uid,'/usr/bin/sudo','-n','-u','#'+uid]
job='/System/Library/LaunchAgents/com.apple.Dock.plist'
domain='gui/'+uid
unload=subprocess.Popen(['/bin/launchctl','bootout',domain,job],stdout=subprocess.PIPE,stderr=subprocess.STDOUT);out=unload.communicate()[0]
if unload.returncode:raise RuntimeError('Could not suspend the clone Dock job: '+out)
log=open(base+'/legacy-dock.log','w')
child=None;running=False
try:
 child=subprocess.Popen(prefix+['/usr/bin/env','-i','PATH=/usr/bin:/bin:/usr/sbin:/sbin','DYLD_BIND_AT_LAUNCH=1','DYLD_FORCE_FLAT_NAMESPACE=1','DYLD_INSERT_LIBRARIES='+base+'/LegacyDockCompatibility.dylib',app+'/Contents/MacOS/Dock'],stdin=open('/dev/null'),stdout=log,stderr=subprocess.STDOUT,close_fds=True)
 time.sleep(12);running=child.poll() is None
finally:
 # A trial is bounded even when the old process starts successfully. Restore the
 # actual GUI job in the correct domain, without changing persistent overrides.
 if child is not None and child.poll() is None:subprocess.call(prefix+['/usr/bin/killall','Dock'])
 subprocess.call(['/bin/launchctl','enable',domain+'/com.apple.Dock.agent'])
 subprocess.call(['/bin/launchctl','bootstrap',domain,job])
 restored=subprocess.call(['/bin/launchctl','kickstart',domain+'/com.apple.Dock.agent'])==0
 log.close()
print(json.dumps({'runningDuringTrial':running,'launcherPID':child.pid if child else None,'exitCode':child.poll() if child else None,'log':open(base+'/legacy-dock.log').read()[-12000:],'restoredModernDock':restored}))
