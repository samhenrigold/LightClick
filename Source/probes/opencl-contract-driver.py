"""guest-bench: fixed native Metal export, then diagnostic guest OpenCL query/compute helpers.

Arguments: NEWRESULTS QUERYHELPER COMPUTEHELPER. No host Apple binary execution or performance qualification.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import time

FILES = {
    'metal': ('/System/Library/Frameworks/Metal.framework/Versions/A/Metal', 'Metal', 32 * 1024 * 1024),
    'metal-info': ('/System/Library/Frameworks/Metal.framework/Versions/A/Resources/Info.plist', 'Metal-Info.plist', 1048576),
    'system-version': ('/System/Library/CoreServices/SystemVersion.plist', 'SystemVersion.plist', 1048576),
}
CHUNK = 192 * 1024
RESPONSE_CAP = 1048576

# Same bounded descriptor/chunk protocol as image-decode-tcg-control-driver; paths are an immutable selector table.
EXPORT = r'''import base64, hashlib, json, os, re, signal, stat, sys
signal.alarm(15)
FILES={'metal':('/System/Library/Frameworks/Metal.framework/Versions/A/Metal',33554432),
       'metal-info':('/System/Library/Frameworks/Metal.framework/Versions/A/Resources/Info.plist',1048576),
       'system-version':('/System/Library/CoreServices/SystemVersion.plist',1048576)}
def identity(s):return {'device':s.st_dev,'inode':s.st_ino,'bytes':s.st_size,'mtime':s.st_mtime,'ctime':s.st_ctime}
def export(selector,operation,args):
    if selector not in FILES:raise ValueError('unknown fixed export selector')
    path,cap=FILES[selector]
    if os.path.realpath(path)!=path:raise ValueError('fixed file is noncanonical')
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    try:
        s=os.fstat(fd)
        if not stat.S_ISREG(s.st_mode) or s.st_uid!=0 or not 0<s.st_size<=cap:raise ValueError('fixed file outside root-owned regular size budget')
        initial=identity(s)
        if operation=='describe' and not args:
            digest=hashlib.sha256();count=0
            while True:
                data=os.read(fd,192*1024)
                if not data:break
                count+=len(data)
                if count>cap:raise ValueError('file grew beyond budget')
                digest.update(data)
            if count!=s.st_size:raise ValueError('fixed file size changed')
            result={'path':path,'identity':initial,'bytes':count,'sha256':digest.hexdigest()}
        elif operation=='chunk' and len(args)==3:
            if any(not re.match(r'\A[0-9]{1,10}\Z',v) for v in args[:2]):raise ValueError('invalid chunk range')
            offset,length=map(int,args[:2])
            if not 0<length<=192*1024 or offset+length>s.st_size or initial!=json.loads(args[2]):raise ValueError('chunk identity/range changed')
            os.lseek(fd,offset,os.SEEK_SET);data=os.read(fd,length)
            if len(data)!=length:raise ValueError('short fixed file chunk')
            result={'identity':initial,'offset':offset,'bytes':length,'sha256':hashlib.sha256(data).hexdigest(),'base64':base64.b64encode(data).decode('ascii')}
        else:raise ValueError('invalid fixed export operation')
        if identity(os.fstat(fd))!=initial:raise ValueError('fixed file changed during export')
        return result
    finally:os.close(fd)
sys.stdout.write(json.dumps(export(sys.argv[1],sys.argv[2],sys.argv[3:])))
'''

# Python2 guest. Stage verification/copy and audit-session entry follow the established FCP/Numbers collectors.
COLLECTOR = r'''import ctypes, hashlib, json, os, pwd, re, signal, stat, subprocess, sys, tempfile, threading, time
CAP=65536
owned=[]
report={'result':'DIAGNOSTIC','scope':'OpenCL inventory and bounded integer GPU qualifier; no performance claim','commands':[]}
def store(path,data):
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o700)
    with os.fdopen(fd,'wb') as out:out.write(data)
def staged(path,expected):
    if not re.match(r'\A/private/var/tmp/VirtualIntelMac\.[A-Za-z0-9]{6}/Transfer\.bin\Z',path):raise ValueError('invalid fixed stage receipt')
    parent=os.path.dirname(path);s=os.lstat(parent)
    if os.path.realpath(parent)!=parent or not stat.S_ISDIR(s.st_mode) or s.st_uid!=0 or stat.S_IMODE(s.st_mode)!=0o700:raise ValueError('stage parent identity changed')
    if os.path.realpath(path)!=path:raise ValueError('noncanonical staged helper')
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    try:
        s=os.fstat(fd)
        if not stat.S_ISREG(s.st_mode) or s.st_uid!=0 or s.st_nlink!=1 or not 0<s.st_size<=2097152:raise ValueError('staged helper outside size/ownership budget')
        data=os.read(fd,2097153)
        after=os.fstat(fd)
        if len(data)!=s.st_size or (s.st_ino,s.st_size,s.st_mtime,s.st_ctime)!=(after.st_ino,after.st_size,after.st_mtime,after.st_ctime) or hashlib.sha256(data).hexdigest()!=expected:raise ValueError('staged helper hash/identity changed')
        return data
    finally:os.close(fd)
def stop(child):
    if child.poll() is not None:return
    if os.getpgid(child.pid)!=child.pid:raise ValueError('owned process group changed')
    os.killpg(child.pid,signal.SIGTERM)
    until=time.time()+1
    while child.poll() is None and time.time()<until:time.sleep(.05)
    if child.poll() is None:os.killpg(child.pid,signal.SIGKILL)
    until=time.time()+1
    while child.poll() is None and time.time()<until:time.sleep(.05)
    if child.poll() is None:raise ValueError('owned process did not reap')
def reader(stream):
    state={'parts':[],'bytes':0,'at_limit':False,'error':None}
    def drain():
        try:
            while True:
                data=stream.read(4096)
                if not data:break
                remaining=max(0,CAP-state['bytes'])
                if remaining:state['parts'].append(data[:remaining])
                state['bytes']+=len(data)
                if state['bytes']>CAP:state['at_limit']=True
        except Exception as e:state['error']=repr(e)
        finally:stream.close()
    thread=threading.Thread(target=drain);thread.daemon=True;thread.start()
    return state,thread
def captured(pair):
    state,thread=pair;thread.join(2)
    return {'text':b''.join(state['parts']).decode('utf-8','replace'),'bytes':state['bytes'],
            'at_limit':state['at_limit'],'reader_finished':not thread.is_alive(),'error':state['error']}
def command(argv,seconds,env):
    with open(os.devnull,'rb') as null:
        child=subprocess.Popen(argv,stdin=null,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,preexec_fn=os.setsid,close_fds=True)
    owned.append(child)
    a,b=reader(child.stdout),reader(child.stderr);until=time.time()+seconds
    while child.poll() is None and time.time()<until and not a[0]['at_limit'] and not b[0]['at_limit']:time.sleep(.05)
    expired=child.poll() is None and time.time()>=until
    if child.poll() is None:stop(child)
    out,err=captured(a),captured(b);code=child.poll()
    row={'argv':argv,'timeout_seconds':seconds,'timed_out':expired,'exit_code':code,'signal':-code if code is not None and code<0 else None,
         'stdout':out,'stderr':err,'diagnostics_complete':not(out['at_limit'] or err['at_limit'] or out['error'] or err['error']) and out['reader_finished'] and err['reader_finished']}
    report['commands'].append(row)
    return row
def join_console():
    uid=os.stat('/dev/console').st_uid
    if uid==0:raise ValueError('no logged-in guest console user')
    user=pwd.getpwuid(uid)
    found=command(['/usr/bin/pgrep','-x','Finder'],3,dict(os.environ))
    pids=found['stdout']['text'].split()
    if found['timed_out'] or found['exit_code'] or not found['diagnostics_complete'] or len(pids)!=1:raise ValueError('guest Finder identity ambiguous')
    libc=ctypes.CDLL('/usr/lib/libSystem.B.dylib');me=ctypes.c_uint.in_dll(libc,'mach_task_self_').value
    task,bootstrap,session=ctypes.c_uint(),ctypes.c_uint(),ctypes.c_uint()
    token,count=(ctypes.c_uint*8)(),ctypes.c_uint(8)
    if libc.task_for_pid(me,int(pids[0]),ctypes.byref(task)) or libc.task_info(task,15,token,ctypes.byref(count)) or libc.task_get_special_port(task,4,ctypes.byref(bootstrap)):
        raise ValueError('could not read Finder audit/bootstrap session')
    if libc.audit_session_port(token[6],ctypes.byref(session))==-1 or libc.audit_session_join(session)==-1 or libc.task_set_special_port(me,4,bootstrap):raise ValueError('could not join Finder audit/bootstrap session')
    os.initgroups(user.pw_name,user.pw_gid);os.setgid(user.pw_gid);os.setuid(uid)
    return uid
try:
    def interrupted(n,frame):raise RuntimeError('OpenCL collector interrupted '+str(n))
    for n in (signal.SIGALRM,signal.SIGTERM,signal.SIGINT):signal.signal(n,interrupted)
    signal.alarm(100)
    if len(sys.argv)!=5:raise ValueError('expected exactly two staged helper/hash pairs')
    query=staged(sys.argv[1],sys.argv[2]);compute=staged(sys.argv[3],sys.argv[4])
    report['console_uid']=join_console()
    directory=tempfile.mkdtemp(prefix='LightClickOpenCLContract.',dir='/private/var/tmp');os.chmod(directory,0o700)
    report['private_directory']=directory
    home=directory+'/home';os.mkdir(home,0o700)
    env=dict(os.environ,HOME=home,CFFIXED_USER_HOME=home,TMPDIR=directory+'/')
    env.pop('PYTHONPATH',None);env.pop('PYTHONHOME',None)
    for name,data,seconds in (('query',query,12),('compute',compute,35)):
        path=directory+'/'+name;store(path,data)
        row=command([path],seconds,env);report[name]=row
except Exception as error:report.update(result='INCONCLUSIVE',error=repr(error))
finally:
    errors=[]
    for child in reversed(owned):
        try:stop(child)
        except Exception as error:errors.append(repr(error))
    report['cleanup_errors']=errors
    if errors:report['result']='INCONCLUSIVE'
    signal.alarm(0);print(json.dumps(report))
'''


def save_new(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as out:
        out.write(data)


def receipt(response):
    if not isinstance(response, dict) or 'Error' in response or type(response.get('ExitCode')) is not int or response['ExitCode'] != 0:
        raise ValueError('guest export/collector failed: ' + repr(response))
    text = response.get('Stdout')
    if not isinstance(text, str) or len(text.encode()) > RESPONSE_CAP:
        raise ValueError('guest response outside 1MiB JSON envelope')
    result = json.loads(text)
    if not isinstance(result, dict):
        raise ValueError('guest JSON must be an object')
    return result


def macho_header(path):
    with path.open('rb') as stream:
        data = stream.read(32)
    result = {'first_32_bytes_hex': data.hex(), 'bytes': path.stat().st_size,
              'qualification': 'Header observation only; a loose file may be a stub or omit shared-cache code.'}
    if len(data) >= 28 and data[:4] in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe'):
        keys = ('magic', 'cpu_type', 'cpu_subtype', 'file_type', 'load_commands', 'load_command_bytes', 'flags')
        result.update(zip(keys, struct.unpack('<7I', data[:28])))
    elif data[:4] in (b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'):
        result['container'] = 'fat Mach-O; per-architecture inspection required'
    else:
        result['container'] = 'unrecognized or short header'
    return result


def export_fixed(results, selector):
    path, name, cap = FILES[selector]
    manifest = {'selector': selector, 'path': path, 'result': 'INCONCLUSIVE', 'chunks': []}
    deadline = time.monotonic() + 300
    def call(operation, args):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ValueError('fixed export deadline exhausted')
        response = request({'Executable': '/usr/bin/python', 'Arguments': ['-c', EXPORT, selector, operation, *args]}, min(20, remaining))
        encoded = json.dumps(response).encode()
        manifest['last_response'] = response if len(encoded) <= RESPONSE_CAP else {
            'error': 'response outside 1MiB envelope', 'response_bytes': len(encoded),
            'bounded_prefix': encoded[:65536].decode('utf-8', 'replace')}
        return receipt(response)
    try:
        descriptor = call('describe', [])
        manifest['descriptor'] = descriptor
        count, identity, expected = descriptor.get('bytes'), descriptor.get('identity'), descriptor.get('sha256')
        if (descriptor.get('path') != path or type(count) is not int or not 0 < count <= cap or not isinstance(identity, dict)
                or identity.get('bytes') != count or not isinstance(expected, str) or not re.fullmatch('[0-9a-f]{64}', expected)):
            raise ValueError('invalid fixed-file descriptor')
        partial, target = results / (name + '.partial'), results / name
        digest = hashlib.sha256()
        fd = os.open(partial, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'wb') as out:
            for offset in range(0, count, CHUNK):
                length = min(CHUNK, count - offset)
                row = call('chunk', [str(offset), str(length), json.dumps(identity, separators=(',', ':'))])
                payload = row.get('base64')
                if not isinstance(payload, str) or len(payload) > (CHUNK + 2) // 3 * 4:
                    raise ValueError('invalid chunk payload')
                data = base64.b64decode(payload, validate=True)
                if (row.get('identity') != identity or type(row.get('offset')) is not int or row['offset'] != offset
                        or type(row.get('bytes')) is not int or row['bytes'] != length or len(data) != length
                        or row.get('sha256') != hashlib.sha256(data).hexdigest()):
                    raise ValueError('fixed-file chunk identity/range/hash mismatch')
                out.write(data); digest.update(data)
                manifest['chunks'].append({key: row[key] for key in ('identity', 'offset', 'bytes', 'sha256')})
        if partial.stat().st_size != count or digest.hexdigest() != expected:
            raise ValueError('fixed-file final size/hash mismatch')
        os.link(partial, target); partial.unlink()  # Exclusive publication, never replace a prior artifact.
        manifest.update(result='EXPORTED', artifact=str(target), bytes=count, sha256=expected)
        if selector == 'metal':
            manifest['macho_header'] = macho_header(target)
    except Exception as error:
        manifest['error'] = repr(error)
    finally:
        # Cancellation/SystemExit still retains completed receipts and propagates: no ambiguous-channel resend.
        save_new(results / (selector + '-export.json'), (json.dumps(manifest, indent=2) + '\n').encode())
    return manifest


def run():
    if len(arguments) != 3:
        raise ValueError('expected NEWRESULTS QUERYHELPER COMPUTEHELPER')
    results = Path(arguments[0])
    if not results.is_dir() or any(results.iterdir()):
        raise ValueError('results must be a fresh existing empty directory')
    report = {'result': 'INCONCLUSIVE', 'scope': 'native Metal export and guest OpenCL DIAGNOSTIC only; no performance claim', 'exports': []}
    try:
        # Nothing launches/stages the helpers until all three fixed export attempts finish.
        for selector in FILES:
            report['exports'].append(export_fixed(results, selector))
        report['exports_complete'] = all(row['result'] == 'EXPORTED' for row in report['exports'])
        helper_paths, hashes = [], []
        for name, local in zip(('query', 'compute'), arguments[1:]):
            p = Path(local)
            if p.is_symlink() or not p.is_file() or not 0 < p.stat().st_size <= 2097152:
                raise ValueError('local helper must be a regular non-symlink file <=2MiB')
            digest = hashlib.sha256(p.read_bytes()).hexdigest()
            hashes.append(digest)
            report[name + '_helper'] = {'path': str(p), 'bytes': p.stat().st_size, 'sha256': digest}
            staged = stage(p)
            if not isinstance(staged, str) or not re.fullmatch(r'/private/var/tmp/VirtualIntelMac\.[A-Za-z0-9]{6}/Transfer\.bin', staged):
                raise ValueError('invalid helper stage receipt')
            helper_paths.append(staged)
        response = request({'Executable': '/usr/bin/python', 'Arguments': ['-c', COLLECTOR, helper_paths[0], hashes[0], helper_paths[1], hashes[1]]}, 110)
        encoded = (json.dumps(response, separators=(',', ':')) + '\n').encode()
        if len(encoded) > RESPONSE_CAP:
            save_new(results / 'opencl-response.oversize-prefix.txt', encoded[:RESPONSE_CAP])
            raise ValueError('full OpenCL response outside 1MiB envelope; bounded prefix retained')
        save_new(results / 'opencl-response.json', encoded)
        diagnostic = receipt(response)
        report['diagnostic'] = diagnostic
        for name in ('query', 'compute'):
            row = diagnostic.get(name)
            if not isinstance(row, dict):
                continue
            for stream in ('stdout', 'stderr'):
                text = row.get(stream, {}).get('text')
                if isinstance(text, str):
                    save_new(results / (name + '.' + stream + '.txt'), text.encode())
            # Parse complete JSON lines opportunistically; raw checkpoints/partial crash output remain authoritative.
            parsed, malformed = [], []
            for line in row.get('stdout', {}).get('text', '').splitlines():
                try: parsed.append(json.loads(line))
                except ValueError: malformed.append(line)
            row['parsed_stdout_lines'], row['malformed_stdout_lines'] = parsed, malformed
        report['result'] = 'DIAGNOSTIC' if diagnostic.get('result') == 'DIAGNOSTIC' and diagnostic.get('cleanup_errors') == [] else 'INCONCLUSIVE'
        print('OpenCL DIAGNOSTIC captured; no performance qualification; evidence ' + str(results), flush=True)
    except BaseException as error:
        report['error'] = repr(error)
        raise
    finally:
        save_new(results / 'opencl-contract.json', (json.dumps(report, indent=2) + '\n').encode())


run()
