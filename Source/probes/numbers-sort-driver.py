"""guest-bench NEW_RESULTS EXISTING_HELPER EXPECTED_SHA256 [32|512].

One owned Numbers2.3/i386 CSV/sort task with full model verification.
Timing describes AppleEvent/model boundaries, not UI completion or pure sort CPU.
The helper uses declared legacy AppleEvents; no AppleScript commands are guessed.
Never run the guest helper or this collector on the host.
"""
import hashlib
import json
import math
from pathlib import Path
import re
import stat
import time

COLLECTOR = r'''import ctypes,errno,hashlib,json,os,plistlib,pwd,re,signal,stat,struct,subprocess,sys,tempfile,threading,time
APP='/Applications/Numbers.app'
BINARY=APP+'/Contents/MacOS/Numbers'
FINDER='/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder'
report={'schema':1,'result':'INCOMPLETE','scope':'one owned32bit Numbers CSV/model-sort qualification; no app speed or UI claim','helper_launches':0,'commands':[]}
owned=[];unreaped=set();app=None;app_log=None;code=0
class Stop(Exception):pass
libc=ctypes.CDLL('/usr/lib/libSystem.B.dylib',use_errno=True)
class Timebase(ctypes.Structure):_fields_=[('numer',ctypes.c_uint),('denom',ctypes.c_uint)]
tb=Timebase();libc.mach_absolute_time.restype=ctypes.c_uint64
if libc.mach_timebase_info(ctypes.byref(tb)) or not tb.numer or not tb.denom:raise Stop('mach clock unavailable')
def now():return libc.mach_absolute_time()*float(tb.numer)/tb.denom/1e9
collector_started=int(libc.mach_absolute_time())
report['collector_timing']={'clock':'mach_absolute_time','timebase_numer':int(tb.numer),'timebase_denom':int(tb.denom),'markers':{'collector_started':collector_started}}
deadline=now()+80
def interrupted(number,frame):raise Stop('collector interrupted '+str(number))
for sig in (signal.SIGALRM,signal.SIGTERM,signal.SIGINT):signal.signal(sig,interrupted)
signal.alarm(80)
def reader(stream,cap):
    state={'parts':[],'bytes':0,'over':False,'eof':False,'done':False,'error':None}
    def drain():
        try:
            while True:
                try:data=os.read(stream.fileno(),4096)
                except OSError as e:
                    if e.errno==errno.EINTR:continue
                    raise
                if not data:state['eof']=True;break
                room=max(0,cap-state['bytes'])
                if room:state['parts'].append(data[:room])
                state['bytes']+=len(data)
                if state['bytes']>cap:state['over']=True
        except BaseException as e:state['error']=repr(e)[:160]
        finally:
            try:stream.close()
            except BaseException as e:state['error']=repr(e)[:160]
            state['done']=True
    thread=threading.Thread(target=drain);thread.daemon=True;thread.start()
    return state,thread
def capture(pair):
    state,thread=pair;thread.join(1)
    return dict((k,state[k])for k in ('bytes','over','eof','done','error')),b''.join(state['parts']).decode('utf-8','replace'),not thread.is_alive()
def packed(pair):
    state,text,retired=capture(pair);state.update(text=text,reader_retired=retired);return state
def clean_stream(row):return row['done'] and row['eof'] and row['reader_retired'] and not row['over'] and row['error'] is None
def stop(child):
    if child.poll() is not None:return True
    if child.pid in unreaped:return False
    for sig in (signal.SIGTERM,signal.SIGKILL):
        try:
            if os.getpgid(child.pid)!=child.pid:unreaped.add(child.pid);return False
            os.killpg(child.pid,sig)
        except OSError as e:
            if e.errno!=errno.ESRCH:unreaped.add(child.pid);return False
        for unused in range(20):
            if child.poll() is not None:return True
            time.sleep(.05)
    if child.poll() is not None:return True
    unreaped.add(child.pid);return False
def spawn(argv,env,caps):
    with open(os.devnull,'rb')as null:
        child=subprocess.Popen(argv,stdin=null,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,preexec_fn=os.setsid,close_fds=True)
    owned.append(child);return child,(reader(child.stdout,caps[0]),reader(child.stderr,caps[1]))
def command_abort(logs):
    if app is not None:
        if app.poll() is not None:return 'app_exited','app'
        if any(x[0]['error'] for x in app_log):return 'stream_error','app'
        if any(x[0]['over'] for x in app_log):return 'app_output_bound','app'
    if any(x[0]['error'] for x in logs):return 'stream_error','helper'
    if any(x[0]['over'] for x in logs):return 'helper_output_bound','helper'
    return None,None
def command(argv,seconds,env,caps=(4096,4096)):
    child,logs=spawn(argv,env,caps);until=min(deadline,now()+seconds)
    reason,origin=None,None
    while True:
        running=child.poll() is None
        if running and now()>=until:reason='deadline_expired';break
        reason,origin=command_abort(logs)
        if reason or not running:break
        time.sleep(.05)
    unreaped_command=child.poll() is None and not stop(child)
    row={'argv':argv,'pid':child.pid,'exit_code':child.poll(),'timed_out':reason=='deadline_expired','abort_reason':reason,'abort_stream':origin,'stdout':packed(logs[0]),'stderr':packed(logs[1])}
    if not reason and not all(clean_stream(row[k]) for k in ('stdout','stderr')):
        reason='helper_output_bound' if any(row[k]['over'] for k in ('stdout','stderr'))else 'stream_error'
        row.update(abort_reason=reason,abort_stream='helper')
    if unreaped_command:row['unreaped']=True
    report['commands'].append(row)
    if reason:report.update(abort_reason=reason,abort_stream=row['abort_stream'])
    if unreaped_command or reason:raise Stop('command aborted:'+str(reason)+';unreaped='+str(unreaped_command))
    return row
def regular(path,cap,owner=None):
    if os.path.realpath(path)!=path:raise Stop('noncanonical regular path')
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    try:
        a=os.fstat(fd)
        if not stat.S_ISREG(a.st_mode) or a.st_nlink!=1 or not 0<a.st_size<=cap or(owner is not None and a.st_uid!=owner):raise Stop('regular file identity/budget')
        data=os.read(fd,cap+1);b=os.fstat(fd)
        if len(data)!=a.st_size or(a.st_dev,a.st_ino,a.st_size,a.st_mtime,a.st_ctime)!=(b.st_dev,b.st_ino,b.st_size,b.st_mtime,b.st_ctime):raise Stop('file changed/short')
        return data
    finally:os.close(fd)
def create(path,data,mode,uid,gid):
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,mode)
    try:
        at=0
        while at<len(data):
            n=os.write(fd,data[at:])
            if n<=0:raise Stop('copy write failed')
            at+=n
        os.fchmod(fd,mode);os.fchown(fd,uid,gid)
    finally:os.close(fd)
class BSDInfo(ctypes.Structure):
    # proc_bsdinfo/PROC_PIDTBSDINFO:12uint32,16+32chars,6uint32,2uint64.
    _fields_=[('prefix',ctypes.c_uint32*12),('comm',ctypes.c_char*16),('name',ctypes.c_char*32),('suffix',ctypes.c_uint32*6),('started',ctypes.c_uint64*2)]
proc=ctypes.CDLL('/usr/lib/libproc.dylib',use_errno=True)
proc.proc_pidinfo.argtypes=[ctypes.c_int,ctypes.c_int,ctypes.c_uint64,ctypes.c_void_p,ctypes.c_int];proc.proc_pidinfo.restype=ctypes.c_int
proc.proc_pidpath.argtypes=[ctypes.c_int,ctypes.c_void_p,ctypes.c_uint32];proc.proc_pidpath.restype=ctypes.c_int
def identity(pid,uid,path):
    value=BSDInfo();buf=ctypes.create_string_buffer(4096)
    if ctypes.sizeof(value)!=136 or proc.proc_pidinfo(pid,3,0,ctypes.byref(value),136)!=136 or proc.proc_pidpath(pid,buf,4096)<=0:raise Stop('process metadata unavailable')
    actual=buf.value.decode('utf-8','strict')
    if value.prefix[3]!=pid or value.prefix[5]!=uid or value.prefix[7]!=uid or actual!=path or not value.started[0] or value.started[1]>=1000000:raise Stop('process PID/UID/path mismatch')
    return {'pid':pid,'uid':uid,'path':actual,'start_seconds':int(value.started[0]),'start_microseconds':int(value.started[1])}
def same_process(before):
    if identity(before['pid'],before['uid'],before['path'])!=before:raise Stop('process start identity changed')
def finders(uid,env):
    row=command(['/usr/bin/pgrep','-x','-U',str(uid),'Finder'],3,env)
    words=row['stdout']['text'].split()
    if row['exit_code']!=0 or row['stderr']['text'] or len(words)!=1 or not words[0].isdigit():raise Stop('Finder identity ambiguous')
    return identity(int(words[0]),uid,FINDER)
def join(finder):
    same_process(finder);me=ctypes.c_uint.in_dll(libc,'mach_task_self_').value
    task,bootstrap,session=ctypes.c_uint(),ctypes.c_uint(),ctypes.c_uint();token=(ctypes.c_uint*8)();count=ctypes.c_uint(8)
    if(libc.task_for_pid(me,finder['pid'],ctypes.byref(task)) or libc.task_info(task,15,token,ctypes.byref(count)) or count.value!=8 or token[5]!=finder['pid'] or token[1]!=finder['uid'] or token[3]!=finder['uid'] or libc.task_get_special_port(task,4,ctypes.byref(bootstrap)) or libc.audit_session_port(token[6],ctypes.byref(session))==-1 or libc.audit_session_join(session)==-1 or libc.task_set_special_port(me,4,bootstrap)):raise Stop('Finder audit/bootstrap join failed')
    for port in (session.value,bootstrap.value,task.value):
        if port:libc.mach_port_deallocate(me,port)
    same_process(finder)
try:
    if os.geteuid()!=0 or len(sys.argv)!=2 or os.uname()[0]!='Darwin' or os.uname()[2].split('.')[0]!='13':raise Stop('owned root Darwin13 collector required')
    spec=json.loads(sys.argv[1]);staged=spec['helper_path'];expected=spec['helper_sha256'];rows=spec['rows']
    if type(rows)not in(int,long) or rows not in(32,512):raise Stop('rows must be exactly32 or512')
    report['rows_requested']=rows
    if not re.match(r'\A/private/var/tmp/VirtualIntelMac\.[A-Za-z0-9]{6}/Transfer\.bin\Z',staged):raise Stop('helper stage prefix')
    parent=os.path.dirname(staged);a=os.lstat(parent)
    if os.path.realpath(parent)!=parent or not stat.S_ISDIR(a.st_mode) or a.st_uid!=0 or stat.S_IMODE(a.st_mode)!=0o700:raise Stop('stage parent identity')
    helper_data=regular(staged,1048576,0)
    if helper_data[:8]!='\xcf\xfa\xed\xfe\x07\x00\x00\x01' or hashlib.sha256(helper_data).hexdigest()!=expected:raise Stop('staged helper bytes')
    info=plistlib.readPlistFromString(regular(APP+'/Contents/Info.plist',524288))
    wanted={'CFBundleIdentifier':'com.apple.iWork.Numbers','CFBundleShortVersionString':'2.3','CFBundleVersion':'554','CFBundleExecutable':'Numbers'}
    if dict((k,info.get(k))for k in wanted)!=wanted:raise Stop('Numbers exact bundle identity')
    binary=regular(BINARY,33554432)
    if binary[:4]!='\xce\xfa\xed\xfe' or struct.unpack('<7I',binary[:28])[1:4]!=(7,3,2):raise Stop('Numbers thin i386 identity')
    report['application']=wanted;report['application_architecture']='i386';report['application_binary_sha256']=hashlib.sha256(binary).hexdigest()
    for filename,key,wanted_hash in (('Numbers.scriptSuite','script_suite_sha256','f5bff41c70f87ca9473880d457f134fdf4aaae21d9d602e4d26fe9e78b41022e'),('Numbers.scriptTerminology','script_terminology_sha256','8c09c258cd19d319807b27da69cb758312af26cd76fc852ae709ab69c6e5ad39')):
        actual_hash=hashlib.sha256(regular(APP+'/Contents/Resources/'+filename,262144)).hexdigest()
        if actual_hash!=wanted_hash:raise Stop('Numbers legacy declarations changed')
        report[key]=actual_hash
    uid=os.stat('/dev/console').st_uid
    if uid!=501:raise Stop('expected owned console UID501')
    user=pwd.getpwuid(uid);env={'PATH':'/usr/bin:/bin','LANG':'C','LC_ALL':'C'}
    finder=finders(uid,env);report['finder_before']=finder
    existing=command(['/usr/bin/pgrep','-x','Numbers'],3,env)
    if existing['exit_code']!=1 or existing['stdout']['text'].strip() or existing['stderr']['text']:raise Stop('preexisting Numbers refused')
    directory=tempfile.mkdtemp(prefix='LightClickNumbersSort.',dir='/private/var/tmp');os.chmod(directory,0o700)
    home=directory+'/home';os.mkdir(home,0o700);helper=directory+'/sort-helper';csv=directory+'/input.csv'
    csv_data=''.join('%d,%d\n'%(key,key*17+3)for key in range(rows,0,-1))
    create(helper,helper_data,0o700,uid,user.pw_gid);create(csv,csv_data,0o600,uid,user.pw_gid)
    if hashlib.sha256(regular(helper,1048576,uid)).hexdigest()!=expected:raise Stop('private helper copy mismatch')
    os.chown(home,uid,user.pw_gid);os.chown(directory,uid,user.pw_gid)
    report.update(private_directory=directory,helper_sha256=expected,csv_sha256=hashlib.sha256(csv_data).hexdigest(),csv_bytes=len(csv_data),csv_path=csv)
    join(finder);os.initgroups(user.pw_name,user.pw_gid);os.setgid(user.pw_gid);os.setuid(uid)
    if os.getuid()!=uid or os.geteuid()!=uid or os.stat('/dev/console').st_uid!=uid:raise Stop('console credentials changed')
    same_process(finder);report['console_uid']=uid
    env.update(HOME=home,CFFIXED_USER_HOME=home,TMPDIR=directory+'/')
    report['collector_timing']['markers']['app_spawn']=int(libc.mach_absolute_time())
    app,app_log=spawn([BINARY],env,(4096,16384));report['owned_app_pid']=app.pid
    app_until=min(deadline,now()+5)
    while True:
        if app.poll() is not None:raise Stop('owned Numbers exited')
        try:app_identity=identity(app.pid,uid,BINARY);break
        except Stop:
            if now()>=app_until:raise
            time.sleep(.05)
    report['app_identity_before']=app_identity
    helper_argv=[helper,'--pid',str(app.pid),'--csv',csv,'--uid',str(uid)]
    if rows==512:helper_argv+=['--rows','512']
    report['helper_launches']=1
    report['collector_timing']['markers']['helper_spawn']=int(libc.mach_absolute_time())
    helper_result=command(helper_argv,60,env,(24576,4096));report['helper']=helper_result
    report['collector_timing']['markers']['helper_complete']=int(libc.mach_absolute_time())
    ct=report['collector_timing'];cm=ct['markers'];scale=float(tb.numer)/tb.denom/1e9
    ct.update(scope='collector_process_spawn_through_helper_stdio_collection',phase_seconds=dict((key,(value-collector_started)*scale)for key,value in cm.items()),app_spawn_to_helper_spawn_seconds=(cm['helper_spawn']-cm['app_spawn'])*scale,app_spawn_to_helper_complete_seconds=(cm['helper_complete']-cm['app_spawn'])*scale,helper_process_and_stdio_seconds=(cm['helper_complete']-cm['helper_spawn'])*scale)
    if app.poll() is not None:raise Stop('owned Numbers exited during helper')
    same_process(app_identity);same_process(finder)
    report['app_identity_after']=identity(app.pid,uid,BINARY);report['finder_after']=identity(finder['pid'],uid,FINDER)
    report['app_alive_after_helper']=True;report['result']='NUMBERS_SORT_COLLECTED'
except BaseException as error:
    report.update(result='STOP_ALL_REQUESTS',error=repr(error)[:320]);code=77
finally:
    signal.alarm(0)
    for sig in (signal.SIGTERM,signal.SIGINT):signal.signal(sig,signal.SIG_IGN)
    errors=[]
    for child in reversed(owned):
        try:
            if not stop(child):errors.append('owned child unreaped:'+str(child.pid))
        except BaseException as error:errors.append(repr(error)[:160])
    if app_log is not None:
        report['app_stdout']=packed(app_log[0]);report['app_stderr']=packed(app_log[1]);report['app_exit_after_cleanup']=app.poll()
        if not all(clean_stream(report[k])for k in ('app_stdout','app_stderr')):errors.append('app stdio incomplete')
    report['cleanup_errors']=errors
    report['unreaped_pids']=sorted(unreaped)
    if errors:report['result']='STOP_ALL_REQUESTS';code=77
    text=json.dumps(report,separators=(',',':'))
    if len(text.encode('utf-8'))>65535:text='{"schema":1,"result":"STOP_ALL_REQUESTS","error":"collector receipt cap"}';code=77
    sys.stdout.write(text+'\n');sys.stdout.flush()
sys.exit(code)
'''


def closed_stream(row, cap):
    return (isinstance(row, dict) and row.get('eof') is True and row.get('done') is True and
            row.get('reader_retired') is True and row.get('over') is False and
            'error' in row and row['error'] is None and type(row.get('bytes')) is int and
            0 <= row['bytes'] <= cap and isinstance(row.get('text'), str) and len(row['text'].encode()) <= cap)


def process_identity(row, path):
    return (isinstance(row, dict) and type(row.get('pid')) is int and 1 < row['pid'] < 2147483648 and
            type(row.get('uid')) is int and row['uid'] == 501 and row.get('path') == path and
            type(row.get('start_seconds')) is int and row['start_seconds'] > 0 and
            type(row.get('start_microseconds')) is int and 0 <= row['start_microseconds'] < 1000000)


def finite_number(value):
    return type(value) in (int, float) and math.isfinite(value)


def unsigned(value, maximum=(1 << 64) - 1):
    return type(value) is int and 0 <= value <= maximum


def same_seconds(value, expected):
    # NSNumber JSON doubles and independent integer-tick conversion may round.
    return finite_number(value) and math.isclose(value, expected, rel_tol=1e-8, abs_tol=1e-8)


def clock_fields(clock, names, upper):
    if not isinstance(clock, dict) or clock.get('clock') != 'mach_absolute_time':
        raise ValueError('mach clock evidence missing')
    numer, denom = clock.get('timebase_numer'), clock.get('timebase_denom')
    if not unsigned(numer, 0xffffffff) or not numer or not unsigned(denom, 0xffffffff) or not denom:
        raise ValueError('mach timebase invalid')
    markers = clock.get('markers')
    if not isinstance(markers, dict) or set(markers) != set(names):
        raise ValueError('clock markers incomplete')
    ticks = [markers[name] for name in names]
    if any(not unsigned(tick) or not tick for tick in ticks) or any(a >= b for a, b in zip(ticks, ticks[1:])):
        raise ValueError('clock markers not strictly ordered')
    phases = [(tick-ticks[0])*numer/denom/1e9 for tick in ticks]
    if not all(math.isfinite(value) for value in phases) or not 0 < phases[-1] < upper:
        raise ValueError('clock interval outside deadline')
    return phases


def validate_measurements(report, value, rows):
    collector = report.get('collector_timing')
    if collector is not None:
        # These bracket process creation and helper completion/stdio collection.
        # Their epoch is never compared with the helper's separate phase clock.
        cnames = ('collector_started', 'app_spawn', 'helper_spawn', 'helper_complete')
        cseconds = clock_fields(collector, cnames, 80)
        phases = collector.get('phase_seconds')
        durations = {'app_spawn_to_helper_spawn_seconds': cseconds[2]-cseconds[1],
                     'app_spawn_to_helper_complete_seconds': cseconds[3]-cseconds[1],
                     'helper_process_and_stdio_seconds': cseconds[3]-cseconds[2]}
        if (collector.get('scope') != 'collector_process_spawn_through_helper_stdio_collection' or
                not isinstance(phases, dict) or set(phases) != set(cnames) or
                any(not same_seconds(phases[n], sec) for n, sec in zip(cnames, cseconds)) or
                any(not same_seconds(collector.get(k), sec) for k, sec in durations.items())):
            raise ValueError('collector process timing conversion mismatch')
    elif rows != 32:
        raise ValueError('collector task timing missing')
    if value.get('timing_qualified') is False and rows == 32 and 'timing' not in value:
        # Original 32-row qualification helper remains supported unchanged.
        return
    if value.get('timing_qualified') is not True or type(value.get('rows_requested')) is not int or value['rows_requested'] != rows:
        raise ValueError('helper measured-task scope missing')
    names = ('before_open', 'open_reply', 'initial_model_verified', 'before_sort', 'sort_reply', 'sorted_model_verified')
    timing = value.get('timing')
    seconds = clock_fields(timing, names, 60)
    if (timing.get('complete') is not True or
            timing.get('scope') != 'guest_AE_roundtrip_and_full_model_verification_startup_excluded' or
            any(timing.get(k) is not False for k in ('pure_algorithm_timing', 'ui_completion_observed',
                                                     'host_cpu_observed', 'observer_overhead_calibrated'))):
        raise ValueError('helper timing interpretation unqualified')
    phases = timing.get('phase_seconds')
    if not isinstance(phases, dict) or set(phases) != set(names) or any(not same_seconds(phases[n], s) for n, s in zip(names, seconds)):
        raise ValueError('helper phase conversion mismatch')
    derived = {'open_roundtrip_seconds': seconds[1], 'import_model_verified_seconds': seconds[2],
               'sort_roundtrip_seconds': seconds[4]-seconds[3],
               'sort_model_verified_seconds': seconds[5]-seconds[3], 'task_model_verified_seconds': seconds[5]}
    if any(not same_seconds(timing.get(k), s) or not 0 < timing[k] < 60 for k, s in derived.items()):
        raise ValueError('helper phase durations mismatch')
    if not finite_number(value.get('helper_seconds')) or not seconds[-1] <= value['helper_seconds'] <= 60:
        raise ValueError('helper elapsed interval inconsistent')
    cpu = value.get('target_cpu')
    if (not isinstance(cpu, dict) or type(cpu.get('available')) is not bool or type(cpu.get('qualified')) is not bool or
            type(cpu.get('pid')) is not int or cpu['pid'] != report['owned_app_pid'] or
            cpu.get('scope') != 'owned_Numbers_process_snapshots_bracketing_before_open_to_sorted_model_verified' or
            cpu.get('host_cpu_observed') is not False):
        raise ValueError('target guest CPU scope invalid')
    time_keys = ('before_user_ticks', 'before_system_ticks', 'after_user_ticks', 'after_system_ticks',
                 'user_ticks', 'system_ticks', 'user_seconds', 'system_seconds', 'unit', 'timebase_numer', 'timebase_denom')
    if cpu['available']:
        if (any(type(cpu.get(k)) is not int for k in ('before_status', 'before_errno', 'after_status', 'after_errno')) or
                any(type(cpu.get(k)) is not bool for k in ('before_sampled', 'after_sampled'))):
            raise ValueError('target guest CPU sample statuses missing')
    elif cpu['qualified'] or any(k in cpu for k in ('before_status', 'before_errno', 'after_status', 'after_errno', 'before_sampled', 'after_sampled')):
        raise ValueError('unavailable CPU has fabricated samples')
    if not cpu['qualified']:
        if any(k in cpu for k in time_keys):
            raise ValueError('unqualified CPU has numerical times')
        return  # Optional CPU failures do not invalidate a verified wall task.
    if (not cpu['available'] or cpu.get('unit') != 'RUSAGE_INFO_V0_mach_absolute_ticks' or
            any(type(cpu.get(k)) is not int or cpu[k] != timing[k] for k in ('timebase_numer', 'timebase_denom')) or
            cpu['before_status'] != 0 or cpu['after_status'] != 0 or
            cpu['before_sampled'] is not True or cpu['after_sampled'] is not True or
            any(not unsigned(cpu.get(k)) for k in time_keys[:6])):
        raise ValueError('target CPU counters unqualified')
    for label in ('user', 'system'):
        before, after, delta = (cpu[k] for k in ('before_'+label+'_ticks', 'after_'+label+'_ticks', label+'_ticks'))
        if after < before or delta != after-before or not same_seconds(cpu.get(label+'_seconds'), delta*cpu['timebase_numer']/cpu['timebase_denom']/1e9):
            raise ValueError('target CPU delta mismatch')


def qualify(response, expected, csv_hash, rows=32):
    if type(rows) is not int or rows not in (32, 512):
        raise ValueError('rows must be exactly32 or512')
    if not isinstance(response, dict) or 'Error' in response or type(response.get('ExitCode')) is not int or response['ExitCode'] != 0:
        raise ValueError('collector failed/ambiguous; stop all requests')
    text = response.get('Stdout')
    if not isinstance(text, str) or len(text.encode()) > 65536:
        raise ValueError('collector receipt outside bound')
    report = json.loads(text)
    if report.get('rows_requested', 32) != rows or type(report.get('rows_requested', 32)) is not int:
        raise ValueError('collector rows changed')
    if (type(report.get('schema')) is not int or report['schema'] != 1 or report.get('result') != 'NUMBERS_SORT_COLLECTED' or
            report.get('helper_sha256') != expected or report.get('csv_sha256') != csv_hash or
            type(report.get('helper_launches')) is not int or report['helper_launches'] != 1 or
            type(report.get('console_uid')) is not int or report['console_uid'] != 501 or
            report.get('cleanup_errors') != [] or report.get('unreaped_pids') != [] or
            report.get('script_suite_sha256') != 'f5bff41c70f87ca9473880d457f134fdf4aaae21d9d602e4d26fe9e78b41022e' or
            report.get('script_terminology_sha256') != '8c09c258cd19d319807b27da69cb758312af26cd76fc852ae709ab69c6e5ad39' or
            report.get('abort_reason') is not None or report.get('error') is not None or
            report.get('app_alive_after_helper') is not True):
        raise ValueError('collector scope/cleanup did not qualify')
    if (report.get('application') != {'CFBundleIdentifier': 'com.apple.iWork.Numbers', 'CFBundleShortVersionString': '2.3',
                                     'CFBundleVersion': '554', 'CFBundleExecutable': 'Numbers'} or
            report.get('application_architecture') != 'i386' or
            not isinstance(report.get('application_binary_sha256'), str) or
            not re.fullmatch(r'[0-9a-f]{64}', report['application_binary_sha256']) or
            type(report.get('app_exit_after_cleanup')) is not int):
        raise ValueError('application identity/retirement missing')
    if (not process_identity(report.get('finder_before'), '/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder') or
            not process_identity(report.get('app_identity_before'), '/Applications/Numbers.app/Contents/MacOS/Numbers')):
        raise ValueError('process identity evidence missing')
    if report.get('finder_before') != report.get('finder_after') or report.get('app_identity_before') != report.get('app_identity_after'):
        raise ValueError('process identity changed')
    for name in ('app_stdout', 'app_stderr'):
        if not closed_stream(report.get(name), 16384 if name == 'app_stderr' else 4096):
            raise ValueError('app output not closed')
    helper = report.get('helper', {})
    if (type(helper.get('pid')) is not int or helper['pid'] <= 1 or helper['pid'] == report.get('owned_app_pid') or
            type(helper.get('exit_code')) is not int or helper['exit_code'] != 0 or helper.get('timed_out') is not False or
            'abort_reason' not in helper or helper['abort_reason'] is not None or helper.get('abort_stream') is not None):
        raise ValueError('helper task did not complete successfully')
    for name in ('stdout', 'stderr'):
        if not closed_stream(helper.get(name), 24576 if name == 'stdout' else 4096):
            raise ValueError('helper output not closed')
    directory = report.get('private_directory')
    if (not isinstance(directory, str) or not re.fullmatch(r'/private/var/tmp/LightClickNumbersSort\.[A-Za-z0-9_-]{6,16}', directory) or
            report.get('csv_path') != directory+'/input.csv' or type(report.get('owned_app_pid')) is not int or
            report['owned_app_pid'] != report['app_identity_before']['pid'] or
            helper.get('argv') != [directory+'/sort-helper', '--pid', str(report['owned_app_pid']), '--csv', report['csv_path'], '--uid', '501'] + (['--rows', '512'] if rows == 512 else [])):
        raise ValueError('helper/document scope changed')
    value = json.loads(helper['stdout']['text'])
    wanted = {'schema': 1, 'result': 'NUMBERS_LEGACY_SORT_PASS', 'pid': report['owned_app_pid'], 'uid': 501,
              'csv_path': report['csv_path'], 'initial_documents': 0, 'row_count': rows, 'column_count': 2,
              'sort_status': 0, 'sort_event': 'NmTb/SORT', 'sort_direction': 'ascn',
              'document_owned': True, 'no_ui_input': True,
              'document_count': 1, 'sheet_count': 1, 'table_count': 1, 'phase': 'complete',
              'document_ownership_basis': 'empty_to_one_private_open_and_full_fixture',
              'sort_send_count': 1, 'readback_mode': 'two_column_bulk_values',
              'pid_start_sec': report['app_identity_before']['start_seconds'],
              'pid_start_usec': report['app_identity_before']['start_microseconds']}
    if any(type(value.get(k)) is not type(v) or value[k] != v for k, v in wanted.items()):
        raise ValueError('helper protocol/ownership did not qualify')
    if value.get('document_path_state') not in ('exact_csv', 'empty_import_path', 'null_import_path', 'missing_import_path'):
        raise ValueError('document path state unqualified')
    path_types = {'exact_csv': ('utxt', 'utf8', 'TEXT'), 'empty_import_path': ('utxt', 'utf8', 'TEXT'),
                  'null_import_path': ('null',), 'missing_import_path': ('type',)}
    if (value.get('document_path_type') not in path_types[value['document_path_state']] or
            value.get('object_shape') != {'documents': 'list', 'document': 'obj ', 'sheets': 'list',
                                          'sheet': 'obj ', 'tables': 'list', 'table': 'obj '}):
        raise ValueError('document object/path descriptor shape unqualified')
    readiness = value.get('readiness', {})
    if (readiness.get('method') != 'NSRunningApplication.finishedLaunching' or readiness.get('finished_launching') is not True or
            readiness.get('before_first_send') is not True or type(readiness.get('helper_seconds')) not in (int, float) or
            not math.isfinite(readiness['helper_seconds']) or not 0 <= readiness['helper_seconds'] <= 60):
        raise ValueError('application readiness unqualified')
    for key in ('before', 'after'):
        shape = value.get(key+'_shape', {})
        types = value.get(key+'_numeric_types')
        if (shape.get('row_count_type') != 'long' or shape.get('column_count_type') != 'long' or
                shape.get('column_value_types') != ['list', 'list'] or
                shape.get('column_value_counts') != [rows, rows] or
                any(type(n) is not int for n in shape.get('column_value_counts', [])) or
                not isinstance(types, list) or not types or len(types) != len(set(types)) or
                any(t not in ('shor', 'long', 'comp', 'magn', 'ucom', 'sing', 'doub') for t in types)):
            raise ValueError('bulk numeric readback descriptor/counts invalid')
    for key, keys in (('before_pairs', range(rows, 0, -1)), ('after_pairs', range(1, rows + 1))):
        pairs = value.get(key)
        if not isinstance(pairs, list) or len(pairs) != rows:
            raise ValueError('full table readback missing')
        for pair, number in zip(pairs, keys):
            if (not isinstance(pair, list) or len(pair) != 2 or
                    any(type(v) not in (int, float) or not math.isfinite(v) for v in pair) or
                    pair != [number, number * 17 + 3]):
                raise ValueError('table order/pairs did not qualify')
    validate_measurements(report, value, rows)
    return report, value


def run():
    if len(arguments) not in (3, 4) or (len(arguments) == 4 and arguments[3] not in ('32', '512')):
        raise ValueError('fresh RESULTS, compiled helper, exact SHA256, optional32/512 required')
    rows = int(arguments[3]) if len(arguments) == 4 else 32
    results, helper = map(Path, arguments[:2]); expected = arguments[2]
    if not results.is_absolute() or results.exists() or not re.fullmatch(r'[0-9a-f]{64}', expected):
        raise ValueError('fresh absolute results and exact hash required')
    info = helper.lstat()
    if helper.resolve() != helper or not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= 1048576:
        raise ValueError('canonical bounded helper required')
    data = helper.read_bytes()
    if len(data) != info.st_size or data[:8] != bytes.fromhex('cffaedfe07000001') or hashlib.sha256(data).hexdigest() != expected:
        raise ValueError('helper architecture/bytes changed')
    results.mkdir(parents=True)
    report = {'result': 'INCOMPLETE', 'helper_sha256': expected, 'requests': [], 'performance_qualified': False,
              'scope': 'One private Numbers09 verified CSV/model-sort task; no comparative speed/UI/host CPU claim',
              'rows_requested': rows}
    def save():
        (results/'result.json').write_text(json.dumps(report, indent=2)+'\n')
    deadline = time.monotonic()+170
    def checked(command, maximum):
        remaining = deadline-time.monotonic()
        if remaining <= 0:
            raise TimeoutError('global Numbers driver deadline')
        response = request(command, min(maximum, remaining))
        report['requests'].append({'command': command, 'response': response}); save()
        if time.monotonic() > deadline or not isinstance(response, dict) or 'Error' in response:
            raise ValueError('ambiguous Numbers response; no further requests')
        return response
    save()
    try:
        (channel/'Transfer.bin').write_bytes(data)
        staged = checked({'Action': 'stage-probe'}, 60)
        if 'ExitCode' in staged and (type(staged['ExitCode']) is not int or staged['ExitCode'] != 0):
            raise ValueError('staging exit ambiguous')
        transfer = staged.get('Transfer')
        directory = transfer.get('Directory') if isinstance(transfer, dict) else None
        if (not isinstance(transfer, dict) or transfer.get('FilesStaged') is not True or
                not isinstance(directory, str) or not re.fullmatch(r'/private/var/tmp/VirtualIntelMac\.[A-Za-z0-9]{6}', directory)):
            raise ValueError('stage directory outside owned pattern')
        spec = {'helper_path': directory+'/Transfer.bin', 'helper_sha256': expected, 'rows': rows}
        response = checked({'Executable': '/usr/bin/python', 'Arguments': ['-c', COLLECTOR, json.dumps(spec)]}, 100)
        text = response.get('Stdout')
        if isinstance(text, str) and len(text.encode()) <= 65536:
            (results/'collector-receipt.txt').write_text(text)
        csv = ''.join('%d,%d\n' % (key, key*17+3) for key in range(rows, 0, -1)).encode()
        receipt, value = qualify(response, expected, hashlib.sha256(csv).hexdigest(), rows)
        report.update(result='NUMBERS09_PRIVATE_SORT_QUALIFIED', collector=receipt, helper=value); save()
    except BaseException as error:
        report.update(result='STOP_ALL_REQUESTS', error=repr(error)[:512]); save(); raise


run()
