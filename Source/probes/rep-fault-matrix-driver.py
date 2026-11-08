"""Guest-only six-case REP matrix: RESULTS HELPER SHA256 plain|bulk|page.

Requested mode is launch metadata, never a presumed guest result. R2 untouched.
"""
import hashlib
import json
from pathlib import Path
import re
import time

COLLECTOR=r'''import errno,hashlib,json,os,re,signal,stat,subprocess,sys,threading,time
report={'schema':1,'result':'INCOMPLETE','helper_started':False};child=None;unreaped=False;code=0
class Stop(Exception):pass
def interrupted(number,frame):raise Stop('collector interrupted')
for number in (signal.SIGALRM,signal.SIGTERM,signal.SIGINT):signal.signal(number,interrupted)
def stop():
    global unreaped
    if unreaped:return False
    if child is None or child.poll() is not None:return True
    for kind in (signal.SIGTERM,signal.SIGKILL):
        try:
            if os.getpgid(child.pid)!=child.pid:unreaped=True;return False
            os.killpg(child.pid,kind)
        except OSError as error:
            if error.errno!=errno.ESRCH:unreaped=True;return False
        for unused in range(20):
            if child.poll() is not None:return True
            time.sleep(.05)
    unreaped=child.poll() is None;return not unreaped
def reader(stream,cap):
    state={'parts':[],'bytes':0,'over':False,'done':False,'eof':False,'error':False}
    def drain():
        try:
            while True:
                try:data=os.read(stream.fileno(),4096)
                except OSError as error:
                    if error.errno==errno.EINTR:continue
                    raise
                if not data:state['eof']=True;break
                room=max(0,cap-state['bytes'])
                if room:state['parts'].append(data[:room])
                state['bytes']+=len(data)
                if state['bytes']>cap:state['over']=True
        except Exception:state['error']=True
        finally:
            try:stream.close()
            except Exception:state['error']=True
            state['done']=True
    thread=threading.Thread(target=drain);thread.daemon=True;thread.start();return state,thread
signal.alarm(17)
try:
    if os.geteuid()!=0 or len(sys.argv)!=3:raise Stop('privileged collector/helper pin required')
    path,expected=sys.argv[1:]
    if not re.match(r'\A/private/var/tmp/VirtualIntelMac\.[A-Za-z0-9]{6,}/Transfer\.bin\Z',path):raise Stop('unexpected owned helper stage path')
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
        child=subprocess.Popen([path,'--darwin13-owned-rep-matrix'],stdin=null,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
            env={'PATH':'/usr/bin:/bin','LANG':'C','LC_ALL':'C'},preexec_fn=os.setsid,close_fds=True)
    report.update(helper_started=True,pid=child.pid)
    out,err=reader(child.stdout,32768),reader(child.stderr,4096)
    for unused in range(240):
        if child.poll() is not None or any(s['over'] or s['error'] for s,t in (out,err)):break
        time.sleep(.05)
    timed_out=child.poll() is None and not any(s['over'] or s['error'] for s,t in (out,err))
    if child.poll() is None and not stop():raise Stop('owned helper unreaped')
    for state,thread in (out,err):thread.join(.5)
    report.update(exit_code=child.poll(),timed_out=timed_out)
    for name,(state,thread) in (('stdout',out),('stderr',err)):
        report[name]={'text':b''.join(state['parts']).decode('utf-8','replace'),'bytes':state['bytes'],
            'over':state['over'],'done':state['done'],'eof':state['eof'],'error':state['error']}
    if timed_out or report['exit_code'] in (None,77) or any(not s['done'] or not s['eof'] or s['over'] or s['error'] for s,t in (out,err)):raise Stop('timeout, ambiguous exit or incomplete output')
    report['result']='HELPER_FINISHED'
except BaseException as error:
    report.update(result='STOP_ALL_REQUESTS',error=str(error)[:160]);code=77
finally:
    signal.alarm(0)
    if not stop():report.update(result='STOP_ALL_REQUESTS',error='owned helper unreaped');code=77
    text=json.dumps(report,separators=(',',':'))
    if len(text)>65535:text='{"schema":1,"result":"STOP_ALL_REQUESTS","error":"receipt cap"}';code=77
    sys.stdout.write(text+'\n');sys.stdout.flush()
sys.exit(code)
'''

def pointer(value):
    if not isinstance(value,str) or not re.fullmatch('[0-9a-f]{16}',value):raise ValueError('noncanonical pointer/flags')
    return int(value,16)


def uint(value):
    if type(value) is not int or not 0<=value<2**64:raise ValueError('invalid raw integer')
    return value



CASES=[('movsb_source',1,True,True),('movsb_destination',1,True,False),
       ('movsq_source',8,True,True),('movsq_destination',8,True,False),
       ('stosb_destination',1,False,False),('stosq_destination',8,False,False)]

def exact(row,key,wanted):
    if type(row.get(key)) is not type(wanted) or row[key]!=wanted:raise ValueError('matrix field '+key)

def boolean(row,key):
    if type(row.get(key)) is not bool:raise ValueError('matrix boolean '+key)
    return row[key]

def bytes64(row):
    value=row.get('destination_hex')
    if not isinstance(value,str) or not re.fullmatch('[0-9a-f]{128}',value):raise ValueError('matrix byte evidence')
    return bytes.fromhex(value)

def qualify(response,expected_sha256):
    if not isinstance(response,dict) or 'Error' in response or type(response.get('ExitCode')) is not int or response['ExitCode']!=0 or response.get('Stderr')!='':raise ValueError('collector failed; stop all requests')
    text=response.get('Stdout')
    if not isinstance(text,str) or not 0<len(text.encode())<=65536:raise ValueError('collector receipt bound')
    receipt=json.loads(text)
    for key,wanted in [('schema',1),('result','HELPER_FINISHED'),('helper_sha256',expected_sha256),('helper_started',True),('exit_code',0),('timed_out',False)]:exact(receipt,key,wanted)
    for name,cap in [('stdout',32768),('stderr',4096)]:
        row=receipt.get(name,{})
        for key,wanted in [('done',True),('eof',True),('error',False),('over',False)]:exact(row,key,wanted)
        if type(row.get('bytes')) is not int or not 0<=row['bytes']<=cap or not isinstance(row.get('text'),str) or len(row['text'].encode())!=row['bytes']:raise ValueError('stdio byte bound')
    if receipt['stderr']['text']!='':raise ValueError('unexpected helper stderr')
    value=json.loads(receipt['stdout']['text'])
    for key,wanted in [('schema',1),('architecture','x86_64'),('count_bytes',64),('prefix_bytes',16),('guarded_faults',6),('cleanup_strategy','process_exit_reclaims_owned_mappings_and_altstack'),('speedup_measured',False)]:exact(value,key,wanted)
    rows=value.get('cases')
    if type(rows) is not list or len(rows)!=6:raise ValueError('six exact matrix cases required')
    passed=True;controls=True
    for index,(row,(name,width,movs,source_guard)) in enumerate(zip(rows,CASES)):
        for key,wanted in [('case',name),('width',width),('movs',movs),('source_guard',source_guard),('initial_count',64//width)]:exact(row,key,wanted)
        si=pointer(row.get('initial_rsi'));di=pointer(row.get('initial_rdi'));ax=pointer(row.get('initial_rax'));seed=pointer(row.get('seed_flags'))
        if ax!=0x1122334455667788 or seed!=(0x202|(0x8d5 if index&1 else 0)):raise ValueError('initial state oracle')
        pattern=bytes((17*i+3)&127 for i in range(64)) if movs else (ax.to_bytes(8,'little')[:width]*(64//width))
        fault=row.get('fault',{});restart=row.get('restart',{});control=row.get('completion',{})
        for key in ['signal','code']:
            if type(fault.get(key)) is not int:raise ValueError('fault signal/code type')
        if (fault['signal'],fault['code']) not in [(10,2),(11,2)]:raise ValueError('fault kind')
        ip=pointer(fault.get('rip'));expected_ip=pointer(fault.get('expected_rip'));address=pointer(fault.get('address'));expected_address=pointer(fault.get('expected_address'))
        if ip!=expected_ip or address!=expected_address or address!=(si if source_guard else di)+16:raise ValueError('fault guard/RIP identity')
        fc=uint(fault.get('rcx'));fs=pointer(fault.get('rsi'));fd=pointer(fault.get('rdi'));fa=pointer(fault.get('rax'));ff=pointer(fault.get('rflags'))
        if bytes64(fault)!=pattern[:16]+bytes([0xa5])*48:raise ValueError('pre-restart committed-prefix oracle')
        fault_ok=fc==48//width and fs==si+(16 if movs else 0) and fd==di+16 and fa==ax and ff&(0x8d5|0x400)==seed&0x8d5
        if boolean(fault,'qualified') is not fault_ok:raise ValueError('fault progress oracle mismatch')
        for key,wanted in [('same_rep_instruction',True),('normal_context_guard_repair',True),('recovery_count',1),('reported_registers_unchanged',True)]:exact(restart,key,wanted)
        for stage,wanted_bytes in [(restart,bytes(range(0xd0,0xe0))+pattern[16:]),(control,pattern)]:
            count=uint(stage.get('rcx'));ss=pointer(stage.get('rsi'));dd=pointer(stage.get('rdi'));aa=pointer(stage.get('rax'));flags=pointer(stage.get('rflags'));data=bytes64(stage);outside=boolean(stage,'outside_sentinels_intact')
            ok=count==0 and ss==si+(64 if movs else 0) and dd==di+64 and aa==ax and flags&(0x8d5|0x400)==seed&0x8d5 and data==wanted_bytes and outside
            if boolean(stage,'qualified') is not ok:raise ValueError('restart/completion oracle mismatch')
            if stage is restart:
                poison=data[:16]==bytes(range(0xd0,0xe0))
                if boolean(stage,'poison_preserved') is not poison:raise ValueError('poison oracle mismatch')
            else:controls=controls and ok
            passed=passed and ok
        passed=passed and fault_ok
    exact(value,'result','REP_FAULT_MATRIX_PASS' if passed else 'REP_FAULT_MATRIX_MISMATCH')
    return {'collector':receipt,'probe':value,'architectural_progress_qualified':passed,'completion_control_qualified':controls}

def run():
    if len(arguments)!=4 or arguments[3] not in ('plain','bulk','page'):raise ValueError('RESULTS HELPER SHA256 plain|bulk|page required')
    results,helper=map(Path,arguments[:2]);sha,mode=arguments[2:]
    if not re.fullmatch('[0-9a-f]{64}',sha) or helper.is_symlink() or not helper.is_file():raise ValueError('helper pin/path')
    data=helper.read_bytes()
    if not 0<len(data)<=65536 or hashlib.sha256(data).hexdigest()!=sha:raise ValueError('helper changed/outside budget')
    results.mkdir(parents=True,exist_ok=False)
    report={'result':'INCOMPLETE','requested_backend_mode':mode,'helper_sha256':sha,'requests':0,'speedup_measured':False,'scope':'Six guest-only REP fault/restart/completion observations; mode is requested backend control, not an expected answer.'}
    receipts=[];deadline=time.monotonic()+95
    def save():
        (results/'result.json').write_text(json.dumps(report,indent=2)+'\n')
        (results/'requests.json').write_text(json.dumps(receipts,indent=2)+'\n')
    def call(command,limit):
        remaining=deadline-time.monotonic()
        if remaining<=0:raise TimeoutError('global driver deadline')
        report['requests']+=1;save();start=time.monotonic()
        response=request(command,min(limit,remaining))
        receipts.append({'command':command,'host_elapsed_seconds':time.monotonic()-start,'response':response});save()
        if time.monotonic()>deadline or not isinstance(response,dict) or 'Error' in response:raise ValueError('deadline/ambiguous response; stop all requests')
        if 'ExitCode' in response and (type(response['ExitCode']) is not int or response['ExitCode']!=0):raise ValueError('nonzero exit; stop all requests')
        return response
    try:
        save();(channel/'Transfer.bin').write_bytes(data)
        stage=call({'Action':'stage-probe'},60);transfer=stage.get('Transfer',{});directory=transfer.get('Directory')
        if not isinstance(directory,str) or not re.fullmatch(r'/private/var/tmp/VirtualIntelMac\.[A-Za-z0-9]{6,}',directory) or transfer.get('FilesStaged') is not True or transfer.get('Files')!=[{'Name':'Transfer.bin','Size':len(data)}]:raise ValueError('stage receipt mismatch')
        remote=directory+'/Transfer.bin';changed=call({'Executable':'/bin/chmod','Arguments':['0700',remote]},10)
        if type(changed.get('ExitCode')) is not int or changed['ExitCode']!=0 or changed.get('Stdout')!='' or changed.get('Stderr')!='':raise ValueError('chmod failed')
        response=call({'Executable':'/usr/bin/python','Arguments':['-c',COLLECTOR,remote,sha]},20)
        text=response.get('Stdout')
        if isinstance(text,str) and len(text.encode())<=65536:(results/'collector-receipt.txt').write_text(text)
        observed=qualify(response,sha);report.update(observed)
        report['result']='REP_FAULT_MATRIX_ARCHITECTURAL_PASS' if observed['architectural_progress_qualified'] else 'REP_FAULT_MATRIX_OBSERVED_MISMATCH'
        save();print(report['result']+'; raw observation retained: '+str(results),flush=True)
    except BaseException as error:
        report.update(result='STOP_ALL_REQUESTS',error=repr(error)[:240]);save();raise


run()
