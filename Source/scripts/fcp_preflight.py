"""Same-boot disposable guest FCP preflight; bounded commands and observation, never host installation."""
import json

# Python2-compatible. Expected identity/payload is supplied only from the host's fixed case table.
GUEST = r'''import ctypes, hashlib, json, os, re, plistlib, pwd, resource, signal, stat, subprocess, sys, tempfile, threading, time, xml.etree.ElementTree as ET
spec,before=json.loads(sys.argv[1])
CAP=131072
owned=[]
report={'result':'INCONCLUSIVE','commands':[],'scope':'disposable-guest install and no-input launch observation only'}
directory=tempfile.mkdtemp(prefix='LightClickFCP.',dir='/private/var/tmp')
os.chmod(directory,0o700)
app=None
log=None
def stop(child):
    if child.poll() is not None:return
    if os.getpgid(child.pid)!=child.pid:raise ValueError('owned process group changed')
    os.killpg(child.pid,signal.SIGTERM)
    until=time.time()+2
    while child.poll() is None and time.time()<until:time.sleep(.1)
    if child.poll() is None:os.killpg(child.pid,signal.SIGKILL)
    until=time.time()+2
    while child.poll() is None and time.time()<until:time.sleep(.1)
    if child.poll() is None:raise ValueError('owned process did not reap')
def limits():
    # Payload and app-owned files must remain unrestricted; bound only diagnostic pipes.
    os.setsid()
def reader(stream):
    state={'parts':[],'bytes':0,'at_limit':False}
    def drain():
        try:
            while True:
                data=stream.read(4096)
                if not data:break
                remaining=max(0,CAP-state['bytes'])
                if remaining:state['parts'].append(data[:remaining])
                state['bytes']+=len(data)
                if state['bytes']>CAP:state['at_limit']=True
        finally:stream.close()
    thread=threading.Thread(target=drain);thread.daemon=True;thread.start()
    return state,thread
def captured(pair):
    state,thread=pair
    thread.join(2)
    return {'text':b''.join(state['parts']).decode('utf-8','replace'),'at_limit':state['at_limit'],'bytes':state['bytes'],'reader_finished':not thread.is_alive()}
def command(argv,seconds,allowed=(0,)):
    with open(os.devnull,'rb') as null:
        child=subprocess.Popen(argv,stdin=null,stdout=subprocess.PIPE,stderr=subprocess.PIPE,preexec_fn=limits,close_fds=True)
    owned.append(child);out=reader(child.stdout);err=reader(child.stderr)
    until=time.time()+seconds
    while child.poll() is None and time.time()<until and not out[0]['at_limit'] and not err[0]['at_limit']:time.sleep(.1)
    expired=child.poll() is None and time.time()>=until
    if child.poll() is None:stop(child)
    a,b=captured(out),captured(err)
    row={'argv':argv,'exit_code':child.poll(),'timed_out':expired,'stdout':a['text'],'stderr':b['text'],'at_limit':a['at_limit'] or b['at_limit'],'readers_finished':a['reader_finished'] and b['reader_finished']}
    report['commands'].append(row)
    if expired or row['exit_code'] not in allowed or row['at_limit'] or not row['readers_finished']:raise ValueError('bounded command failed: '+repr(argv))
    return a['text'].encode('utf-8')
def plist_command(argv):return plistlib.readPlistFromString(command(argv,10))
def identity(path):
    p=path+'/Contents/Info.plist'
    if os.path.realpath(p)!=p or not stat.S_ISREG(os.lstat(p).st_mode) or os.stat(p).st_size>524288:raise ValueError('invalid app plist')
    x=plistlib.readPlist(p)
    return dict((k,x.get(k)) for k in ('CFBundleIdentifier','CFBundleShortVersionString','CFBundleVersion','CFBundleExecutable'))
def exact_identity(path):
    x=identity(path)
    if x!=spec['identity']:raise ValueError('application identity mismatch '+repr(x))
    return x
def join_console():
    uid=os.stat('/dev/console').st_uid
    if uid==0:raise ValueError('no logged-in console user')
    user=pwd.getpwuid(uid)
    found=command(['/usr/bin/pgrep','-x','Finder'],3).split()
    if len(found)!=1:raise ValueError('Finder identity ambiguous')
    libc=ctypes.CDLL('/usr/lib/libSystem.B.dylib');me=ctypes.c_uint.in_dll(libc,'mach_task_self_').value
    task,bootstrap,session=ctypes.c_uint(),ctypes.c_uint(),ctypes.c_uint()
    token,count=(ctypes.c_uint*8)(),ctypes.c_uint(8)
    if libc.task_for_pid(me,int(found[0]),ctypes.byref(task)) or libc.task_info(task,15,token,ctypes.byref(count)) or libc.task_get_special_port(task,4,ctypes.byref(bootstrap)) or libc.audit_session_port(token[6],ctypes.byref(session))==-1 or libc.audit_session_join(session)==-1 or libc.task_set_special_port(me,4,bootstrap):raise ValueError('cannot join Finder audit/bootstrap session')
    os.chown(directory,uid,user.pw_gid)
    os.chown(spec['ax_helper'],uid,user.pw_gid)
    os.initgroups(user.pw_name,user.pw_gid);os.setgid(user.pw_gid);os.setuid(uid)
    return uid
def observe(pid):
    raw=command([spec['ax_helper'],spec['variant'],str(pid)],14)
    return json.loads(raw)


def validate_package_metadata(package,distribution):
    identity={'identifier':package.get('identifier'),'version':package.get('version')}
    if identity!={'identifier':'com.apple.pkg.FinalCutProXTrial','version':'10.4.4.0.1.1539134424'}:raise ValueError('trial package identity mismatch')
    if not any(e.tag=='pkg-ref' and e.get('id')=='com.apple.pkg.FinalCutTrial' and e.get('version')=='10.4.4.0.1.1539134424' for e in distribution.iter()):raise ValueError('trial Distribution identity mismatch')
    return identity

try:
    def interrupted(n,frame):raise RuntimeError('bounded collector interrupted '+str(n))
    for n in (signal.SIGALRM,signal.SIGTERM,signal.SIGINT):signal.signal(n,interrupted)
    signal.alarm(1080)
    version=command(['/usr/bin/sw_vers','-productVersion'],5).strip()
    if not version.startswith(spec['os_prefix']):raise ValueError('wrong guestOS '+version)
    found=None
    until=time.time()+30
    while time.time()<until:
        disks=plist_command(['/usr/sbin/diskutil','list','-plist']).get('WholeDisks',[])
        new=sorted(set(disks)-set(before))
        if len(new)>1:raise ValueError('multiple new whole disks')
        if len(new)==1:
            info=plist_command(['/usr/sbin/diskutil','info','-plist','/dev/'+new[0]])
            if info.get('Internal') is not False or info.get('BusProtocol')!='USB':raise ValueError('new disk not externalUSB')
            found=new[0];report['disk']=info;break
        time.sleep(.5)
    if not found:raise ValueError('no unique new disk')
    command(['/usr/sbin/diskutil','mountDisk','/dev/'+found],20)
    listing=plist_command(['/usr/sbin/diskutil','list','-plist','/dev/'+found])
    mounts=[]
    def collect(node):
        if isinstance(node,dict):
            if node.get('MountPoint'):mounts.append(node['MountPoint'])
            for value in node.values():collect(value)
        elif isinstance(node,list):
            for value in node:collect(value)
    collect(listing)
    mounts=sorted(set(mounts));matches=[]
    for mount in mounts:
        payload=mount+'/'+spec['payload']
        if os.path.exists(payload):matches.append((mount,payload))
    if len(matches)!=1:raise ValueError('expected payload mount ambiguous/absent')
    mount,payload=matches[0]
    if not mount.startswith('/Volumes/') or os.path.realpath(payload)!=payload:raise ValueError('payload path noncanonical')
    report['payload']=payload
    target=spec['app']
    if spec['kind']=='app':report['source_identity']=exact_identity(payload)
    elif spec['kind']=='pkg':
        metadata_dir=directory+'/package-metadata';os.mkdir(metadata_dir,0o700)
        command(['/usr/bin/xar','-xf',payload,'-C',metadata_dir,'Distribution','FinalCutProXTrial.pkg/PackageInfo'],30)
        def xml_metadata(relative):
            path=metadata_dir+'/'+relative
            if os.path.realpath(path)!=path or not stat.S_ISREG(os.lstat(path).st_mode) or not 0<os.stat(path).st_size<=524288:raise ValueError('package metadata outside bounds')
            with open(path,'rb') as stream:return ET.fromstring(stream.read(524289))
        package=xml_metadata('FinalCutProXTrial.pkg/PackageInfo')
        distribution=xml_metadata('Distribution')
        report['package_identity']=validate_package_metadata(package,distribution)
    else:raise ValueError('unknown fixed install type')
    if os.path.exists(target):
        report['preexisting_app']=exact_identity(target)
        report['installation_mode']='reused_exact_preexisting_app'
    else:
        if spec['kind']=='app':command(['/usr/bin/ditto',payload,target],840)
        else:command(['/usr/sbin/installer','-pkg',payload,'-target','/'],840)
        report['installation_mode']='installed_this_boot'
    report['installed_identity']=exact_identity(target)
    binary=target+'/Contents/MacOS/'+spec['identity']['CFBundleExecutable']
    if os.path.realpath(binary)!=binary or not stat.S_ISREG(os.lstat(binary).st_mode):raise ValueError('nonregular installed executable')
    # QGA staging directories are root-private. Copy only the verified small helper into our
    # soon-to-be-console-owned directory before dropping identity.
    helper=spec['ax_helper']
    if not re.match(r'\A/private/var/tmp/VirtualIntelMac\.[A-Za-z0-9]{6}/Transfer\.bin\Z',helper):raise ValueError('invalid stage receipt')
    parent=os.path.dirname(helper);parent_info=os.lstat(parent)
    if os.path.realpath(parent)!=parent or not stat.S_ISDIR(parent_info.st_mode) or parent_info.st_uid!=0 or stat.S_IMODE(parent_info.st_mode)!=0o700:raise ValueError('stage parent identity changed')
    fd=os.open(helper,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    try:
        metadata=os.fstat(fd)
        if not stat.S_ISREG(metadata.st_mode) or not 0<metadata.st_size<=2097152:raise ValueError('AX helper outside regular/size budget')
        helper_data=os.read(fd,2097153)
    finally:os.close(fd)
    if len(helper_data)!=metadata.st_size or hashlib.sha256(helper_data).hexdigest()!=spec['ax_helper_sha256']:raise ValueError('staged AX helper identity changed')
    helper=directory+'/ax-observe'
    fd=os.open(helper,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o755)
    with os.fdopen(fd,'wb') as stream:stream.write(helper_data)
    spec['ax_helper']=helper
    report['console_uid']=join_console()
    home=directory+'/home';os.mkdir(home,0o700)
    env=dict(os.environ,HOME=home,CFFIXED_USER_HOME=home,TMPDIR=directory+'/')
    env.pop('PYTHONPATH',None);env.pop('PYTHONHOME',None)
    # Observe existing processes without signaling or launching a second copy.
    existing=command(['/usr/bin/pgrep','-x',spec['identity']['CFBundleExecutable']],3,(1,))
    if existing.strip():raise ValueError('preexisting app process')
    with open(os.devnull,'rb') as null:
        app=subprocess.Popen([binary],stdin=null,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,preexec_fn=limits,close_fds=True)
    log=(reader(app.stdout),reader(app.stderr))
    owned.append(app);report['owned_app_pid']=app.pid
    report['observations']=[]
    launched_at=time.time()
    for delay in (3,7,10):
        time.sleep(delay)
        row={'elapsed_seconds':time.time()-launched_at,'alive':app.poll() is None,'exit_code':app.poll()}
        if row['alive']:
            try:row['ax']=observe(app.pid)
            except Exception as e:row['ax']={'available':False,'reason':repr(e)}
        report['observations'].append(row)
        if not row['alive']:break
    report['result']='OBSERVED_LAUNCH'
except Exception as error:report['error']=repr(error)
finally:
    errors=[]
    for child in reversed(owned):
        try:stop(child)
        except Exception as error:errors.append(repr(error))
    if log is not None:
        out,err=captured(log[0]),captured(log[1]);report['app_stdout']=out;report['app_stderr']=err
        report['app_log_at_limit']=out['at_limit'] or err['at_limit'] or not out['reader_finished'] or not err['reader_finished']
    report['cleanup_errors']=errors
    signal.alarm(0)
    print(json.dumps(report))
'''


def wire_bool(value, expected):
    """NSNumber JSON may encode native booleans as0/1; accept no other coercions."""
    return type(value) in (bool,int) and value in (0,1) and value == expected


def qualify_launch(report):
    """Observation never mistakes a live PID or an alert for an operational editor."""
    if not isinstance(report,dict) or report.get('result')!='OBSERVED_LAUNCH' or report.get('cleanup_errors')!=[] or report.get('app_log_at_limit') is not False:
        return 'INCONCLUSIVE'
    observations=report.get('observations',[])
    if len(observations)!=3 or any(row.get('alive') is not True for row in observations):return 'EXITED_OR_INCOMPLETE'
    ax=observations[-1].get('ax',{})
    if ax.get('result')!='OBSERVED_WINDOWS' or any(not wire_bool(ax.get(key),True) for key in ('identityMatched','identityStillMatched','axTrusted')) or not ax.get('windowCount') or not wire_bool(ax.get('truncated'),False) or not wire_bool(ax.get('deadlineExceeded'),False):return 'INCONCLUSIVE'
    nodes=[]
    def flatten(value):
        if isinstance(value,dict):
            nodes.append(value)
            for child in value.values():flatten(child)
        elif isinstance(value,list):
            for child in value:flatten(child)
    flatten(ax.get('windows',[]))
    text=' '.join(str(v) for row in nodes for v in row.values() if isinstance(v,str)).lower()
    if any(token in text for token in ('graphics configuration','graphics card','unsupported graphics','not supported','minimum system','unexpectedly quit','opencl','opengl')):return 'BLOCKED_GRAPHICS_OR_COMPATIBILITY'
    if any(row.get('AXRole') in ('AXSheet','AXAlert') or row.get('AXSubrole') in ('AXDialog','AXSystemDialog') for row in nodes):return 'BLOCKED_OR_FIRST_RUN_DIALOG'
    # Even a plain first window can be a splash/welcome screen. Preserve observations for review.
    return 'OBSERVED_WINDOWS_REQUIRES_REVIEW'
