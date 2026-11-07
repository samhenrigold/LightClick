"""Exclusive clone-test ownership shared by worktrees and script entry points."""
import ctypes
import errno
import fcntl
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import struct
import subprocess
import sys
import time


class LeaseRefused(RuntimeError):
    pass


class CloneLease:
    def __init__(self, path=None, check_running=True):
        self.path = Path(path) if path is not None else Path('/tmp')/f'lightclick-clone-{os.getuid()}.lock'
        self.check_running = check_running
        self.fd = None

    def acquire(self):
        if self.fd is not None:
            raise RuntimeError('This lease is already acquired')
        fd = os.open(self.path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                raise LeaseRefused('clone lease is not a regular file owned by this user')
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as error:
                if error.errno in (errno.EACCES, errno.EAGAIN):
                    raise LeaseRefused('another clone test owns the global lease') from error
                raise
            if self.check_running:
                # macOS pgrep matches the process name rather than argv; cover the wrapper's real binary too.
                for name in ('qemu-system-x86_64', 'qemu-system-x86_64.real', 'qemu-system-x86'):
                    found = subprocess.run(['pgrep', '-x', name], capture_output=True, text=True, timeout=5)
                    if found.returncode == 0:
                        raise LeaseRefused('a VM is already running; leave it alone and retry after it closes')
                    if found.returncode != 1:
                        raise LeaseRefused(f'could not check for running VMs: {found.stderr.strip()}')
            os.ftruncate(fd, 0)
            os.write(fd, f'owner pid {os.getpid()}\n'.encode())
            self.fd = fd
            return self
        except BaseException:
            os.close(fd)
            raise

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None
        # Never unlink the pathname: a waiter may have opened this same inode.

    release = close

    def __enter__(self):
        return self.acquire()

    def __exit__(self, *unused):
        self.close()


def process_identity(pid):
    result = subprocess.run(['ps', '-p', str(pid), '-o', 'stat=,lstart='], capture_output=True,
                            text=True, timeout=5, env={**os.environ, 'TZ': 'UTC'})
    if result.returncode == 1 and not result.stdout.strip() and not result.stderr.strip():
        return None  # ps found no such PID.
    if result.returncode != 0 or result.stderr.strip():
        raise LeaseRefused('could not verify an owned process identity: '+result.stderr.strip())
    fields = result.stdout.strip().split(None, 1)
    if len(fields) != 2:
        raise LeaseRefused('ps returned an incomplete owned process identity')
    return None if fields[0].startswith('Z') else fields[1]


def save_launch(pid, path):
    size = ctypes.c_size_t(1 << 20)
    buffer = ctypes.create_string_buffer(size.value)
    if ctypes.CDLL(None).sysctl((ctypes.c_int * 3)(1, 49, pid), 3, buffer, ctypes.byref(size), None, 0):
        raise OSError('could not read the test QEMU arguments')
    data = buffer.raw[:size.value]
    argc = struct.unpack('i', data[:4])[0]
    start = data.index(b'\0', 4)
    while data[start] == 0:
        start += 1
    parts = data[start:].split(b'\0')
    env = dict(p.decode(errors='replace').split('=', 1) for p in parts[argc:] if b'=' in p)
    path.write_text(json.dumps({'args': [p.decode(errors='replace') for p in parts[:argc]], 'env': env},
                              indent=1, sort_keys=True))


def launch_clone(source, arguments):
    if len(arguments) < 2:
        raise LeaseRefused('usage: boot-clone <app> <machine> [work directory [app arguments...]]')
    app, machine = (Path(p).expanduser().resolve() for p in arguments[:2])
    work = Path(arguments[2]).expanduser().resolve() if len(arguments) > 2 else source/'Build/clone'
    if not (machine/'Machine.plist').is_file() or not (app/'Contents/MacOS/Light Click').is_file():
        raise LeaseRefused('the app or source machine is missing')
    if machine == work or machine.is_relative_to(work) or work.is_relative_to(machine) or app.is_relative_to(work):
        raise LeaseRefused('the clone work directory overlaps the source machine or app')
    if work.exists():
        shutil.rmtree(work)
    library = work/'home/Library/Application Support/Light Click'
    (library/'Machines').mkdir(parents=True)
    (library/'Downloads').mkdir()
    (library/'Installers').mkdir()
    clone = library/'Machines'/f'Clone of {machine.name}'
    subprocess.run(['cp', '-c', '-R', str(machine), str(clone)], check=True, timeout=120)
    (clone/'State/PendingConfiguration.plist').unlink(missing_ok=True)
    with (work/'app.log').open('w') as log:
        process = subprocess.Popen([str(app/'Contents/MacOS/Light Click'), '--open-vm', str(clone),
                                    *arguments[3:]], stdout=log, stderr=subprocess.STDOUT,
                                   env={**os.environ, 'CFFIXED_USER_HOME': str(work/'home')})
    identities = {}
    try:
        identity = process_identity(process.pid)
        if identity:
            identities[process.pid] = identity
        deadline = time.monotonic()+60
        qemu = None
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError(f'the app exited; see {work}/app.log')
            found = subprocess.run(['pgrep', '-P', str(process.pid), '-x', 'qemu-system-x86_64'],
                                   capture_output=True, text=True, timeout=5)
            if found.returncode == 0:
                qemu = int(found.stdout.split()[0])
                break
            if found.returncode != 1:
                raise RuntimeError('could not check for the test QEMU child')
            time.sleep(0.5)
        if qemu is None:
            raise RuntimeError(f'no QEMU after a minute; see {work}/app.log')
        identity = process_identity(qemu)
        if not identity:
            raise RuntimeError('QEMU exited before its arguments could be saved')
        identities[qemu] = identity
        time.sleep(1)
        save_launch(qemu, work/'launch.json')
        return process, identities, f'app {process.pid} qemu {qemu} log "{clone}/State/session.log"', clone
    except BaseException:
        stop_owned(process, identities)
        raise


def stop_owned(process, identities):
    for number in (signal.SIGTERM, signal.SIGKILL):
        # A direct, unreaped Popen child remains ours even when ps is unavailable.
        if process.poll() is None:
            process.send_signal(number)
        for pid, identity in identities.items():
            if pid == process.pid:
                continue
            try:
                still_ours = process_identity(pid) == identity
            except (LeaseRefused, OSError, subprocess.TimeoutExpired):
                continue  # Never signal an unverified descendant PID.
            if still_ours:
                try:
                    os.kill(pid, number)
                except ProcessLookupError:
                    pass
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            pass


def guardian(reply, source, arguments):
    process = None
    identities = {}
    try:
        with CloneLease():
            process, identities, line, clone = launch_clone(source, arguments)
            message = {'line': line, 'warning': f'The window titled "{clone.stem}" is a throwaway clone. Anything changed in it is lost.'}
            os.write(reply, (json.dumps(message)+'\n').encode())
            os.close(reply)
            reply = None
            # The short launcher returns, but this process holds the lease until BOTH app and QEMU have gone.
            while True:
                process.poll()  # Reap our direct child, including zombies.
                try:
                    alive = any(process_identity(pid) == identity for pid, identity in identities.items())
                except (LeaseRefused, OSError, subprocess.TimeoutExpired):
                    # An inspection failure is not proof of death. Keep the lease until inspection works again.
                    time.sleep(1)
                    continue
                if not alive:
                    break
                time.sleep(1)
    except BaseException as error:
        if process is not None:
            stop_owned(process, identities)
        if reply is not None:
            try:
                os.write(reply, (json.dumps({'error': str(error)})+'\n').encode())
            except OSError:
                pass
        return 3
    return 0


def detached_clone(source, arguments):
    read_fd, write_fd = os.pipe()
    worker = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), '--guardian', str(write_fd),
                               str(source), *arguments], pass_fds=(write_fd,), start_new_session=True,
                              stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.close(write_fd)
    with os.fdopen(read_fd) as response:
        line = response.readline()
    if not line:
        worker.wait()
        print('REFUSED: clone lease guardian exited before reporting readiness', file=sys.stderr)
        return 3
    result = json.loads(line)
    if 'error' in result:
        worker.wait()
        print('REFUSED: '+result['error'], file=sys.stderr)
        return 3
    print('WARNING: '+result['warning'], file=sys.stderr)
    print(result['line'])
    return 0


if __name__ == '__main__':
    if len(sys.argv) > 3 and sys.argv[1] == '--guardian':
        sys.exit(guardian(int(sys.argv[2]), Path(sys.argv[3]), sys.argv[4:]))
    if len(sys.argv) < 2:
        sys.exit('usage: clone_lease.py SOURCE <app> <machine> [work [arguments...]]')
    sys.exit(detached_clone(Path(sys.argv[1]), sys.argv[2:]))
