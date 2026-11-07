#!/usr/bin/env python3
"""Mocked composition/profiling checks only: no guest, build, desktop, DTrace, or sockets."""
import ast
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


def main():
    names = ('success', 'materials-fail', 'probe-stage-fail', 'wrapper-stage-fail',
             'nonzero', 'missing-hot', 'missing-json', 'control-error', 'host-timeout', 'boolean-exit')
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
                assert shlex.split(shell.splitlines()[1]) == [
                    'exec', '/private/var/tmp/VirtualIntelMac.ABC123/Transfer.bin', '--full-resolution',
                    '/Library/Desktop Pictures/Mojave.heic', '--timeout', '15']
                assert len(shell.splitlines()) == 2 and '--raw' not in shell and '/Users/' not in shell
                if name == 'wrapper-stage-fail':
                    raise RuntimeError('mock wrapper staging failed')
                return '/private/var/tmp/VirtualIntelMac.DEF456/Transfer.bin'

            def request(command, timeout):
                requests.append(command)
                assert len(requests) == 1 and len(stages) == 2 and timeout == 35
                assert command['Executable'] == '/usr/sbin/dtrace'
                options = command['Arguments']
                assert options[:2] == ['-q', '-n'] and options[2] == namespace['PROFILE']
                assert options[3] == '-c' and shlex.split(options[4]) == [
                    '/private/var/tmp/VirtualIntelMac.DEF456/Transfer.bin']
                assert 'pid == $target && arg1' in options[2] and 'tick-20s { exit(1); }' in options[2]
                assert 'trunc(@hot, 30)' in options[2]
                if name == 'host-timeout':
                    raise SystemExit('Timed out waiting for mock profile')
                output = ('HEVC_HOT AppleHEVCDecoder`real_function+0x8 0x0000000123456789 123\n'
                          + json.dumps({'mode': 'full-resolution', 'format_version': 1}) + '\n')
                if name == 'missing-hot':
                    output = output.split('\n', 1)[1]
                if name == 'missing-json':
                    output = output.split('\n')[0] + '\n'
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
                    assert name != 'success', 'successful profile unexpectedly failed'
                else:
                    assert name == 'success', f'{name}: invalid profile passed'
            evidence_path = source/'Build/bench/fixture.hevc-profile.json'
            evidence = json.loads(evidence_path.read_text())
            assert evidence['result'] == ('PASS' if name == 'success' else 'FAIL')
            # The evidence is a sibling of, not contained in, guest-bench's disposable tag work directory.
            assert not evidence_path.is_relative_to(source/'Build/bench/fixture')
            if name == 'materials-fail':
                assert not stages and not requests
            elif name == 'probe-stage-fail':
                assert len(stages) == 1 and not requests
            elif name == 'wrapper-stage-fail':
                assert len(stages) == 2 and not requests
            else:
                assert len(requests) == 1
                if name == 'host-timeout':
                    assert 'Timed out waiting' in evidence['error'] and 'response' not in evidence
                else:
                    response = evidence['response']
                    assert response == replies[0], 'complete response changed or was truncated'
                    if 'Stdout' in response:
                        assert evidence_path.with_suffix('.stdout.txt').read_text() == response['Stdout']
                        assert evidence_path.with_suffix('.stderr.txt').read_text() == response['Stderr']
            if name == 'success':
                assert evidence['hot_rows'] == [{'symbol': 'AppleHEVCDecoder`real_function+0x8',
                                                'rip': '0x0000000123456789', 'samples': 123}]
                assert len(evidence['probe_reports']) == 1
                assert phases[-1][0] == 'hevc_profile_finished'
    print(f'PASS quiet profile composition: {len(names)} mocked cases; release ordering, fixed scope, deadlines and durable failures')


if __name__ == '__main__':
    main()
