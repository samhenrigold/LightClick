import hashlib,json,math,re,time
from pathlib import Path
out=Path(arguments[0]);out.mkdir(parents=True,exist_ok=False)
probe=Path(arguments[1]);data=probe.read_bytes()
if hashlib.sha256(data).hexdigest()!=arguments[2]:raise SystemExit('probe hash mismatch')
receipts=[]
def call(command,timeout):
    t=time.monotonic();response=request(command,timeout)
    receipts.append({'command':command,'host_elapsed_seconds':time.monotonic()-t,'response':response})
    (out/'requests.json').write_text(json.dumps(receipts,indent=2)+'\n')
    if 'Error' in response:raise SystemExit('diagnostics rejected; no resend')
    return response
(channel/'Transfer.bin').write_bytes(data)
r=call({'Action':'stage-probe'},60);transfer=r.get('Transfer',{});directory=transfer.get('Directory','')
if not re.fullmatch(r'/private/var/tmp/VirtualIntelMac\.[A-Za-z0-9]{6,}',directory) or transfer.get('FilesStaged') is not True:raise SystemExit('stage receipt invalid')
remote=directory+'/Transfer.bin';r=call({'Executable':'/bin/chmod','Arguments':['0755',remote]},10)
if type(r.get('ExitCode')) is not int or r['ExitCode']!=0:raise SystemExit('chmod failed')
import sys
sys.path.insert(0,str(source/'scripts'))
from hevc_tally import TallyCollector
collector=TallyCollector(Path(arguments[3]),2,out/'tally-snapshots')
collector.start()
phase_start=time.monotonic()
try:
    r=call({'Executable':remote,'Arguments':['--exec-count','1024','--mmap-cycles','4096','--pages','64']},70)
finally:
    phase_end=time.monotonic()
    collector.stop()
    (out/'component-phase.json').write_text(json.dumps(collector.phase(phase_start,phase_end),indent=2)+'\n')
if type(r.get('ExitCode')) is not int or r['ExitCode']!=0 or r.get('Stderr')!='':raise SystemExit('benchmark failed')
text=r.get('Stdout','')
if not isinstance(text,str) or len(text.encode())>65536:raise SystemExit('benchmark output invalid')
rows=[json.loads(line) for line in text.splitlines() if line.strip()]
if len(rows)!=4:raise SystemExit('expected four cases')
for row,(kind,workers,count) in zip(rows,[('exec',1,1024),('exec',2,1024),('mmap',1,4096),('mmap',2,4096)]):
    if row.get('result')!='GENERAL_PROCESS_MEMORY_PASS' or row.get('case')!=kind:raise SystemExit('case failed')
    for key,value in [('workers',workers),('operations_per_worker',count),('expected_ops',workers*count),('completed_ops',workers*count),('pages_per_mapping',64 if kind=='mmap' else 0),('page_bytes',4096),('errors',0)]:
        if type(row.get(key)) is not int or row[key]!=value:raise SystemExit('invalid '+key)
    elapsed=row.get('elapsed_seconds')
    if type(elapsed) not in (int,float) or not math.isfinite(elapsed) or not 0<elapsed<=60:raise SystemExit('invalid timing')
    if not isinstance(row.get('checksum'),str) or not re.fullmatch('[0-9a-f]{16}',row['checksum']) or row['checksum']!=row.get('expected_checksum'):raise SystemExit('checksum failed')
independent={'exec1': '00ec9fca364d1713', 'exec2': '0d94c2958ac90014', 'mmap1': '02f26e6cb92a34b4', 'mmap2': 'f666b82fe85c84b2'}
for row in rows:
    if row['checksum'] != independent[row['case']+str(row['workers'])]:raise SystemExit('independent checksum mismatch')
(out/'stdout.txt').write_text(text)
(out/'result.json').write_text(json.dumps({'result':'FIXED_WORK_PROCESS_MEMORY_PASS','probe_sha256':arguments[2],'cases':rows,'host_request_elapsed_seconds':receipts[-1]['host_elapsed_seconds'],'speedup_measured':False,'scope':'One fixed-work process/memory run. No app/UI or comparative speedup claim; source review and independent checksum validation separate.'},indent=2)+'\n')
print('Fixed-work process/memory result retained: '+str(out),flush=True)
