"""Owned disposable FCP export verification. Guest functions are Python2 compatible.

Guest wiring: export_spec supplies workflow_export_action_mode, workflow_export_action,
workflow_export_verifier and workflow_export_verifier_sha256. Inject guest_export_source()
after limits/stop/current_executable definitions. CAP/pipe reader remain untouched.
stdout_receipt identifies ONLY fixture/export-verification.json; stderr is preserved in
fixture/export-verification.stderr, with an honest bounded preview, not fetched here.
"""
import base64
import hashlib
import inspect
import json
import os
from pathlib import Path
import re
import stat
import struct
import time


def run_private_export_verifier(spec, app, workflow_directory):
    # Self-contained Python2-compatible function; existing GUEST owns subprocesses.
    import re
    import resource
    import signal
    limit = 512 * 1024 + 1  # C JSON body <=512KiB, followed by one newline.
    result = {'result': 'EXPORT_VERIFIER_SKIPPED', 'attempted': False, 'launched': False,
              'structure_qualified': False, 'fidelity_requires_review': True, 'app_alive_before': False, 'app_alive_after': False,
              'stdout_protocol_limit': limit, 'stderr_policy_limit': 8192,
              'stderr_raw_exported': False}
    child = None
    def monotonic_clock():
        available = getattr(time, 'monotonic', None)
        if available is not None:
            return available
        # Python2 on Mavericks: initialize Mach clock/timebase once per supervisor.
        import ctypes
        library = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
        class Timebase(ctypes.Structure):
            _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]
        library.mach_absolute_time.argtypes = []
        library.mach_absolute_time.restype = ctypes.c_uint64
        library.mach_timebase_info.argtypes = [ctypes.POINTER(Timebase)]
        library.mach_timebase_info.restype = ctypes.c_int
        info = Timebase()
        if library.mach_timebase_info(ctypes.byref(info)) != 0 or not info.numer or not info.denom:
            raise ValueError('Mach monotonic timebase unavailable')
        scale = float(info.numer) / info.denom / 1000000000.0
        return lambda: library.mach_absolute_time() * scale
    clock = None
    stop_attempted = [False]
    def stop_verifier(process):
        # Only our NEW verifier; old GUEST stop/FCP semantics remain untouched.
        if process.poll() is not None:
            return
        if stop_attempted[0]:
            raise ValueError('owned verifier stop already attempted; no resend')
        stop_attempted[0] = True
        if os.getpgid(process.pid) != process.pid:
            raise ValueError('owned verifier process group changed')
        os.killpg(process.pid, signal.SIGTERM)
        until = clock() + 2
        while process.poll() is None and clock() < until:
            time.sleep(.05)
        if process.poll() is None:
            if os.getpgid(process.pid) != process.pid:
                raise ValueError('owned verifier process group changed before kill')
            os.killpg(process.pid, signal.SIGKILL)
        until = clock() + 2
        while process.poll() is None and clock() < until:
            time.sleep(.05)
        if process.poll() is None:
            raise ValueError('owned verifier did not reap within monotonic bound')
    def truth(value):
        return type(value) in (bool, int) and value == 1
    def directory(path, uid):
        info = os.lstat(path)
        if os.path.realpath(path) != path or not stat.S_ISDIR(info.st_mode) or info.st_uid != uid or stat.S_IMODE(info.st_mode) != 0o700:
            raise ValueError('private directory identity/mode changed')
        return info
    def identity(info):
        return {'device': info.st_dev, 'inode': info.st_ino, 'uid': info.st_uid,
                'mode': stat.S_IMODE(info.st_mode), 'nlink': info.st_nlink,
                'bytes': info.st_size, 'mtime': info.st_mtime, 'ctime': info.st_ctime}
    def receipt(fd, path, initial):
        info = os.fstat(fd)
        if (info.st_dev, info.st_ino) != (initial.st_dev, initial.st_ino) or not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600 or identity(os.lstat(path)) != identity(info) or os.path.realpath(path) != path:
            raise ValueError('owned verifier report identity changed')
        value = dict(identity(info), path=path)
        if not 0 <= info.st_size <= limit:
            value['sha256_omitted_oversize'] = True
            return value
        os.lseek(fd, 0, os.SEEK_SET)
        digest = hashlib.sha256()
        count = 0
        while True:
            data = os.read(fd, 65536)
            if not data:
                break
            count += len(data)
            if count > limit:
                raise ValueError('verifier report grew while hashing')
            digest.update(data)
        if count != info.st_size or identity(os.fstat(fd)) != identity(info):
            raise ValueError('verifier report changed during hashing')
        value['sha256'] = digest.hexdigest()
        return value
    fds = []
    initial = []
    paths = []
    try:
        clock = monotonic_clock()
        actor = spec.get('workflow_export_action', {})
        if app in owned:
            result['app_exit_code_before'] = app.poll()
        uid = os.getuid()
        if (spec.get('workflow_export_action_mode') != 'export-h264-private-fixture'
                or spec.get('variant') != '10.1' or os.uname()[0] != 'Darwin'
                or os.uname()[2].split('.')[0] != '13' or uid <= 0
                or os.stat('/dev/console').st_uid != uid or app not in owned
                or type(app.pid) is not int or app.pid <= 1 or app.poll() is not None
                or current_executable(app.pid) != '/Applications/Final Cut Pro.app/Contents/MacOS/Final Cut Pro'):
            raise ValueError('explicit owned Mavericks console app contract missing')
        if (not isinstance(actor, dict) or actor.get('result') != 'PRIVATE_EXPORT_CANDIDATE_REQUIRES_MEDIA_VERIFICATION'
                or actor.get('mode') != 'export-h264-private-fixture' or actor.get('variant') != '10.1'
                or type(actor.get('pid')) is not int or actor['pid'] != app.pid
                or any(not truth(actor.get(k)) for k in ('identityMatched', 'identityStillMatched', 'axTrusted', 'privateFixtureValid', 'exportAttempted', 'savePressed', 'privateExportControlsVerified', 'pathNavigationVerified', 'candidateFileVerified'))
                or actor.get('outputPath') != workflow_directory + '/export.mov'):
            raise ValueError('one-shot Save controller candidate receipt not qualified')
        if not re.match(r'\A/private/var/tmp/LightClickFCPFixture\.[A-Za-z0-9_-]{6,16}\Z', workflow_directory):
            raise ValueError('fixture outside generated scope')
        parent = directory(workflow_directory, uid)
        output_path = workflow_directory + '/export.mov'
        fd = os.open(output_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            info = os.fstat(fd)
            if (os.path.realpath(output_path) != output_path or not stat.S_ISREG(info.st_mode)
                    or info.st_uid != uid or info.st_nlink != 1 or not 0 < info.st_size <= 512 * 1024 * 1024):
                raise ValueError('export candidate file outside own regular scope')
        finally:
            os.close(fd)
        helper = spec.get('workflow_export_verifier', '')
        pinned = '4ea324317573d13665904794855f26852aecbb0f86a0c4ec5b08edb9210278ee'
        if (spec.get('workflow_export_verifier_sha256') != pinned
                or not re.match(r'\A/private/var/tmp/LightClickFCP\.[A-Za-z0-9_-]{6,16}/export-verify\Z', helper)):
            raise ValueError('immutable verifier receipt/path invalid')
        helper_directory = helper.rsplit('/', 1)[0]
        directory(helper_directory, uid)
        home = helper_directory + '/home'
        directory(home, uid)
        fd = os.open(helper, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            info = os.fstat(fd)
            if (os.path.realpath(helper) != helper or not stat.S_ISREG(info.st_mode)
                    or info.st_uid != uid or info.st_nlink != 1 or not info.st_mode & 0o111
                    or not 0 < info.st_size <= 2097152):
                raise ValueError('owned verifier helper identity invalid')
            data = os.read(fd, 2097153)
            if len(data) != info.st_size or hashlib.sha256(data).hexdigest() != pinned:
                raise ValueError('immutable verifier SHA mismatch')
        finally:
            os.close(fd)
        result['app_alive_before'] = True
        result['save_action_status'] = actor.get('exportSaveActionStatus')
        result['attempted'] = True
        paths = [workflow_directory + '/export-verification.json', workflow_directory + '/export-verification.stderr']
        for path in paths:
            fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            fds.append(fd)
            os.fchmod(fd, 0o600)
            initial.append(os.fstat(fd))
        again = directory(workflow_directory, uid)
        if (again.st_dev, again.st_ino) != (parent.st_dev, parent.st_ino) or app.poll() is not None or current_executable(app.pid) != '/Applications/Final Cut Pro.app/Contents/MacOS/Final Cut Pro':
            raise ValueError('owned app/fixture changed before verifier launch')
        def verifier_limits():
            limits()
            # Safe only for this readonly verifier; never inherited by FCP.
            resource.setrlimit(resource.RLIMIT_FSIZE, (limit, limit))
        env = dict(os.environ, HOME=home, CFFIXED_USER_HOME=home, TMPDIR=workflow_directory + '/')
        with open(os.devnull, 'rb') as null:
            child = subprocess.Popen([helper, workflow_directory], stdin=null, stdout=fds[0], stderr=fds[1],
                                     preexec_fn=verifier_limits, close_fds=True, cwd=workflow_directory, env=env)
        owned.append(child)
        result['launched'] = True
        began = clock()
        # Reserve our verifier-only monotonic TERM/KILL/reap window.
        until = began + 66
        result['parent_wait_seconds'] = 66
        result['parent_wait_plus_cleanup_bound_seconds'] = 70
        while child.poll() is None and app.poll() is None and clock() < until and os.fstat(fds[0]).st_size <= limit and os.fstat(fds[1]).st_size <= 8192:
            time.sleep(.05)
        result['timed_out'] = child.poll() is None and clock() >= until
        result['app_alive_after'] = app.poll() is None and current_executable(app.pid) == '/Applications/Final Cut Pro.app/Contents/MacOS/Final Cut Pro'
        if child.poll() is None:
            stop_verifier(child)  # Never stop FCP here.
        result['exit_code'] = child.poll()
        result['elapsed_seconds'] = clock() - began
        result['stdout_receipt'] = receipt(fds[0], paths[0], initial[0])
        result['stderr_receipt'] = receipt(fds[1], paths[1], initial[1])
        out_size, err_size = os.fstat(fds[0]).st_size, os.fstat(fds[1]).st_size
        result['stdout_policy_overflow'] = out_size > limit
        result['stderr_policy_overflow'] = err_size > 8192
        os.lseek(fds[1], 0, os.SEEK_SET)
        result['stderr_preview'] = os.read(fds[1], 4096).decode('utf-8', 'replace')
        result['stderr_preview_truncated'] = err_size > 4096
        if 0 < out_size <= limit:
            os.lseek(fds[0], 0, os.SEEK_SET)
            raw = os.read(fds[0], limit + 1)
            if len(raw) != out_size:
                raise ValueError('short verifier JSON file')
            parsed = json.loads(raw.decode('utf-8'))
            if not isinstance(parsed, dict):
                raise ValueError('verifier JSON is not an object')
            # Deliberately do not embed thumbnails/samples/large JSON in main report.
            result['verifier_result'] = parsed.get('result')
            strict = (type(result['exit_code']) is int and result['exit_code'] == 0 and not result['timed_out'] and result['app_alive_after']
                      and not result['stdout_policy_overflow'] and not result['stderr_policy_overflow']
                      and parsed.get('result') == 'MEDIA_STRUCTURE_VALID_FIDELITY_REQUIRES_REVIEW'
                      and all(truth(parsed.get(k)) for k in ('report_complete', 'media_structure_qualified', 'files_stable_after_verification'))
                      and parsed.get('fidelity_qualified') is False)
            result['structure_qualified'] = strict
            result['result'] = 'MEDIA_STRUCTURE_VALID_FIDELITY_REQUIRES_REVIEW' if strict else 'EXPORT_VERIFIER_INCONCLUSIVE'
        else:
            result['result'] = 'EXPORT_VERIFIER_INCONCLUSIVE'
    except Exception as error:
        result['error'] = repr(error)
        if result['attempted']:
            result['result'] = 'EXPORT_VERIFIER_INCONCLUSIVE'
    finally:
        if child is not None and child.poll() is None:
            try:
                stop_verifier(child)
            except Exception as error:
                result['cleanup_error'] = repr(error)
        if app in owned:
            result['app_exit_code_after'] = app.poll()
        # Preserve receipts even on parse/child failure, never unlink/truncate output.
        for i, fd in enumerate(fds):
            key = 'stdout_receipt' if i == 0 else 'stderr_receipt'
            if key not in result:
                try:
                    result[key] = receipt(fd, paths[i], initial[i])
                except Exception as error:
                    result[key + '_error'] = repr(error)
            os.close(fd)
    return result


def guest_export_source():
    """Inject after existing GUEST helpers; does not import/execute AVFoundation."""
    return inspect.getsource(run_private_export_verifier) + '\n'


REPORT_CHUNK_GUEST = r'''import hashlib,base64,json,os,re,signal,stat,sys
signal.alarm(10)
e=json.loads(sys.argv[1]);directory=e['fixture_directory'];uid=e['uid'];receipt=e['receipt'];path=directory+'/export-verification.json'
def identity(info):
    return {'device':info.st_dev,'inode':info.st_ino,'uid':info.st_uid,'mode':stat.S_IMODE(info.st_mode),'nlink':info.st_nlink,'bytes':info.st_size,'mtime':info.st_mtime,'ctime':info.st_ctime}
if not re.match(r'\A/private/var/tmp/LightClickFCPFixture\.[A-Za-z0-9_-]{6,16}\Z',directory)or os.path.realpath(directory)!=directory:raise ValueError('private fixture path outside scope')
p=os.lstat(directory)
if not stat.S_ISDIR(p.st_mode)or p.st_uid!=uid or stat.S_IMODE(p.st_mode)!=0o700 or receipt.get('path')!=path or os.path.realpath(path)!=path:raise ValueError('private report path/parent changed')
fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
try:
    info=os.fstat(fd);initial=identity(info)
    if not stat.S_ISREG(info.st_mode)or info.st_uid!=uid or info.st_nlink!=1 or stat.S_IMODE(info.st_mode)!=0o600 or not 0<info.st_size<=524289 or any(receipt.get(k)!=v for k,v in initial.items()):raise ValueError('report identity mismatch')
    offset,length=e['offset'],e['length']
    if type(offset)is not int or type(length)is not int or offset<0 or not 0<length<=196608 or offset+length>info.st_size:raise ValueError('report chunk range outside bound')
    digest=hashlib.sha256();total=0
    while True:
        data=os.read(fd,65536)
        if not data:break
        total+=len(data)
        if total>524289:raise ValueError('report grew during hash')
        digest.update(data)
    if total!=info.st_size or digest.hexdigest()!=receipt['sha256']:raise ValueError('whole report SHA mismatch')
    os.lseek(fd,offset,os.SEEK_SET);data=os.read(fd,length)
    if len(data)!=length or identity(os.fstat(fd))!=initial or identity(os.lstat(path))!=initial:raise ValueError('report changed while reading')
    sys.stdout.write(json.dumps({'identity':initial,'offset':offset,'bytes':length,'whole_sha256':digest.hexdigest(),'sha256':hashlib.sha256(data).hexdigest(),'base64':base64.b64encode(data).decode('ascii')}))
finally:os.close(fd)
'''



CLOSED_MEDIA_GUEST = r'''import hashlib,json,os,re,signal,stat,sys
signal.alarm(35)
e=json.loads(sys.argv[1]);directory=e['fixture_directory'];uid=e['uid'];path=directory+'/export.mov';expected=e['output_file']
def identity(info):return {'device':info.st_dev,'inode':info.st_ino,'uid':info.st_uid,'bytes':info.st_size,'mode':stat.S_IMODE(info.st_mode),'nlink':info.st_nlink,'mtime':info.st_mtime,'ctime':info.st_ctime}
if not re.match(r'\A/private/var/tmp/LightClickFCPFixture\.[A-Za-z0-9_-]{6,16}\Z',directory)or os.path.realpath(directory)!=directory or os.path.realpath(path)!=path:raise ValueError('fixed closed movie path outside scope')
p=os.lstat(directory)
if not stat.S_ISDIR(p.st_mode)or p.st_uid!=uid or stat.S_IMODE(p.st_mode)!=0o700:raise ValueError('private movie parent changed')
fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
try:
    info=os.fstat(fd);before=identity(info)
    if not stat.S_ISREG(info.st_mode)or info.st_uid!=uid or info.st_nlink!=1 or not 0<info.st_size<=512*1024*1024 or any(expected.get(k)!=before[k]for k in('device','inode','uid','bytes')):raise ValueError('closed movie identity/size changed')
    digest=hashlib.sha256();count=0
    while True:
        data=os.read(fd,65536)
        if not data:break
        count+=len(data)
        if count>info.st_size:raise ValueError('closed movie grew during hash')
        digest.update(data)
    if count!=info.st_size or digest.hexdigest()!=e['output_sha256']or identity(os.fstat(fd))!=before or identity(os.lstat(path))!=before:raise ValueError('closed movie hash/stat changed')
    sys.stdout.write(json.dumps({'result':'CLOSED_MEDIA_BYTES_MATCH','path':path,'identity':before,'sha256':digest.hexdigest(),'bytes':count}))
finally:os.close(fd)
'''

def fetch_private_export_report(request, receipt, fixture_directory, uid, results):
    """One-shot <=3 JSON chunks plus ONE closed-MOV hash check, exclusive NEW host directory.

    Returns artifact paths/metadata, never the large report/PNG blobs. Exceptions,
    including SystemExit channel ambiguity, persist fetch-error.json then propagate.
    Raw stderr stays in guest; caller must not claim all stderr was exported.
    """
    results = Path(results)
    if (not re.fullmatch(r'/private/var/tmp/LightClickFCPFixture\.[A-Za-z0-9_-]{6,16}', fixture_directory)
            or type(uid) is not int or uid <= 0 or not isinstance(receipt, dict)
            or receipt.get('path') != fixture_directory + '/export-verification.json'
            or type(receipt.get('bytes')) is not int or not 0 < receipt['bytes'] <= 524289
            or receipt.get('uid') != uid or receipt.get('mode') != 0o600 or receipt.get('nlink') != 1
            or not isinstance(receipt.get('sha256'), str) or not re.fullmatch('[0-9a-f]{64}', receipt['sha256'])):
        raise ValueError('invalid fixed private verifier report receipt')
    if not results.is_absolute():
        raise ValueError('new absolute host results directory required')
    results.mkdir(mode=0o700)  # Fail rather than reuse or replace an existing path.
    summary = {'result': 'FETCH_INCOMPLETE', 'chunks': [], 'fidelity_requires_review': True,
               'stderr_raw_exported': False, 'receipt': receipt, 'closed_media_revalidated': False}
    began = time.monotonic()
    deadline = began + 90
    chunk_deadline = began + 45
    def save():
        (results / 'fetch-status.json').write_text(json.dumps(summary, indent=2) + '\n')
    def exclusive(path, data):
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
    try:
        save()
        data = bytearray()
        identity = {k: receipt[k] for k in ('device', 'inode', 'uid', 'mode', 'nlink', 'bytes', 'mtime', 'ctime')}
        for offset in range(0, receipt['bytes'], 196608):
            if len(summary['chunks']) >= 3:
                raise ValueError('report exceeds three chunks')
            remaining = chunk_deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('private report fetch deadline')
            length = min(196608, receipt['bytes'] - offset)
            expected = {'fixture_directory': fixture_directory, 'uid': uid, 'receipt': receipt,
                        'offset': offset, 'length': length}
            response = request({'Executable': '/usr/bin/python', 'Arguments': ['-c', REPORT_CHUNK_GUEST, json.dumps(expected)]}, min(12, remaining))
            if not isinstance(response, dict) or response.get('Error') or type(response.get('ExitCode')) is not int or response.get('ExitCode') != 0:
                summary['failed_response'] = response
                raise ValueError('private report chunk failed')
            text = response.get('Stdout')
            if not isinstance(text, str) or len(text.encode()) > 300 * 1024:
                raise ValueError('chunk JSON envelope outside bound')
            item = json.loads(text)
            encoded = item.get('base64')
            if not isinstance(encoded, str) or len(encoded) > 262144:
                raise ValueError('chunk base64 outside bound')
            piece = base64.b64decode(encoded, validate=True)
            if (item.get('identity') != identity or item.get('offset') != offset or item.get('bytes') != length
                    or item.get('whole_sha256') != receipt['sha256'] or len(piece) != length
                    or hashlib.sha256(piece).hexdigest() != item.get('sha256')):
                raise ValueError('chunk identity/range/hash mismatch')
            data.extend(piece)
            summary['chunks'].append({'offset': offset, 'bytes': length, 'sha256': item['sha256']})
            save()
        raw = bytes(data)
        if len(raw) != receipt['bytes'] or hashlib.sha256(raw).hexdigest() != receipt['sha256']:
            raise ValueError('complete verifier report hash/size mismatch')
        # Retain verified raw bytes even if malformed JSON/thumbnail content fails below.
        partial = results / 'export-verification.json.partial'
        exclusive(partial, raw)
        summary.update(raw_json_partial=str(partial), sha256=receipt['sha256'], bytes=len(raw))
        parsed = json.loads(raw.decode('utf-8'))
        if not isinstance(parsed, dict):
            raise ValueError('verifier JSON is not an object')
        raw_path = results / 'export-verification.json'
        os.link(partial, raw_path)  # Publish only after complete hash AND JSON validation.
        partial.unlink()
        summary['raw_json'] = str(raw_path)
        summary.pop('raw_json_partial', None)
        summary['verifier_result'] = parsed.get('result')
        artifacts = []
        summary['thumbnail_artifacts'] = artifacts
        inline = parsed.get('inline_pngs', [])
        if not isinstance(inline, list) or len(inline) > 4:
            raise ValueError('inline PNG pair count outside bound')
        seen = set()
        for pair in inline:
            frame = pair.get('frame') if isinstance(pair, dict) else None
            if type(frame) is not int or frame not in (0, 30, 120, 239) or frame in seen:
                raise ValueError('thumbnail frame outside fixed set or duplicate')
            seen.add(frame)
            for kind in ('source', 'output'):
                encoded = pair.get(kind + '_png_base64')
                if not isinstance(encoded, str) or len(encoded) > 350000:
                    raise ValueError('thumbnail encoded size outside bound')
                png = base64.b64decode(encoded, validate=True)
                if (not 24 <= len(png) <= 262144 or png[:8] != b'\x89PNG\r\n\x1a\n'
                        or png[12:16] != b'IHDR' or struct.unpack('>II', png[16:24]) != (320, 180)):
                    raise ValueError('thumbnail PNG signature/dimensions invalid')
                path = results / ('frame-%03d-%s.png' % (frame, kind))
                exclusive(path, png)
                artifacts.append({'frame': frame, 'kind': kind, 'path': str(path), 'bytes': len(png),
                                  'sha256': hashlib.sha256(png).hexdigest()})
                save()
        summary.update(result='REPORT_FETCHED_FIDELITY_REQUIRES_REVIEW', thumbnail_artifacts=artifacts, thumbnails_complete=len(seen) == 4,
                       report_complete=parsed.get('report_complete'), structure_claim=parsed.get('media_structure_qualified'))
        save()
        # FCP has been cleaned up by the collector. Validate the CLOSED movie bytes,
        # not a possibly still-open export observed only while FCP was alive.
        truth = lambda value: type(value) in (bool, int) and value == 1
        structural = (parsed.get('result') == 'MEDIA_STRUCTURE_VALID_FIDELITY_REQUIRES_REVIEW'
                      and all(truth(parsed.get(k)) for k in ('report_complete', 'media_structure_qualified', 'files_stable_after_verification'))
                      and parsed.get('fidelity_qualified') is False)
        if structural:
            output_file = parsed.get('output_file', {})
            output_sha = parsed.get('output_sha256')
            if (not isinstance(output_file, dict) or any(type(output_file.get(k)) is not int for k in ('device', 'inode', 'uid', 'bytes'))
                    or output_file.get('uid') != uid or not 0 < output_file.get('bytes', 0) <= 512 * 1024 * 1024
                    or not isinstance(output_sha, str) or not re.fullmatch('[0-9a-f]{64}', output_sha)):
                summary['closed_media_error'] = 'successful verifier omitted bounded output identity/hash'
            else:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError('closed movie postcheck deadline')
                expected = {'fixture_directory': fixture_directory, 'uid': uid,
                            'output_file': output_file, 'output_sha256': output_sha}
                response = request({'Executable': '/usr/bin/python', 'Arguments': ['-c', CLOSED_MEDIA_GUEST, json.dumps(expected)]}, min(45, remaining))
                summary['closed_media_response'] = response
                if (isinstance(response, dict) and not response.get('Error') and type(response.get('ExitCode')) is int
                        and response['ExitCode'] == 0 and isinstance(response.get('Stdout'), str)
                        and len(response['Stdout'].encode()) <= 32768):
                    try:
                        closed = json.loads(response['Stdout'])
                        summary['closed_media_revalidated'] = (isinstance(closed, dict) and closed.get('result') == 'CLOSED_MEDIA_BYTES_MATCH'
                            and closed.get('path') == fixture_directory + '/export.mov' and closed.get('sha256') == output_sha
                            and closed.get('bytes') == output_file['bytes']
                            and all(closed.get('identity', {}).get(k) == output_file[k] for k in ('device', 'inode', 'uid', 'bytes')))
                    except (ValueError, TypeError):
                        summary['closed_media_error'] = 'invalid closed media response JSON'
                if not summary['closed_media_revalidated']:
                    summary.setdefault('closed_media_error', 'closed movie identity/hash postcheck did not qualify')
            summary['result'] = ('REPORT_FETCHED_CLOSED_MEDIA_VERIFIED_FIDELITY_REQUIRES_REVIEW' if summary['closed_media_revalidated']
                                 else 'REPORT_FETCHED_CLOSED_MEDIA_UNQUALIFIED')
        else:
            summary['closed_media_skipped'] = 'verifier report not structurally successful'
        save()
        return summary
    except BaseException as error:
        summary['error'] = repr(error)
        save()
        raise
    finally:
        summary['elapsed_seconds'] = time.monotonic() - began
        save()
