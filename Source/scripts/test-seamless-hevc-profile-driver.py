#!/usr/bin/env python3
"""Mocked composition/profiling checks only: no guest, build, desktop, DTrace, or sockets."""
import ast
import base64
import hashlib
import os
import stat
import types
import contextlib
import io
import json
from pathlib import Path
import shlex
import tempfile


def load_driver():
    path = Path(__file__).resolve().parents[1]/'probes/seamless-hevc-profile-driver.py'
    tree = ast.parse(path.read_text(), filename=str(path))
    nodes = [node for node in tree.body if isinstance(node, (ast.Import, ast.ImportFrom, ast.FunctionDef, ast.Assign))]
    namespace = {}
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(path), 'exec'), namespace)
    return namespace



def helper_checks():
    driver = load_driver()
    tree = ast.parse(driver['METADATA_HELPER'])
    body = [node for node in tree.body if isinstance(node, (ast.Import, ast.FunctionDef, ast.Assign))]
    helper = {}
    exec(compile(ast.Module(body=body, type_ignores=[]), 'metadata helper extracted', 'exec'), helper)
    original = dict(helper)
    profile_path = '/System/Library/ColorSync/Profiles/Display P3.icc'
    for option in ('valid', 'alias', 'owner', 'kind', 'empty', 'large', 'short'):
        closed, opened = [], []
        payload = b'ICC fixture'
        info = types.SimpleNamespace(st_uid=501 if option == 'owner' else 0,
                                     st_mode=stat.S_IFLNK if option == 'kind' else stat.S_IFREG,
                                     st_size=0 if option == 'empty' else 65537 if option == 'large' else len(payload))
        def open_profile(path, flags):
            assert path == profile_path and flags & os.O_NOFOLLOW
            opened.append(path)
            return 9
        helper['os'] = types.SimpleNamespace(path=types.SimpleNamespace(realpath=lambda path: '/Users/forbidden' if option == 'alias' else path),
                                             open=open_profile, O_RDONLY=os.O_RDONLY, O_NOFOLLOW=os.O_NOFOLLOW,
                                             fstat=lambda _: info, read=lambda fd, count: payload[:-1] if option == 'short' else payload,
                                             close=lambda fd: closed.append(fd))
        try:
            result = helper['icc_profile']()
        except ValueError:
            assert option != 'valid'
        else:
            assert option == 'valid'
            assert base64.b64decode(result['base64']) == payload
            assert result['sha256'] == hashlib.sha256(payload).hexdigest()
        assert closed == ([9] if opened else [])
    helper.update(original)
    directory = '/private/var/tmp/VirtualIntelMac.ABC123'
    for option in ('valid', 'alias', 'owner', 'permissions', 'symlink', 'escape'):
        info = types.SimpleNamespace(st_uid=501 if option == 'owner' else 0,
                                     st_mode=stat.S_IFLNK if option == 'symlink' else stat.S_IFDIR | (0o755 if option == 'permissions' else 0o700))
        helper['os'] = types.SimpleNamespace(lstat=lambda path: info,
                                             path=types.SimpleNamespace(realpath=lambda path: '/Users/forbidden' if option == 'alias' else path))
        try:
            helper['private_directory']('/Users/forbidden' if option == 'escape' else directory)
        except ValueError:
            assert option != 'valid'
        else:
            assert option == 'valid'
    helper.update(original)
    valid_info = types.SimpleNamespace(st_uid=0, st_mode=stat.S_IFREG)
    helper['os'] = types.SimpleNamespace(lstat=lambda path: valid_info,
                                         path=types.SimpleNamespace(basename=os.path.basename, realpath=lambda path: path))
    listing = ('1 0 /Users/private/VTDecoderFake\n'
               '2 0 /System/Library/VTDecoderOne\n'
               '2 0 /System/Library/VTDecoderOne\n'
               '3 0 /System/Library/VTDecoderTwo\n'
               '4 0 /System/Library/VTDecoderThree\n')
    assert helper['service_pids'](listing) == [2, 3]
    helper.update(original)
    with tempfile.TemporaryDirectory(prefix='lightclick-map-capture-test-') as temporary:
        for option in ('filtered', 'oversize', 'timeout', 'budget', 'late-service'):
            clock, killed, limits, calls = [0.0], [], [], []
            helper['time'] = types.SimpleNamespace(time=lambda: clock[0], sleep=lambda value: clock.__setitem__(0, clock[0] + value))
            helper['resource'] = types.SimpleNamespace(RLIMIT_FSIZE=1, setrlimit=lambda kind, value: limits.append(value))
            def popen(command, **kwargs):
                calls.append(command)
                kwargs['preexec_fn']()
                # Unknown executable region appears after many heap rows; a blind first32KiB loses it.
                data = (b'header\n' * 15 + b'heap rw-/rwx\n' * 4000 + b'JIT 000010cb0000-000010cc0000 r-x/rwx\n')
                if option == 'oversize':
                    data = b'A' * (512 * 1024 + 10)
                elif option == 'late-service':
                    data = (b'42 1 /private/var/tmp/VirtualIntelMac.ABC123/Transfer.bin\n'
                            + b'100 1 /System/Library/UnrelatedLongExecutableName\n' * 2000
                            + b'314 1 /System/Library/VTDecoderLate\n')
                    assert data.index(b'314 1') > 32768
                kwargs['stdout'].write(data)
                kwargs['stdout'].flush()
                return types.SimpleNamespace(poll=lambda: -9 if killed else None if option == 'timeout' else 0,
                                             kill=lambda: killed.append(True))
            helper['subprocess'] = types.SimpleNamespace(Popen=popen, STDOUT=-2)
            command = ['/bin/ps', '-axo', 'pid=,ppid=,comm='] if option == 'late-service' else ['/usr/bin/vmmap', '-w', '42']
            result = helper['capture'](command, temporary, 0 if option == 'budget' else 7, '42')
            if option == 'budget':
                assert not calls and 'budget' in result['error']
            else:
                assert limits == [(512 * 1024, 512 * 1024)]
                assert len(result['output'].encode()) <= 32768
                assert result['bytes_observed'] <= 512 * 1024 + 1
                if option == 'filtered':
                    assert 'JIT 000010cb0000' in result['output'] and 'heap' not in result['output']
                elif option == 'oversize':
                    assert result['source_truncated'] and result['truncated']
                elif option == 'late-service':
                    assert result['bytes_observed'] > 32768 and not result['source_truncated']
                    assert result['output'].splitlines() == [
                        '42 1 /private/var/tmp/VirtualIntelMac.ABC123/Transfer.bin',
                        '314 1 /System/Library/VTDecoderLate']
                    assert not result['truncated']
                    previous_os = helper['os']
                    helper['os'] = types.SimpleNamespace(lstat=lambda path: valid_info,
                        path=types.SimpleNamespace(basename=os.path.basename, realpath=lambda path: path))
                    assert helper['service_pids'](result['output']) == [314]
                    helper['os'] = previous_os
                else:
                    assert result['timeout'] and killed and clock[0] <= 2.6
    helper.update(original)
    # The real orchestration can request only the fixed target + ps + two service maps, then two fixed artifacts.
    outputs, commands = [], []
    helper.update(private_directory=lambda directory: None, icc_profile=lambda: {'bytes': 1},
                  service_pids=lambda text: [2, 3],
                  capture=lambda command, directory, deadline, target=None: commands.append(command) or {'command': command, 'output': 'metadata'},
                  write_fixed=lambda directory, name, data: outputs.append((name, data)),
                  time=types.SimpleNamespace(time=lambda: 0, sleep=lambda value: None))
    helper['collect']('42', '/unused/mock')
    assert len(commands) == 4 and [item[0] for item in outputs] == ['profile-metadata.json', 'profile-metadata.done']
    assert len(outputs[0][1]) <= 320 * 1024
    for target in ('0', '-1', '2147483648', '42;other'):
        try:
            helper['collect'](target, '/unused/mock')
        except ValueError:
            pass
        else:
            raise AssertionError('invalid target PID accepted')
    reader = ast.parse(driver['METADATA_READ'])
    reader.body = [node for node in reader.body if not isinstance(node, ast.Import)]
    for option in ('valid', 'not-ready', 'marker-owner', 'marker-size', 'json-owner', 'json-large', 'symlink'):
        clock, closed = [0.0], []
        payload = b'{"captures": []}'
        def open_fixed(path, flags):
            assert flags & os.O_NOFOLLOW
            assert path in (directory + '/profile-metadata.done', directory + '/profile-metadata.json')
            if option == 'symlink' or option == 'not-ready':
                raise OSError('refused absent or symlink artifact')
            return 1 if path.endswith('.done') else 2
        def fstat(fd):
            return types.SimpleNamespace(st_mode=stat.S_IFREG,
                st_uid=501 if option == ('marker-owner' if fd == 1 else 'json-owner') else 0,
                st_size=(2 if option == 'marker-size' else 1) if fd == 1 else
                        (320 * 1024 + 1 if option == 'json-large' else len(payload)))
        fake_os = types.SimpleNamespace(O_RDONLY=os.O_RDONLY, O_NOFOLLOW=os.O_NOFOLLOW, open=open_fixed,
            lstat=lambda path: types.SimpleNamespace(st_uid=0, st_mode=stat.S_IFDIR | 0o700),
            path=types.SimpleNamespace(realpath=lambda path: path, exists=lambda path: option != 'not-ready'),
            fstat=fstat, read=lambda fd, limit: b'1' if fd == 1 else payload, close=lambda fd: closed.append(fd))
        output = io.BytesIO()
        namespace = dict(original, os=fake_os, sys=types.SimpleNamespace(argv=['reader', directory], stdout=output),
            time=types.SimpleNamespace(time=lambda: clock[0], sleep=lambda value: clock.__setitem__(0, clock[0] + value)))
        try:
            exec(compile(reader, 'metadata reader extracted', 'exec'), namespace)
        except (OSError, ValueError):
            assert option != 'valid'
        else:
            assert option == 'valid' and output.getvalue() == payload and closed == [1, 2]
        assert clock[0] <= 10.1
    print('PASS metadata helper: fixed ICC path, root/canonical/size/hash checks, two-service cap, map filtering and bounded captures')


def main():
    helper_checks()
    names = ('success', 'materials-fail', 'probe-stage-fail', 'wrapper-stage-fail',
             'nonzero', 'missing-hot', 'missing-json', 'control-error', 'host-timeout', 'boolean-exit',
             'metadata-fail', 'metadata-timeout', 'bad-icc', 'metadata-cancel')
    with tempfile.TemporaryDirectory(prefix='lightclick-hevc-profile-test-') as temporary:
        root = Path(temporary)
        for name in names:
            namespace = load_driver()
            source = root/name
            (source/'probes').mkdir(parents=True)
            probe = source/'probe with spaces'
            probe.write_bytes(b'not executable: staging is mocked')
            (source/'probes/seamless-driver.py').write_text('''
assert arguments == ['desktop', 'materials']
assert record_phase is expected_record
events.append('materials')
record_phase('mock_materials_started')
if materials_failure:
    raise SystemExit('mock materials failed')
events.append('agent_released')
record_phase('mock_materials_agent_released')
''')
            events, phases, stages, requests, replies = [], [], [], [], []

            def record(phase, **fields):
                phases.append((phase, fields))

            def stage(path):
                assert events[-1] == 'agent_released', 'staged before materials completed and released the agent'
                stages.append(Path(path))
                if len(stages) == 1:
                    assert Path(path) == probe.resolve()
                    if name == 'probe-stage-fail':
                        raise SystemExit('mock probe staging failed')
                    return '/private/var/tmp/VirtualIntelMac.ABC123/Transfer.bin'
                assert len(stages) == 2
                shell = Path(path).read_text()
                assert shell.splitlines()[0] == '#!/bin/sh'
                assert shell.endswith('--timeout 15\n')
                wrapper_exec = shell.rsplit('\nexec ', 1)[1].strip()
                assert shlex.split('exec ' + wrapper_exec) == [
                    'exec', '/private/var/tmp/VirtualIntelMac.ABC123/Transfer.bin', '--full-resolution',
                    '/Library/Desktop Pictures/Mojave.heic', '--timeout', '15']
                assert '--raw' not in shell and '/Users/' not in shell
                assert shlex.quote(namespace['METADATA_HELPER']) in shell and '"$$" "${0%/*}"' in shell
                if name == 'wrapper-stage-fail':
                    raise RuntimeError('mock wrapper staging failed')
                return '/private/var/tmp/VirtualIntelMac.DEF456/Transfer.bin'

            def request(command, timeout):
                requests.append(command)
                assert len(stages) == 2
                if command['Executable'] == '/usr/bin/python':
                    assert len(requests) == 2 and timeout == 15
                    assert command['Arguments'] == ['-c', namespace['METADATA_READ'], '/private/var/tmp/VirtualIntelMac.DEF456']
                    if name == 'metadata-cancel':
                        raise SystemExit(130)
                    if name == 'metadata-timeout':
                        raise SystemExit('Timed out waiting for metadata')
                    if name == 'metadata-fail':
                        return {'Error': 'mock metadata unavailable'}
                    payload = b'fixed OS ICC bytes'
                    metadata = {'captures': [], 'icc_profile': {
                        'path': '/System/Library/ColorSync/Profiles/Display P3.icc', 'bytes': len(payload),
                        'sha256': '0' * 64 if name == 'bad-icc' else hashlib.sha256(payload).hexdigest(),
                        'base64': base64.b64encode(payload).decode()}}
                    return {'ExitCode': 0, 'Stdout': json.dumps(metadata)}
                assert len(requests) == 1 and timeout == 35
                assert command['Executable'] == '/usr/sbin/dtrace'
                options = command['Arguments']
                assert options[:2] == ['-q', '-n'] and options[2] == namespace['PROFILE']
                assert options[3] == '-c' and shlex.split(options[4]) == [
                    '/private/var/tmp/VirtualIntelMac.DEF456/Transfer.bin']
                assert 'pid == $target || substr(execname, 0, 9) == "VTDecoder"' in options[2] and 'tick-20s { exit(1); }' in options[2]
                assert 'trunc(@hot, 30)' in options[2]
                if name == 'host-timeout':
                    raise SystemExit('Timed out waiting for mock profile')
                output = ('PROFILE_PC 42 VTDecoderXPCServ fixture`function+0x8 0x0000000123456789 123\n'
                          'PROFILE_FUNCTION 42 VTDecoderXPCServ fixture`function 456\n'
                          'PROFILE_TOTAL 42 VTDecoderXPCServ 789\n'
                          + json.dumps({'mode': 'full-resolution', 'format_version': 1}) + '\n')
                if name == 'missing-hot':
                    output = output.split('\n', 1)[1]
                if name == 'missing-json':
                    output = '\n'.join(line for line in output.splitlines() if not line.startswith('{')) + '\n'
                response = {'ExitCode': 1 if name == 'nonzero' else 0,
                            'Stdout': output, 'Stderr': 'retained complete diagnostic\n'}
                if name == 'control-error':
                    response = {'Error': 'The control response timed out.'}
                if name == 'boolean-exit':
                    response['ExitCode'] = False
                replies.append(response)
                return response

            namespace.update(source=source, tag='fixture', arguments=[str(probe)], request=request, stage=stage,
                             events=events, record_phase=record, expected_record=record,
                             materials_failure=name == 'materials-fail')
            with contextlib.redirect_stdout(io.StringIO()):
                try:
                    namespace['profile_after_materials']()
                except SystemExit:
                    assert name not in ('success', 'metadata-fail', 'metadata-timeout', 'bad-icc'), 'successful profile unexpectedly failed'
                else:
                    assert name in ('success', 'metadata-fail', 'metadata-timeout', 'bad-icc'), f'{name}: invalid profile passed'
            evidence_path = source/'Build/bench/fixture.hevc-profile.json'
            evidence = json.loads(evidence_path.read_text())
            assert evidence['result'] == ('PASS' if name in ('success', 'metadata-fail', 'metadata-timeout', 'bad-icc') else 'FAIL')
            # The evidence is a sibling of, not contained in, guest-bench's disposable tag work directory.
            assert not evidence_path.is_relative_to(source/'Build/bench/fixture')
            if name == 'materials-fail':
                assert not stages and not requests
            elif name == 'probe-stage-fail':
                assert len(stages) == 1 and not requests
            elif name == 'wrapper-stage-fail':
                assert len(stages) == 2 and not requests
            else:
                assert len(requests) == (1 if name in ('host-timeout', 'control-error', 'boolean-exit') else 2)
                if name == 'host-timeout':
                    assert 'Timed out waiting' in evidence['error'] and 'response' not in evidence
                else:
                    response = evidence['response']
                    assert response == replies[0], 'complete response changed or was truncated'
                    if 'Stdout' in response:
                        assert evidence_path.with_suffix('.stdout.txt').read_text() == response['Stdout']
                        assert evidence_path.with_suffix('.stderr.txt').read_text() == response['Stderr']
            if name in ('metadata-fail', 'metadata-timeout', 'bad-icc'):
                assert evidence['metadata']['error']
            if name == 'success':
                assert evidence['hot_rows'] == [{'pid': 42, 'execname': 'VTDecoderXPCServ', 'symbol': 'fixture`function+0x8',
                                                'rip': '0x0000000123456789', 'samples': 123}]
                assert len(evidence['probe_reports']) == 1
                assert evidence['sample_totals'][0]['samples'] == 789
                assert evidence['function_rows'][0]['samples'] == 456
                assert phases[-1][0] == 'hevc_profile_finished'
    print(f'PASS quiet profile composition: {len(names)} mocked cases; release ordering, fixed scope, deadlines and durable failures')


if __name__ == '__main__':
    main()
