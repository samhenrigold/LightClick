#!/usr/bin/env python3
"""Local files/mocks only: timeout evidence cannot issue guest requests or prevent cleanup."""
import ast
from contextlib import redirect_stderr
import io
import json
import os
from pathlib import Path
import stat
import tempfile
from types import SimpleNamespace
from unittest.mock import Mock, patch

import diagnostics_evidence as evidence


def manifest(path):
    return json.loads((path / 'manifest.json').read_text())


with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    channel = root / 'channel'
    channel.mkdir(mode=0o700)
    bench = root / 'bench'
    bench.mkdir()
    (channel / 'Request.json').write_bytes(b'{malformed-but-preserve-exactly')
    (channel / 'Result.json').write_bytes(b'x' * (evidence.LIMITS['Result.json'] + 7))
    output = evidence.retain_timeout(channel, bench, 'test', app_pid=123, timeout=30)
    data = manifest(output)
    assert (output / 'Request.json').read_bytes() == b'{malformed-but-preserve-exactly'
    assert data['files']['Running.json']['status'] == 'missing'
    assert data['files']['Result.json']['truncated'] is True
    assert (output / 'Result.json').stat().st_size == evidence.LIMITS['Result.json']
    assert data['session_busy_flags'] == {'available': False}
    assert stat.S_IMODE(output.stat().st_mode) == 0o700
    assert all(stat.S_IMODE(p.stat().st_mode) == 0o600 for p in output.iterdir())
    # Fixed names only; symlinks and FIFOs cannot block or export their targets.
    (channel / 'Result.json').unlink()
    (channel / 'Request.json').unlink()
    secret = root / 'not-channel-data'
    secret.write_bytes(b'do not read')
    (channel / 'Request.json').symlink_to(secret)
    os.mkfifo(channel / 'Running.json')
    output = evidence.retain_timeout(channel, bench, 'links', app_pid=123, timeout=30)
    data = manifest(output)
    assert data['files']['Request.json']['status'] == 'read_or_copy_error'
    assert data['files']['Running.json']['status'] == 'rejected_nonregular_foreign_or_linked'
    assert list(output.iterdir()) == [output / 'manifest.json']
    linked_channel = root / 'channel-link'
    linked_channel.symlink_to(channel)
    try:
        evidence.retain_timeout(linked_channel, bench, 'bad', app_pid=123, timeout=30)
        raise AssertionError('directory symlink accepted')
    except OSError:
        pass
    channel.chmod(0o755)
    try:
        evidence.retain_timeout(channel, bench, 'bad', app_pid=123, timeout=30)
        raise AssertionError('nonprivate channel accepted')
    except ValueError:
        pass
    channel.chmod(0o700)
    # A file disappearing between open and read is recorded as an error, not a thrown cleanup blocker.
    (channel / 'Result.json').write_bytes(b'{}')
    with patch.object(evidence.os, 'read', side_effect=OSError(5, 'injected read failure')):
        output = evidence.retain_timeout(channel, bench, 'read-error', app_pid=123, timeout=30)
    assert manifest(output)['files']['Result.json']['status'] == 'read_or_copy_error'
    # A rename after open retains that descriptor's original bytes, without following the replacement symlink.
    (channel / 'Result.json').unlink()
    (channel / 'Running.json').unlink()
    (channel / 'Request.json').unlink()
    (channel / 'Request.json').write_bytes(b'old request')
    real_read = os.read
    def rename_on_read(fd, count):
        old = channel / 'old-request'
        if not old.exists():
            (channel / 'Request.json').rename(old)
            (channel / 'Request.json').symlink_to(secret)
        return real_read(fd, count)
    with patch.object(evidence.os, 'read', side_effect=rename_on_read):
        output = evidence.retain_timeout(channel, bench, 'rename', app_pid=123, timeout=30)
    assert (output / 'Request.json').read_bytes() == b'old request'
    assert not (output / 'old-request').exists()

    # Execute the real request() definition with its loop deadline already reached, never launch any process.
    script = Path(__file__).with_name('guest-bench')
    tree = ast.parse(script.read_text())
    function = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'request')
    for failure in (None, OSError('injected retention failure')):
        clock = Mock()
        clock.time.side_effect = [0, 31]
        retain = Mock(return_value=output, side_effect=failure)
        namespace = dict(channel=channel, source=root, args=SimpleNamespace(tag='test'),
                         process=SimpleNamespace(pid=123), json=json, time=clock,
                         retain_timeout=retain, sys=SimpleNamespace(stderr=io.StringIO()))
        exec(compile(ast.Module(body=[function], type_ignores=[]), str(script), 'exec'), namespace)
        cleaned = False
        try:
            try:
                namespace['request']({'Executable': '/bin/test', 'Arguments': ['-f', '/System/example']}, 30)
                raise AssertionError('original timeout lost')
            finally:
                cleaned = True
        except SystemExit as error:
            assert str(error).startswith('Timed out waiting for ')
        assert cleaned and retain.call_count == 1
        assert clock.sleep.call_count == 0
print('PASS: bounded private timeout snapshots, missing/oversize/link/FIFO/read/rename cases, original timeout and cleanup')
