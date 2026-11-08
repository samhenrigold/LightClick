"""Preserve clone QEMU capabilities when adding sampling permissions."""
import os
from pathlib import Path
import plistlib
import subprocess

MAX_ENTITLEMENT_BYTES = 1024 * 1024
SAMPLING_KEYS = ('com.apple.security.cs.allow-jit',
                 'com.apple.security.cs.disable-library-validation',
                 'com.apple.security.get-task-allow')


def sampling_plist(original):
    """Merge only requested sampling keys; never infer other capabilities."""
    if not isinstance(original, bytes) or not original or len(original) > MAX_ENTITLEMENT_BYTES:
        raise ValueError('Original entitlement plist is missing or oversized')
    try:
        values = plistlib.loads(original)
    except Exception as error:
        raise ValueError('Original entitlements are not a valid plist') from error
    if not isinstance(values, dict) or any(not isinstance(key, str) or not key for key in values):
        raise ValueError('Original entitlement plist must be a dictionary with nonempty string keys')
    merged = dict(values)
    for key in SAMPLING_KEYS:
        merged[key] = True
    return plistlib.dumps(merged, fmt=plistlib.FMT_XML, sort_keys=True)


def prepare_sampling_entitlements(binary, destination):
    # :- requests XML rather than the human-readable display used by '-'.
    # Failure/invalid output must stop sampling before any re-sign operation.
    result = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(binary)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, timeout=10)
    data = sampling_plist(result.stdout)
    fd = os.open(Path(destination), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(data)
