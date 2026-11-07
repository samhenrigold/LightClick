"""guest-bench driver: qualify desktop materials, then profile one quiet fixed-OS-image decode.

One driver argument: an already-built x86_64 image-decode probe. No build, raw export, Preview, or timing claim.
Complete profiling evidence lives beside the disposable bench directory, so guest-bench cleanup preserves it.
"""
import base64
import hashlib
import json
from pathlib import Path
import re
import shlex
import tempfile

OS_IMAGE = '/Library/Desktop Pictures/Mojave.heic'
PROFILE = r'''#pragma D option quiet
profile-997 /arg1 && (pid == $target || substr(execname, 0, 9) == "VTDecoder")/ {
    @total[pid, execname] = count();
    @functions[pid, execname, usym(arg1)] = count();
    @hot[pid, execname, usym(arg1), arg1] = count();
}
tick-20s { exit(1); }
dtrace:::END {
    printa("PROFILE_TOTAL %d %s %@d\n", @total);
    trunc(@functions, 30);
    printa("PROFILE_FUNCTION %d %s %A %@d\n", @functions);
    trunc(@hot, 30);
    printa("PROFILE_PC %d %s %A 0x%016x %@d\n", @hot);
}
'''

# Python 2.7 guest helper. The only file payload it reads is this fixed OS ICC profile. Process maps are metadata.
METADATA_HELPER = r'''import base64, hashlib, json, os, re, resource, signal, stat, subprocess, sys, tempfile, time
ICC = '/System/Library/ColorSync/Profiles/Display P3.icc'
def private_directory(directory):
    if not re.match(r'\A/private/var/tmp/VirtualIntelMac\.[A-Za-z0-9]{6}\Z', directory):
        raise ValueError('invalid metadata directory')
    info = os.lstat(directory)
    if os.path.realpath(directory) != directory or not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o077:
        raise ValueError('metadata directory must be canonical private root-owned directory')
def icc_profile():
    if os.path.realpath(ICC) != ICC:
        raise ValueError('ICC path is not canonical')
    fd = os.open(ICC, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or not 0 < info.st_size <= 65536:
            raise ValueError('ICC must be root-owned regular file within 64 KiB')
        data = os.read(fd, 65537)
        if len(data) != info.st_size:
            raise ValueError('ICC changed size while being read')
        return {'path': ICC, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
                'base64': base64.b64encode(data).decode('ascii')}
    finally:
        os.close(fd)
def service_pids(text):
    found = []
    for line in text.splitlines():
        fields = line.split(None, 2)
        if len(fields) != 3 or not fields[0].isdigit() or not fields[1].isdigit():
            continue
        pid, executable = int(fields[0]), fields[2]
        if not 0 < pid < 2147483648 or pid in found or not executable.startswith('/System/Library/') or not os.path.basename(executable).startswith('VTDecoder'):
            continue
        try:
            info = os.lstat(executable)
            if os.path.realpath(executable) == executable and stat.S_ISREG(info.st_mode) and info.st_uid == 0:
                found.append(pid)
        except OSError:
            pass
        if len(found) == 2:
            break
    return found
def capture(command, directory, deadline, target=None):
    remaining = min(2.0, deadline - time.time())
    if remaining <= 0:
        return {'command': command, 'error': 'metadata time budget exhausted'}
    def limit_output():
        resource.setrlimit(resource.RLIMIT_FSIZE, (512 * 1024, 512 * 1024))
    with tempfile.TemporaryFile(dir=directory) as output:
        process = subprocess.Popen(command, stdin=open(os.devnull, 'rb'), stdout=output, stderr=subprocess.STDOUT,
                                   close_fds=True, preexec_fn=limit_output)
        stop = time.time() + remaining
        while process.poll() is None and time.time() < stop:
            time.sleep(0.05)
        timed_out = process.poll() is None
        if timed_out:
            process.kill()
            stop = time.time() + 0.5
            while process.poll() is None and time.time() < stop:
                time.sleep(0.05)
        output.seek(0)
        data = output.read(512 * 1024 + 1)
        text = data.decode('utf-8', 'replace')
        if command[0] == '/usr/bin/vmmap':
            lines = text.splitlines()
            # Preserve process/image headers plus executable mappings, including anonymous/JIT executable regions.
            selected = [line for i, line in enumerate(lines) if i < 15 or re.search(r'\b[r-][w-]x(?:/|\s)', line)]
            text = '\n'.join(selected) + '\n'
        elif command[0] == '/bin/ps':
            selected = []
            for line in text.splitlines():
                fields = line.split(None, 2)
                if len(fields) == 3 and (fields[0] == target or os.path.basename(fields[2]).startswith('VTDecoder')):
                    selected.append(line)
            text = '\n'.join(selected) + '\n'
        selected_bytes = text.encode('utf-8')
        return {'command': command, 'exit_code': process.poll(), 'timeout': timed_out,
                'bytes_observed': len(data), 'source_truncated': len(data) >= 512 * 1024,
                'selected_bytes': len(selected_bytes), 'truncated': len(selected_bytes) > 32768,
                'selection': 'headers and executable mappings' if command[0] == '/usr/bin/vmmap' else 'target and VTDecoder process metadata',
                'output': selected_bytes[:32768].decode('utf-8', 'replace')}
def write_fixed(directory, name, data):
    fd = os.open(directory + '/' + name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as output:
        output.write(data)
def collect(target, directory):
    private_directory(directory)
    if not re.match(r'\A[1-9][0-9]{0,9}\Z', target) or int(target) >= 2147483648:
        raise ValueError('invalid target PID')
    os.umask(0o077)
    time.sleep(0.7)
    deadline = time.time() + 7
    result = {'target_pid': int(target), 'observer_delay_seconds': 0.7, 'captures': [], 'errors': []}
    try:
        result['icc_profile'] = icc_profile()
    except Exception as error:
        result['errors'].append('ICC: ' + str(error))
    for command in (['/usr/bin/vmmap', '-w', target], ['/bin/ps', '-axo', 'pid=,ppid=,comm=']):
        try:
            result['captures'].append(capture(command, directory, deadline, target))
        except Exception as error:
            result['errors'].append(str(error))
    listing = next((item.get('output', '') for item in result['captures'] if item['command'][0] == '/bin/ps'), '')
    result['service_pids'] = service_pids(listing)
    for pid in result['service_pids']:
        try:
            result['captures'].append(capture(['/usr/bin/vmmap', '-w', str(pid)], directory, deadline))
        except Exception as error:
            result['errors'].append(str(error))
    data = json.dumps(result, ensure_ascii=True).encode('ascii')
    if len(data) > 320 * 1024:
        for item in result['captures']:
            item['output'] = ''
            item['truncated'] = True
        result['errors'].append('serialized metadata exceeded 320 KiB; command text omitted')
        data = json.dumps(result, ensure_ascii=True).encode('ascii')
    write_fixed(directory, 'profile-metadata.json', data)
    write_fixed(directory, 'profile-metadata.done', b'1')
signal.alarm(12)
collect(sys.argv[1], sys.argv[2])
'''

METADATA_READ = r'''import json, os, re, stat, sys, time
directory = sys.argv[1]
if not re.match(r'\A/private/var/tmp/VirtualIntelMac\.[A-Za-z0-9]{6}\Z', directory):
    raise ValueError('invalid metadata directory')
info = os.lstat(directory)
if os.path.realpath(directory) != directory or not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o077:
    raise ValueError('metadata directory is not canonical private root-owned directory')
deadline = time.time() + 10
while not os.path.exists(directory + '/profile-metadata.done') and time.time() < deadline:
    time.sleep(0.1)
marker = os.open(directory + '/profile-metadata.done', os.O_RDONLY | os.O_NOFOLLOW)
try:
    info = os.fstat(marker)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_size != 1 or os.read(marker, 2) != b'1':
        raise ValueError('metadata completion marker is invalid')
finally:
    os.close(marker)
fd = os.open(directory + '/profile-metadata.json', os.O_RDONLY | os.O_NOFOLLOW)
try:
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or not 0 < info.st_size <= 320 * 1024:
        raise ValueError('metadata file violates size/ownership contract')
    data = os.read(fd, 320 * 1024 + 1)
    if len(data) != info.st_size:
        raise ValueError('metadata file changed size')
    sys.stdout.write(data)
finally:
    os.close(fd)
'''


def staged_path(value):
    if not isinstance(value, str) or not re.fullmatch(r'/private/var/tmp/VirtualIntelMac\.[A-Za-z0-9]{6}/Transfer\.bin', value):
        raise RuntimeError(f'unexpected private staging receipt: {value!r}')
    return value


def collect_metadata(guest_wrapper):
    response = request({'Executable': '/usr/bin/python',
                        'Arguments': ['-c', METADATA_READ, guest_wrapper.rsplit('/', 1)[0]]}, 15)
    if (not isinstance(response, dict) or 'Error' in response or type(response.get('ExitCode')) is not int
            or response['ExitCode'] != 0):
        return {'response': response, 'error': 'metadata command failed; decode result is independent'}
    try:
        text = response.get('Stdout')
        if not isinstance(text, str) or len(text) > 320 * 1024:
            raise ValueError('metadata report exceeded its limit or is not text')
        report = json.loads(text)
        if not isinstance(report, dict) or not isinstance(report.get('captures'), list) or len(report['captures']) > 4:
            raise ValueError('invalid metadata capture shape')
        profile = report.get('icc_profile')
        if profile is not None:
            if profile.get('path') != '/System/Library/ColorSync/Profiles/Display P3.icc':
                raise ValueError('unexpected ICC path')
            if not isinstance(profile.get('base64'), str) or len(profile['base64']) > 87384:
                raise ValueError('ICC payload exceeds its limit')
            payload = base64.b64decode(profile['base64'], validate=True)
            if (not 0 < len(payload) <= 65536 or type(profile.get('bytes')) is not int or
                    profile['bytes'] != len(payload) or hashlib.sha256(payload).hexdigest() != profile.get('sha256')):
                raise ValueError('ICC payload does not match its bounded size/hash report')
        return {'response': response, 'report': report,
                'note': 'ICC bytes are a fixed OS artifact; compare its hash to the prior P3 guest report before conversion. Metadata collection perturbs execution.'}
    except (ValueError, TypeError, AttributeError) as error:
        return {'response': response, 'error': str(error)}


def profile_after_materials():
    if not re.fullmatch(r'[A-Za-z0-9._-]+', tag) or tag in ('.', '..'):
        raise RuntimeError('profile driver needs a simple bench tag')
    destination = source/'Build/bench'/f'{tag}.hevc-profile'
    destination.parent.mkdir(parents=True, exist_ok=True)
    evidence = {'result': 'RUNNING', 'phase': 'arguments', 'os_image': OS_IMAGE, 'dtrace_program': PROFILE}

    def save():
        Path(str(destination) + '.json').write_text(json.dumps(evidence, indent=2)+'\n')

    try:
        save()
        if len(arguments) != 1 or not Path(arguments[0]).is_file():
            raise RuntimeError('supply exactly one existing host x86_64 image-decode probe')
        probe = Path(arguments[0]).resolve()
        evidence['phase'] = 'materials'
        save()
        # Use the original globals, including the timeline callback. desktop/materials raises on any failed check,
        # and returns only after toggle-off plus a successful gpu-mode-0 snapshot confirms agent release.
        materials = dict(globals(), arguments=['desktop', 'materials'])
        driver = source/'probes/seamless-driver.py'
        exec(compile(driver.read_text(), str(driver), 'exec'), materials)
        evidence['phase'] = 'materials_completed_agent_released'
        save()
        record = globals().get('record_phase')
        if record:
            record('hevc_profile_materials_completed')
        guest_probe = staged_path(stage(probe))
        wrapper = ('#!/bin/sh\n/usr/bin/python -c ' + shlex.quote(METADATA_HELPER) + ' "$$" "${0%/*}" </dev/null >/dev/null 2>&1 &\n'
                   'exec ' + shlex.quote(guest_probe) + ' --full-resolution ' + shlex.quote(OS_IMAGE) + ' --timeout 15\n')
        evidence.update(phase='wrapper_staging', guest_probe=guest_probe, wrapper=wrapper)
        save()
        with tempfile.TemporaryDirectory(prefix='lightclick-hevc-profile-') as temporary:
            local = Path(temporary)/'decode.sh'
            local.write_text(wrapper)
            guest_wrapper = staged_path(stage(local))
        command = {'Executable': '/usr/sbin/dtrace', 'Arguments': ['-q', '-n', PROFILE, '-c', shlex.quote(guest_wrapper)]}
        evidence.update(phase='profile_requested', command=command)
        save()
        if record:
            record('hevc_profile_requested')
        # Do not retry: an ambiguous host timeout can leave an outstanding command/reply in the diagnostics channel.
        response = request(command, 35)
        evidence.update(phase='profile_replied', response=response)
        save()
        if isinstance(response, dict):
            for field, suffix in (('Stdout', '.stdout.txt'), ('Stderr', '.stderr.txt')):
                Path(str(destination) + suffix).write_text(str(response.get(field) or ''))
        if isinstance(response, dict) and type(response.get('ExitCode')) is int:
            try:
                evidence['metadata'] = collect_metadata(guest_wrapper)
            except (Exception, SystemExit) as error:
                if isinstance(error, SystemExit) and isinstance(error.code, int):
                    raise
                evidence['metadata'] = {'error': repr(error), 'note': 'No retry; decode result is independent.'}
            save()
            if evidence['metadata'].get('error'):
                print(f'# metadata collection warning: {evidence["metadata"]["error"]}', flush=True)
        if (not isinstance(response, dict) or 'Error' in response or
                type(response.get('ExitCode')) is not int or response['ExitCode'] != 0):
            raise RuntimeError(f'profiling command failed: {response!r}')
        stdout = response.get('Stdout') or ''
        rows = [{'pid': int(m[1]), 'execname': m[2], 'symbol': m[3], 'rip': '0x' + m[4], 'samples': int(m[5])}
                for m in re.finditer(r'^PROFILE_PC ([1-9][0-9]*) (\S+) (.+?) 0x([0-9a-fA-F]{1,16}) ([1-9][0-9]*)\s*$', stdout, re.M)]
        totals = [{'pid': int(m[1]), 'execname': m[2], 'samples': int(m[3])}
                  for m in re.finditer(r'^PROFILE_TOTAL ([1-9][0-9]*) (\S+) ([1-9][0-9]*)\s*$', stdout, re.M)]
        functions = [{'pid': int(m[1]), 'execname': m[2], 'symbol': m[3], 'samples': int(m[4])}
                     for m in re.finditer(r'^PROFILE_FUNCTION ([1-9][0-9]*) (\S+) (.+?) ([1-9][0-9]*)\s*$', stdout, re.M)]
        reports = []
        for line in stdout.splitlines():
            if line.startswith('{'):
                report = json.loads(line)
                if isinstance(report, dict) and report.get('mode') == 'full-resolution':
                    reports.append(report)
        evidence.update(hot_rows=rows, function_rows=functions, sample_totals=totals, probe_reports=reports)
        save()
        if not rows or not functions or not totals:
            raise RuntimeError('profile returned an empty PC/function/total table; no substitute workload was run')
        if len(reports) != 1 or reports[0].get('format_version') != 1:
            raise RuntimeError('profile did not retain exactly one successful full-resolution probe JSON report')
        evidence.update(result='PASS', phase='complete', note='Sample discovery only; no decoder or application speedup claim.')
        save()
        if record:
            record('hevc_profile_finished', hot_rows=len(rows))
        print(f'PASS quiet user-PC profile: {len(rows)} hot user-PC rows; evidence {destination}.json', flush=True)
    except (Exception, SystemExit) as error:
        evidence.update(result='FAIL', error=repr(error))
        save()
        raise SystemExit(f'FAIL quiet HEVC profile: {error}; evidence {destination}.json') from error


profile_after_materials()
