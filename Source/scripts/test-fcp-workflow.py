#!/usr/bin/env python3
"""No-guest tests of frozen-source composition and exact generated-XML open routing."""
import ast
import copy
import json
import plistlib
import tempfile
from pathlib import Path
import types
import unittest
from fcp_preflight import GUEST
from fcp_workflow import OBSERVE, PLACEHOLDER, compose_guest, replace_once, xml_template


class Checks(unittest.TestCase):
    def test_composition_keeps_existing_cleanup_and_refuses_anchor_drift(self):
        composed=compose_guest(GUEST)
        ast.parse(composed)
        self.assertEqual(composed.count('def stop(child):'),1)
        self.assertEqual(composed.count('for child in reversed(owned):'),1)
        self.assertLess(composed.index('workflow_directory=tempfile.mkdtemp'),composed.index("report['console_uid']=join_console()"))
        self.assertLess(composed.index("report['workflow']['inventory_before']"),composed.index('for child in reversed(owned):'))
        self.assertIn('for path in workflow_paths:os.chown(path,uid,user.pw_gid)',composed)
        with self.assertRaises(ValueError):compose_guest(GUEST.replace("    report['console_uid']=join_console()",''))
        with self.assertRaises(ValueError):replace_once('twice twice','twice','other')
        self.assertNotIn('AXUIElementPerformAction',composed)

    def test_xml_template_uses_builder_and_only_generated_media(self):
        import xml.etree.ElementTree as ET
        data,manifest=xml_template(Path(__file__).parents[1])
        self.assertEqual(data.count(PLACEHOLDER.encode()),1)
        actual='/private/var/tmp/LightClickFCPFixture.Abc123'
        rewritten=data.replace(PLACEHOLDER.encode(),actual.encode())
        root=ET.fromstring(rewritten)
        self.assertEqual(root.attrib['version'],'1.3')
        self.assertEqual(root.find('.//asset').attrib['src'],'file://'+actual+'/input-prores422.mov')
        self.assertEqual(manifest['expected_input']['bytes'],58747744)

    def test_ambiguous_base_observer_stage_never_ejects_or_detaches(self):
        path=Path(__file__).parents[1]/'probes/fcp-workflow-driver.py'
        tree=ast.parse(path.read_text());tree.body.pop()
        source=Path(__file__).parents[1]
        ns={'source':source};exec(compile(tree,str(path),'exec'),ns)
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary).resolve();fixture=root/'fixture.dmg';fixture.write_bytes(b'fixture')
            helper=root/'helper';helper.write_bytes(bytes.fromhex('cffaedfe07000001'))
            calls=[];stages=[];disk_lists=[0]
            base=dict(GUEST=GUEST,CASES={'mavericks-10.1':dict(variant='10.1')},checked_response=lambda r:r['Stdout'])
            def experiment():base['stage'](root/'observer')
            base['experiment']=experiment
            def stage(path):
                stages.append(path)
                if len(stages)==2:raise SystemExit('ambiguous base observer staging')
                return '/private/var/tmp/VirtualIntelMac.Abc123/Transfer.bin'
            def request(command,timeout):
                calls.append(command)
                if command.get('Action')=='insert-disc':return dict(Inserted=1)
                args=command['Arguments']
                if args==['list','-plist']:
                    disk_lists[0]+=1;value=dict(WholeDisks=['disk0']+(['disk7'] if disk_lists[0]>1 else []))
                elif args[0]=='info':value=dict(DeviceIdentifier='disk7',Internal=False,BusProtocol='USB')
                elif args[0]=='mountDisk':return dict(ExitCode=0,Stdout='mounted')
                else:value=dict(AllDisksAndPartitions=[dict(DeviceIdentifier='disk7',Partitions=[dict(VolumeName='LC_FCP_Fixture',MountPoint='/Volumes/LC_FCP_Fixture')])])
                return dict(ExitCode=0,Stdout=plistlib.dumps(value).decode())
            ns.update(FIXTURE=fixture,arguments=['mavericks-10.1',str(root/'result'),'observer',str(helper)],stage=stage,request=request,load_preflight=lambda *args:base)
            with self.assertRaisesRegex(SystemExit,'ambiguous base observer'):ns['run_workflow']()
            self.assertEqual(len(stages),2)
            self.assertEqual([c for c in calls if c.get('Action')=='insert-disc'],[dict(Action='insert-disc',Path=str(fixture),Slot=1)])
            self.assertFalse(any(c.get('Arguments',[''])[0]=='eject' for c in calls))

    def test_optional_action_targets_exact_owned_dialog_and_private_fixture(self):
        for wrong_after_pid in (False,True):
            calls=[];inventories=[0]
            inventory=dict(result='MENU_INVENTORY',identityMatched=1,identityStillMatched=1,axTrusted=1,pid=321,variant='10.1',mode='inventory')
            def command(argv,seconds):
                calls.append((argv,seconds))
                if argv[0]=='/own/ax-workload':
                    inventories[0]+=1;value=dict(inventory)
                    if wrong_after_pid and inventories[0]==2:value['pid']=999
                    return json.dumps(value).encode()
                if argv[0]=='/own/ax-actions':return json.dumps(dict(result='NEW_LIBRARY_PANEL_OBSERVED_REQUIRES_REVIEW')).encode()
                return b''
            directory='/private/var/tmp/LightClickFCPFixture.Abc123'
            report=dict(workflow=dict(import_attempted=False))
            ns=dict(app=types.SimpleNamespace(pid=321,poll=lambda:None),report=report,command=command,json=json,
                    os=types.SimpleNamespace(path=types.SimpleNamespace(lexists=lambda p:False,isdir=lambda p:False,islink=lambda p:False)),
                    time=types.SimpleNamespace(time=lambda:0,sleep=lambda sec:None),launched_at=0,workflow_directory=directory,
                    spec=dict(workflow_helper='/own/ax-workload',workflow_action_helper='/own/ax-actions',variant='10.1',app='/Applications/Final Cut Pro.app'),xml_path=directory+'/generated.fcpxml')
            exec(compile('if True:\n'+OBSERVE,'<production optional library action>','exec'),ns)
            actions=[call for call in calls if call[0][0]=='/own/ax-actions']
            if wrong_after_pid:self.assertEqual(actions,[])
            else:
                self.assertEqual(actions,[(['/own/ax-actions','10.1','321','new-private-library',directory],20)])
                self.assertFalse(report['workflow']['library_artifact']['exists'])
                self.assertIn('inventory_after_library_action',report['workflow'])
                self.assertNotIn('PASS',json.dumps(report))

    def test_open_exact_own_xml_only_after_trusted_inventory(self):
        for trusted in (1,0,'1'):
            calls=[];clock=[0]
            inventory=dict(result='MENU_INVENTORY',identityMatched=1,identityStillMatched=1,axTrusted=trusted,pid=321,variant='10.1',mode='inventory')
            def command(argv,seconds):
                calls.append((argv,seconds))
                return json.dumps(inventory).encode() if argv[0]=='/own/ax-workload' else b''
            report=dict(workflow=dict(import_attempted=False))
            xml='/private/var/tmp/LightClickFCPFixture.Abc123/generated.fcpxml'
            ns=dict(app=types.SimpleNamespace(pid=321,poll=lambda:None),report=report,command=command,json=json,
                    time=types.SimpleNamespace(time=lambda:clock[0],sleep=lambda sec:clock.__setitem__(0,clock[0]+sec)),
                    launched_at=0,spec=dict(workflow_helper='/own/ax-workload',variant='10.1',app='/Applications/Final Cut Pro.app'),xml_path=xml)
            exec(compile('if True:\n'+OBSERVE,'<production live-app hook>','exec'),ns)
            if trusted==1 and type(trusted) is int:
                self.assertEqual(calls[1],(['/usr/bin/open','-a','/Applications/Final Cut Pro.app',xml],10))
                self.assertEqual(calls[-1],(['/own/ax-workload','10.1','321','inventory'],14))
                self.assertTrue(report['workflow']['import_attempted'])
                self.assertIn('inventory_after_open',report['workflow'])
            else:
                self.assertEqual(len(calls),1)
                self.assertFalse(report['workflow']['import_attempted'])
            self.assertNotIn('PASS',json.dumps(report))


if __name__=='__main__':unittest.main()
