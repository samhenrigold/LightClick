#!/usr/bin/env python3
"""Local fake-transport/collector-helper tests only; never execute Apple binaries, apps or guests."""
import ast
import base64
import hashlib
import json
import os
from pathlib import Path
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
from unittest.mock import Mock


def load():
    path = Path(__file__).resolve().parents[1] / 'probes/opencl-contract-driver.py'
    tree = ast.parse(path.read_text())
    tree.body = [n for n in tree.body if not isinstance(n, ast.Expr)]
    ns = {}
    exec(compile(tree, str(path), 'exec'), ns)
    return ns


def main():
    ns = load()
    for key in ('EXPORT', 'COLLECTOR'):
        ast.parse(ns[key])
    assert '/Users/' not in ns['EXPORT'] + ns['COLLECTOR']
    assert 'RLIMIT_FSIZE' not in ns['COLLECTOR']
    assert ns['COLLECTOR'].index("report['console_uid']=join_console()") < ns['COLLECTOR'].index("directory=tempfile.mkdtemp")
    assert ns['COLLECTOR'].index('query=staged(') < ns['COLLECTOR'].index("report['console_uid']=join_console()")
    payloads = {
        'metal': struct.pack('<8I', 0xfeedfacf, 0x1000007, 3, 6, 4, 512, 0, 0) + b'x' * 200000,
        'metal-info': b'fixed framework plist', 'system-version': b'fixed OS build plist',
    }
    identities = {k: dict(device=1, inode=i, bytes=len(v), mtime=1, ctime=1) for i, (k, v) in enumerate(payloads.items(), 1)}
    def reply(value): return {'ExitCode': 0, 'Stdout': json.dumps(value), 'Stderr': ''}
    def capture(code, text):
        stream = dict(text=text, bytes=len(text), at_limit=False, reader_finished=True, error=None)
        return dict(exit_code=code, signal=-code if code < 0 else None, timed_out=False,
                    diagnostics_complete=True, stdout=stream, stderr=dict(stream, text='', bytes=0))
    diagnostic = dict(result='DIAGNOSTIC', cleanup_errors=[],
                      query=capture(-6, '{"checkpoint":"enumerate"}\n'),
                      compute=capture(-6, '{"event":"begin","api":"clBuildProgram"}\npartial crash line'))
    with tempfile.TemporaryDirectory(prefix='lightclick-opencl-contract-test-') as temporary:
        root = Path(temporary)
        helpers = [root / 'query', root / 'compute']
        for helper in helpers: helper.write_bytes(b'fake-helper-source-identity')
        for case in ('good', 'tamper', 'cancel', 'oversize', 'bad-stage'):
            results = root / case
            results.mkdir()
            events = []
            def request(command, timeout):
                assert command['Executable'] == '/usr/bin/python'
                argv = command['Arguments']
                if argv[1] == ns['COLLECTOR']:
                    events.append('collector')
                    assert events[-3:] == ['stage', 'stage', 'collector']
                    assert timeout == 110 and len(argv) == 6
                    if case == 'oversize': return reply(dict(diagnostic, extra='x' * 1100000))
                    return reply(diagnostic)
                assert argv[:2] == ['-c', ns['EXPORT']] and 0 < timeout <= 20
                selector, operation = argv[2:4]
                events.append((selector, operation))
                if case == 'cancel': raise SystemExit('ambiguous host timeout')
                data = payloads[selector]
                identity = identities[selector]
                if operation == 'describe':
                    return reply(dict(path=ns['FILES'][selector][0], identity=identity, bytes=len(data), sha256=hashlib.sha256(data).hexdigest()))
                offset, length = map(int, argv[4:6])
                assert json.loads(argv[6]) == identity
                chunk = data[offset:offset + length]
                return reply(dict(identity=identity, offset=offset, bytes=length,
                                  sha256='0' * 64 if case == 'tamper' else hashlib.sha256(chunk).hexdigest(),
                                  base64=base64.b64encode(chunk).decode()))
            def stage(path):
                events.append('stage')
                assert all((selector, 'describe') in events for selector in ns['FILES'])
                return '/Users/not-a-stage/Transfer.bin' if case == 'bad-stage' else '/private/var/tmp/VirtualIntelMac.ABC123/Transfer.bin'
            ns.update(arguments=[str(results), *map(str, helpers)], request=request, stage=stage)
            try: ns['run']()
            except (ValueError, SystemExit): assert case in ('cancel', 'oversize', 'bad-stage')
            else: assert case in ('good', 'tamper')
            report = json.loads((results / 'opencl-contract.json').read_text())
            if case == 'cancel':
                assert events == [('metal', 'describe')]
                assert (results / 'metal-export.json').exists() and 'ambiguous host timeout' in report['error']
            elif case == 'tamper':
                assert all(x['result'] == 'INCONCLUSIVE' for x in report['exports'])
                assert not (results / 'Metal').exists()
                assert (results / 'Metal.partial').exists()
            else:
                assert all(x['result'] == 'EXPORTED' for x in report['exports'])
                assert (results / 'Metal').read_bytes() == payloads['metal']
                header = report['exports'][0]['macho_header']
                assert header['cpu_type'] == 0x1000007 and header['load_commands'] == 4
                if case == 'good':
                    assert report['result'] == 'DIAGNOSTIC'
                    assert report['exports_complete'] is True
                    assert report['diagnostic']['query']['signal'] == 6
                    assert report['diagnostic']['compute']['parsed_stdout_lines'][0]['api'] == 'clBuildProgram'
                    assert (results / 'compute.stdout.txt').read_text().endswith('partial crash line')
                elif case == 'oversize':
                    assert (results / 'opencl-response.oversize-prefix.txt').stat().st_size == 1048576
                    assert not (results / 'opencl-response.json').exists()
                elif case == 'bad-stage': assert 'collector' not in events
        # Exclusive final publication cannot replace existing output.
        results = root / 'exclusive'; results.mkdir(); (results / 'Metal').write_bytes(b'keep-existing')
        ns.update(request=request)
        result = ns['export_fixed'](results, 'metal')
        assert result['result'] == 'INCONCLUSIVE' and (results / 'Metal').read_bytes() == b'keep-existing'
        # Guest fixed export rejects unknown selectors and canonical-path escapes before opening anything.
        tree = ast.parse(ns['EXPORT'])
        safe = [n for n in tree.body if isinstance(n, (ast.FunctionDef, ast.Assign))]
        opened = Mock()
        guest = dict(os=SimpleNamespace(path=SimpleNamespace(realpath=lambda p: '/Users/escape'), open=opened),
                     re=__import__('re'), json=json)
        exec(compile(ast.Module(body=safe, type_ignores=[]), 'guest fixed export definitions', 'exec'), guest)
        for selector in ('unknown', 'metal'):
            try: guest['export'](selector, 'describe', [])
            except ValueError: pass
            else: raise AssertionError('accepted export escape')
        opened.assert_not_called()
        # Execute only collector subprocess/pipe functions with tiny headless Python children.
        # An actual abort is deliberately avoided: ReportCrash could put UI on the owner's desktop.
        tree = ast.parse(ns['COLLECTOR'])
        definitions = [n for n in tree.body if isinstance(n, ast.FunctionDef)]
        child_ns = {key: globals()[key] for key in ('os', 'signal', 'subprocess', 'threading', 'time')}
        child_ns.update(CAP=1024, owned=[], report={'commands': []})
        exec(compile(ast.Module(body=definitions, type_ignores=[]), 'collector functions only', 'exec'), child_ns)
        payload = root / 'headless-payload'
        code = "import sys;open(sys.argv[1],'wb').write(b'x'*200000);print('{\"event\":\"checkpoint\"}');sys.exit(7)"
        try:
            row = child_ns['command']([sys.executable, '-c', code, str(payload)], 5, dict(os.environ))
            assert row['exit_code'] == 7 and row['signal'] is None and row['diagnostics_complete']
            assert payload.stat().st_size == 200000 and 'checkpoint' in row['stdout']['text']
            code = "import sys,time;sys.stdout.write('x'*200000);sys.stdout.flush();time.sleep(30)"
            row = child_ns['command']([sys.executable, '-c', code], 5, dict(os.environ))
            assert not row['diagnostics_complete'] and row['stdout']['at_limit']
            assert len(row['stdout']['text']) == 1024 and child_ns['owned'][-1].poll() is not None
        finally:
            for child in reversed(child_ns['owned']): child_ns['stop'](child)
    print('PASS fixed Metal export receipts, tamper/exclusive/cancellation bounds, helper order, crash checkpoints and guest path limits')


if __name__ == '__main__': main()
