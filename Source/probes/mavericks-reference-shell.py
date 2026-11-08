import json,os,shutil,subprocess,time
if os.getuid()!=0 or not os.uname()[2].startswith('13.'):raise RuntimeError('Original Mavericks reference clone required')
uid=str(os.stat('/dev/console').st_uid)
if int(uid)<501:raise RuntimeError('Console required')
finder=subprocess.check_output(['/usr/bin/pgrep','-x','-U',uid,'Finder']).strip()
session=['/tmp/MavericksReferenceSession',finder,'/usr/bin/sudo','-n','-u','#'+uid]
job='/System/Library/LaunchAgents/com.apple.Dock.plist'
app='/tmp/MavericksReferenceDock.app'
if not os.path.isdir(app):subprocess.check_call(['/usr/bin/ditto','/System/Library/CoreServices/Dock.app',app])
shutil.copyfile('/tmp/MavericksDockDecrypted',app+'/Contents/MacOS/Dock');os.chmod(app+'/Contents/MacOS/Dock',0755)
subprocess.call(session+['/bin/launchctl','unload',job])
if os.path.isfile('/tmp/MavericksReferenceShell/scene.json'):os.unlink('/tmp/MavericksReferenceShell/scene.json')
log=open('/tmp/MavericksReferenceDock.log','w')
child=None
try:
 child=subprocess.Popen(session+['/usr/bin/env','DYLD_INSERT_LIBRARIES=/tmp/MavericksReferenceShell.dylib',app+'/Contents/MacOS/Dock'],stdout=log,stderr=subprocess.STDOUT)
 for i in range(45):
  if os.path.isfile('/tmp/MavericksReferenceShell/scene.json') or child.poll() is not None:break
  time.sleep(1)
finally:
 subprocess.call(['/usr/bin/killall','Dock'])
 subprocess.call(session+['/bin/launchctl','unsetenv','DYLD_INSERT_LIBRARIES'])
 subprocess.call(session+['/bin/launchctl','load','-w',job])
 subprocess.call(session+['/bin/launchctl','start','com.apple.Dock.agent'])
 time.sleep(2)
 if subprocess.call(['/usr/bin/pgrep','-x','Dock'],stdout=open('/dev/null','w')):
  subprocess.Popen(session+['/usr/bin/env','-u','DYLD_INSERT_LIBRARIES','/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock'],stdout=log,stderr=subprocess.STDOUT,close_fds=True)
 log.close()
print(json.dumps({'exported':os.path.isfile('/tmp/MavericksReferenceShell/scene.json'),'loaded':open('/tmp/MavericksReferenceLoaded.txt').read() if os.path.isfile('/tmp/MavericksReferenceLoaded.txt') else None,'log':open('/tmp/MavericksReferenceDock.log').read()[-3000:]}))
