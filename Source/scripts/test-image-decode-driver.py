#!/usr/bin/env python3
"""Local TCP/protocol regression: no guest, decoder binary, build, or desktop.

Extracts the driver's transport/parser functions with AST so experiment() never
runs. A local fake guest sends independently constructed protocol bytes through
real loopback sockets, including truncated/corrupt transfers and withheld EOF.
"""
import ast
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import re
import signal
import socket
import stat
import struct
import tempfile
import threading
import time
import types


def load_driver():
    path = Path(__file__).resolve().parents[1]/'probes/image-decode-driver.py'
    tree = ast.parse(path.read_text(), filename=str(path))
    constants = {'CAP', 'OUTPUT_CAP', 'TRANSFER_SECONDS', 'SENDER', 'OS_IMAGE'}
    nodes = [node for node in tree.body if isinstance(node, (ast.Import, ast.ImportFrom))
             or isinstance(node, ast.FunctionDef) and node.name in ('export', 'parse_report', 'staged_directory', 'experiment')
             or isinstance(node, ast.Assign) and any(isinstance(target, ast.Name) and target.id in constants
                                                    for target in node.targets)]
    namespace = {}
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(path), 'exec'), namespace)
    namespace['TRANSFER_SECONDS'] = 0.25
    # Syntax is common to Python 2.7 and 3: the Python 2 sender intentionally uses byte strings, not Python 3-only
    # f-strings, annotations or socket context managers. This parse alone does not claim a Python 2 runtime check.
    ast.parse(namespace['SENDER'], filename='embedded Mojave sender')
    return namespace


def transport_checks(namespace, work):
    passed = 0
    # More than one receiver chunk, binary NULs and non-ASCII bytes included.
    large = bytes(range(256)) * 8192 + bytes(range(17))
    cases = ('exact', 'wrong-nonce', 'truncated-header', 'short', 'extra', 'wrong-hash',
             'zero-count', 'over-cap', 'withheld-eof', 'existing-output')
    for name in cases:
        payload = large if name == 'exact' else b'\x00\xffbinary\n\x80'
        target = work/(name + '.bin')
        sentinel = b'preserve the existing artifact'
        if name == 'existing-output':
            target.write_bytes(sentinel)
        acknowledged = []

        def fake_request(command, timeout):
            assert command['Executable'] == '/usr/bin/python'
            arguments = command['Arguments']
            port, nonce = int(arguments[-2]), bytes.fromhex(arguments[-1])
            digest, size, body = hashlib.sha256(payload).digest(), len(payload), payload
            if name == 'wrong-nonce':
                nonce = bytes([nonce[0] ^ 1]) + nonce[1:]
            elif name == 'short':
                size += 1
            elif name == 'extra':
                body += b'!'
            elif name == 'wrong-hash':
                digest = bytes([digest[0] ^ 1]) + digest[1:]
            elif name == 'zero-count':
                size, body = 0, b''
            elif name == 'over-cap':
                size, body = namespace['CAP'] + 1, b''
            header = nonce + struct.pack('>Q', size) + digest
            if name == 'truncated-header':
                header, body = header[:19], b''
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=1) as client:
                    client.settimeout(1)
                    # Fragment the header independently of the receiver's requested sizes.
                    for start in range(0, len(header), 7):
                        client.sendall(header[start:start + 7])
                    if body:
                        client.sendall(body)
                    if name != 'withheld-eof':
                        client.shutdown(socket.SHUT_WR)
                    ack = client.recv(1)
            except (ConnectionError, OSError):
                ack = b''
            acknowledged.append(ack)
            return {'ExitCode': 0 if ack == b'1' else 1, 'Stdout': 'local fake guest'}

        namespace['request'] = fake_request
        before = set(threading.enumerate())
        began = time.monotonic()
        problem = None
        with contextlib.redirect_stdout(io.StringIO()):
            try:
                result = namespace['export']('encoded', '/private/var/tmp/VirtualIntelMac.Abc123', target)
            except RuntimeError as error:
                problem = error
        if time.monotonic() - began > 2:
            raise AssertionError(f'{name}: transport exceeded its short local deadline')
        if set(threading.enumerate()) - before:
            raise AssertionError(f'{name}: receiver thread leaked')
        if name == 'exact':
            if problem or target.read_bytes() != payload or acknowledged != [b'1']:
                raise AssertionError(f'{name}: exact bytes/ack failed: {problem}')
            if result['size'] != len(payload) or result['sha256'] != hashlib.sha256(payload).hexdigest():
                raise AssertionError('exact: verified size/hash differ')
        else:
            if problem is None or acknowledged != [b'']:
                raise AssertionError(f'{name}: invalid export was accepted or acknowledged')
            if name == 'existing-output':
                if target.read_bytes() != sentinel:
                    raise AssertionError('existing output was overwritten or deleted')
            elif target.exists():
                raise AssertionError(f'{name}: invalid/partial output remained')
        passed += 1
    print(f'PASS image-decode export: {passed} real loopback cases, deadlines and thread cleanup')


def report_checks(namespace):
    parse = namespace['parse_report']
    valid = {'format_version': 1, 'mode': 'full-resolution', 'width': 2, 'height': 2,
             'row_bytes': 8, 'output_bytes': 16, 'pixel_sha256': 'a' * 64, 'input_sha256': 'b' * 64}
    if parse(json.dumps(valid)) != valid:
        raise AssertionError('valid report changed')
    invalid = [dict(valid, format_version=2), dict(valid, mode='thumbnail'), dict(valid, width=0),
               dict(valid, width=True), dict(valid, height=-1), dict(valid, row_bytes=9),
               dict(valid, output_bytes=15), dict(valid, pixel_sha256='not-a-hash'),
               dict(valid, input_sha256='A' * 64),
               dict(valid, width=1, height=namespace['OUTPUT_CAP'], row_bytes=4,
                    output_bytes=namespace['OUTPUT_CAP'] * 4), [], {'format_version': 1}]
    for report in invalid:
        try:
            parse(json.dumps(report))
        except (RuntimeError, ValueError):
            continue
        raise AssertionError(f'invalid report accepted: {report}')
    for text in ('{"truncated":', ' ' * (1024 * 1024 + 1)):
        try:
            parse(text)
        except (RuntimeError, ValueError):
            continue
        raise AssertionError('malformed/oversized report accepted')
    print(f'PASS image-decode reports: valid record and {len(invalid) + 2} invalid cases')


def path_checks(namespace):
    directory = '/private/var/tmp/VirtualIntelMac.Abc123'
    raw = directory + '/first-image.rgba'
    os_image = '/Library/Desktop Pictures/Mojave.heic'
    if namespace['staged_directory'](directory + '/Transfer.bin') != directory:
        raise AssertionError('valid staging receipt refused')
    for path in ('/Users/person/Transfer.bin', directory + '/../Transfer.bin', directory + '//Transfer.bin',
                 '/private/var/tmp/VirtualIntelMac.Abc1234/Transfer.bin', directory + '/different.bin'):
        try:
            namespace['staged_directory'](path)
        except RuntimeError:
            continue
        raise AssertionError(f'unsafe staging receipt accepted: {path}')
    sender = ast.parse(namespace['SENDER'])
    function = next(node for node in sender.body if isinstance(node, ast.FunctionDef) and node.name == 'export_file')

    def check(selector='pixels', *, aliases=None, directory_mode=stat.S_IFDIR | 0o700,
              directory_owner=0, file_owner=0, links=1, size=8, wanted=True):
        opened, closed = [], []

        def open_file(path, flags):
            opened.append((path, flags))
            return 7

        fake_os = types.SimpleNamespace(
            path=types.SimpleNamespace(realpath=lambda path: (aliases or {}).get(path, path)),
            lstat=lambda path: types.SimpleNamespace(st_mode=directory_mode, st_uid=directory_owner),
            O_RDONLY=os.O_RDONLY, O_NOFOLLOW=os.O_NOFOLLOW, open=open_file, close=closed.append,
            fstat=lambda fd: types.SimpleNamespace(st_mode=stat.S_IFREG | 0o600, st_uid=file_owner,
                                                  st_nlink=links, st_size=size))
        names = {'os': fake_os, 'stat': stat, 're': re}
        exec(compile(ast.Module(body=[function], type_ignores=[]), '<sender-preflight>', 'exec'), names)
        try:
            result = names['export_file'](selector, directory)
        except ValueError:
            if wanted:
                raise
            if opened and closed != [7]:
                raise AssertionError('refused sender file descriptor leaked')
            return opened
        if not wanted:
            raise AssertionError('unsafe sender export accepted')
        if result != (7, size) or opened != [(raw if selector == 'pixels' else os_image, os.O_RDONLY | os.O_NOFOLLOW)]:
            raise AssertionError('sender did not derive the exact allowed path with O_NOFOLLOW')
        return opened

    check()
    check('encoded')
    for options in ({'aliases': {directory: '/Users/person/private'}},
                    {'aliases': {raw: '/Users/person/private'}},
                    {'selector': 'encoded', 'aliases': {os_image: '/Users/person/image'}},
                    {'directory_owner': 501}, {'directory_mode': stat.S_IFDIR | 0o755},
                    {'directory_mode': stat.S_IFLNK | 0o700}, {'selector': 'arbitrary'}):
        if check(wanted=False, **options):
            raise AssertionError('unsafe sender path reached os.open')
    for options in ({'file_owner': 501}, {'links': 2}, {'size': 0}, {'size': 512 * 1024 * 1024 + 1}):
        check(wanted=False, **options)
    print('PASS private staging, fixed OS/raw selectors, root ownership and symlink/escape refusals')


def preflight_checks(namespace, work):
    cases = [('present', {'ExitCode': 0}, 'after successful preflight', True),
             ('absent', {'ExitCode': 1, 'Stderr': ''}, 'absent or not a regular file', False),
             ('launch-error', {'Error': 'No such executable'}, 'did not execute successfully', False),
             ('missing-exit', {'Stdout': ''}, 'did not execute successfully', False),
             ('error-with-zero', {'ExitCode': 0, 'Error': 'launch failed'}, 'did not execute successfully', False),
             ('unexpected-exit', {'ExitCode': 127}, 'did not execute successfully', False),
             ('boolean-exit', {'ExitCode': False}, 'did not execute successfully', False),
             ('invalid-response', None, 'did not execute successfully', False)]
    for name, response, wanted, should_stage in cases:
        result_directory = work/name
        result_directory.mkdir()
        staged, requests = [], []

        def fake_request(command, timeout):
            requests.append(command)
            if command != {'Executable': '/bin/test', 'Arguments': ['-f', namespace['OS_IMAGE']]}:
                return {'Error': 'wrong preflight executable or arguments'}
            return response

        def fake_stage(binary):
            staged.append(binary)
            # Stop at the first instruction after successful preflight: no transport, probe, or decoder can run.
            raise RuntimeError('after successful preflight')

        namespace.update(arguments=[str(result_directory), '/unused/host-probe', '/unused/guest-probe'],
                         request=fake_request, stage=fake_stage)
        try:
            namespace['experiment']()
        except SystemExit:
            pass
        else:
            raise AssertionError(f'{name}: experiment unexpectedly continued')
        report = json.loads((result_directory/'result.json').read_text())
        if wanted not in report['error'] or bool(staged) != should_stage:
            raise AssertionError(f'{name}: wrong preflight classification/staging: {report}')
        if len(requests) != 1 or report['trials'] != {'guest': [], 'host': []}:
            raise AssertionError(f'{name}: work started after unsuccessful preflight')
        if not should_stage and repr(response) not in report['error']:
            raise AssertionError(f'{name}: full diagnostic response was not preserved')
    print(f'PASS actual experiment preflight: /bin/test, absent vs launch failure, {len(cases)} cases')


def main():
    signal.alarm(30)
    namespace = load_driver()
    with tempfile.TemporaryDirectory(prefix='lightclick-image-transport-check-') as temporary:
        work = Path(temporary)
        transport_checks(namespace, work)
        preflight_checks(namespace, work)
    report_checks(namespace)
    path_checks(namespace)
    print('PASS embedded sender syntax; Python 2 runtime compatibility remains a guest check')


if __name__ == '__main__':
    try:
        main()
    except (AssertionError, OSError, RuntimeError, ValueError) as error:
        raise SystemExit(f'FAIL image-decode driver: {error}') from error
