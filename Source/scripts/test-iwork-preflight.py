#!/usr/bin/env python3
"""Mock the real composed inventory/dictionary drivers; no apps, guests, tools, builds or VM operations."""
import ast
import base64
import contextlib
import hashlib
import io
import json
from pathlib import Path
import shutil
import tempfile


def load():
    source=Path(__file__).resolve().parents[1]
    path=source/'probes/iwork-preflight-driver.py'
    tree=ast.parse(path.read_text())
    tree.body=[node for node in tree.body if isinstance(node,(ast.Import,ast.ImportFrom,ast.FunctionDef,ast.Assign))]
    ns={};exec(compile(tree,str(path),'exec'),ns)
    return source,ns


def main():
    with tempfile.TemporaryDirectory(prefix='lightclick-iwork-preflight-test-')as temporary:
        root=Path(temporary)
        for case in ('two-apps','absent','missing-version','dictionary-timeout'):
            repository,ns=load()
            source=root/case
            (source/'probes').mkdir(parents=True)
            for name in ('keynote-availability-driver.py','keynote-dictionary-driver.py'):
                shutil.copyfile(repository/'probes'/name,source/'probes'/name)
            results=source/'results';results.mkdir()
            helper=source/'compiled-helper';helper.write_bytes(b'fixed helper fixture only; not executed')
            apps=[]
            for index,path in enumerate(('/Applications/Numbers.app',"/Applications/iWork '09/Pages.app",'/Applications/Final Cut Pro.app')):
                bundle={'CFBundleIdentifier':f'actual.fixture.{index}','CFBundleShortVersionString':f'observed-{index}',
                        'CFBundleVersion':f'observed-build-{index}'}
                if case=='missing-version' and index==0:del bundle['CFBundleVersion']
                apps.append({'index':index,'path':path,'present':case!='absent','bundle':bundle,'sdef':[],
                             'macho':{'slices':[{'architecture':'i386'}]}})
            stages,calls=[],[]
            xml=b'<dictionary><suite name="Synthetic Only"><command name="fixture operation" code="abcdEFGH"/></suite></dictionary>'
            identity=[1,2,len(xml),1.5,2.5]
            def stage(path):
                stages.append(path);assert path==helper
                return '/private/var/tmp/VirtualIntelMac.ABC123/Transfer.bin'
            def request(command,timeout):
                assert command['Executable']=='/usr/bin/python'
                arguments=command['Arguments'];assert arguments[0]=='-c'
                operation=arguments[2];calls.append(operation)
                if operation=='inventory':
                    return {'ExitCode':0,'Stdout':json.dumps({'system':{'ProductVersion':'10.9.5'},'apps':apps})}
                if operation=='collect-native-target':
                    assert len(stages)==1
                    if case=='dictionary-timeout':raise SystemExit('Timed out waiting for dictionary')
                    assert arguments[3:5]==['/private/var/tmp/VirtualIntelMac.ABC123/Transfer.bin',hashlib.sha256(helper.read_bytes()).hexdigest()]
                    selector,location=arguments[5:7]
                    assert (selector,location)in(('numbers','direct'),('pages','iwork09'))
                    expected=json.loads(arguments[7]);actual=next(app for app in apps if app['path']==expected['path'])
                    assert all(expected[key]==actual['bundle'][key]for key in('CFBundleIdentifier','CFBundleVersion','CFBundleShortVersionString'))
                    descriptor={'selector':'sdef-native','bytes':len(xml),'identity':identity,'sha256':hashlib.sha256(xml).hexdigest()}
                    return {'ExitCode':0,'Stdout':json.dumps({'directory':'/private/var/tmp/LightClickKeynote.ABC123',
                        'manifest':{'files':[descriptor],'extractor':{'mode':'native-osa','exit_code':0}}})}
                assert operation=='chunk'
                assert arguments[3:7]==['/private/var/tmp/LightClickKeynote.ABC123','sdef-native','0',str(len(xml))]
                return {'ExitCode':0,'Stdout':json.dumps({'selector':'sdef-native','offset':0,'bytes':len(xml),
                    'identity':identity,'sha256':hashlib.sha256(xml).hexdigest(),'base64':base64.b64encode(xml).decode()})}
            ns.update(source=source,arguments=[str(results),str(helper)],stage=stage,request=request)
            with contextlib.redirect_stdout(io.StringIO()):
                try:ns['preflight']()
                except (Exception,SystemExit):assert case in('missing-version','dictionary-timeout')
                else:assert case in('two-apps','absent')
            report=json.loads((results/'iwork-preflight.json').read_text())
            if case=='two-apps':
                assert report['result']=='COLLECTED_UNREVIEWED'and len(report['targets'])==2
                assert len(stages)==1 and calls==['inventory','collect-native-target','chunk','collect-native-target','chunk']
                for target in report['targets']:
                    assert target['collection_result']=='PASS_COLLECTION'
                    assert target['dictionaries'][0]['dictionary']['commands'][0]['name']=='fixture operation'
            elif case=='absent':
                assert report['result']=='NO_NUMBERS_OR_PAGES'and not stages and calls==['inventory']
            else:
                assert report['result']=='INCONCLUSIVE'and report['error']
                if case=='dictionary-timeout':assert calls==['inventory','collect-native-target']and len(stages)==1
                else:assert calls==['inventory']and not stages
    print('PASS composed inventory+actual dictionary transport: fixed targets/actual versions, one helper stage, serial extraction, absent/error/timeout handling')


if __name__=='__main__':main()
