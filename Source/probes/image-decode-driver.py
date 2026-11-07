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


def experiment():
    if len(arguments) != 3:
        raise RuntimeError('driver requires results directory and host/guest probe paths')
    results, host, guest_binary = map(Path, arguments)
    trials = {'guest': [], 'host': []}
    try:
        exists = request({'Executable': '/usr/bin/test', 'Arguments': ['-f', OS_IMAGE]}, 15)
        if exists.get('ExitCode') != 0:
            raise RuntimeError(f'required OS fixture is absent: {OS_IMAGE}')
        guest = stage(guest_binary)
        directory = staged_directory(guest)
        raw = directory + '/first-image.rgba'
        encoded = export('encoded', directory, results/'Mojave.heic')
        guest_raw, host_raw = results/'guest-first.rgba', results/'host-first.rgba'
        for trial in range(3):
            options = ['--full-resolution', OS_IMAGE, '--index', '0', '--timeout', '120',
                       '--max-output-bytes', str(OUTPUT_CAP)] + (['--raw', raw] if trial == 0 else [])
            response = request({'Executable': guest, 'Arguments': options}, 130)
            if response.get('ExitCode') != 0:
                raise RuntimeError(f'guest trial {trial + 1} failed: {response}')
            report = parse_report(response.get('Stdout') or '')
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
            trials['host'].append(report)
            (results/f'host-{trial + 1}.json').write_text(json.dumps(report, indent=2)+'\n')
            print(f'fresh-process trial pair {trial + 1}/3 recorded', flush=True)
        reference = trials['guest'][0]
        keys = ('input_sha256', 'input_bytes', 'item_index', 'item_count', 'width', 'height', 'row_bytes',
                'output_bytes', 'orientation', 'orientation_applied', 'pixel_format', 'output_color_space',
                'row_order', 'rendering_intent', 'pixel_sha256')
        for side, reports in trials.items():
            for i, report in enumerate(reports, 1):
                if report['input_sha256'] != encoded['sha256'] or report['input_bytes'] != encoded['size']:
                    raise RuntimeError(f'{side} trial {i} did not decode the exported encoded bytes')
                for key in keys:
                    if report.get(key) != reference.get(key):
                        raise RuntimeError(f'{side} trial {i} differs at {key}; unexplained mismatch')
        compare_bytes(guest_raw, host_raw)
        (results/'result.json').write_text(json.dumps({'result': 'PASS', 'exact_pixels': True, 'trials': trials,
            'note': 'Fresh processes; filesystem caches uncontrolled. Transfer outside decode timing. No application acceleration claim.'}, indent=2)+'\n')
        print(f'PASS image-decode: identical input, shape, hashes and exact first-frame pixels; results {results}', flush=True)
    except (Exception, SystemExit) as error:
        (results/'result.json').write_text(json.dumps({'result': 'FAIL', 'error': str(error), 'trials': trials}, indent=2)+'\n')
        raise SystemExit(f'FAIL image-decode: {error}') from error


experiment()
