#!/usr/bin/env python3
"""Exercise the period-Python probe's timeout helper without Quartz, applications, or a VM."""
import contextlib
import io
from pathlib import Path
import sys
import time
from unittest.mock import patch

script = (Path(__file__).parents[1]/'probes/app-launch.sh').read_text().split("<<'EOF'\n", 1)[1].split('\nEOF', 1)[0]
script = script.replace('import Quartz', '')
namespace = {}
exec(compile(script.split('\nbad = 0', 1)[0], 'app-launch.py', 'exec'), namespace)
output = io.StringIO()
with contextlib.redirect_stdout(output):
    start = time.monotonic()
    code, text, expired = namespace['command']([sys.executable, '-c', 'import time; time.sleep(30)'], .15, 'stuck quit')
    assert expired and code != 0 and time.monotonic()-start < 2
    code, text, expired = namespace['command']([sys.executable, '-c', 'print("ok")'], 2, 'normal')
    assert (code, text.strip(), expired) == (0, 'ok', False)
    identity = namespace['identity']
    stamp = 'Sat Nov 7 12:34:56 2026'
    for response in ((-9, '', True), (1, 'ps: permission denied', False),
                     (2, '', False), (0, '', False), (0, 'S malformed', False)):
        with patch.dict(namespace, command=lambda *args: response):
            try:
                identity(123)
            except RuntimeError:
                pass
            else:
                raise AssertionError('unknown process identity was mistaken for confirmed exit: %r' % (response,))
    for response, expected in (((1, '', False), None), ((0, 'Z '+stamp, False), None),
                               ((0, 'S '+stamp, False), stamp)):
        with patch.dict(namespace, command=lambda *args: response):
            assert identity(123) == expected
    # A successful AppleEvent cannot turn failed process inspection into a successful quit.
    def unknown(pid):
        raise RuntimeError('identity inspection failed')
    with patch.dict(namespace, command=lambda *args: (0, '', False), identity=unknown):
        with patch('os.kill') as kill:
            try:
                namespace['quit_app']('fixture', {123: stamp})
            except RuntimeError:
                pass
            else:
                raise AssertionError('quit passed without proving that its owned process exited')
            kill.assert_not_called()
    # A timed-out AppleEvent is failure even if the app happened to exit meanwhile.
    with patch.dict(namespace, command=lambda *args: (-9, '', True), identity=lambda pid: None):
        assert namespace['quit_app']('fixture', {123: 'original-start'}) is False
    # Never signal a PID whose start identity changed since the probe launched it.
    with patch.dict(namespace, command=lambda *args: (0, '', False), identity=lambda pid: 'different-start'):
        with patch('os.kill') as kill:
            assert namespace['quit_app']('fixture', {123: 'original-start'}) is True
            kill.assert_not_called()
assert 'TIMEOUT stuck quit' in output.getvalue() and 'STEP normal exit=0' in output.getvalue()
print('PASS app launch: bounded child, normal completion, quit timeout, inspection errors and PID-reuse safety')
