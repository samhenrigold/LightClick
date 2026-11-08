"""guest-bench compile-only Numbers09 gate. Argument: fresh existing results directory.

Launches fixed Numbers2.3 in a disposable guest/private home. Compiles, NEVER runs,
the repository's cell repaint script with its application literal changed to the
inventoried direct path. No documents, calculated results or export API are qualified.
"""
import base64
import hashlib
import json
from pathlib import Path

LEGACY_APP = '/Applications/iWork \'09/Numbers.app'
APP = '/Applications/Numbers.app'


def compile_source(source):
    path = source / 'probes/iwork-cell-repaint.applescript'
    original = path.read_bytes()
    if not 0 < len(original) <= 16384:
        raise ValueError('existing Numbers script outside source budget')
    old = ('tell application "' + LEGACY_APP + '"').encode()
    new = ('tell application "' + APP + '"').encode()
    if original.count(old) != 1:
        raise ValueError('existing Numbers script application literal changed; review required')
    return original, original.replace(old, new)


COLLECTOR = r'''import base64, ctypes, hashlib, json, os, plistlib, pwd, resource, signal, stat, subprocess, sys, tempfile, threading, time
APP='/Applications/Numbers.app'
CAP=65536
owned=[]
report={'result':'INCONCLUSIVE','scope':'fixed Numbers launch and compile ONLY; no script/document execution', 'commands':[]}
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
    return {'text':b''.join(state['parts']).decode('utf-8','replace'),'at_limit':state['at_limit'],
            'bytes':state['bytes'],'reader_finished':not thread.is_alive()}

def limits():
    # Payload/cache/app-owned files remain unrestricted; bound diagnostic pipes only.
    os.setsid()

def command(argv, seconds, directory, env):
    def command_limits():
        limits()
        resource.setrlimit(resource.RLIMIT_CPU,(20,20))
    with open(os.devnull,'rb') as null:
        child=subprocess.Popen(argv,stdin=null,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                               env=env,preexec_fn=command_limits,close_fds=True)
    owned.append(child)
    out,err=reader(child.stdout),reader(child.stderr)
    until=time.time()+seconds
    while child.poll() is None and time.time()<until and not out[0]['at_limit'] and not err[0]['at_limit']:time.sleep(.05)
    expired=child.poll() is None and time.time()>=until
    if child.poll() is None:stop(child)
    a,b=captured(out),captured(err)
    result={'argv':argv,'timeout_seconds':seconds,'timed_out':expired,'exit_code':child.poll(),
            'stdout':a['text'],'stderr':b['text'],'at_limit':a['at_limit'] or b['at_limit'],
            'readers_finished':a['reader_finished'] and b['reader_finished']}
    report['commands'].append(result)
    if result['at_limit'] or not result['readers_finished']:raise ValueError('command diagnostics incomplete/outside budget')
    return result

def stop(child):
    if child.poll() is not None:return
    # Only this Popen child's own session, never process-name or window selection.
    if os.getpgid(child.pid)!=child.pid:raise ValueError('owned child process group changed')
    os.killpg(child.pid,signal.SIGTERM)
    until=time.time()+1
    while child.poll() is None and time.time()<until:time.sleep(.05)
    if child.poll() is None:os.killpg(child.pid,signal.SIGKILL)
    until=time.time()+1
    while child.poll() is None and time.time()<until:time.sleep(.05)
    if child.poll() is None:raise ValueError('owned child did not reap')

def regular(path,cap):
    if os.path.realpath(path)!=path:raise ValueError('noncanonical fixed/generated path')
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    try:
        info=os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or not 0<info.st_size<=cap:raise ValueError('file outside regular/size budget')
        data=os.read(fd,cap+1)
        if len(data)!=info.st_size:raise ValueError('short/changed file')
        return data
    finally:os.close(fd)

def join_console():
    uid=os.stat('/dev/console').st_uid
    if uid==0:raise ValueError('no logged-in guest console user')
    user=pwd.getpwuid(uid)
    found=command(['/usr/bin/pgrep','-x','Finder'],3,'/private/var/tmp',dict(os.environ))
    pids=found['stdout'].split()
    if found['timed_out'] or found['exit_code'] or len(pids)!=1:raise ValueError('guest Finder identity ambiguous')
    libc=ctypes.CDLL('/usr/lib/libSystem.B.dylib')
    me=ctypes.c_uint.in_dll(libc,'mach_task_self_').value
    task,bootstrap,session=ctypes.c_uint(),ctypes.c_uint(),ctypes.c_uint()
    token,count=(ctypes.c_uint*8)(),ctypes.c_uint(8)
    if libc.task_for_pid(me,int(pids[0]),ctypes.byref(task)) or libc.task_info(task,15,token,ctypes.byref(count)) or libc.task_get_special_port(task,4,ctypes.byref(bootstrap)):
        raise ValueError('could not read guest Finder audit/bootstrap session')
    if libc.audit_session_port(token[6],ctypes.byref(session))==-1 or libc.audit_session_join(session)==-1 or libc.task_set_special_port(me,4,bootstrap):
        raise ValueError('could not join guest Finder session')
    os.initgroups(user.pw_name,user.pw_gid);os.setgid(user.pw_gid);os.setuid(uid)
    return uid

try:
    def interrupted(signum,frame):raise RuntimeError('collector interrupted: '+str(signum))
    signal.signal(signal.SIGALRM,interrupted)
    signal.signal(signal.SIGTERM,interrupted)
    signal.signal(signal.SIGINT,interrupted)
    signal.alarm(65)
    data=base64.b64decode(sys.argv[1])
    if not 0<len(data)<=16384 or hashlib.sha256(data).hexdigest()!=sys.argv[2]:raise ValueError('script source identity/budget mismatch')
    metadata=plistlib.readPlistFromString(regular(APP+'/Contents/Info.plist',524288))
    actual=dict((key,metadata.get(key))for key in('CFBundleIdentifier','CFBundleShortVersionString','CFBundleVersion','CFBundleExecutable'))
    report['application']=actual
    if actual!={'CFBundleIdentifier':'com.apple.iWork.Numbers','CFBundleShortVersionString':'2.3','CFBundleVersion':'554','CFBundleExecutable':'Numbers'}:
        raise ValueError('fixed installed Numbers2.3/build554 identity changed')
    binary=APP+'/Contents/MacOS/Numbers'
    if os.path.realpath(binary)!=binary or not stat.S_ISREG(os.lstat(binary).st_mode):raise ValueError('fixed executable noncanonical/nonregular')
    report['console_uid']=join_console()
    directory=tempfile.mkdtemp(prefix='LightClickNumbersCompile.',dir='/private/var/tmp')
    os.chmod(directory,0o700)
    report['private_directory']=directory
    home=directory+'/home';os.mkdir(home,0o700)
    env=dict(os.environ,HOME=home,CFFIXED_USER_HOME=home,TMPDIR=directory+'/')
    env.pop('PYTHONPATH',None);env.pop('PYTHONHOME',None)
    existing=command(['/usr/bin/pgrep','-x','Numbers'],3,directory,env)
    if existing['timed_out'] or existing['exit_code']!=1 or existing['stdout'].strip():raise ValueError('preexisting/ambiguous guest Numbers process; refusing launch')
    script=directory+'/cell-repaint.applescript';compiled=directory+'/cell-repaint.scpt'
    fd=os.open(script,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'wb')as stream:stream.write(data)
    with open(os.devnull,'rb') as null:
        app=subprocess.Popen([binary],stdin=null,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                             env=env,preexec_fn=limits,close_fds=True)
    owned.append(app);report['owned_app_pid']=app.pid
    log=(reader(app.stdout),reader(app.stderr))
    time.sleep(2)
    if app.poll() is not None:raise ValueError('owned Numbers process exited before compilation')
    result=command(['/usr/bin/osacompile','-o',compiled,script],30,directory,env)
    report['compiler']=result
    if result['timed_out'] or result['exit_code']!=0:raise ValueError('Numbers compile gate failed; retained diagnostics, no API qualified')
    output=regular(compiled,1048576)
    report['compiled']={'bytes':len(output),'sha256':hashlib.sha256(output).hexdigest()}
    report['result']='PASS_COMPILE_ONLY'
except Exception as error:report['error']=repr(error)
finally:
    errors=[]
    for child in reversed(owned):
        try:stop(child)
        except Exception as error:errors.append(repr(error))
    if 'log'in globals():
        a,b=captured(log[0]),captured(log[1])
        report['app_stdout']=a;report['app_stderr']=b
        report['app_log_at_limit']=a['at_limit'] or b['at_limit'] or not a['reader_finished'] or not b['reader_finished']
        if report['app_log_at_limit']:report['result']='INCONCLUSIVE'
    report['cleanup_errors']=errors
    if errors:report['result']='INCONCLUSIVE'
    signal.alarm(0)
    print(json.dumps(report))
'''


def parse_response(response):
    if not isinstance(response, dict) or response.get('ExitCode') != 0:
        raise ValueError('guest launch/control failed: ' + repr(response))
    stdout = response.get('Stdout')
    if not isinstance(stdout, str) or len(stdout.encode()) > 300000:
        raise ValueError('guest report missing/outside budget')
    report = json.loads(stdout)
    if not isinstance(report, dict):
        raise ValueError('invalid guest report')
    if report.get('result') != 'PASS_COMPILE_ONLY':
        raise ValueError('compile gate not passed: ' + repr(report))
    compiler = report.get('compiler', {})
    directory = report.get('private_directory', '')
    import re
    if not re.fullmatch(r'/private/var/tmp/LightClickNumbersCompile\.[A-Za-z0-9_-]{6,16}', directory):
        raise ValueError('invalid generated compile directory')
    if (compiler.get('argv') != ['/usr/bin/osacompile', '-o', directory+'/cell-repaint.scpt', directory+'/cell-repaint.applescript']
            or compiler.get('exit_code') != 0 or compiler.get('timed_out') is not False or compiler.get('at_limit') is not False
            or compiler.get('readers_finished') is not True or report.get('app_log_at_limit') is not False
            or report.get('cleanup_errors') != []):
        raise ValueError('compiler/cleanup result invalid')
    compiled = report.get('compiled', {})
    if (type(compiled.get('bytes')) is not int or not 0 < compiled['bytes'] <= 1048576
            or not isinstance(compiled.get('sha256'), str) or not re.fullmatch('[0-9a-f]{64}', compiled['sha256'])):
        raise ValueError('compiled artifact absent/invalid')
    return report


def preflight():
    if len(arguments) != 1:
        raise ValueError('Numbers compile preflight requires fresh existing results directory')
    directory = Path(arguments[0]); artifact = directory/'numbers-compile.json'
    if not directory.is_dir() or artifact.exists():
        raise ValueError('results must be fresh/existing')
    original, script = compile_source(source)
    report = {'result': 'INCONCLUSIVE', 'phase': 'compile_only',
              'original_script_sha256': hashlib.sha256(original).hexdigest(),
              'compiled_source_sha256': hashlib.sha256(script).hexdigest(),
              'source_change': 'only fixed application literal: legacy subdirectory to direct path',
              'note': 'Compilation is not evidence of successful document/calculation/export operations.'}
    def save(): artifact.write_text(json.dumps(report, indent=2)+'\n')
    save()
    try:
        response = request({'Executable':'/usr/bin/python','Arguments':['-c',COLLECTOR,
                            base64.b64encode(script).decode(),hashlib.sha256(script).hexdigest()]},timeout=75)
        report['response'] = response; save()
        report['guest'] = parse_response(response)
        report.update(result='PASS_COMPILE_ONLY',phase='complete'); save()
        print(f'PASS_COMPILE_ONLY Numbers terms compiled, never executed; evidence {artifact}',flush=True)
    except (Exception,SystemExit) as error:
        report['error']=repr(error);save();raise


preflight()
