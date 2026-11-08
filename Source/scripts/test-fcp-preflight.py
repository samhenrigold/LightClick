#!/usr/bin/env python3
"""Headless launch-qualification/parser tests. No app, process, guest, or installer execution."""
import ast
import copy
import contextlib
import io
import json
import plistlib
import tempfile
from pathlib import Path
import unittest
from fcp_preflight import GUEST, qualify_launch, wire_bool


def observed():
    ax=dict(result='OBSERVED_WINDOWS',identityMatched=True,identityStillMatched=True,axTrusted=True,windowCount=1,
            truncated=False,deadlineExceeded=False,windows=[dict(AXRole='AXWindow',AXTitle='Final Cut Pro',children=[])])
    return dict(result='OBSERVED_LAUNCH',cleanup_errors=[],app_log_at_limit=False,
                observations=[dict(alive=True,ax=copy.deepcopy(ax)) for _ in range(3)])


class Checks(unittest.TestCase):
    def test_known_native_boolean_fields_accept_only_bool_or_zero_one(self):
        for value in (True,1):self.assertTrue(wire_bool(value,True))
        for value in (False,0):self.assertTrue(wire_bool(value,False))
        for value in ('1','0','true','false',2,-1,None,1.0,0.0,[],{}):
            self.assertFalse(wire_bool(value,True));self.assertFalse(wire_bool(value,False))
        actual={'Images':[{'CanDisconnect':True,'Format':'dmg','Slot':0,'Path':'/Users/shg/Downloads/FinalCutPro-10.1.dmg'}],
                'MediaChangePending':False,'Inserted':1}
        self.assertTrue(wire_bool(actual['Inserted'],True))
        value=observed();ax=value['observations'][-1]['ax']
        for key in ('identityMatched','identityStillMatched','axTrusted'):ax[key]=1
        for key in ('truncated','deadlineExceeded'):ax[key]=0
        self.assertEqual(qualify_launch(value),'OBSERVED_WINDOWS_REQUIRES_REVIEW')
        for field in ('identityMatched','identityStillMatched','axTrusted','truncated','deadlineExceeded'):
            bad=copy.deepcopy(value);bad['observations'][-1]['ax'][field]='1' if field.startswith('identity') or field=='axTrusted' else '0'
            self.assertEqual(qualify_launch(bad),'INCONCLUSIVE')

    def test_pid_or_first_window_never_qualifies_editor(self):
        value=observed()
        self.assertEqual(qualify_launch(value),'OBSERVED_WINDOWS_REQUIRES_REVIEW')
        value['observations'][-1]['ax']={}
        self.assertEqual(qualify_launch(value),'INCONCLUSIVE')
        value=observed();value['observations'][1]['alive']=False
        self.assertEqual(qualify_launch(value),'EXITED_OR_INCOMPLETE')
        value=observed();value['observations'][-1]['ax']['identityStillMatched']=False
        self.assertEqual(qualify_launch(value),'INCONCLUSIVE')

    def test_nested_graphics_alerts_first_run_and_incomplete_observation(self):
        value=observed();value['observations'][-1]['ax']['windows'][0]['children']=[dict(AXRole='AXStaticText',AXValue='The graphics configuration is not supported')]
        self.assertEqual(qualify_launch(value),'BLOCKED_GRAPHICS_OR_COMPATIBILITY')
        value=observed();value['observations'][-1]['ax']['windows'][0]['AXSubrole']='AXDialog'
        self.assertEqual(qualify_launch(value),'BLOCKED_OR_FIRST_RUN_DIALOG')
        for field in ('truncated','deadlineExceeded'):
            value=observed();value['observations'][-1]['ax'][field]=True
            self.assertEqual(qualify_launch(value),'INCONCLUSIVE')
        value=observed();value['cleanup_errors']=['owned process alive']
        self.assertEqual(qualify_launch(value),'INCONCLUSIVE')

    def test_ambiguous_request_never_followed_by_eject_or_retry(self):
        path=Path(__file__).parents[1]/'probes/fcp-install-preflight-driver.py'
        nodes=ast.parse(path.read_text()).body
        ns={'source':Path(__file__).parents[1]};exec(compile(ast.Module(body=nodes[:-1],type_ignores=[]),str(path),'exec'),ns)
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary).resolve();dmg=root/'image.dmg';dmg.write_bytes(b'fixture')
            helper=root/'helper';helper.write_bytes(bytes.fromhex('cffaedfe07000001'))
            case=copy.deepcopy(ns['CASES']['mavericks-10.1']);case['dmg']=str(dmg)
            ns['CASES']={'mavericks-10.1':case};calls=[]
            def request(command,timeout):
                calls.append(command)
                if command.get('Executable')=='/usr/sbin/diskutil':return dict(ExitCode=0,Stdout=plistlib.dumps(dict(WholeDisks=['disk0'])).decode())
                if command.get('Action')=='insert-disc':return dict(Images=[dict(CanDisconnect=True,Format='dmg',Slot=0,Path=str(dmg))],MediaChangePending=False,Inserted=1)
                raise SystemExit('ambiguous collector timeout')
            ns.update(arguments=['mavericks-10.1',str(root/'results'),str(helper)],stage=lambda p:'/private/var/tmp/VirtualIntelMac.Abc123/Transfer.bin',request=request)
            with self.assertRaisesRegex(SystemExit,'ambiguous'):ns['experiment']()
            self.assertEqual(len(calls),3)
            self.assertEqual([x for x in calls if x.get('Action')=='insert-disc'],[dict(Action='insert-disc',Path=str(dmg),Slot=0)])
            self.assertEqual(json.loads((root/'results/result.json').read_text())['result'],'INCONCLUSIVE')

    def test_production_identity_decodes_real_binary_and_xml_info_without_rewriting(self):
        import hashlib, os, shutil, signal, stat, subprocess, sys, threading, time, types
        provided=Path('/private/tmp/lightclick-fcp1044-package-metadata/selected/Info.plist')
        expected=dict(CFBundleIdentifier='com.apple.FinalCutTrial',CFBundleShortVersionString='10.4.4',CFBundleVersion='330236',CFBundleExecutable='Final Cut Pro Trial')
        # Always exercise a real binary plist and XML through production plutil, even outside this scratch checkout.
        original=provided.read_bytes() if provided.is_file() else plistlib.dumps(expected,fmt=plistlib.FMT_BINARY)
        self.assertTrue(original.startswith(b'bplist00'))
        expected_from_source={key:plistlib.loads(original).get(key) for key in expected}
        self.assertEqual(expected_from_source,expected)
        functions=[node for node in ast.parse(GUEST).body if isinstance(node,ast.FunctionDef) and node.name in ('stop','limits','reader','captured','command','identity')]
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary).resolve();app=root/'Final Cut Pro Trial.app';(app/'Contents').mkdir(parents=True)
            path=app/'Contents/Info.plist'
            ns=dict(os=os,subprocess=subprocess,threading=threading,time=time,signal=signal,stat=stat,CAP=131072,owned=[],report={'commands':[]},plistlib=types.SimpleNamespace(readPlistFromString=plistlib.loads))
            exec(compile(ast.Module(body=functions,type_ignores=[]),'<production identity>','exec'),ns)
            for kind,data in (('binary',original),('xml',plistlib.dumps(plistlib.loads(original),fmt=plistlib.FMT_XML))):
                with self.subTest(kind=kind):
                    path.write_bytes(data);before=hashlib.sha256(path.read_bytes()).hexdigest()
                    self.assertEqual(ns['identity'](str(app)),expected)
                    self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(),before)
                    self.assertEqual(ns['report']['commands'][-1]['argv'],['/usr/bin/plutil','-convert','xml1','-o','-',str(path)])

    def test_historical_trial_signature_recorded_before_explicit_clone_installer(self):
        node=next(node for node in ast.parse(GUEST).body if isinstance(node,ast.FunctionDef) and node.name=='install_trial')
        calls=[];report={'commands':[]}
        def command(argv,seconds,allowed=(0,)):
            calls.append((argv,seconds,allowed))
            report['commands'].append(dict(argv=argv,exit_code=1,stdout='untrusted certificate',stderr=''))
        ns=dict(command=command,report=report);exec(compile(ast.Module(body=[node],type_ignores=[]),'<production trial install>','exec'),ns)
        payload='/Volumes/Trial/FinalCutProXTrial.pkg';ns['install_trial'](payload)
        self.assertEqual(calls[0],(['/usr/sbin/pkgutil','--check-signature',payload],20,None))
        self.assertEqual(calls[1],(['/usr/sbin/installer','-allowUntrusted','-pkg',payload,'-target','/'],840,(0,)))
        self.assertEqual(report['package_signature']['exit_code'],1)
        self.assertIn('certificate',report['package_signature']['stdout'])
        path=Path(__file__).parents[1]/'probes/fcp-install-preflight-driver.py'
        tree=ast.parse(path.read_text())
        requests=[node for node in ast.walk(tree) if isinstance(node,ast.Dict) and any(isinstance(v,ast.List) and v.elts and isinstance(v.elts[0],ast.Constant) and v.elts[0].value=='eject' for v in node.values)]
        self.assertEqual(len(requests),1)
        arguments=next(value for key,value in zip(requests[0].keys,requests[0].values) if isinstance(key,ast.Constant) and key.value=='Arguments')
        self.assertEqual(eval(compile(ast.Expression(arguments),'<production eject route>','eval'),{'device':'disk7'}),['eject','/dev/disk7'])

    def test_actual_trial_distribution_package_id_not_application_id(self):
        import xml.etree.ElementTree as ET
        node=next(node for node in ast.parse(GUEST).body if isinstance(node,ast.FunctionDef) and node.name=='validate_package_metadata')
        ns={};exec(compile(ast.Module(body=[node],type_ignores=[]),'<production package validator>','exec'),ns)
        # Minimal transcription of the supplied PackageInfo/Distribution attributes; no vendor XML copied.
        package=ET.fromstring('<pkg-info identifier="com.apple.pkg.FinalCutProXTrial" version="10.4.4.0.1.1539134424"/>')
        distribution=ET.fromstring('<installer-gui-script><choices-outline/><pkg-ref id="com.apple.pkg.FinalCutTrial">#FinalCutProXTrial.pkg</pkg-ref><pkg-ref id="com.apple.pkg.FinalCutTrial" installKBytes="3738794" version="10.4.4.0.1.1539134424"/></installer-gui-script>')
        self.assertEqual(ns['validate_package_metadata'](package,distribution)['identifier'],'com.apple.pkg.FinalCutProXTrial')
        for key,value in (('id','com.apple.FinalCutTrial'),('version','10.4.4')):
            bad=copy.deepcopy(distribution);bad[-1].set(key,value)
            with self.assertRaisesRegex(ValueError,'Distribution'):ns['validate_package_metadata'](package,bad)
        package.set('identifier','com.apple.FinalCutTrial')
        with self.assertRaisesRegex(ValueError,'package'):ns['validate_package_metadata'](package,distribution)

    def test_diagnostic_pipe_cap_does_not_limit_payload_files(self):
        import os, subprocess, sys, threading, time
        nodes=ast.parse(GUEST).body
        functions=[node for node in nodes if isinstance(node,ast.FunctionDef) and node.name in ('stop','limits','reader','captured','command')]
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);payload=root/'payload'
            ns=dict(os=os,subprocess=subprocess,threading=threading,time=time,signal=__import__('signal'),CAP=131072,owned=[],report={'commands':[]})
            exec(compile(ast.Module(body=functions,type_ignores=[]),'<guest command functions>','exec'),ns)
            data=ns['command']([sys.executable,'-c','import sys;open(sys.argv[1],"wb").write(b"x"*300000);print("ok")',str(payload)],5)
            self.assertEqual(data,b'ok\n');self.assertEqual(payload.stat().st_size,300000)
            with self.assertRaises(ValueError):ns['command']([sys.executable,'-c','print("x"*300000)'],5)
            self.assertTrue(ns['report']['commands'][-1]['at_limit'])
            self.assertLessEqual(len(ns['report']['commands'][-1]['stdout']),131072)

    def test_fixed_install_contract_and_guest_syntax(self):
        tree=ast.parse(GUEST)
        self.assertTrue(tree.body)
        self.assertNotIn('killall',GUEST)
        self.assertNotIn('AXUIElementPerformAction',GUEST)
        path=Path(__file__).parents[1]/'probes/fcp-install-preflight-driver.py'
        nodes=ast.parse(path.read_text()).body
        # Evaluate only imports/definitions/table, never the driver call.
        ns={'source':Path(__file__).parents[1]};exec(compile(ast.Module(body=nodes[:-1],type_ignores=[]),str(path),'exec'),ns)
        self.assertEqual(set(ns['CASES']),{'mavericks-10.1','mojave-10.4.4'})
        self.assertEqual(ns['CASES']['mavericks-10.1']['identity']['CFBundleVersion'],'238755')
        self.assertEqual(ns['CASES']['mojave-10.4.4']['identity']['CFBundleVersion'],'330236')
        with self.assertRaises(ValueError):ns['checked_response'](dict(ExitCode=1,Stdout=''))
        with self.assertRaises(ValueError):ns['checked_response'](dict(ExitCode=0,Stdout='x'*(2*1024*1024+1)))


if __name__=='__main__':unittest.main()
