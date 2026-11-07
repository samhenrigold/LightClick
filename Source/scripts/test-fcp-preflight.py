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
