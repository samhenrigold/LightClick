"""guest-bench: same-probe source/1 TCG control against a prior engine artifact, then one fixed OS decoder export.

Arguments: fresh results directory, arm64 probe, identical x86_64 probe, prior engine results directory.
The caller selects TCG. This driver does not attest the CPU backend or claim an acceleration.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import time

DECODER_PATH = '/System/Library/Video/Plug-Ins/VCPHEVC.bundle/Contents/MacOS/VCPHEVC'
DECODER_LIMIT = 16 * 1024 * 1024
CHUNK_LIMIT = 192 * 1024
EXPORT_SECONDS = 180

# Python 2.7-compatible. No caller-supplied paths: only operation, numeric range, and expected stat identity.
DECODER_EXPORT = r'''import base64, hashlib, json, os, re, signal, stat, sys
signal.alarm(15)
PATH = '/System/Library/Video/Plug-Ins/VCPHEVC.bundle/Contents/MacOS/VCPHEVC'
def identity(info):
    return {'device': info.st_dev, 'inode': info.st_ino, 'bytes': info.st_size,
            'mtime': info.st_mtime, 'ctime': info.st_ctime}
def export(operation, arguments):
    if os.path.realpath(PATH) != PATH:
        raise ValueError('decoder path is not canonical')
    fd = os.open(PATH, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or not 0 < info.st_size <= 16 * 1024 * 1024:
            raise ValueError('decoder must be root-owned regular file within 16 MiB')
        initial = identity(info)
        if operation == 'describe' and not arguments:
            digest, count = hashlib.sha256(), 0
            while True:
                data = os.read(fd, 192 * 1024)
                if not data:
                    break
                count += len(data)
                if count > 16 * 1024 * 1024:
                    raise ValueError('decoder grew beyond budget')
                digest.update(data)
            if count != initial['bytes']:
                raise ValueError('decoder size changed while hashing')
            result = {'path': PATH, 'identity': initial, 'bytes': count, 'sha256': digest.hexdigest()}
        elif operation == 'chunk' and len(arguments) == 3:
            if any(not re.match(r'\A[0-9]{1,10}\Z', value) for value in arguments[:2]):
                raise ValueError('invalid decoder range')
            offset, length = map(int, arguments[:2])
            if not 0 < length <= 192 * 1024 or offset + length > info.st_size or initial != json.loads(arguments[2]):
                raise ValueError('decoder range or identity changed')
            os.lseek(fd, offset, os.SEEK_SET)
            data = os.read(fd, length)
            if len(data) != length:
                raise ValueError('short decoder chunk')
            result = {'identity': initial, 'offset': offset, 'bytes': len(data),
                      'sha256': hashlib.sha256(data).hexdigest(), 'base64': base64.b64encode(data).decode('ascii')}
        else:
            raise ValueError('invalid fixed decoder export operation')
        if identity(os.fstat(fd)) != initial:
            raise ValueError('decoder identity changed during export')
        return result
    finally:
        os.close(fd)
sys.stdout.write(json.dumps(export(sys.argv[1], sys.argv[2:])))
'''


def digest_file(path):
    digest = hashlib.sha256()
    with path.open('rb') as file:
        for data in iter(lambda: file.read(1024 * 1024), b''):
            digest.update(data)
    return digest.hexdigest()


def same_bytes(left, right):
    with left.open('rb') as a, right.open('rb') as b:
        while True:
            x, y = a.read(1024 * 1024), b.read(1024 * 1024)
            if x != y:
                return False
            if not x:
                return True


def expected_native_mismatch(error, results):
    if not isinstance(error.code, str) or not error.code.startswith('FAIL image-decode: unexplained comparison mismatches: '):
        return False
    required = ('guest-first.rgba', 'host-first.rgba', 'guest-1.json', 'host-1.json', 'comparison-differences.json', 'result.json')
    if not all((results/name).is_file() for name in required):
        return False
    report = json.loads((results/'result.json').read_text())
    differences = json.loads((results/'comparison-differences.json').read_text())
    for side in ('guest', 'host'):
        probe = json.loads((results/f'{side}-1.json').read_text())
        raw = results/f'{side}-first.rgba'
        if (probe.get('mode') != 'full-resolution' or type(probe.get('output_bytes')) is not int
                or probe['output_bytes'] <= 0 or raw.stat().st_size != probe['output_bytes']
                or digest_file(raw) != probe.get('pixel_sha256')):
            return False
    return (report.get('result') == 'FAIL' and error.code == 'FAIL image-decode: ' + report.get('error', '')
            and isinstance(differences, list) and bool(differences)
            and all(isinstance(item, dict) and item.get('side') == 'host' and item.get('trial') == 1
                    for item in differences))


def compare_guest(results, reference):
    keys = ('format_version', 'mode', 'input_sha256', 'input_bytes', 'item_index', 'item_count', 'width', 'height',
            'row_bytes', 'output_bytes', 'orientation', 'orientation_applied', 'pixel_format', 'row_order',
            'rendering_intent', 'pixel_sha256', 'source_type', 'source_bits_per_component', 'source_bits_per_pixel',
            'source_alpha_info', 'source_color_space', 'source_icc_bytes', 'source_icc_sha256',
            'output_color_space', 'output_icc_bytes', 'output_icc_sha256', 'requested_output_color_space')
    try:
        reports = [json.loads((directory/'guest-1.json').read_text()) for directory in (reference, results)]
        for directory, report in zip((reference, results), reports):
            if any(key not in report for key in keys) or report['requested_output_color_space'] != 'source':
                raise ValueError('missing comparison fields or reference is not source-space mode')
            for filename, size_key, hash_key in (('Mojave.heic', 'input_bytes', 'input_sha256'),
                                                  ('guest-first.rgba', 'output_bytes', 'pixel_sha256')):
                path = directory/filename
                if path.stat().st_size != report[size_key] or digest_file(path) != report[hash_key]:
                    raise ValueError(f'artifact size/hash disagrees with guest report: {path}')
        if (reports[0]['input_sha256'] != reports[1]['input_sha256'] or
                reports[0]['input_bytes'] != reports[1]['input_bytes'] or
                not same_bytes(reference/'Mojave.heic', results/'Mojave.heic')):
            return {'result': 'INCONCLUSIVE', 'error': 'Encoded inputs differ; pixel differences cannot be attributed to the execution backend.',
                    'engine_input_sha256': reports[0]['input_sha256'], 'control_input_sha256': reports[1]['input_sha256']}
        differences = [{'field': key, 'engine': reports[0][key], 'control': reports[1][key]}
                       for key in keys if reports[0][key] != reports[1][key]]
        if not same_bytes(reference/'guest-first.rgba', results/'guest-first.rgba'):
            differences.append({'field': 'guest-first.rgba', 'exact_bytes_equal': False})
        return {'result': 'MISMATCH' if differences else 'MATCH', 'differences': differences}
    except (OSError, ValueError, KeyError, TypeError) as error:
        return {'result': 'INCONCLUSIVE', 'error': str(error)}


def export_decoder(results):
    manifest = {'result': 'RUNNING', 'path': DECODER_PATH, 'chunks': []}
    deadline = time.monotonic() + EXPORT_SECONDS
    manifest_path = results/'decoder-export.json'
    def save():
        manifest_path.write_text(json.dumps(manifest, indent=2)+'\n')
    def call(operation, options):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError('fixed decoder export exhausted its deadline')
        response = request({'Executable': '/usr/bin/python', 'Arguments': ['-c', DECODER_EXPORT, operation, *options]},
                           min(20, remaining))
        if (not isinstance(response, dict) or 'Error' in response or type(response.get('ExitCode')) is not int
                or response['ExitCode'] != 0):
            manifest['failed_response'] = response
            raise RuntimeError(f'fixed decoder {operation} failed: {response!r}')
        text = response.get('Stdout')
        if not isinstance(text, str) or len(text) > 300 * 1024:
            raise RuntimeError('decoder response exceeded its bounded JSON envelope')
        return json.loads(text)
    try:
        save()
        descriptor = call('describe', [])
        manifest['descriptor'] = descriptor
        save()
        count, identity, expected = descriptor.get('bytes'), descriptor.get('identity'), descriptor.get('sha256')
        if (descriptor.get('path') != DECODER_PATH or type(count) is not int or not 0 < count <= DECODER_LIMIT
                or not isinstance(identity, dict) or identity.get('bytes') != count
                or not isinstance(expected, str) or not re.fullmatch('[0-9a-f]{64}', expected)):
            raise RuntimeError('invalid fixed decoder descriptor')
        target, partial = results/'VCPHEVC', results/'VCPHEVC.partial'
        if target.exists():
            raise RuntimeError('refusing an existing final decoder artifact')
        digest = hashlib.sha256()
        fd = os.open(partial, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'wb') as output:
            for offset in range(0, count, CHUNK_LIMIT):
                length = min(CHUNK_LIMIT, count - offset)
                item = call('chunk', [str(offset), str(length), json.dumps(identity, separators=(',', ':'))])
                payload = item.get('base64')
                if not isinstance(payload, str) or len(payload) > (CHUNK_LIMIT + 2) // 3 * 4:
                    raise RuntimeError('invalid decoder chunk payload')
                data = base64.b64decode(payload, validate=True)
                if (item.get('identity') != identity or type(item.get('offset')) is not int or item['offset'] != offset
                        or type(item.get('bytes')) is not int or item['bytes'] != length or len(data) != length
                        or hashlib.sha256(data).hexdigest() != item.get('sha256')):
                    raise RuntimeError('decoder chunk identity, range, length or hash mismatch')
                output.write(data)
                digest.update(data)
                manifest['chunks'].append({key: item[key] for key in ('identity', 'offset', 'bytes', 'sha256')})
                save()
        if partial.stat().st_size != count or digest.hexdigest() != expected or digest_file(partial) != expected:
            raise RuntimeError('decoder final size/hash mismatch; partial artifact retained')
        os.link(partial, target)  # Exclusive publication: never replace an existing artifact.
        partial.unlink()
        manifest.update(result='PASS', artifact=str(target), sha256=expected, bytes=count)
        save()
        return manifest
    except (Exception, SystemExit) as error:
        manifest.update(result='FAIL', error=repr(error))
        save()
        raise


def control():
    if len(arguments) != 4:
        raise RuntimeError('control driver requires results, host probe, guest probe, and prior engine results')
    results, host, guest, reference = map(Path, arguments)
    report = {'result': 'INCONCLUSIVE', 'phase': 'preflight',
              'note': 'Caller selects TCG; this driver does not attest the backend. No acceleration claim.'}
    def save():
        (results/'tcg-control.json').write_text(json.dumps(report, indent=2)+'\n')
    try:
        save()
        previous_probe = reference/'image-decode-x86_64'
        if digest_file(guest) != digest_file(previous_probe):
            raise RuntimeError('control and engine must use the identical x86_64 probe bytes')
        report.update(phase='measurement', probe_sha256=digest_file(guest))
        save()
        composed = dict(globals(), arguments=[str(results), str(host), str(guest), 'source', '1'])
        driver = source/'probes/image-decode-driver.py'
        try:
            exec(compile(driver.read_text(), str(driver), 'exec'), composed)
        except SystemExit as error:
            if not expected_native_mismatch(error, results):
                raise
            report['native_comparison'] = 'Expected native cross-environment mismatch retained separately in result.json.'
        report.update(compare_guest(results, reference), phase='decoder_export')
        save()
        report['decoder_export'] = export_decoder(results)
        report['phase'] = 'complete'
        save()
        message = f'{report["result"]} TCG guest control; decoder export verified; evidence {results}'
        if report['result'] != 'MATCH':
            report.setdefault('error', 'Guest control did not match the prior engine result; decoder export completed separately.')
            save()
            raise SystemExit(message)
        print(message, flush=True)
    except (Exception, SystemExit) as error:
        report.setdefault('error', repr(error))
        save()
        raise


control()
