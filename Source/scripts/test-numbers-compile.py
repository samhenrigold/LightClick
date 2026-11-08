#!/usr/bin/env python3
"""Local source-provenance/parser/control tests; no applications or guests launched."""
import ast
import base64
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import resource
import signal
import subprocess
import sys
import tempfile
import threading
import time


def load():
    source=Path(__file__).resolve().parents[1]
    path=source/'probes/numbers-compile-driver.py'
    tree=ast.parse(path.read_text())
    tree.body=[n for n in tree.body if not isinstance(n,ast.Expr)]
    ns={};exec(compile(tree,str(path),'exec'),ns)
    return source,ns


def main():
    source,ns=load()
    original,script=ns['compile_source'](source)
    expected=original.replace(b'/Applications/iWork \'09/Numbers.app',b'/Applications/Numbers.app')
    assert script==expected and script!=original
    assert b'set value of cell "B3"' in script and b'POSIX file (path of candidate)' in script
    collector=ast.parse(ns['COLLECTOR'])
    # Both encoded sources are compileable Python syntax; test never runs collector.
    assert collector
    directory='/private/var/tmp/LightClickNumbersCompile.ABC123'
    assert 'RLIMIT_FSIZE' not in ns['COLLECTOR']
    good={'result':'PASS_COMPILE_ONLY','private_directory':directory,'cleanup_errors':[],'app_log_at_limit':False,
          'compiler':{'argv':['/usr/bin/osacompile','-o',directory+'/cell-repaint.scpt',directory+'/cell-repaint.applescript'],
                      'exit_code':0,'timed_out':False,'at_limit':False,'readers_finished':True},'compiled':{'bytes':42,'sha256':'a'*64}}
    def response(report):return {'ExitCode':0,'Stdout':json.dumps(report)}
    assert ns['parse_response'](response(good))==good
    rejected=[{'Error':'The control response timed out.'},{'ExitCode':1,'Stdout':'diagnostic'},
              {'ExitCode':0,'Stdout':'not json'},{'ExitCode':0,'Stdout':'x'*300001}]
    for field,value in [('result','INCONCLUSIVE'),('private_directory','/Users/example'),('cleanup_errors',['unreaped']),('app_log_at_limit',True)]:
        bad=dict(good);bad[field]=value;rejected.append(response(bad))
    for field,value in [('exit_code',1),('timed_out',True),('at_limit',True),('readers_finished',False),('argv',['/usr/bin/osascript','fixture'])]:
        bad=dict(good,compiler=dict(good['compiler'],**{field:value}));rejected.append(response(bad))
    for value in ({'bytes':0,'sha256':'a'*64},{'bytes':True,'sha256':'a'*64},{'bytes':1048577,'sha256':'a'*64},{'bytes':42,'sha256':'invalid'}):
        rejected.append(response(dict(good,compiled=value)))
    for invalid in rejected:
        try:ns['parse_response'](invalid)
        except (ValueError,TypeError):pass
        else:raise AssertionError('accepted invalid compiler/control report')
    with tempfile.TemporaryDirectory(prefix='lightclick-numbers-compile-test-')as temporary:
        root=Path(temporary)
        # Execute only production pipe/process helpers, never collector main, Numbers, or AppleScript.
        helpers={name:globals()[name] for name in ('os','resource','signal','subprocess','threading','time')}
        helpers.update(CAP=65536,owned=[],report={'commands':[]})
        definitions=[n for n in collector.body if isinstance(n,ast.FunctionDef) and n.name in ('reader','captured','limits','command','stop')]
        exec(compile(ast.Module(body=definitions,type_ignores=[]),'Numbers collector helpers','exec'),helpers)
        home=root/'headless-home';home.mkdir(mode=0o700)
        env=dict(os.environ,HOME=str(home),CFFIXED_USER_HOME=str(home),TMPDIR=str(home)+'/')
        payload=home/'legitimate-cache'
        childcode="import sys;open(sys.argv[1],'wb').write(b'x'*200000);sys.stdout.write('small diagnostic')"
        try:
            result=helpers['command']([sys.executable,'-c',childcode,str(payload)],10,str(home),env)
            assert result['exit_code']==0 and result['stdout']=='small diagnostic' and not result['at_limit']
            assert payload.stat().st_size==200000
            # App launch uses limits() directly, without any process-wide file-size restriction either.
            with open(os.devnull,'rb')as null:
                child=subprocess.Popen([sys.executable,'-c',childcode,str(payload)],stdin=null,stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE,env=env,preexec_fn=helpers['limits'],close_fds=True)
            helpers['owned'].append(child)
            out,err=helpers['reader'](child.stdout),helpers['reader'](child.stderr)
            assert child.wait(timeout=10)==0
            assert helpers['captured'](out)['text']=='small diagnostic'
            assert helpers['captured'](err)['reader_finished']
            assert payload.stat().st_size==200000
            # Fast-exiting output floods still fail rather than silently accepting truncated diagnostics.
            for stream in ('stdout','stderr'):
                flood="import sys;sys.%s.write('x'*200000)"%stream
                try:helpers['command']([sys.executable,'-c',flood],10,str(home),env)
                except ValueError:pass
                else:raise AssertionError('accepted over-cap '+stream)
                row=helpers['report']['commands'][-1]
                assert row['at_limit'] and len(row[stream].encode())<=65536
            # A still-running flood is stopped through only its owned session/group, not left behind.
            flood="import sys,time;sys.stdout.write('x'*200000);sys.stdout.flush();time.sleep(30)"
            try:helpers['command']([sys.executable,'-c',flood],10,str(home),env)
            except ValueError:pass
            else:raise AssertionError('accepted running output flood')
            assert helpers['owned'][-1].poll() is not None
            assert helpers['report']['commands'][-1]['at_limit']
        finally:
            for child in reversed(helpers['owned']):helpers['stop'](child)
        changed=root/'altered';(changed/'probes').mkdir(parents=True)
        (changed/'probes/iwork-cell-repaint.applescript').write_bytes(b'tell application "unexpected"')
        try:ns['compile_source'](changed)
        except ValueError:pass
        else:raise AssertionError('accepted changed source application literal')
        for outcome in ('pass','compiler-fail','control-timeout'):
            results=root/outcome;results.mkdir();calls=[]
            def request(command,timeout):
                calls.append(command)
                assert timeout==75 and command['Executable']=='/usr/bin/python'
                argv=command['Arguments'];assert argv[:2]==['-c',ns['COLLECTOR']]
                assert base64.b64decode(argv[2])==script
                assert argv[3]==hashlib.sha256(script).hexdigest()
                if outcome=='control-timeout':raise SystemExit('ambiguous control timeout')
                return response(good if outcome=='pass'else dict(good,result='INCONCLUSIVE',error='compile failed'))
            ns.update(source=source,arguments=[str(results)],request=request)
            with contextlib.redirect_stdout(io.StringIO()):
                try:ns['preflight']()
                except (Exception,SystemExit):assert outcome!='pass'
                else:assert outcome=='pass'
            report=json.loads((results/'numbers-compile.json').read_text())
            assert len(calls)==1 # no ambiguous retry
            if outcome=='pass':assert report['result']=='PASS_COMPILE_ONLY'
            elif outcome=='compiler-fail':assert report['response']['Stdout'] and report['error']
            else:assert 'ambiguous control timeout'in report['error'] and 'response'not in report
    print('PASS Numbers compile-only provenance/control, unrestricted 200KB child payloads, bounded diagnostic pipes and owned cleanup')


if __name__=='__main__':main()
