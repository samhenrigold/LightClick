#!/usr/bin/env python3
"""Local fake-transport/collector-helper tests only; never execute Apple binaries, apps or guests."""
import ast
import base64
import copy
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
        dylib=root/'diagnostic.dylib';dylib.write_bytes(struct.pack('<8I',0xfeedfacf,0x1000007,3,6,0,0,0,0))
        ns['validate_diagnostic_dylib'](dylib)
        for file_type in (2,8):
            bad=root/('wrongtype'+str(file_type));bad.write_bytes(struct.pack('<8I',0xfeedfacf,0x1000007,3,file_type,0,0,0,0))
            try:ns['validate_diagnostic_dylib'](bad)
            except ValueError:pass
            else:raise AssertionError('accepted non-dylib')
        for case in ('good', 'tamper', 'cancel', 'oversize', 'bad-stage','dialect','missing-witness','wrong-pid','malformed-options','standard-kernel','preview-only','standard-header'):
            results = root / case
            results.mkdir()
            events = []
            def request(command, timeout):
                assert command['Executable'] == '/usr/bin/python'
                argv = command['Arguments']
                if argv[1] == ns['COLLECTOR']:
                    events.append('collector')
                    injected=case in ('dialect','missing-witness','wrong-pid','malformed-options','standard-kernel','preview-only','standard-header')
                    assert events[-(4 if injected else 3):] == ['stage']*(3 if injected else 2)+['collector']
                    assert timeout == 110 and len(argv) == (9 if injected else 6)
                    if case == 'oversize': return reply(dict(diagnostic, extra='x' * 1100000))
                    value=copy.deepcopy(diagnostic)
                    if injected:
                        value['compute']['pid']=1234
                        assert argv[-1]==(case if case in ('standard-kernel','standard-header') else 'dialect-only')
                        logs=[dict(event='installed',pid=999 if case=='wrong-pid' else 1234,**{'class':'MTLCompileOptionsInternal'},pipelineModeChanged=False),dict(event='arguments',callerArguments='-cl-std=CL1.2',actualArguments='wrong' if case=='malformed-options' else '-cl-std=CL1.2 -x cl',languageVersion=131074,mode='dialect-only',nativeLibraryScope=case!='preview-only',callerImage='/System/Library/Frameworks/Metal.framework/Versions/A/Metal',callerImageOffset=0x50471)]
                        if case=='standard-kernel':
                            logs[1].update(mode='standard-kernel',sourceSHA256='f110a56696746ed66d54450f587bf4c063386815a5e79f5e7b13d83fef730d22',callerArguments='-fapplecl-lax-vector-conversions -cl-std=CL1.2',actualArguments=' -cl-std=CL1.2 -std=cl1.2 -x cl')
                        if case=='standard-header':
                            logs[1].update(mode='standard-header',sourceSHA256='f110a56696746ed66d54450f587bf4c063386815a5e79f5e7b13d83fef730d22',actualArguments='-cl-std=CL1.2 -std=cl1.2 -x cl -include /System/Library/PrivateFrameworks/GPUCompiler.framework/Versions/31001/Libraries/lib/clang/31001.192/include/opencl-c.h')
                            logs.append(dict(event='headerVerified',path='/System/Library/PrivateFrameworks/GPUCompiler.framework/Versions/31001/Libraries/lib/clang/31001.192/include/opencl-c.h',sha256='388facd88852bbca216b87023cca7d31064b0ef901f582d3baf4b5960abafc72',bytes=805181,uid=0,inode=123))
                        if case=='standard-header':logs.append(dict(event='libraryFunctions',functionCount=1,functionNames=['lc_integer_add'],truncated=False,typeFailure=False,rendererExpectedPrefix='__entry_'))
                        value['compute']['stderr']['text']='' if case=='missing-witness' else ''.join('LC_OPENCL_DIALECT '+json.dumps(x)+'\n' for x in logs)
                    return reply(value)
                assert argv[:2] == ['-c', ns['EXPORT']]
                selector, operation = argv[2:4]
                assert timeout==(120 if selector=='metal' and operation=='describe' else 20)
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
            ns.update(arguments=[str(results), *map(str, helpers)]+([str(dylib)] if case in ('dialect','missing-witness','wrong-pid','malformed-options','standard-kernel','preview-only','standard-header') else [])+([case] if case in ('standard-kernel','standard-header') else []), request=request, stage=stage)
            try: ns['run']()
            except (ValueError, SystemExit): assert case in ('cancel', 'oversize', 'bad-stage')
            else: assert case in ('good', 'tamper','dialect','missing-witness','wrong-pid','malformed-options','standard-kernel','preview-only','standard-header')
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
                assert report['exports'][0]['first_describe_queued_allowance_seconds']==120
                assert report['exports'][0]['guest_export_alarm_seconds']==15
                assert all(x['first_describe_queued_allowance_seconds']==20 for x in report['exports'][1:])
                assert (results / 'Metal').read_bytes() == payloads['metal']
                header = report['exports'][0]['macho_header']
                assert header['cpu_type'] == 0x1000007 and header['load_commands'] == 4
                if case == 'good':
                    assert report['result'] == 'DIAGNOSTIC'
                    assert report['exports_complete'] is True
                    assert report['diagnostic']['query']['signal'] == 6
                    assert report['diagnostic']['compute']['parsed_stdout_lines'][0]['api'] == 'clBuildProgram'
                    assert (results / 'compute.stdout.txt').read_text().endswith('partial crash line')
                elif case in ('dialect','missing-witness','wrong-pid','malformed-options','standard-kernel','preview-only','standard-header'):
                    assert report['result']==('DIALECT_DIAGNOSTIC_CAPTURED' if case in ('dialect','standard-kernel','standard-header') else 'INCONCLUSIVE')
                    assert report['source_language_diagnostic']['witnessed']==(case in ('dialect','standard-kernel','standard-header'))
                    assert report['source_language_diagnostic_dylib']['macho_header']['file_type']==6
                    if case=='standard-header':
                        observed=[row for row in report['source_language_diagnostic']['events'] if row.get('event')=='libraryFunctions']
                        assert observed==[dict(event='libraryFunctions',functionCount=1,functionNames=['lc_integer_add'],truncated=False,typeFailure=False,rendererExpectedPrefix='__entry_')]
                        assert (results/'compute.stderr.txt').read_text().count('lc_integer_add')==1
                        for observation in (dict(event='libraryFunctions',functionCount=0,functionNames=[],truncated=False,typeFailure=False),
                                            dict(event='libraryFunctions',functionCount=40,functionNames=['x'*64]*32,truncated=True,typeFailure=False),
                                            dict(event='libraryFunctions',functionCount=0,functionNames=[],truncated=False,typeFailure=True)):
                            # Metadata availability/truncation stays explicit; no inference or name rewriting.
                            fake=copy.deepcopy(report['diagnostic']['compute'])
                            fake['stderr']['text']='LC_OPENCL_DIALECT '+json.dumps(observation)+'\n'
                            captured=ns['dialect_witness'](fake,'standard-header')
                            assert captured['events']==[observation] and not captured['witnessed']

                        bad=copy.deepcopy(report['diagnostic']['compute']);bad['stderr']['text']=bad['stderr']['text'].replace('388facd88852bbca216b87023cca7d31064b0ef901f582d3baf4b5960abafc72','0'*64)
                        assert not ns['dialect_witness'](bad,'standard-header')['witnessed']
                        bad=copy.deepcopy(report['diagnostic']['compute']);bad['stderr']['text']='\n'.join(line for line in bad['stderr']['text'].splitlines() if 'headerVerified' not in line)
                        assert not ns['dialect_witness'](bad,'standard-header')['witnessed']
                elif case == 'oversize':
                    assert (results / 'opencl-response.oversize-prefix.txt').stat().st_size == 1048576
                    assert not (results / 'opencl-response.json').exists()
                elif case == 'bad-stage': assert 'collector' not in events
        # The first allowance is clipped by the unchanged overall export deadline; never retry it.
        old_time=ns['time'];clock=iter((100.0,350.0));requests=[]
        clipped=root/'clipped';clipped.mkdir()
        def timeout_request(command,timeout):
            requests.append((command,timeout))
            raise SystemExit('one queued request timed out')
        ns.update(time=SimpleNamespace(monotonic=lambda:next(clock)),request=timeout_request)
        try:
            try:ns['export_fixed'](clipped,'metal')
            except SystemExit:pass
            else:raise AssertionError('ambiguous request was swallowed')
            assert len(requests)==1 and requests[0][1]==50
            manifest=json.loads((clipped/'metal-export.json').read_text())
            assert manifest['first_describe_queued_allowance_seconds']==120
            assert manifest['first_describe_host_timeout_seconds']==50
        finally:ns['time']=old_time
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
        dirty={'DYLD_INSERT_LIBRARIES':'wrong','LC_OPENCL_SOURCE_LANGUAGE_DIAGNOSTIC':'wrong','KEEP':'yes'}
        assert child_ns['helper_environment'](dirty,'query','/own/diagnostic.dylib')=={'KEEP':'yes'}
        assert child_ns['helper_environment'](dirty,'compute',None)=={'KEEP':'yes'}
        assert child_ns['helper_environment'](dirty,'compute','/own/diagnostic.dylib')==dict(KEEP='yes',DYLD_INSERT_LIBRARIES='/own/diagnostic.dylib',LC_OPENCL_SOURCE_LANGUAGE_DIAGNOSTIC='1',LC_OPENCL_DIAGNOSTIC_MODE='dialect-only')
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
