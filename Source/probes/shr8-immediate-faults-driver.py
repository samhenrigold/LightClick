"""One bounded guest-only SHR8 normal/following-fault qualification.

Arguments: fresh existing RESULTS, compiled x64 min10.9 HELPER, SHA256.
Reuses the audited AF collector with only helper argument/deadline changes.
Undefined AF/OF are checked against the existing Engine h_shift model.
Never execute the guest helper on the host.
"""
import hashlib
import json
from pathlib import Path
import re
import shutil
import time

COLLECTOR=r'''import errno,hashlib,json,os,re,signal,stat,subprocess,sys,threading,time
report={'schema':1,'result':'INCOMPLETE','helper_started':False};child=None;code=0
class Stop(Exception):pass
def interrupted(number,frame):raise Stop('collector interrupted')
for number in (signal.SIGALRM,signal.SIGTERM,signal.SIGINT):signal.signal(number,interrupted)
def stop():
    if child is None or child.poll() is not None:return True
    try:
        if os.getpgid(child.pid)!=child.pid:return False
    except OSError as error:
        if error.errno==errno.ESRCH:return child.poll() is not None
        return False
    for kind in (signal.SIGTERM,signal.SIGKILL):
        try:os.killpg(child.pid,kind)
        except OSError as error:
            if error.errno!=errno.ESRCH:return False
        for unused in range(20):
            if child.poll() is not None:return True
            time.sleep(.05)
    return child.poll() is not None
def reader(stream,cap):
    state={'parts':[],'bytes':0,'over':False,'done':False,'error':False}
    def drain():
        try:
            while True:
                try:data=os.read(stream.fileno(),4096)
                except OSError as error:
                    if error.errno==errno.EINTR:continue
                    raise
                if not data:break
                room=max(0,cap-state['bytes'])
                if room:state['parts'].append(data[:room])
                state['bytes']+=len(data)
                if state['bytes']>cap:state['over']=True
        except Exception:state['error']=True
        finally:stream.close();state['done']=True
    thread=threading.Thread(target=drain);thread.daemon=True;thread.start()
    return state,thread
signal.alarm(34)
try:
    if os.geteuid()!=0 or len(sys.argv)!=3:raise Stop('privileged collector/helper pin required')
    path,expected=sys.argv[1:]
    if not re.match(r'\A/private/var/tmp/VirtualIntelMac\.[A-Za-z0-9]{6}/Transfer\.bin\Z',path):raise Stop('unexpected owned helper stage path')
    parent=os.path.dirname(path);info=os.lstat(parent)
    if os.path.realpath(parent)!=parent or not stat.S_ISDIR(info.st_mode) or info.st_uid!=0 or stat.S_IMODE(info.st_mode)!=0o700:raise Stop('stage parent changed')
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    try:
        info=os.fstat(fd)
        if os.path.realpath(path)!=path or not stat.S_ISREG(info.st_mode) or info.st_uid!=0 or info.st_nlink!=1 or not 0<info.st_size<=65536:raise Stop('staged helper identity outside budget')
        data=os.read(fd,65537);after=os.fstat(fd)
        if len(data)!=info.st_size or (info.st_dev,info.st_ino,info.st_size,info.st_mtime,info.st_ctime)!=(after.st_dev,after.st_ino,after.st_size,after.st_mtime,after.st_ctime) or hashlib.sha256(data).hexdigest()!=expected:raise Stop('staged helper hash/identity mismatch')
        os.fchmod(fd,0o700)
    finally:os.close(fd)
    report['helper_sha256']=expected
    with open(os.devnull,'rb') as null:
        child=subprocess.Popen([path,'--darwin13-owned-shr8-faults'],stdin=null,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
            env={'PATH':'/usr/bin:/bin','LANG':'C','LC_ALL':'C'},preexec_fn=os.setsid,close_fds=True)
    report.update(helper_started=True,pid=child.pid)
    out,err=reader(child.stdout,8192),reader(child.stderr,4096)
    for unused in range(600):
        if child.poll() is not None or out[0]['over'] or err[0]['over']:break
        time.sleep(.05)
    timed_out=child.poll() is None and not(out[0]['over'] or err[0]['over'])
    if child.poll() is None and not stop():raise Stop('owned helper unreaped')
    for state,thread in (out,err):thread.join(.5)
    report.update(exit_code=child.poll(),timed_out=timed_out)
    for name,(state,thread) in (('stdout',out),('stderr',err)):
        report[name]={'text':b''.join(state['parts']).decode('utf-8','replace'),'bytes':state['bytes'],
            'over':state['over'],'done':state['done'],'error':state['error']}
    if timed_out or report['exit_code'] in (None,77) or any(not state['done'] or state['over'] or state['error'] for state,thread in (out,err)):raise Stop('helper timeout, ambiguous exit, or incomplete output')
    report['result']='HELPER_FINISHED'
except BaseException as error:
    report.update(result='STOP_ALL_REQUESTS',error=str(error)[:160]);code=77
finally:
    signal.alarm(0)
    if not stop():report.update(result='STOP_ALL_REQUESTS',error='owned helper unreaped');code=77
    text=json.dumps(report,separators=(',',':'))
    if len(text)>16384:text='{"schema":1,"result":"STOP_ALL_REQUESTS","error":"receipt cap"}';code=77
    sys.stdout.write(text+'\n');sys.stdout.flush()
sys.exit(code)
'''

def qualify(response,expected_sha256):
    if not isinstance(response,dict) or 'Error' in response or type(response.get('ExitCode')) is not int or response['ExitCode']!=0:
        raise ValueError('ambiguous collector failure; stop all requests')
    text=response.get('Stdout')
    if not isinstance(text,str) or len(text.encode())>16385:raise ValueError('missing/oversized collector receipt')
    receipt=json.loads(text)
    if receipt.get('schema')!=1 or receipt.get('result')!='HELPER_FINISHED' or receipt.get('helper_sha256')!=expected_sha256 or (type(receipt.get('exit_code')) is not int or receipt['exit_code']!=0) or receipt.get('timed_out') is not False:
        raise ValueError('helper failed/unqualified; no retry')
    for name,cap in (('stdout',8192),('stderr',4096)):
        row=receipt.get(name,{})
        if row.get('done') is not True or row.get('error') is not False or row.get('over') is not False or type(row.get('bytes')) is not int or not 0<=row['bytes']<=cap:
            raise ValueError('incomplete bounded helper stdio')
        if not isinstance(row.get('text'),str) or len(row['text'].encode())>cap:raise ValueError('helper text outside budget')
    value=json.loads(receipt['stdout']['text'])
    wanted={'schema':1,'result':'PASS','architecture':'x86_64','darwin_major':13,'euid':0,'flag_mask':2261,
        'guarded_faults':1152,'low_byte_cases':576,'high_byte_cases':576,'effective_zero_cases':64,
        'exact_fault_resume_address_guards':True,'handler_no_alloc_or_stdio':True,
        'model':'existing_h_shift_including_undefined_AF_OF','observation_digest':"148efdcc09b153dd"}
    if any(type(value.get(key)) is not type(expected) or value[key]!=expected for key,expected in wanted.items()):
        raise ValueError('SHR8 flags/results/counts/model mismatch')
    if any(type(value.get(key)) is not int or value[key]<0 for key in ('SIGSEGV','SIGBUS')) or value['SIGSEGV']+value['SIGBUS']!=1152:
        raise ValueError('SHR8 signal coverage mismatch')
    seconds=value.get('seconds_guest_monotonic')
    if type(seconds) not in (float,int) or not 0<seconds<=25:raise ValueError('guest runtime outside25s')
    if [value.get(key) for key in ('ucontext_mcontext_offset','ucontext_mcsize_offset','mcontext_rip_offset','mcontext_rflags_offset')]!=[48,40,144,152]:
        raise ValueError('x64 signal layout differs from statically audited prefix')
    return {'collector':receipt,'probe':value}

def run():
    if len(arguments)!=3:raise ValueError('explicit fresh RESULTS, compiled HELPER path and expected SHA256 required')
    results,helper=map(Path,arguments[:2]);expected_sha256=arguments[2]
    if not isinstance(expected_sha256,str) or not re.fullmatch(r'[0-9a-f]{64}',expected_sha256):raise ValueError('expected SHA256 must be 64 lowercase hexadecimal characters')
    artifact=results/'shr8-faults.json'
    if not results.is_dir() or artifact.exists():raise ValueError('results must exist fresh')
    if not helper.is_file() or helper.stat().st_size>65536 or hashlib.sha256(helper.read_bytes()).hexdigest()!=expected_sha256:
        raise ValueError('exact pinned helper absent or changed')
    report={'result':'INCOMPLETE','helper_sha256':expected_sha256,'requests':0,'scope':'one guest-only SHR8 normal/following-fault run; no UI/input'}
    deadline=time.monotonic()+90
    def save():artifact.write_text(json.dumps(report,indent=2)+'\n')
    def bounded(command, timeout):
        remaining=deadline-time.monotonic()
        if remaining<=0:raise TimeoutError('global driver deadline')
        report['requests']+=1;save()
        value=request(command,min(timeout,remaining))
        if time.monotonic()>deadline:raise TimeoutError('global driver deadline after request')
        if not isinstance(value,dict) or 'Error' in value:raise ValueError('ambiguous response; stop all requests')
        if 'ExitCode' in value and (type(value['ExitCode']) is not int or value['ExitCode']!=0):
            raw=value.get('Stdout')
            if isinstance(raw,str) and len(raw.encode())<=16385:
                try:report['stopped_collector_receipt']=json.loads(raw)
                except ValueError:report['stopped_collector_receipt_malformed']=True
            raise ValueError('nonzero/ambiguous exit; stop all requests')
        return value
    save()
    try:
        shutil.copyfile(helper,channel/'Transfer.bin')
        staged=bounded({'Action':'stage-probe'},60)
        directory=staged.get('Transfer',{}).get('Directory')
        if not isinstance(directory,str) or not re.fullmatch(r'/private/var/tmp/VirtualIntelMac\.[A-Za-z0-9]{6}',directory):raise ValueError('stage receipt directory outside exact owned pattern')
        report['staged_directory']=directory;save()
        response=bounded({'Executable':'/usr/bin/python','Arguments':['-c',COLLECTOR,directory+'/Transfer.bin',expected_sha256]},38)
        raw=response.get('Stdout')
        if isinstance(raw,str) and len(raw.encode())<=16385:
            try:report['raw_collector_receipt']=json.loads(raw)
            except ValueError:report['collector_receipt_malformed']=True
        report.update(qualified=qualify(response,expected_sha256),result='GUEST_SHR8_NORMAL_AND_PRECISE_FAULT_PASS');save()
        print('PASS guest SHR8 normal and following-fault flags/results; no host helper execution.',flush=True)
    except BaseException as error:
        report.update(result='STOP_ALL_REQUESTS',error=repr(error)[:240]);save();raise

run()
