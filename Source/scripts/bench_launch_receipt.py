"""Retain the exact files prepared for a disposable benchmark launch."""
import hashlib
import json
import os
from pathlib import Path
import stat


def fingerprint(path):
    path = Path(path).resolve(strict=True)
    def identity(info):
        return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
    digest = hashlib.sha256()
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode):
            raise ValueError(f'Launch input is not a regular file: {path}')
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
        if identity(before) != identity(os.fstat(stream.fileno())):
            raise ValueError(f'Launch input changed during hashing: {path}')
    if identity(before) != identity(path.stat()):
        raise ValueError(f'Launch input was replaced during hashing: {path}')
    return {'path': str(path), 'bytes': before.st_size, 'sha256': digest.hexdigest()}


def write_launch_receipt(output, source_app, source_machine, clone_app, clone_machine, driver=None):
    clone_app, clone_machine = Path(clone_app), Path(clone_machine)
    record = {
        'version': 1,
        'scope': 'Files prepared immediately before Popen; not runtime image or workload qualification',
        'source_app': str(Path(source_app).resolve(strict=True)),
        'source_machine': str(Path(source_machine).resolve(strict=True)),
        'cloned_app_main': fingerprint(clone_app/'Contents/MacOS/Light Click'),
        'cloned_qemu_real': fingerprint(clone_app/'Contents/Resources/Runtime/bin/qemu-system-x86_64.real'),
        'cloned_qemu_wrapper': fingerprint(clone_app/'Contents/Resources/Runtime/bin/qemu-system-x86_64'),
        'cloned_machine_plist': fingerprint(clone_machine/'Machine.plist'),
        'driver': fingerprint(driver) if driver is not None else None,
    }
    with Path(output).open('w') as stream:
        json.dump(record, stream, indent=2)
        stream.write('\n')
    return record


def read_recorded_driver(path, recorded):
    """Compile these same bytes later, rather than reopening a mutable script."""
    data = Path(path).read_bytes()
    if len(data) != recorded['bytes'] or hashlib.sha256(data).hexdigest() != recorded['sha256']:
        raise ValueError('Benchmark driver changed after launch preparation')
    return data
