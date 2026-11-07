#!/usr/bin/env python3
"""Local mocked host metadata/files only: no VM, apps, signals, capture, permission request, or desktop input."""
import ast
import contextlib
import io
import json
import os
from pathlib import Path
import plistlib
import signal
import tempfile
import types
import uuid


def load():
    path = Path(__file__).resolve().parents[1]/'probes/seamless-driver.py'
    tree = ast.parse(path.read_text())
    tree.body = [node for node in tree.body if isinstance(node, (ast.Import, ast.ImportFrom)) or
                 isinstance(node, ast.FunctionDef) and node.name in
                 ('owner_capture_identity', 'qualify_owner_capture', 'qualify_material_fixture')]
    namespace = {}
    exec(compile(tree, str(path), 'exec'), namespace)
    return namespace


def owner_checks(root):
    cases = ('success', 'no-preflight-api', 'stale-file', 'fresh-wrong-nonce', 'wrong-guest', 'wrong-pid',
             'bad-host-id', 'wrong-cg-owner', 'duplicate-cg', 'no-cg', 'zero-reads', 'boolean-reads', 'zero-dimensions',
             'capture-error', 'process-changed', 'changed-before-signal', 'wrong-bundle', 'outside-clone', 'timeout', 'oversize', 'symlink',
             'fifo', 'oversize-guest-id', 'unexpected-payload', 'cancellation')
    for name in cases:
        ns = load()
        source = root/name
        tag, pid, window = 'fixture', 123, 42
        home = source/'Build/bench'/tag/'home'
        bundle = home/'Library/Caches/Light Click/Seamless Apps/Fixture.app'
        (bundle/'Contents').mkdir(parents=True)
        identifier = 'wrong.bundle' if name == 'wrong-bundle' else 'org.virtualintelmac.SeamlessMaterialsFixture'
        (bundle/'Contents/Info.plist').write_bytes(plistlib.dumps({'LCGuestBundleIdentifier': identifier}))
        results = source/'Build/seamless'
        results.mkdir()
        command = results/f'{tag}-clicks.txt.command'
        reply = Path(str(command)+'.owner-capture.json')
        artifact = results/f'{tag}-materials-owner-capture.json'
        if name == 'stale-file':
            reply.write_text(json.dumps({'nonce': 'stale must be removed'}))
        clock, signals, ps_calls, cg_calls = [0.0], [], [], []
        def run(command, **options):
            assert options['timeout'] == 2
            if command[0] == 'ps':
                ps_calls.append(command)
                assert command == ['ps', '-p', str(pid), '-ww', '-o', 'pid=,lstart=,command=']
                if name=='changed-before-signal' and len(ps_calls)==2:
                    assert command.read_text().startswith('owner-capture-report '), 'identity must be rechecked after command write'
                changed = (name=='process-changed' and len(ps_calls)>2 or name=='changed-before-signal' and len(ps_calls)>1)
                birth = '16:00:01' if changed else '16:00:00'
                location = '/Users/forbidden.app' if name == 'outside-clone' else str(bundle)
                return types.SimpleNamespace(returncode=0, stdout=f'{pid} Sat Nov 7 {birth} 2026 {location}/Contents/MacOS/SeamlessProxy\n')
            cg_calls.append(command)
            assert command == [str(results/'seamless-guest'), 'list']
            # Empty title and tiny dimensions deliberately exercise exact IDs rather than title/size selection.
            rows = f'id=456 pid={999 if name=="wrong-cg-owner" else pid} layer=0 alpha=1 owner="" title="" bounds=0,0 1x1\n'
            if name == 'duplicate-cg': rows += rows
            return types.SimpleNamespace(returncode=1 if name=='no-cg' else 0, stdout=rows)
        def kill(actual_pid, number):
            assert actual_pid == pid and number == signal.SIGUSR2
            signals.append(actual_pid)
            assert not reply.exists(), 'stale report was not removed before command'
            fields = command.read_text().split()
            assert fields[:2] == ['owner-capture-report', str(window)] and len(fields)==3
            assert str(uuid.UUID(fields[2])) == fields[2]
            if name == 'cancellation': raise SystemExit(130)
            if name == 'timeout': return
            report = dict(guestID=window, nonce=fields[2], proxyPID=pid, hostWindowID=456,
                          preflightAvailable=True, preflightAllowed=False, readCount=1,
                          width=800, height=600, failureCategory='none')
            mutations = {'fresh-wrong-nonce': {'nonce':str(uuid.uuid4())}, 'wrong-guest':{'guestID':43},
                         'wrong-pid':{'proxyPID':124},'bad-host-id':{'hostWindowID':0},'zero-reads':{'readCount':0},
                         'boolean-reads':{'readCount':True},'zero-dimensions':{'height':0},
                         'capture-error':{'failureCategory':'captureTimedOut'},'unexpected-payload':{'pixels':'must not retain'}}
            report.update(mutations.get(name,{}))
            if name == 'no-preflight-api':
                report['preflightAvailable']=False
                del report['preflightAllowed']
            if name == 'oversize':
                reply.write_text('x'*16385)
            elif name == 'symlink':
                target = results/'unread.txt'
                target.write_text('must not follow')
                reply.symlink_to(target)
            elif name == 'fifo':
                os.mkfifo(reply,0o600)  # No writer: O_RDONLY without O_NONBLOCK would hang before fstat.
            else:
                reply.write_text(json.dumps(report))
        ns.update(source=source, tag=tag, results=results, guest_tool=results/'seamless-guest',
                  subprocess=types.SimpleNamespace(run=run),
                  os=types.SimpleNamespace(kill=kill,open=os.open,fdopen=os.fdopen,fstat=os.fstat,
                                           O_RDONLY=os.O_RDONLY,O_NOFOLLOW=os.O_NOFOLLOW,O_NONBLOCK=os.O_NONBLOCK),
                  time=types.SimpleNamespace(monotonic=lambda:clock[0],sleep=lambda value:clock.__setitem__(0,clock[0]+value)),
                  request=lambda *args: (_ for _ in ()).throw(AssertionError('owner proof must not use guest channel')))
        with contextlib.redirect_stdout(io.StringIO()):
            try:
                passed = ns['qualify_owner_capture'](0x100000000 if name=='oversize-guest-id' else window,pid)
            except SystemExit as error:
                assert name=='cancellation' and error.code==130
                passed=False
        assert passed == (name in ('success','no-preflight-api','stale-file')), name
        saved = json.loads(artifact.read_text())
        assert saved['result'] == ('PASS_ONE_IMAGE' if passed else 'FAIL')
        assert command.read_text()=='' and clock[0]<=5.1
        assert len(signals) <= 1 and len(cg_calls)<=1
        if name in ('wrong-bundle','outside-clone','changed-before-signal','oversize-guest-id'): assert not signals
        if name=='fresh-wrong-nonce': assert len(signals)==1 and not cg_calls
        if name=='timeout': assert clock[0]>=5 and saved['result']=='FAIL'
        if name=='unexpected-payload': assert 'must not retain' not in artifact.read_text()
        if passed:
            assert saved['owned_cg_record']=={'hostWindowID':456,'proxyPID':pid}
    print(f'PASS owner proof: {len(cases)} mocked identity/nonce/CG/schema/deadline/cancellation cases, no guest calls')


def lifecycle_checks(root):
    for mode in ('default','owner-pass','owner-fail','ambiguous-toggle'):
        ns=load()
        results=root/mode
        results.mkdir()
        tag,window,pid='fixture',42,123
        command=results/f'{tag}-clicks.txt.command'
        materials=Path(str(command)+'.materials')
        events,checks,requests=[],[],[]
        clock=[0.0]
        def kill(actual_pid,number):
            assert actual_pid==pid and number==signal.SIGUSR2 and command.read_text()=='materials-report'
            events.append('materials')
            materials.write_text('mock material report')
        def owner(actual_window,actual_pid):
            assert actual_window==window and actual_pid==pid and not requests
            events.append('owner')
            return mode!='owner-fail'
        def request(value,timeout):
            requests.append(value)
            if value.get('Action')=='seamless-toggle':
                events.append('toggle-off')
                if mode=='ambiguous-toggle': raise SystemExit('Timed out waiting for toggle')
                return {}
            assert requests[0].get('Action')=='seamless-toggle'
            events.append('agent-released')
            return {'ExitCode':0,'Stdout':'gpu mode 0 retained\nbackdrop id 42 order 0 material 1 \n'}
        ns.update(results=results,tag=tag,qualify_owner_capture=owner,request=request,
                  os=types.SimpleNamespace(kill=kill), material_report=lambda text:{42:(1,1,True)},
                  time=types.SimpleNamespace(monotonic=lambda:clock[0],sleep=lambda value:clock.__setitem__(0,clock[0]+value)))
        with contextlib.redirect_stdout(io.StringIO()):
            try:
                ns['qualify_material_fixture']('/fixed/tool',window,
                    lambda:['id=456 pid=123 owner="SeamlessMaterials (fixture)"'],
                    lambda description,value:checks.append((description,value)),owner_capture=mode!='default')
            except SystemExit:
                assert mode=='ambiguous-toggle' and len(requests)==1
            else:
                assert mode!='ambiguous-toggle'
        expected=['materials']+(['owner'] if mode!='default' else [])+['toggle-off']
        if mode!='ambiguous-toggle': expected+=['agent-released']
        assert events==expected and command.read_text()==''
        if mode=='owner-fail': assert any(not value for label,value in checks)
        elif mode!='ambiguous-toggle': assert all(value for label,value in checks)
    print('PASS lifecycle: default unchanged; proof before toggle; proof failure restores; ambiguous toggle never retried')


def main():
    def timeout(number, frame):
        raise SystemExit('FAIL owner-proof test exceeded its deadline; possible blocking FIFO open')
    previous=signal.signal(signal.SIGALRM,timeout)
    signal.alarm(15)
    try:
        with tempfile.TemporaryDirectory(prefix='lightclick-owner-materials-test-') as temporary:
            root=Path(temporary)
            owner_checks(root)
            lifecycle_checks(root)
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM,previous)


if __name__=='__main__':
    main()
