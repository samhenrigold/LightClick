#!/usr/bin/env python3
"""No VM: failed inspection cannot count as successful clone cleanup."""
import ast
from pathlib import Path
import signal
import subprocess
from types import SimpleNamespace
from unittest.mock import Mock

source = Path(__file__).with_name('guest-bench')
tree = ast.parse(source.read_text())
function = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'stop_test_processes')
clock = Mock()
clock.monotonic.return_value = 0
signals = []
lookup = Mock(return_value='Fri Nov 7 12:00:00 2026')
runner = Mock()
namespace = {'subprocess': SimpleNamespace(run=runner, TimeoutExpired=subprocess.TimeoutExpired),
             'time': clock, 'signal': signal, 'os': SimpleNamespace(environ={'TZ': 'America/New_York', 'KEEP': 'inherited'},
                                               kill=lambda *args: signals.append(args)),
             'process_identity': lookup}
exec(compile(ast.Module(body=[function], type_ignores=[]), str(source), 'exec'), namespace)
stop = namespace['stop_test_processes']
work = Path('/clone-test')

for result in (SimpleNamespace(returncode=1, stdout='', stderr='denied'),
               SimpleNamespace(returncode=0, stdout='', stderr=''),
               SimpleNamespace(returncode=0, stdout='malformed', stderr='')):
    runner.return_value = result
    assert stop(Mock(), work), 'unknown process state was accepted as clean'
    assert not signals

runner.side_effect = subprocess.TimeoutExpired('ps', 5)
assert stop(Mock(), work), 'inspection timeout was accepted as clean'
runner.side_effect = None
runner.return_value = SimpleNamespace(returncode=0, stdout='42 S Fri Nov 7 12:00:00 2026 /other/app\n', stderr='')
assert stop(Mock(), work) is None
assert not signals

# A PID reused before the first identity lookup must not be signaled: the discovery snapshot owns the birth time.
runner.side_effect = [SimpleNamespace(returncode=0, stdout='42 S Fri Nov 7 12:00:00 2026 /clone-test/app\n', stderr=''),
                      SimpleNamespace(returncode=0, stdout='42 S Fri Nov 7 12:00:00 2026 /other/app\n', stderr='')]
lookup.side_effect = ['Fri Nov 7 12:00:01 2026']
assert stop(Mock(), work) is None
assert not signals
# Discovery and recheck must use the same time zone even when the host's local zone differs.
lookup.side_effect = None
lookup.return_value = 'Fri Nov 7 17:00:00 2026'
observations = [0]
def zoned_snapshot(*args, **kwargs):
    observations[0] += 1
    if observations[0] > 1:
        text = '42 S Fri Nov 7 17:00:00 2026 /other/app\n'
    else:
        birth = '17:00:00' if kwargs.get('env', {}).get('TZ') == 'UTC' else '12:00:00'
        text = '42 S Fri Nov 7 %s 2026 /clone-test/app\n' % birth
    return SimpleNamespace(returncode=0, stdout=text, stderr='')
runner.side_effect = zoned_snapshot
assert stop(Mock(), work) is None
assert signals == [(42, signal.SIGTERM)], 'a local-time snapshot did not match the UTC identity recheck'
for call in runner.call_args_list:
    assert call.kwargs['env']['TZ'] == 'UTC'
    assert call.kwargs['env']['KEEP'] == 'inherited'
print('PASS guest-bench cleanup: inspection errors, timeout, exclusion, PID reuse and UTC birth snapshots')
