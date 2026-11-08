"""Guest-only one-shot REP fault observation: RESULTS HELPER SHA256 plain|bulk.

MODE records the launcher's requested backend, never an expected guest answer.
A completed architectural mismatch is captured explicitly, never labeled PASS.
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
        child=subprocess.Popen([path,'--darwin13-owned-rep-progress'],stdin=null,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
            env={'PATH':'/usr/bin:/bin','LANG':'C','LC_ALL':'C'},preexec_fn=os.setsid,close_fds=True)
    report.update(helper_started=True,pid=child.pid)
    out,err=reader(child.stdout,8192),reader(child.stderr,4096)
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
    if len(text)>32768:text='{"schema":1,"result":"STOP_ALL_REQUESTS","error":"receipt cap"}';code=77
    sys.stdout.write(text+'\n');sys.stdout.flush()
sys.exit(code)
'''


def pointer(value):
    if not isinstance(value,str) or not re.fullmatch('[0-9a-f]{16}',value):raise ValueError('noncanonical pointer/flags')
    return int(value,16)


def uint(value):
    if type(value) is not int or not 0<=value<2**64:raise ValueError('invalid raw integer')
    return value


def qualify(response,expected_sha256):
    if not isinstance(response,dict) or 'Error' in response or type(response.get('ExitCode')) is not int or response['ExitCode']!=0 or response.get('Stderr')!='':
        raise ValueError('collector failed; stop all requests')
    text=response.get('Stdout')
    if not isinstance(text,str) or not 0<len(text.encode())<=32769:raise ValueError('collector receipt bound')
    receipt=json.loads(text)
    if receipt.get('schema')!=1 or receipt.get('result')!='HELPER_FINISHED' or receipt.get('helper_sha256')!=expected_sha256 or receipt.get('helper_started') is not True or type(receipt.get('exit_code')) is not int or receipt['exit_code']!=0 or receipt.get('timed_out') is not False:
        raise ValueError('helper did not complete; no retry')
    for name,cap in [('stdout',8192),('stderr',4096)]:
        row=receipt.get(name,{})
        if any(row.get(k) is not v for k,v in [('done',True),('eof',True),('error',False),('over',False)]):raise ValueError('stdio not closed and error-free')
        if type(row.get('bytes')) is not int or not 0<=row['bytes']<=cap or not isinstance(row.get('text'),str) or len(row['text'].encode())!=row['bytes']:raise ValueError('stdio byte bound')
    if receipt['stderr']['text']!='':raise ValueError('unexpected helper stderr')
    value=json.loads(receipt['stdout']['text'])
    for key,wanted in [('schema',1),('scope','one_guest_rep_movsb_fault_and_separate_completion'),('page_bytes',4096),('count',64),('expected_prefix_bytes',16),('instruction_bytes','f3a4'),('speedup_measured',False)]:
        if type(value.get(key)) is not type(wanted) or value[key]!=wanted:raise ValueError('probe scope/shape mismatch')
    fault=value.get('fault',{});complete=value.get('completion',{})
    if type(fault.get('seen')) is not int or fault['seen']!=1 or fault.get('returned_without_fault') is not False or type(fault.get('signal')) is not int or type(fault.get('code')) is not int or (fault.get('signal'),fault.get('code')) not in [(10,2),(11,2)]:raise ValueError('not one expected guarded fault')
    fault_rcx=uint(fault.get('rcx'))
    address,expected_address,rip,expected_rip,rsi,start_rsi,rdi,start_rdi,flags=[pointer(fault.get(k)) for k in ['address','expected_address','rip','expected_rip','rsi','initial_rsi','rdi','initial_rdi','rflags']]
    if address!=expected_address or expected_address!=start_rsi+16 or rip!=expected_rip or fault.get('rip_matches') is not True:raise ValueError('owned fault address/instruction mismatch')
    def advance(value,origin):return value-origin if origin<=value<=origin+64 else -1
    for key,wanted in [('source_advance',advance(rsi,start_rsi)),('destination_advance',advance(rdi,start_rdi))]:
        if type(fault.get(key)) is not int or fault[key]!=wanted:raise ValueError('raw register/delta mismatch')
    raw=fault.get('destination_hex');done=complete.get('destination_hex')
    if not isinstance(raw,str) or not re.fullmatch('[0-9a-f]{128}',raw) or not isinstance(done,str) or not re.fullmatch('[0-9a-f]{128}',done):raise ValueError('destination byte evidence missing')
    data=bytes.fromhex(raw);pattern=bytes((17*i+3)&127 for i in range(64));prefix=0
    while prefix<64 and data[prefix]==pattern[prefix]:prefix+=1
    contiguous=data[prefix:]==bytes([0xa5])*(64-prefix)
    if type(fault.get('committed_prefix_bytes')) is not int or fault['committed_prefix_bytes']!=prefix or fault.get('prefix_contiguous') is not contiguous:raise ValueError('destination prefix oracle mismatch')
    for row in [fault,complete]:
        if type(row.get('outside_sentinels_intact')) is not bool:raise ValueError('missing full-page sentinel observation')
    for key in ['source_advance','destination_advance']:
        if type(complete.get(key)) is not int or not -1<=complete[key]<=64:raise ValueError('invalid completion pointer advance')
    completion_pass=uint(complete.get('rcx'))==0 and complete['source_advance']==64 and complete['destination_advance']==64 and bytes.fromhex(done)==pattern and complete.get('outside_sentinels_intact') is True
    if complete.get('all_bytes_match') is not (bytes.fromhex(done)==pattern) or complete.get('qualified') is not completion_pass:raise ValueError('completion oracle mismatch')
    progress=prefix==16 and contiguous and fault['outside_sentinels_intact'] and fault_rcx==48 and rsi==start_rsi+16 and rdi==start_rdi+16 and not(flags&0x400)
    if fault.get('architectural_progress') is not progress or value.get('result')!=('REP_FAULT_PROGRESS_PASS' if progress and completion_pass else 'REP_FAULT_PROGRESS_MISMATCH'):raise ValueError('reported progress disagrees with raw observation')
    return {'collector':receipt,'probe':value,'architectural_progress_qualified':progress and completion_pass,'completion_control_qualified':completion_pass}


def run():
    if len(arguments)!=4 or arguments[3] not in ('plain','bulk'):raise ValueError('RESULTS HELPER SHA256 plain|bulk required')
    results,helper=map(Path,arguments[:2]);sha,mode=arguments[2:]
    if not re.fullmatch('[0-9a-f]{64}',sha) or helper.is_symlink() or not helper.is_file():raise ValueError('helper pin/path')
    data=helper.read_bytes()
    if not 0<len(data)<=65536 or hashlib.sha256(data).hexdigest()!=sha:raise ValueError('helper changed/outside budget')
    results.mkdir(parents=True,exist_ok=False)
    report={'result':'INCOMPLETE','requested_backend_mode':mode,'helper_sha256':sha,'requests':0,'speedup_measured':False,'scope':'One guest-only REP fault/completion observation; mode is requested backend control, not an expected answer.'}
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
        report['result']='REP_FAULT_PROGRESS_ARCHITECTURAL_PASS' if observed['architectural_progress_qualified'] else 'REP_FAULT_PROGRESS_OBSERVED_MISMATCH'
        save();print(report['result']+'; raw observation retained: '+str(results),flush=True)
    except BaseException as error:
        report.update(result='STOP_ALL_REQUESTS',error=repr(error)[:240]);save();raise


run()
