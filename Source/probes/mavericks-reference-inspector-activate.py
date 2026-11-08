import os,subprocess,json
if os.getuid()!=0 or not os.uname()[2].startswith('13.'):raise RuntimeError('Original Mavericks reference required')
uid=str(os.stat('/dev/console').st_uid);finder=subprocess.check_output(['/usr/bin/pgrep','-x','-U',uid,'Finder']).strip()
script='''import subprocess,time
subprocess.check_call(['/bin/launchctl','setenv','DYLD_INSERT_LIBRARIES','/tmp/MavericksReferenceInspector.dylib'])
subprocess.call(['/usr/bin/killall','Finder','SystemUIServer'])
time.sleep(7)
subprocess.check_call(['/usr/bin/open','-a','Finder','/Applications'])
'''
subprocess.check_call(['/tmp/MavericksReferenceSession',finder,'/usr/bin/sudo','-n','-u','#'+uid,'/usr/bin/python','-c',script])
print(json.dumps({'referenceInspectorEnabled':True}))
