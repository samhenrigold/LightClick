#!/usr/bin/env python3
"""Local artifact/protocol mocks only; no guest, build, UI, sockets, or decoder execution."""
import ast
import base64
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import stat
import tempfile
import types


def load():
    path = Path(__file__).resolve().parents[1]/'probes/image-decode-tcg-control-driver.py'
    tree = ast.parse(path.read_text())
    tree.body = [node for node in tree.body if isinstance(node, (ast.Import, ast.ImportFrom, ast.Assign, ast.FunctionDef))]
    namespace = {}
    exec(compile(tree, str(path), 'exec'), namespace)
    return namespace


def fixture(directory, changed=False):
    directory.mkdir(parents=True, exist_ok=True)
    encoded, pixels = b'fixed encoded OS fixture', bytes(range(16))
    if changed:
        pixels = b'\xff' + pixels[1:]
    report = dict(format_version=1, mode='full-resolution', input_sha256=hashlib.sha256(encoded).hexdigest(),
                  input_bytes=len(encoded), item_index=0, item_count=1, width=2, height=2, row_bytes=8, output_bytes=16,
                  orientation=None, orientation_applied=False, pixel_format='RGBA8-premultiplied', row_order='top-to-bottom',
                  rendering_intent='relative-colorimetric', pixel_sha256=hashlib.sha256(pixels).hexdigest(),
                  source_type='public.heic', source_bits_per_component=8, source_bits_per_pixel=32, source_alpha_info=5,
                  source_color_space='kCGColorSpaceDisplayP3', output_color_space='kCGColorSpaceDisplayP3',
                  source_icc_bytes=548, output_icc_bytes=548, source_icc_sha256='a'*64, output_icc_sha256='a'*64,
                  requested_output_color_space='source')
    (directory/'Mojave.heic').write_bytes(encoded)
    (directory/'guest-first.rgba').write_bytes(pixels)
    (directory/'guest-1.json').write_text(json.dumps(report))
    (directory/'image-decode-x86_64').write_bytes(b'identical x86 probe fixture')
    return report


def native_mismatch(directory):
    report = json.loads((directory/'guest-1.json').read_text())
    report['orientation'] = 1
    (directory/'host-1.json').write_text(json.dumps(report))
    (directory/'host-first.rgba').write_bytes((directory/'guest-first.rgba').read_bytes())
    error = 'unexplained comparison mismatches: fixture orientation'
    (directory/'comparison-differences.json').write_text(json.dumps([{'side': 'host', 'trial': 1, 'field': 'orientation'}]))
    (directory/'result.json').write_text(json.dumps({'result': 'FAIL', 'error': error}))
    return SystemExit('FAIL image-decode: ' + error)


def alternate_input(directory):
    encoded = b'different encoded OS fixture'
    (directory/'Mojave.heic').write_bytes(encoded)
    report = json.loads((directory/'guest-1.json').read_text())
    report.update(input_bytes=len(encoded), input_sha256=hashlib.sha256(encoded).hexdigest())
    (directory/'guest-1.json').write_text(json.dumps(report))


def comparison_checks(work):
    ns = load()
    reference, results = work/'reference', work/'current'
    fixture(reference)
    fixture(results)
    assert ns['compare_guest'](results, reference)['result'] == 'MATCH'
    fixture(results, changed=True)
    assert ns['compare_guest'](results, reference)['result'] == 'MISMATCH'
    (results/'guest-first.rgba').write_bytes(b'corruption')
    assert ns['compare_guest'](results, reference)['result'] == 'INCONCLUSIVE'
    fixture(results)
    alternate_input(results)
    different_input = ns['compare_guest'](results, reference)
    assert different_input['result'] == 'INCONCLUSIVE' and 'Encoded inputs differ' in different_input['error']
    assert 'differences' not in different_input
    fixture(results)
    error = native_mismatch(results)
    assert ns['expected_native_mismatch'](error, results)
    for error in (SystemExit(130), SystemExit('Timed out waiting'), SystemExit('FAIL image-decode: 130')):
        assert not ns['expected_native_mismatch'](error, results)
    (results/'host-first.rgba').write_bytes(b'corruption')
    assert not ns['expected_native_mismatch'](native_mismatch_error(), results)
    print('PASS exact guest comparison: MATCH/MISMATCH/INCONCLUSIVE and narrowly accepted native failure')


def native_mismatch_error():
    return SystemExit('FAIL image-decode: unexplained comparison mismatches: fixture orientation')


def export_checks(work):
    cases = ('valid', 'wrong-identity', 'wrong-offset', 'wrong-length', 'wrong-chunk-hash', 'wrong-final-hash',
             'wrong-path', 'oversize', 'bad-base64', 'control-error', 'host-timeout', 'deadline', 'existing', 'existing-partial',
             'written-file-corruption')
    payload = bytes(range(256))*1536 + b'last independent bytes'
    for name in cases:
        ns = load()
        destination = work/name
        destination.mkdir()
        clock, calls = [0.0], []
        ns['time'] = types.SimpleNamespace(monotonic=lambda: clock[0])
        identity = {'device': 1, 'inode': 7, 'bytes': len(payload), 'mtime': 1000.5, 'ctime': 1001.5}
        descriptor = {'path': ns['DECODER_PATH'], 'identity': identity, 'bytes': len(payload),
                      'sha256': hashlib.sha256(payload).hexdigest()}
        if name == 'wrong-path':
            descriptor['path'] = '/Users/forbidden'
        elif name == 'oversize':
            descriptor['bytes'] = ns['DECODER_LIMIT'] + 1
        elif name == 'wrong-final-hash':
            descriptor['sha256'] = '0'*64
        sentinel = destination/('VCPHEVC.partial' if name == 'existing-partial' else 'VCPHEVC')
        if name in ('existing', 'existing-partial'):
            sentinel.write_bytes(b'preserve')

        def request(command, timeout):
            assert command['Executable'] == '/usr/bin/python' and 0 < timeout <= 20
            options = command['Arguments']
            assert options[:2] == ['-c', ns['DECODER_EXPORT']]
            operation = options[2]
            calls.append(operation)
            if name == 'deadline':
                clock[0] += 90
            if name == 'host-timeout':
                raise SystemExit('Timed out waiting for export')
            if name == 'control-error':
                return {'Error': 'The control response timed out.'}
            if operation == 'describe':
                assert len(options) == 3
                result = descriptor
            else:
                assert operation == 'chunk' and json.loads(options[5]) == identity
                offset, length = map(int, options[3:5])
                assert 0 < length <= 192 * 1024 and offset + length <= len(payload)
                data = payload[offset:offset+length]
                if name == 'written-file-corruption' and offset >= 2 * ns['CHUNK_LIMIT']:
                    with (destination/'VCPHEVC.partial').open('r+b') as file:
                        file.write(b'\xff')
                result = dict(identity=identity, offset=offset, bytes=length,
                              sha256=hashlib.sha256(data).hexdigest(), base64=base64.b64encode(data).decode())
                if name == 'wrong-identity':
                    result['identity'] = dict(identity, inode=8)
                elif name == 'wrong-offset':
                    result['offset'] += 1
                elif name == 'wrong-length':
                    result['bytes'] -= 1
                elif name == 'wrong-chunk-hash':
                    result['sha256'] = '0'*64
                elif name == 'bad-base64':
                    result['base64'] = 'not-base64!'
            return {'ExitCode': 0, 'Stdout': json.dumps(result)}
        ns['request'] = request
        try:
            ns['export_decoder'](destination)
        except (Exception, SystemExit):
            assert name != 'valid', 'valid fixed decoder export failed'
        else:
            assert name == 'valid', f'{name}: invalid export passed'
        manifest = json.loads((destination/'decoder-export.json').read_text())
        assert manifest['result'] == ('PASS' if name == 'valid' else 'FAIL')
        if name == 'valid':
            assert (destination/'VCPHEVC').read_bytes() == payload
            assert not (destination/'VCPHEVC.partial').exists()
            assert len(manifest['chunks']) == 3
        elif name in ('existing', 'existing-partial'):
            assert sentinel.read_bytes() == b'preserve'
        else:
            assert not (destination/'VCPHEVC').exists()
        if name in ('host-timeout', 'control-error'):
            assert len(calls) == 1
        if name == 'deadline':
            assert len(calls) == 2 and clock[0] == 180
    print(f'PASS fixed decoder export: {len(cases)} mocked protocol, cap, deadline and exclusive-output cases')


def guest_export_checks():
    driver = load()
    tree = ast.parse(driver['DECODER_EXPORT'])
    tree.body = [node for node in tree.body if isinstance(node, (ast.Import, ast.FunctionDef, ast.Assign))]
    ns = {}
    exec(compile(tree, 'fixed guest decoder export', 'exec'), ns)
    for name in ('valid', 'alias', 'owner', 'symlink', 'empty', 'oversize', 'changed'):
        payload, position, closed, opened, stats = b'actual independent decoder bytes', [0], [], [], [0]
        def info():
            stats[0] += 1
            return types.SimpleNamespace(st_mode=stat.S_IFLNK if name == 'symlink' else stat.S_IFREG,
                st_uid=501 if name == 'owner' else 0, st_dev=1, st_ino=8 if name == 'changed' and stats[0] > 1 else 7,
                st_size=0 if name == 'empty' else 16 * 1024 * 1024 + 1 if name == 'oversize' else len(payload),
                st_mtime=1.5, st_ctime=2.5)
        def open_file(path, flags):
            assert path == driver['DECODER_PATH'] and flags & os.O_NOFOLLOW
            opened.append(path)
            return 9
        def read_file(fd, length):
            data = payload[position[0]:position[0]+length]
            position[0] += len(data)
            return data
        ns['os'] = types.SimpleNamespace(path=types.SimpleNamespace(realpath=lambda p: '/Users/no' if name == 'alias' else p),
            O_RDONLY=os.O_RDONLY, O_NOFOLLOW=os.O_NOFOLLOW, SEEK_SET=os.SEEK_SET, open=open_file,
            fstat=lambda fd: info(), read=read_file, close=lambda fd: closed.append(fd),
            lseek=lambda fd, offset, whence: position.__setitem__(0, offset))
        try:
            result = ns['export']('describe', [])
        except ValueError:
            assert name != 'valid'
        else:
            assert name == 'valid' and result['sha256'] == hashlib.sha256(payload).hexdigest()
            identity = result['identity']
            for offset, length, expected in ((0, 5, payload[:5]), (5, len(payload)-5, payload[5:])):
                chunk = ns['export']('chunk', [str(offset), str(length), json.dumps(identity)])
                assert base64.b64decode(chunk['base64']) == expected
            for options in (['-1', '1', '{}'], ['0', '196609', '{}'], ['0', '1', '{}']):
                try:
                    ns['export']('chunk', options)
                except ValueError:
                    pass
                else:
                    raise AssertionError('invalid guest chunk accepted')
        assert len(closed) == len(opened)
    print('PASS embedded fixed-path exporter: canonical/root/regular/cap/identity checks and exact chunk bytes')


def orchestration_checks(work):
    for name in ('match', 'mismatch', 'different-input', 'cancel', 'unexpected-failure', 'different-probe'):
        ns = load()
        root = work/name
        reference, results = root/'engine', root/'results'
        fixture(reference)
        results.mkdir()
        probe = root/'probe'
        probe.write_bytes(b'wrong' if name == 'different-probe' else (reference/'image-decode-x86_64').read_bytes())
        (root/'probes').mkdir()
        (root/'probes/image-decode-driver.py').write_text('''
assert arguments[3:] == ['source', '1']
create_measurement(Path(arguments[0]), changed=change_pixels)
if different_input:
    change_encoded_input(Path(arguments[0]))
if cancel:
    raise SystemExit(130)
if fail_unexpected:
    raise SystemExit('FAIL image-decode: guest request failed')
raise create_native_mismatch(Path(arguments[0]))
''')
        exports = []
        ns.update(source=root, arguments=[str(results), '/unused/host', str(probe), str(reference)],
                  create_measurement=fixture, create_native_mismatch=native_mismatch,
                  change_encoded_input=alternate_input, different_input=name == 'different-input',
                  change_pixels=name == 'mismatch', cancel=name == 'cancel', fail_unexpected=name == 'unexpected-failure',
                  export_decoder=lambda directory: exports.append(directory) or {'result': 'PASS'})
        with contextlib.redirect_stdout(io.StringIO()):
            try:
                ns['control']()
            except (Exception, SystemExit):
                assert name != 'match'
            else:
                assert name == 'match'
        report = json.loads((results/'tcg-control.json').read_text())
        assert report['result'] == {'match': 'MATCH', 'mismatch': 'MISMATCH'}.get(name, 'INCONCLUSIVE')
        assert bool(exports) == (name in ('match', 'mismatch', 'different-input'))
        if name in ('mismatch', 'different-input'):
            assert report['phase'] == 'complete' and report['decoder_export']['result'] == 'PASS' and report['error']
    print('PASS control composition: source/1, identical probe gate, expected native mismatch, cancellation/error propagation')


def main():
    with tempfile.TemporaryDirectory(prefix='lightclick-tcg-control-test-') as temporary:
        work = Path(temporary)
        comparison_checks(work)
        exports = work/'exports'
        exports.mkdir()
        export_checks(exports)
        guest_export_checks()
        orchestration_checks(work/'orchestration')


if __name__ == '__main__':
    main()
