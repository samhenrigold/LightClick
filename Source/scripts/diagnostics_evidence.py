"""Bounded, passive retention of one harness-owned diagnostics channel at timeout."""
import json
import os
from pathlib import Path
import stat
import time
import uuid


LIMITS = {'Request.json': 65536, 'Running.json': 65536, 'Result.json': 1048576}


def retain_timeout(channel, bench, tag, *, app_pid, timeout):
    """Copy fixed channel files only. Never issue commands or follow source links.

    The caller must catch retention failures and preserve its original timeout/cleanup behavior.
    A snapshot is sequential: a rename during copying can legitimately leave two or no request names.
    """
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
    directory = os.open(channel, flags | os.O_DIRECTORY)
    try:
        info = os.fstat(directory)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
            raise ValueError('diagnostics channel is not a private current-user directory')
        # Tags are already used as harness paths, but this helper accepts a basename only.
        if not tag or Path(tag).name != tag or tag in ('.', '..'):
            raise ValueError('evidence tag must be a basename')
        destination = Path(bench) / (tag + '.diagnostics-timeout-' + uuid.uuid4().hex)
        destination.mkdir(mode=0o700)
        manifest = {
            'schema': 1, 'observed_monotonic_seconds': time.monotonic(),
            'app_pid': app_pid, 'request_timeout_seconds': timeout,
            'session_busy_flags': {'available': False},
            'note': 'Sequential passive snapshot, not atomic. Running is not completion proof; absent files do not prove guest liveness.',
            'files': {},
        }
        for name, cap in LIMITS.items():
            entry = {'limit_bytes': cap, 'observed_monotonic_seconds': time.monotonic()}
            manifest['files'][name] = entry
            fd = None
            try:
                fd = os.open(name, flags, dir_fd=directory)
                before = os.fstat(fd)
                if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or before.st_nlink != 1:
                    entry['status'] = 'rejected_nonregular_foreign_or_linked'
                    continue
                # Read one byte past the cap to distinguish an exact-size file from a truncated prefix.
                chunks, remaining = [], cap + 1
                while remaining:
                    chunk = os.read(fd, remaining)
                    if not chunk:
                        break
                    chunks.append(chunk)
                    remaining -= len(chunk)
                data = b''.join(chunks)
                after = os.fstat(fd)
                entry.update(status='retained', source_size_bytes=before.st_size,
                             source_inode=before.st_ino, source_mtime_ns=before.st_mtime_ns,
                             retained_bytes=min(len(data), cap), truncated=len(data) > cap or before.st_size > cap,
                             changed_during_read=(before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns))
                out = os.open(destination / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                with os.fdopen(out, 'wb') as stream:
                    stream.write(data[:cap])
            except FileNotFoundError:
                entry['status'] = 'missing'
            except OSError as error:
                entry.update(status='read_or_copy_error', errno=error.errno)
            finally:
                if fd is not None:
                    os.close(fd)
        output = os.open(destination / 'manifest.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(output, 'w') as stream:
            json.dump(manifest, stream, indent=2)
            stream.write('\n')
        return destination
    finally:
        os.close(directory)
