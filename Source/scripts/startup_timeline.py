"""Optional passive clone-startup observations; never sends guest commands or signals."""
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import threading
import time


class StartupTimeline:
    def __init__(self, path, clock=time.monotonic):
        self.clock = clock
        self.started = clock()
        self.file = Path(path).open('w')
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.worker = None
        self.seen = set()
        self.record('timeline_started', observation_interval_seconds=0.5)

    def record(self, phase, **details):
        with self.lock:
            if not self.file.closed:
                self.file.write(json.dumps(dict(phase=phase, elapsed_seconds=self.clock()-self.started,
                                               **details))+'\n')
                self.file.flush()

    def observe(self, machine, channel, app_pid, qemu_path, snapshot=None):
        if 'diagnostics_channel' not in self.seen and channel.is_dir():
            self.seen.add('diagnostics_channel')
            self.record('diagnostics_channel')
        if 'desktop_running' not in self.seen:
            try:
                with (machine/'State/GuestStatus.plist').open('rb') as file:
                    status = plistlib.load(file)
                desktop = status.get('Report', {}).get('DesktopRunning')
                # The host's JSONValue -> NSNumber -> plist path persists this flag as integer 1.
                if desktop is True or (type(desktop) is int and desktop == 1):
                    self.seen.add('desktop_running')
                    self.record('desktop_running', source='fresh GuestStatus.plist')
            except (OSError, ValueError, TypeError, AttributeError, plistlib.InvalidFileException):
                pass
        if 'qemu_child' not in self.seen:
            try:
                if snapshot is None:
                    result = subprocess.run(['ps', '-axo', 'pid=,ppid=,command='], capture_output=True,
                                            text=True, timeout=1)
                    if result.returncode:
                        return
                    snapshot = result.stdout
                for row in snapshot.splitlines():
                    fields = row.strip().split(None, 2)
                    if len(fields) == 3 and int(fields[1]) == app_pid and fields[2].startswith(str(qemu_path)+' '):
                        self.seen.add('qemu_child')
                        self.record('qemu_child', pid=int(fields[0]), parent_pid=app_pid)
                        break
            except (OSError, ValueError, subprocess.TimeoutExpired):
                pass

    def start(self, machine, channel, app_pid, qemu_path):
        def monitor():
            while not self.stop.is_set():
                self.observe(machine, channel, app_pid, qemu_path)
                self.stop.wait(0.5)
        self.worker = threading.Thread(target=monitor, name='startup-timeline', daemon=True)
        self.worker.start()

    def close(self):
        self.stop.set()
        if self.worker is not None:
            self.worker.join(timeout=3)
        with self.lock:
            self.file.close()


def preserve_startup_logs(work, destination, tag, temporary, identifier, fresh_identifier, machine=None):
    """Copy only this clone's app log and logs named with its newly assigned identifier."""
    copied = []
    app_log = work/'app.log'
    if app_log.is_file() and not app_log.is_symlink():
        target = destination/f'{tag}.app.log'
        shutil.copyfile(app_log, target)
        copied.append(str(target))
    if machine is not None:
        status = machine/'State/GuestStatus.plist'
        if status.is_file() and not status.is_symlink():
            target = destination/f'{tag}.GuestStatus.plist'
            shutil.copyfile(status, target)
            copied.append(str(target))
    if fresh_identifier:
        name = f'lc-seamless-{identifier[:8]}.log'
        for log in [temporary/name, *temporary.glob(name+'.*')]:
            if log.is_file() and not log.is_symlink():
                target = destination/(f'{tag}.prearm.log'+log.name[len(name):])
                shutil.copyfile(log, target)
                copied.append(str(target))
    return copied
