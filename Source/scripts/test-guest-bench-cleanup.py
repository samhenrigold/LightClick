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
lookup = Mock(return_value='original')
runner = Mock()
namespace = {'subprocess': SimpleNamespace(run=runner, TimeoutExpired=subprocess.TimeoutExpired),
             'time': clock, 'signal': signal, 'os': SimpleNamespace(kill=lambda *args: signals.append(args)),
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
runner.return_value = SimpleNamespace(returncode=0, stdout='42 /other/app\n', stderr='')
assert stop(Mock(), work) is None
assert not signals

# A candidate PID reused between discovery and signaling must not be killed.
runner.side_effect = [SimpleNamespace(returncode=0, stdout='42 /clone-test/app\n', stderr=''),
                      SimpleNamespace(returncode=0, stdout='42 /other/app\n', stderr='')]
lookup.side_effect = ['original', 'replacement']
assert stop(Mock(), work) is None
assert not signals
print('PASS guest-bench cleanup: inspection errors, timeout, exclusion and PID reuse')
