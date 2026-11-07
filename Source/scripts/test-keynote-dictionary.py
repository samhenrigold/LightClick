#!/usr/bin/env python3
"""Local metadata/files/protocol mocks only: no app, tool extraction, guest, VM, or build execution."""
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
    path=Path(__file__).resolve().parents[1]/'probes/keynote-dictionary-driver.py'
    tree=ast.parse(path.read_text())
    tree.body=[node for node in tree.body if isinstance(node,(ast.Import,ast.ImportFrom,ast.FunctionDef,ast.Assign))]
    ns={}
    exec(compile(tree,str(path),'exec'),ns)
    return ns


def guest_functions(driver):
    tree=ast.parse(driver['COLLECTOR'])
    tree.body=[node for node in tree.body if isinstance(node,(ast.Import,ast.FunctionDef)) or isinstance(node,ast.Assign)
               and any(isinstance(target,ast.Name) and target.id in ('APP','SUFFIXES') for target in node.targets)]
    ns={}
    exec(compile(tree,'fixed Keynote collector functions','exec'),ns)
    return ns


def helper_checks(root):
    ns=guest_functions(load())
    assert ns['APP']=='/Applications/Keynote.app'
    app=root/'Keynote.app'
    resources=app/'Contents/Frameworks/F.framework/Versions/A/Resources'
    resources.mkdir(parents=True)
    (resources/'actual.scriptSuite').write_bytes(b'fixed fixture bytes')
    (app/'Contents/Dictionary.sdef').write_bytes(b'<dictionary/>')
    outside=root/'outside'
    outside.mkdir()
    (outside/'secret.sdef').write_bytes(b'must not read')
    (app/'Contents/link').symlink_to(outside,target_is_directory=True)
    (app/'Contents/linked.aete').symlink_to(outside/'secret.sdef')
    ns['APP']=str(app)
    paths,walk=ns['resources']()
    assert set(paths)=={str(resources/'actual.scriptSuite'),str(app/'Contents/Dictionary.sdef')}
    assert walk['symlinks_skipped']==2 and not walk['walk_truncated']
    try: ns['read'](str(app/'Contents/linked.aete'),1000,str(app))
    except ValueError: pass
    else: raise AssertionError('symlink resource followed')
    try: ns['read'](str(outside/'secret.sdef'),1000,str(app))
    except ValueError: pass
    else: raise AssertionError('outside resource read')
    saved_os=ns['os']
    ns['os']=types.SimpleNamespace(path=os.path,listdir=lambda path:['x']*8193)
    assert ns['resources']()[1]['walk_truncated']
    ns['os']=saved_os
    for option in ('valid','owner','mode','alias','wrong-prefix'):
        directory='/private/var/tmp/LightClickKeynote.ABC123'
        info=types.SimpleNamespace(st_uid=501 if option=='owner' else 0,
                                  st_mode=stat.S_IFDIR|(0o755 if option=='mode' else 0o700))
        ns['os']=types.SimpleNamespace(lstat=lambda path:info,path=types.SimpleNamespace(realpath=lambda path:'/Users/no' if option=='alias' else path))
        try: ns['private']('/Users/no' if option=='wrong-prefix' else directory)
        except ValueError: assert option!='valid'
        else: assert option=='valid'
    ns['os']=saved_os
    for mode in ('success','timeout','launch-error'):
        directory=root/('tool-'+mode)
        directory.mkdir()
        clock,killed,limits=[0.0],[],[]
        def popen(command,**options):
            assert command==['/usr/bin/sdef',str(app)]
            assert options['close_fds'] is True
            options['preexec_fn']()
            if mode=='launch-error': raise OSError('mock unavailable sdef')
            options['stdout'].write(b'<dictionary/>');options['stdout'].flush()
            options['stderr'].write(b'full diagnostic');options['stderr'].flush()
            return types.SimpleNamespace(poll=lambda:-9 if killed else None if mode=='timeout' else 0,
                                         kill=lambda:killed.append(True))
        ns.update(subprocess=types.SimpleNamespace(Popen=popen),
                  resource=types.SimpleNamespace(RLIMIT_FSIZE=1,RLIMIT_CPU=2,setrlimit=lambda key,value:limits.append((key,value))),
                  time=types.SimpleNamespace(time=lambda:clock[0],sleep=lambda value:clock.__setitem__(0,clock[0]+value)))
        try: result=ns['extract'](str(directory))
        except OSError: assert mode=='launch-error'
        else:
            assert result['timed_out']==(mode=='timeout') and clock[0]<=17.1
            assert (directory/'sdef.stdout').read_bytes()==b'<dictionary/>'
        assert limits==[(1,(2*1024*1024,2*1024*1024)),(2,(10,10))]
    print('PASS fixed resource/framework walk, no symlink escape, private-directory checks, exact sdef argv/resource/time caps')


def protocol_checks(root):
    cases=('valid','extractor-error','wrong-directory','wrong-identity','wrong-offset','short','bad-hash',
           'bad-final-hash','oversize','duplicate','host-timeout','control-error','deadline','existing')
    payload=b'<dictionary><suite><command name="Synthetic Only" code="abcdEFGH"/></suite></dictionary>'
    large=bytes(range(256))*1536+b'tail'
    for name in cases:
        ns=load()
        destination=root/name
        destination.mkdir()
        calls,clock=[],[0.0]
        ns['time']=types.SimpleNamespace(monotonic=lambda:clock[0])
        files={'resource-000':large,'sdef-stdout':payload,'sdef-stderr':b'full extractor diagnostic'}
        descriptors=[{'selector':selector,'bytes':len(data),'identity':[1,index,len(data),1.5,2.5],
                      'sha256':hashlib.sha256(data).hexdigest()}for index,(selector,data)in enumerate(files.items())]
        if name=='bad-final-hash': descriptors[0]['sha256']='0'*64
        if name=='oversize': descriptors[0]['bytes']=2*1024*1024+1
        if name=='duplicate': descriptors.append(descriptors[0])
        if name=='existing': (destination/'resource-000.bin').write_bytes(b'preserve')
        def request(command,timeout):
            assert command['Executable']=='/usr/bin/python' and 0<timeout<=40
            arguments=command['Arguments'];assert arguments[:2]==['-c',ns['COLLECTOR']]
            calls.append(arguments[2:])
            if name=='deadline': clock[0]+=240
            if name=='host-timeout': raise SystemExit('Timed out waiting for collector')
            if name=='control-error': return {'Error':'The control response timed out.'}
            if arguments[2]=='collect':
                result={'directory':'/private/var/tmp/LightClickKeynote.ABC123',
                        'manifest':{'files':descriptors,'extractor':{'exit_code':1 if name=='extractor-error' else 0}}}
                if name=='wrong-directory': result['directory']='/Users/no'
            else:
                assert arguments[2]=='chunk' and arguments[3]=='/private/var/tmp/LightClickKeynote.ABC123'
                selector,offset,length=arguments[4],int(arguments[5]),int(arguments[6])
                expected=json.loads(arguments[7]);assert 0<length<=192*1024
                data=files[selector][offset:offset+length]
                result={'selector':selector,'offset':offset,'bytes':length,'identity':expected,
                        'sha256':hashlib.sha256(data).hexdigest(),'base64':base64.b64encode(data).decode()}
                if name=='wrong-identity': result['identity']=[0]
                elif name=='wrong-offset': result['offset']+=1
                elif name=='short': result['bytes']-=1
                elif name=='bad-hash': result['sha256']='0'*64
            return {'ExitCode':0,'Stdout':json.dumps(result)}
        ns.update(arguments=[str(destination)],request=request)
        with contextlib.redirect_stdout(io.StringIO()):
            try: ns['collect_dictionary']()
            except (Exception,SystemExit): assert name not in('valid','extractor-error')
            else: assert name in('valid','extractor-error')
        report=json.loads((destination/'keynote-dictionary.json').read_text())
        assert report['result']==('PASS_COLLECTION' if name in('valid','extractor-error') else 'INCONCLUSIVE')
        if name in('valid','extractor-error'):
            assert (destination/'resource-000.bin').read_bytes()==large
            assert report['files'][1]['dictionary']['commands'][0]['name']=='Synthetic Only'
            assert (destination/'sdef-stderr.bin').read_bytes()==files['sdef-stderr']
        if name=='existing': assert (destination/'resource-000.bin').read_bytes()==b'preserve'
        if name in('host-timeout','control-error','deadline'): assert len(calls)==1
    print(f'PASS chunk collection: {len(cases)} mocked identity/hash/cap/deadline/exclusive-output cases; extractor errors retained')


def main():
    with tempfile.TemporaryDirectory(prefix='lightclick-keynote-dictionary-test-')as temporary:
        root=Path(temporary).resolve()
        helper_checks(root)
        protocol=root/'protocol';protocol.mkdir()
        protocol_checks(protocol)


if __name__=='__main__':
    main()
