#!/usr/bin/env python3
"""Local metadata/protocol tests only; no app, guest, disk image, or production library access."""
import ast
import base64
import contextlib
import hashlib
import io
import json
from pathlib import Path
import struct
import tempfile


def load():
    path=Path(__file__).resolve().parents[1]/'probes/keynote-availability-driver.py'
    tree=ast.parse(path.read_text())
    tree.body=[node for node in tree.body if isinstance(node,(ast.Import,ast.ImportFrom,ast.Assign,ast.FunctionDef))]
    namespace={}
    exec(compile(tree,str(path),'exec'),namespace)
    return namespace


def main():
    ns=load()
    tree=ast.parse(ns['INVENTORY'])
    tree.body=[node for node in tree.body if isinstance(node,(ast.Import,ast.FunctionDef)) or
               isinstance(node,ast.Assign) and any(isinstance(target,ast.Name) and target.id in ('APPS','SYSTEM') for target in node.targets)]
    guest={'basestring':str}
    exec(compile(tree,'fixed guest metadata functions','exec'),guest)
    assert guest['APPS']==['/Applications/Keynote.app',"/Applications/iWork '09/Keynote.app",
                          "/Applications/iWork '09/Numbers.app","/Applications/iWork '09/Pages.app",
                          '/Applications/Numbers.app','/Applications/Pages.app','/Applications/Final Cut Pro.app']
    assert guest['SYSTEM']=='/System/Library/CoreServices/SystemVersion.plist'
    with tempfile.TemporaryDirectory(prefix='lightclick-keynote-metadata-test-') as temporary:
        root=Path(temporary).resolve()
        thin64=struct.pack('<IIIIIIII',0xfeedfacf,0x1000007,3,2,0,0,0,0)
        thin32=struct.pack('<IIIIIIII',0xfeedface,7,3,2,0,0,0,0)
        for name,data,width in (('x64',thin64,64),('i386',thin32,32)):
            path=root/name
            path.write_bytes(data)
            report=guest['macho'](str(path))
            assert report['slices'][0]['bits']==width and report['slices'][0]['file_type']==2
        fat=struct.pack('>II',0xcafebabe,2)+struct.pack('>IIIII',7,3,64,32,5)+struct.pack('>IIIII',0x1000007,3,128,32,5)
        fat=fat.ljust(64,b'\0')+thin32
        fat=fat.ljust(128,b'\0')+thin64
        path=root/'fat'
        path.write_bytes(fat)
        assert [item['architecture'] for item in guest['macho'](str(path))['slices']]==['i386','x86_64']
        alias=root/'alias'
        alias.symlink_to(path)
        try: guest['macho'](str(alias))
        except ValueError: pass
        else: raise AssertionError('noncanonical metadata file accepted')
        try: guest['contents'](str(path),1)
        except ValueError: pass
        else: raise AssertionError('oversize metadata accepted')
        xml=b'<dictionary><suite name="Synthetic"><command name="fixture command" code="abcdEFGH"><parameter name="target" type="file"/></command><class name="fixture" code="abcd"><property name="name" code="pnam" type="text"/></class></suite></dictionary>'
        parsed=ns['dictionary_metadata'](xml)
        assert parsed['commands'][0]['name']=='fixture command' and parsed['classes'][0]['properties'][0]['code']=='pnam'
        try: ns['dictionary_metadata'](b'<!ENTITY dangerous "value"><dictionary/>')
        except ValueError: pass
        else: raise AssertionError('entity declaration accepted')
        for case in ('present','absent','launch-error','host-timeout','changed-sdef','malformed-sdef'):
            results=root/case
            results.mkdir()
            data=b'<dictionary>' if case=='malformed-sdef' else xml
            descriptor={'resource':'Synthetic.sdef','bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()}
            calls=[]
            def request(command,timeout):
                assert command['Executable']=='/usr/bin/python' and timeout==30
                options=command['Arguments']
                assert options[:2]==['-c',ns['INVENTORY']]
                calls.append(options[2:])
                if case=='launch-error': return {'Error':'The control response timed out.'}
                if case=='host-timeout': raise SystemExit('Timed out waiting for metadata')
                if options[2]=='inventory':
                    result={'system':{'ProductVersion':'10.9.5'},'apps':[] if case=='absent' else [
                        {'index':1,'present':True,'path':"/Applications/iWork '09/Keynote.app",'sdef':[descriptor]}]}
                else:
                    assert options[2:]==['sdef','1','0']
                    result=dict(descriptor,index=1,item=0,base64=base64.b64encode(data).decode())
                    if case=='changed-sdef': result['sha256']='0'*64
                return {'ExitCode':0,'Stdout':json.dumps(result)}
            ns.update(arguments=[str(results)],request=request)
            with contextlib.redirect_stdout(io.StringIO()):
                try: ns['availability']()
                except (Exception,SystemExit):
                    assert case in ('launch-error','host-timeout','changed-sdef')
                else:
                    assert case in ('present','absent','malformed-sdef')
            report=json.loads((results/'keynote-availability.json').read_text())
            if case=='present':
                assert report['benchmark_preflight_status']=='SDEF_REVIEW_REQUIRED'
                assert (results/'app-1-sdef-0.xml').read_bytes()==xml
            elif case in ('absent','malformed-sdef'):
                assert report['benchmark_preflight_status']=='NO_USABLE_KEYNOTE_SDEF'
            else:
                assert report['result']=='INCONCLUSIVE' and report['error']
                assert len(calls)==(2 if case=='changed-sdef' else 1)
    print('PASS fixed inventory scope, 32/64/fat headers, canonical/budget refusals, dictionary metadata and six protocol outcomes')


if __name__=='__main__':
    main()
