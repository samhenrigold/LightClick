#!/usr/bin/env python3
"""Same-VM FPS regression mocks: no guest, meter, UI, build, process launch or signals."""
import ast
import contextlib
import io
import json
import plistlib
from pathlib import Path
import subprocess
import tempfile
import types


def load():
    path = Path(__file__).parents[1]/'probes/seamless-driver.py'
    tree = ast.parse(path.read_text())
    tree.body = [node for node in tree.body if isinstance(node, (ast.Import, ast.ImportFrom)) or
                 isinstance(node, ast.FunctionDef) and node.name in ('fps_owned_processes', 'fps_window_rows', 'fps_result', 'fps')]
    ns = {}
    exec(compile(tree, str(path), 'exec'), ns)
    return ns


def main():
    ns = load()
    sample = lambda rate, reads=90: dict(presented=rate, reads=reads)
    for windowed, seamless, expected in ((60, 60, 'PASS'), (61, 55, 'PASS'), (62, 55, 'FAIL'),
                                         (60, 54, 'FAIL'), (54, 60, 'INCONCLUSIVE')):
        assert ns['fps_result'](sample(windowed), sample(seamless)) == expected
    assert ns['fps_result'](sample(60, 59), sample(60)) == 'INCONCLUSIVE'
    assert ns['fps_result'](sample(60), sample(60, 59)) == 'INCONCLUSIVE'
    owned = ns['fps_owned_processes'](Path('/tmp/clone'),
        '1 01:02.50 /tmp/clone/App.app/executable\n2 00:01.00 /tmp/clone-other/App\n'
        '3 00:01.00 /usr/bin/python /tmp/clone/tool\n')
    assert set(owned) == {1} and owned[1]['cpu_seconds'] == 62.5
    with tempfile.TemporaryDirectory() as temporary:
        for case in ('pass', 'empty-titles', 'multiple-windows', 'multiple-vm-windows', 'wrong-vm-title', 'wrong-title', 'guest-ambiguous', 'missing-host-id', 'zero-host-id', 'boolean-host-id', 'string-host-id', 'stale-host-id', 'foreign-host-id', 'duplicate-host-id', 'reused-host-id', 'changed-host-id', 'slow', 'low-reads', 'foreign-window', 'wrong-app', 'meter-timeout', 'cancel-meter', 'interrupt-meter', 'restore-fail', 'ambiguous-request'):
            root = Path(temporary)/case
            root.mkdir()
            ns = load()
            tag, clock, active, cpu, calls = 'fixture', [0.0], [False], [10.0], []
            cancelled_at = []
            work = root/'Build/bench'/tag
            app = str(work/'Light Click.app/Contents/MacOS/Light Click')
            bundle = work/'home/Library/Caches/Light Click/Seamless Apps/x/Safari.app'
            (bundle/'Contents').mkdir(parents=True)
            (bundle/'Contents/Info.plist').write_bytes(plistlib.dumps({
                'LCGuestBundleIdentifier': 'com.apple.TextEdit' if case == 'wrong-app' else 'com.apple.Safari'}))
            proxy = str(bundle/'Contents/MacOS/SeamlessProxy')
            def request(command, timeout):
                assert 0 < timeout <= 60
                calls.append(command)
                action = command.get('Action')
                if action == 'seamless-state':
                    if case == 'ambiguous-request':
                        raise SystemExit('Timed out waiting for state')
                    reply = dict(Active=active[0], OwnSurfaces=active[0], WindowVisible=not active[0], HostWindowID=100)
                    if case == 'missing-host-id':
                        del reply['HostWindowID']
                    elif case == 'zero-host-id':
                        reply['HostWindowID'] = 0
                    elif case == 'boolean-host-id':
                        reply['HostWindowID'] = True
                    elif case == 'string-host-id':
                        reply['HostWindowID'] = '100'
                    elif case == 'stale-host-id':
                        reply['HostWindowID'] = 999
                    elif case == 'foreign-host-id':
                        reply['HostWindowID'] = 200
                    elif case == 'changed-host-id' and cpu[0] > 10:
                        reply['HostWindowID'] = 101
                    return reply
                if action == 'seamless-toggle':
                    active[0] = not active[0]
                    return dict(Active=active[0])
                assert command['Executable'] == '/mock/guest'
                if command['Arguments'] == ['list']:
                    assert not active[0] and not any(item.get('Action') == 'seamless-toggle' for item in calls)
                    text = 'id=43 pid=401 layer=0 alpha=1 owner="Safari" title="Seamless page" bounds=0,0 800x600'
                    return dict(ExitCode=0, Stdout=text + ('\n'+text.replace('id=43', 'id=44') if case == 'guest-ambiguous' else ''))
                if command['Arguments'][0] == 'gpu':
                    return dict(ExitCode=0, Stdout='gpu mode 1 wrong' if case == 'restore-fail' else 'gpu mode 0 rows 0')
                assert command['Arguments'] == ['open-app', '--app', 'Safari']
                return dict(ExitCode=0)
            def run(command, **kwargs):
                assert kwargs['timeout'] in (5, 25)
                if command[0] == 'ps':
                    return types.SimpleNamespace(returncode=0, stdout=f'10 00:{cpu[0]:05.2f} {app}\n20 00:01.00 {proxy}', stderr='')
                if command[-1] == 'list':
                    pid = 999 if case == 'foreign-window' else 20
                    vm_title = '' if case in ('empty-titles', 'multiple-vm-windows') else 'Unexpected VM' if case == 'wrong-vm-title' else 'Clone of Test'
                    safari_title = '' if case in ('empty-titles', 'multiple-windows') else 'Wrong page' if case == 'wrong-title' else 'Seamless page'
                    vm_pid = 999 if case == 'reused-host-id' and cpu[0] > 10 else 10
                    text = (f'id=100 pid={vm_pid} layer=0 alpha=1 owner="Light Click" title="{vm_title}" bounds=0,0 800x600\n'
                            f'id=200 pid={pid} layer=0 alpha=1 owner="Safari" title="{safari_title}" bounds=0,0 800x600')
                    if case == 'multiple-windows':
                        text += f'\nid=201 pid={pid} layer=0 alpha=1 owner="Safari" title="" bounds=0,0 400x300'
                    if case in ('multiple-vm-windows', 'changed-host-id'):
                        text += '\nid=101 pid=10 layer=0 alpha=1 owner="Light Click" title="" bounds=0,0 400x300'
                    if case == 'duplicate-host-id':
                        text += '\nid=100 pid=999 layer=0 alpha=1 owner="Other VM" title="" bounds=0,0 400x300'
                    return types.SimpleNamespace(returncode=0, stdout=text, stderr='')
                assert command[0].endswith('seamless-present-meter') and command[2] == '20'
                if case in ('cancel-meter', 'interrupt-meter') and active[0]:
                    cancelled_at.append(len(calls))
                    raise SystemExit(130) if case == 'cancel-meter' else KeyboardInterrupt()
                if case == 'meter-timeout':
                    raise subprocess.TimeoutExpired(command, 25)
                clock[0] += 20
                cpu[0] += 5
                rate = 28 if active[0] and case == 'slow' else 60
                reads = 30 if case == 'low-reads' else 90
                return types.SimpleNamespace(returncode=0, stdout=f'presented {rate} distinct/s, from {reads} reads/s, over 20 s', stderr='')
            ns.update(source=root, results=root, tag=tag, guest_tool=root/'seamless-guest',
                      stage=lambda path: '/mock/guest', request=request,
                      subprocess=types.SimpleNamespace(run=run),
                      time=types.SimpleNamespace(monotonic=lambda: clock[0], sleep=lambda value: clock.__setitem__(0, clock[0]+value)))
            console = io.StringIO()
            with contextlib.redirect_stdout(console):
                try:
                    ns['fps']()
                except SystemExit as error:
                    if case == 'cancel-meter':
                        assert error.code == 130
                    elif case == 'ambiguous-request':
                        assert error.code == 'Timed out waiting for state'
                    else:
                        assert error.code == 1 and case not in ('pass', 'empty-titles', 'multiple-vm-windows', 'wrong-vm-title')
                except KeyboardInterrupt:
                    assert case == 'interrupt-meter'
                else:
                    assert case in ('pass', 'empty-titles', 'multiple-vm-windows', 'wrong-vm-title')
            evidence = json.loads((root/'fixture-fps.json').read_text())
            assert evidence['qualification'] == 'FPS regression guard'
            assert evidence['thresholds'] == dict(minimum_presented_fps=55, minimum_windowed_ratio=0.9,
                                                  minimum_meter_reads_per_second=60)
            assert evidence['cpu_exclusions'] == ['WindowServer', 'meter', 'processes outside this clone']
            assert 'does not qualify the strict 60fps or CPU' in evidence['note']
            if case not in ('cancel-meter', 'interrupt-meter', 'ambiguous-request'):
                assert f'{evidence["result"]} FPS regression guard;' in console.getvalue()
            assert evidence['result'] == ('PASS' if case in ('pass', 'empty-titles', 'multiple-vm-windows', 'wrong-vm-title') else 'FAIL' if case == 'slow' else 'INCONCLUSIVE')
            if case in ('cancel-meter', 'interrupt-meter'):
                assert cancelled_at == [len(calls)] and not evidence['restored']
                assert 'restoration_skipped' in evidence
            elif case == 'ambiguous-request':
                assert len(calls) == 3 and not evidence['restored']
            else:
                assert not active[0]
            if case == 'guest-ambiguous':
                assert not any(item.get('Action') == 'seamless-toggle' or item.get('Arguments') == ['gpu', '--rows'] for item in calls)
                assert not evidence['states'] and 'No Seamless activation' in evidence['restoration_skipped']
            if case in ('pass', 'empty-titles', 'multiple-vm-windows', 'wrong-vm-title'):
                assert evidence['guest_fixture']['id'] == '43' and evidence['guest_fixture']['title'] == 'Seamless page'
                if case == 'empty-titles':
                    assert all('title withheld' in item['provenance'] for item in evidence['window_selections'] if item['kind'] == 'Safari proxy')
                for item in evidence['window_selections']:
                    if item['kind'] == 'VM':
                        assert item['host_window_id'] == 100 and item['window']['pid'] == 10
                        assert item['provenance'] == 'app-reported HostWindowID and exact owned VM PID'
                assert evidence['owned_cpu_ratio'] == 1 and evidence['restored']
                assert len(evidence['samples']) == 2
                assert (root/'fixture-fps-windowed.meter.txt').exists()
                assert (root/'fixture-fps-seamless.meter.txt').exists()
    print('PASS FPS gates, exact clone process scope, same-VM lifecycle, restoration and ambiguous-timeout handling')


if __name__ == '__main__':
    main()
