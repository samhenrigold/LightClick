#!/usr/bin/env python3
"""No VM: lock exclusion, abrupt owner death, detached lifetime and refusal of an existing VM."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
from unittest.mock import patch

from clone_lease import CloneLease, LeaseRefused
import clone_lease


def refused(lease):
    try:
        lease.acquire()
    except LeaseRefused:
        return
    lease.close()
    raise AssertionError('a second owner acquired the clone lease')


with tempfile.TemporaryDirectory(prefix='lightclick-lease-test-') as temporary:
    path = Path(temporary)/'lease'
    with CloneLease(path, check_running=False):
        refused(CloneLease(path, check_running=False))
    with CloneLease(path, check_running=False):
        pass

    ready, reply = os.pipe()
    owner = os.fork()
    if owner == 0:
        os.close(ready)
        with CloneLease(path, check_running=False):
            os.write(reply, b'held')
            time.sleep(30)
        os._exit(0)
    os.close(reply)
    assert os.read(ready, 4) == b'held'
    os.close(ready)
    refused(CloneLease(path, check_running=False))
    os.kill(owner, signal.SIGKILL)
    os.waitpid(owner, 0)
    with CloneLease(path, check_running=False):
        pass

    with patch('clone_lease.subprocess.run', return_value=subprocess.CompletedProcess([], 0, '123\n', '')):
        refused(CloneLease(path))
    # A refusal must close its descriptor rather than retaining the lock.
    with CloneLease(path, check_running=False):
        pass
    with patch('clone_lease.subprocess.run', return_value=subprocess.CompletedProcess([], 2, '', 'denied')):
        refused(CloneLease(path))

    with patch('clone_lease.subprocess.run', return_value=subprocess.CompletedProcess([], 1, '', 'permission denied')):
        try:
            clone_lease.process_identity(123)
        except LeaseRefused:
            pass
        else:
            raise AssertionError('an inspection failure was mistaken for process death')
    child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
    with patch('clone_lease.process_identity', side_effect=LeaseRefused('ps unavailable')):
        clone_lease.stop_owned(child, {child.pid: 'unknown'})
    assert child.poll() is not None

    # Exercise the actual guardian with a sleeping Python process standing in for its owned app. No app or QEMU runs.
    constructor = CloneLease
    def fake_launch(source, arguments):
        child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
        return child, {child.pid: str(child.pid)}, str(child.pid), Path('Clone of fixture')
    inspections = [0]
    def identity(pid):
        inspections[0] += 1
        if inspections[0] == 1:
            raise LeaseRefused('temporary ps failure')
        try:
            os.kill(pid, 0)
            return str(pid)
        except ProcessLookupError:
            return None
    ready, reply = os.pipe()
    owner = os.fork()
    if owner == 0:
        os.close(ready)
        clone_lease.CloneLease = lambda: constructor(path, check_running=False)
        clone_lease.launch_clone = fake_launch
        clone_lease.process_identity = identity
        os._exit(clone_lease.guardian(reply, Path(temporary), []))
    os.close(reply)
    with os.fdopen(ready) as response:
        message = json.loads(response.readline())
    child = int(message['line'])
    refused(CloneLease(path, check_running=False))
    os.kill(child, signal.SIGTERM)  # This exact child was started by this test.
    deadline = time.monotonic()+5
    while time.monotonic() < deadline:
        finished, status = os.waitpid(owner, os.WNOHANG)
        if finished:
            assert os.waitstatus_to_exitcode(status) == 0
            break
        time.sleep(0.05)
    else:
        os.kill(owner, signal.SIGKILL)
        os.waitpid(owner, 0)
        raise AssertionError('guardian retained the lease after its owned child exited')
    with CloneLease(path, check_running=False):
        pass

print('PASS clone lease: exclusion, owner death, detached lifetime and existing-VM refusal')
