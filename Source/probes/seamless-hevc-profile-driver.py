"""guest-bench driver: qualify desktop materials, then profile one quiet fixed-OS-image decode.

One driver argument: an already-built x86_64 image-decode probe. No build, raw export, Preview, or timing claim.
Complete profiling evidence lives beside the disposable bench directory, so guest-bench cleanup preserves it.
"""
import json
from pathlib import Path
import re
import shlex
import tempfile

OS_IMAGE = '/Library/Desktop Pictures/Mojave.heic'
PROFILE = r'''#pragma D option quiet
profile-997 /pid == $target && arg1/ { @hot[usym(arg1), arg1] = count(); }
tick-20s { exit(1); }
dtrace:::END {
    trunc(@hot, 30);
    printa("HEVC_HOT %A 0x%016x %@d\n", @hot);
}
'''


def staged_path(value):
    if not isinstance(value, str) or not re.fullmatch(r'/private/var/tmp/VirtualIntelMac\.[A-Za-z0-9]{6}/Transfer\.bin', value):
        raise RuntimeError(f'unexpected private staging receipt: {value!r}')
    return value


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
        wrapper = '#!/bin/sh\nexec ' + shlex.quote(guest_probe) + ' --full-resolution ' + shlex.quote(OS_IMAGE) + ' --timeout 15\n'
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
        if (not isinstance(response, dict) or 'Error' in response or
                type(response.get('ExitCode')) is not int or response['ExitCode'] != 0):
            raise RuntimeError(f'profiling command failed: {response!r}')
        stdout = response.get('Stdout') or ''
        rows = [{'symbol': m[1], 'rip': '0x' + m[2], 'samples': int(m[3])}
                for m in re.finditer(r'^HEVC_HOT (.+?) 0x([0-9a-fA-F]{1,16}) ([1-9][0-9]*)\s*$', stdout, re.M)]
        reports = []
        for line in stdout.splitlines():
            if line.startswith('{'):
                report = json.loads(line)
                if isinstance(report, dict) and report.get('mode') == 'full-resolution':
                    reports.append(report)
        evidence.update(hot_rows=rows, probe_reports=reports)
        save()
        if not rows:
            raise RuntimeError('profile returned no nonempty sampled user-PC rows; no substitute workload was run')
        if len(reports) != 1 or reports[0].get('format_version') != 1:
            raise RuntimeError('profile did not retain exactly one successful full-resolution probe JSON report')
        evidence.update(result='PASS', phase='complete', note='Sample discovery only; no decoder or application speedup claim.')
        save()
        if record:
            record('hevc_profile_finished', hot_rows=len(rows))
        print(f'PASS quiet HEVC profile: {len(rows)} hot user-PC rows; evidence {destination}.json', flush=True)
    except (Exception, SystemExit) as error:
        evidence.update(result='FAIL', error=repr(error))
        save()
        raise SystemExit(f'FAIL quiet HEVC profile: {error}; evidence {destination}.json') from error


profile_after_materials()
