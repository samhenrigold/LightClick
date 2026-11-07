"""Executed only by guest-bench; it supplies arguments, request(), stage(), source and tag.

The two export selectors are fixed here: Apple's OS image and the first raw output of this staged probe. No generic
guest file fetch exists. Socket transfers and verification happen outside every reported decode timing.
"""
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import socket
import struct
import subprocess
import threading
import time

OS_IMAGE = '/Library/Desktop Pictures/Mojave.heic'
CAP = 512 * 1024 * 1024
OUTPUT_CAP = 256 * 1024 * 1024
TRANSFER_SECONDS = 180
PREFLIGHT_SECONDS = 180
# Exact acknowledged errors from QMPError.timedOut and GuestAgentError startup states.
PREFLIGHT_TRANSIENT_ERRORS = (
    'The control response timed out.',
    'The virtual Mac’s guest tools are not connected.',
    'Wait for this virtual Mac’s current operation to finish, then try again.',
)

# Python 2.7 in Mojave. Header: random 16-byte nonce, big-endian uint64 byte count, raw SHA256 digest.
SENDER = r'''import binascii, hashlib, os, re, signal, socket, stat, struct, sys
signal.alarm(180)
def export_file(selector, directory):
    if not re.match(r'\A/private/var/tmp/VirtualIntelMac\.[A-Za-z0-9]{6}\Z', directory):
        raise ValueError('invalid guest staging directory')
    parent = os.lstat(directory)
    if os.path.realpath(directory) != directory or not stat.S_ISDIR(parent.st_mode) or parent.st_uid != 0 or parent.st_mode & 0o077:
        raise ValueError('staging must be a canonical root-owned private directory')
    paths = {'encoded': '/Library/Desktop Pictures/Mojave.heic', 'pixels': directory + '/first-image.rgba'}
    if selector not in paths: raise ValueError('unknown export selector')
    path = paths[selector]
    if os.path.realpath(path) != path: raise ValueError('export symlink or parent escape refused')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        size = os.fstat(fd)
        if not stat.S_ISREG(size.st_mode) or size.st_uid != 0 or not 0 < size.st_size <= 512 * 1024 * 1024:
            raise ValueError('export requires a root-owned regular file of at most 512 MiB')
        if selector == 'pixels' and size.st_nlink != 1: raise ValueError('raw output must have one link')
    except:
        os.close(fd)
        raise
    return fd, size.st_size
selector, directory, port, token = sys.argv[1:]
fd, size = export_file(selector, directory)
with os.fdopen(fd, 'rb') as f:
    h = hashlib.sha256()
    for data in iter(lambda: f.read(1024 * 1024), ''): h.update(data)
    f.seek(0)
    s = socket.create_connection(('10.0.2.2', int(port)), 30)
    s.settimeout(30)
    s.sendall(binascii.unhexlify(token) + struct.pack('>Q', size) + h.digest())
    for data in iter(lambda: f.read(1024 * 1024), ''): s.sendall(data)
    s.shutdown(socket.SHUT_WR)
    if s.recv(1) != '1': sys.exit('host did not verify export')
    s.close()
print('exported %s %d %s' % (selector, size, h.hexdigest()))
'''


def staged_directory(probe):
    match = re.fullmatch(r'(/private/var/tmp/VirtualIntelMac\.[A-Za-z0-9]{6})/Transfer\.bin', probe)
    if not match:
        raise RuntimeError('probe staging receipt is outside the GuestControl private temporary directory contract')
    return match[1]


def export(selector, directory, target):
    if selector not in ('encoded', 'pixels'):
        raise RuntimeError('unknown export selector')
    staged_directory(directory + '/Transfer.bin')
    token = os.urandom(16)
    deadline = time.monotonic() + TRANSFER_SECONDS
    received, active = {}, []

    def receive(listener):
        def take(connection, count):
            parts = []
            while count:
                connection.settimeout(max(0.01, deadline - time.monotonic()))
                data = connection.recv(min(count, 1024 * 1024))
                if not data or time.monotonic() > deadline:
                    raise RuntimeError('export ended early or exceeded its socket deadline')
                parts.append(data)
                count -= len(data)
            return b''.join(parts)

        created = False
        try:
            listener.settimeout(TRANSFER_SECONDS)
            with listener.accept()[0] as connection:
                active.append(connection)
                header = take(connection, 56)
                size = struct.unpack('>Q', header[16:24])[0]
                if not hmac.compare_digest(header[:16], token) or not 0 < size <= CAP:
                    raise RuntimeError('invalid export nonce or byte count')
                digest = hashlib.sha256()
                with target.open('xb') as file:
                    created = True
                    left = size
                    while left:
                        data = take(connection, min(left, 1024 * 1024))
                        file.write(data)
                        digest.update(data)
                        left -= len(data)
                connection.settimeout(max(0.01, deadline - time.monotonic()))
                if connection.recv(1) or not hmac.compare_digest(digest.digest(), header[24:56]):
                    raise RuntimeError('export length or SHA256 mismatch')
                connection.sendall(b'1')
                received.update(size=size, sha256=digest.hexdigest())
        except Exception as error:
            received['error'] = str(error)
            if created:
                target.unlink(missing_ok=True)

    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        listener.listen(1)
        worker = threading.Thread(target=receive, args=(listener,), daemon=True)
        worker.start()
        try:
            result = request({'Executable': '/usr/bin/python',
                              'Arguments': ['-c', SENDER, selector, directory, str(listener.getsockname()[1]), token.hex()]},
                             TRANSFER_SECONDS + 10)
        finally:
            worker.join(timeout=5)
            if worker.is_alive():
                listener.close()
                for connection in active:
                    try:
                        connection.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
                worker.join(timeout=5)
        if worker.is_alive() or 'error' in received or result.get('ExitCode') != 0 or 'sha256' not in received:
            raise RuntimeError(f'{selector} export failed: {received}; guest {result}')
    print(f'exported {selector}: {received["size"]} bytes, SHA256 {received["sha256"]} (outside decode timing)', flush=True)
    return received


def parse_report(text):
    if len(text) > 1024 * 1024:
        raise RuntimeError('probe report exceeded 1 MiB')
    report = json.loads(text)
    if not isinstance(report, dict) or report.get('format_version') != 1 or report.get('mode') != 'full-resolution':
        raise RuntimeError('wrong probe report version or mode')
    sizes = [report.get(key) for key in ('width', 'height', 'row_bytes', 'output_bytes')]
    if any(type(value) is not int or value <= 0 for value in sizes):
        raise RuntimeError('invalid output shape')
    width, height, row, length = sizes
    if row != width * 4 or length != row * height or length > OUTPUT_CAP:
        raise RuntimeError('output shape violates RGBA8 layout or allocation budget')
    for key in ('pixel_sha256', 'input_sha256'):
        if not isinstance(report.get(key), str) or not re.fullmatch('[0-9a-f]{64}', report[key]):
            raise RuntimeError(f'invalid {key}')
    for prefix in ('source', 'output'):
        count, digest = report.get(prefix + '_icc_bytes'), report.get(prefix + '_icc_sha256')
        if (type(count) is not int or count < 0 or count > CAP or
                (count == 0 and digest is not None) or
                (count > 0 and (not isinstance(digest, str) or not re.fullmatch('[0-9a-f]{64}', digest)))):
            raise RuntimeError(f'invalid {prefix} ICC profile report')
    mode = report.get('requested_output_color_space')
    if mode not in ('srgb', 'source'):
        raise RuntimeError('invalid requested output color space')
    if mode == 'srgb' and report.get('output_color_space') != 'kCGColorSpaceSRGB':
        raise RuntimeError('sRGB output has unexpected color space')
    if mode == 'source' and any(report.get('source_' + key) != report.get('output_' + key)
                                for key in ('color_space', 'icc_bytes', 'icc_sha256')):
        raise RuntimeError('source output did not preserve the source color space/profile')
    return report


def compare_bytes(reference, candidate):
    offset = 0
    with reference.open('rb') as a, candidate.open('rb') as b:
        while True:
            left, right = a.read(1024 * 1024), b.read(1024 * 1024)
            if left != right:
                first = next((i for i, pair in enumerate(zip(left, right)) if pair[0] != pair[1]), min(len(left), len(right)))
                raise RuntimeError(f'pixel bytes differ at offset {offset + first}; unexplained mismatch')
            if not left:
                return
            offset += len(left)


def await_fixture(results):
    started = time.monotonic()
    deadline = started + PREFLIGHT_SECONDS
    attempts = []

    def record(attempt):
        attempt['elapsed_seconds'] = time.monotonic() - started
        attempts.append(attempt)
        (results/'preflight-attempts.json').write_text(json.dumps(attempts, indent=2)+'\n')
        print(f'OS fixture preflight attempt {len(attempts)}: {attempt!r}', flush=True)

    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError(f'OS fixture preflight readiness exhausted {PREFLIGHT_SECONDS}s; attempts {attempts!r}')
        attempt = {'request_timeout_seconds': min(30, remaining)}
        try:
            response = request({'Executable': '/bin/test', 'Arguments': ['-f', OS_IMAGE]},
                               attempt['request_timeout_seconds'])
        except (Exception, SystemExit) as error:
            attempt['exception'] = repr(error)
            record(attempt)
            # Host timeouts have no acknowledged reply/request ID: proceeding could consume a stale reply as staging.
            # App exit and cancellation also abort. Only the acknowledged startup errors below may be retried.
            raise
        attempt['response'] = response
        record(attempt)
        if (isinstance(response, dict) and 'ExitCode' not in response
                and response.get('Error') in PREFLIGHT_TRANSIENT_ERRORS):
            time.sleep(min(2, max(0, deadline - time.monotonic())))
            continue
        if (not isinstance(response, dict) or 'Error' in response or type(response.get('ExitCode')) is not int
                or response['ExitCode'] not in (0, 1)):
            raise RuntimeError(f'OS fixture preflight did not execute successfully: response {response!r}')
        if response['ExitCode'] == 1:
            raise RuntimeError(f'required OS fixture is absent or not a regular file: {OS_IMAGE}; response {response!r}')
        return


def experiment():
    if len(arguments) not in (3, 5):
        raise RuntimeError('driver requires results directory, host/guest probe paths and optional color space/trial count')
    output_space, trial_count = arguments[3:] if len(arguments) == 5 else ('srgb', '3')
    if output_space not in ('srgb', 'source') or trial_count not in ('1', '3'):
        raise RuntimeError('driver color space must be srgb/source and trials must be 1/3')
    trial_count = int(trial_count)
    results, host, guest_binary = map(Path, arguments[:3])
    trials = {'guest': [], 'host': []}
    try:
        await_fixture(results)
        guest = stage(guest_binary)
        directory = staged_directory(guest)
        raw = directory + '/first-image.rgba'
        encoded = export('encoded', directory, results/'Mojave.heic')
        guest_raw, host_raw = results/'guest-first.rgba', results/'host-first.rgba'
        for trial in range(trial_count):
            options = ['--full-resolution', OS_IMAGE, '--index', '0', '--timeout', '120',
                       '--max-output-bytes', str(OUTPUT_CAP), '--output-color-space', output_space
                       ] + (['--raw', raw] if trial == 0 else [])
            response = request({'Executable': guest, 'Arguments': options}, 130)
            if response.get('ExitCode') != 0:
                raise RuntimeError(f'guest trial {trial + 1} failed: {response}')
            report = parse_report(response.get('Stdout') or '')
            if report['requested_output_color_space'] != output_space:
                raise RuntimeError('guest did not honor requested output color space')
            trials['guest'].append(report)
            (results/f'guest-{trial + 1}.json').write_text(json.dumps(report, indent=2)+'\n')
            if trial == 0:
                pixels = export('pixels', directory, guest_raw)
                if pixels['size'] != report['output_bytes'] or pixels['sha256'] != report['pixel_sha256']:
                    raise RuntimeError('exported guest pixels do not match their probe report')
            options[1] = str(results/'Mojave.heic')
            if trial == 0:
                options[-1] = str(host_raw)
            response = subprocess.run([str(host), *options], capture_output=True, text=True, timeout=130)
            if response.returncode:
                raise RuntimeError(f'host trial {trial + 1} failed: {response.stderr}')
            report = parse_report(response.stdout)
            if report['requested_output_color_space'] != output_space:
                raise RuntimeError('host did not honor requested output color space')
            trials['host'].append(report)
            (results/f'host-{trial + 1}.json').write_text(json.dumps(report, indent=2)+'\n')
            print(f'fresh-process trial pair {trial + 1}/{trial_count} recorded', flush=True)
        reference = trials['guest'][0]
        keys = ('input_sha256', 'input_bytes', 'item_index', 'item_count', 'width', 'height', 'row_bytes',
                'output_bytes', 'orientation', 'orientation_applied', 'pixel_format', 'output_color_space',
                'row_order', 'rendering_intent', 'pixel_sha256')
        keys += ('source_color_space', 'source_icc_bytes', 'source_icc_sha256',
                 'output_icc_bytes', 'output_icc_sha256', 'requested_output_color_space')
        differences = []
        for side, reports in trials.items():
            for i, report in enumerate(reports, 1):
                if report['input_sha256'] != encoded['sha256'] or report['input_bytes'] != encoded['size']:
                    raise RuntimeError(f'{side} trial {i} did not decode the exported encoded bytes')
                for key in keys:
                    if report.get(key) != reference.get(key):
                        differences.append({'side': side, 'trial': i, 'field': key,
                                            'guest_reference': reference.get(key), 'value': report.get(key)})
        (results/'comparison-differences.json').write_text(json.dumps(differences, indent=2)+'\n')
        if differences:
            raise RuntimeError(f'unexplained comparison mismatches: {differences!r}')
        compare_bytes(guest_raw, host_raw)
        (results/'result.json').write_text(json.dumps({'result': 'PASS', 'exact_pixels': True, 'trials': trials,
            'note': 'Fresh processes; filesystem caches uncontrolled. Transfer outside decode timing. No application acceleration claim.'}, indent=2)+'\n')
        print(f'PASS image-decode: identical input, shape, hashes and exact first-frame pixels; results {results}', flush=True)
    except (Exception, SystemExit) as error:
        (results/'result.json').write_text(json.dumps({'result': 'FAIL', 'error': str(error), 'trials': trials}, indent=2)+'\n')
        raise SystemExit(f'FAIL image-decode: {error}') from error


experiment()
