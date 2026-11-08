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
from fcp_workflow import OBSERVE, PLACEHOLDER, compose_guest, generated_project_evidence, replace_once, xml_template


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
                    spec=dict(ax_helper='/own/ax-observe',workflow_helper='/own/ax-workload',workflow_action_helper='/own/ax-actions',variant='10.1',app='/Applications/Final Cut Pro.app'),xml_path=directory+'/generated.fcpxml')
            exec(compile('if True:\n'+OBSERVE,'<production optional library action>','exec'),ns)
            actions=[call for call in calls if call[0][0]=='/own/ax-actions']
            if wrong_after_pid:self.assertEqual(actions,[])
            else:
                self.assertEqual(actions,[(['/own/ax-actions','10.1','321','new-private-library',directory],20)])
                self.assertFalse(report['workflow']['library_artifact']['exists'])
                self.assertIn('inventory_after_library_action',report['workflow'])
                self.assertNotIn('PASS',json.dumps(report))

    def test_create_mode_has_explicit_bounded_route(self):
        calls=[]
        inventory=dict(result='MENU_INVENTORY',identityMatched=1,identityStillMatched=1,axTrusted=1,pid=321,variant='10.1',mode='inventory')
        def command(argv,seconds):
            calls.append((argv,seconds))
            return json.dumps(inventory if argv[0]=='/own/ax-workload' else {}).encode()
        directory='/private/var/tmp/LightClickFCPFixture.Abc123'
        report=dict(workflow=dict(import_attempted=False))
        ns=dict(app=types.SimpleNamespace(pid=321,poll=lambda:None),report=report,command=command,json=json,
                os=types.SimpleNamespace(path=types.SimpleNamespace(lexists=lambda p:False,isdir=lambda p:False,islink=lambda p:False)),
                time=types.SimpleNamespace(time=lambda:0,sleep=lambda sec:None),launched_at=0,workflow_directory=directory,
                spec=dict(ax_helper='/own/ax-observe',workflow_helper='/own/ax-workload',workflow_action_helper='/own/ax-actions',workflow_action_mode='create-private-library',variant='10.1',app='/Applications/Final Cut Pro.app'),xml_path=directory+'/generated.fcpxml')
        exec(compile('if True:\n'+OBSERVE,'<production explicit creation route>','exec'),ns)
        self.assertEqual([c for c in calls if c[0][0]=='/own/ax-actions'],[(['/own/ax-actions','10.1','321','create-private-library',directory],60)])
        self.assertFalse(report['workflow']['library_artifact']['exists'])
        self.assertNotIn('PASS',json.dumps(report))

    def test_creation_waits_for_read_only_editor_readiness(self):
        calls=[];reads=[0]
        inventory=dict(result='MENU_INVENTORY',identityMatched=1,identityStillMatched=1,axTrusted=1,pid=321,variant='10.1',mode='inventory')
        def command(argv,seconds):
            calls.append((argv,seconds))
            if argv[0]=='/own/ax-workload':
                reads[0]+=1
                value=dict(inventory)
                if reads[0]==3:value['result']='INCONCLUSIVE'
                if reads[0]>=4:
                    value['windows']=[dict(AXRole='AXWindow',AXSubrole='AXStandardWindow')]
                    value['fileMenu']=dict(AXRole='AXMenuItem',AXTitle='Export XML\u2026',AXEnabled=True)
                return json.dumps(value).encode()
            return b'{}'
        directory='/private/var/tmp/LightClickFCPFixture.Abc123'
        report=dict(workflow=dict(import_attempted=False))
        ns=dict(app=types.SimpleNamespace(pid=321,poll=lambda:None),report=report,command=command,json=json,
                os=types.SimpleNamespace(path=types.SimpleNamespace(lexists=lambda p:True,isdir=lambda p:True,islink=lambda p:False)),
                time=types.SimpleNamespace(time=lambda:0,sleep=lambda sec:None),launched_at=0,workflow_directory=directory,
                spec=dict(ax_helper='/own/ax-observe',workflow_helper='/own/ax-workload',workflow_action_helper='/own/ax-actions',workflow_action_mode='create-private-library',variant='10.1',app='/Applications/Final Cut Pro.app'),xml_path=directory+'/generated.fcpxml')
        exec(compile('if True:\n'+OBSERVE,'<production asynchronous import wait>','exec'),ns)
        self.assertEqual(reads[0],4)
        self.assertEqual(len([c for c in calls if c[0][0]=='/usr/bin/open']),1)
        self.assertEqual(len([c for c in calls if c[0][0]=='/own/ax-actions']),1)
        self.assertEqual([x['export_menu_available'] for x in report['workflow']['post_library_observations']],[False,True])
        self.assertTrue(report['workflow']['owned_app_alive_after_library'])
        compose_guest(GUEST).encode('ascii')

    def test_post_library_full_observation_is_once_read_only_and_owned(self):
        for outcome in ('available','observer-error','app-exited'):
            calls=[];reads=[0];alive=[True]
            inventory=dict(result='MENU_INVENTORY',identityMatched=1,identityStillMatched=1,axTrusted=1,pid=321,variant='10.1',mode='inventory')
            view=dict(result='OBSERVED_WINDOWS',pid=321,windows=[dict(AXRole='AXWindow',children=[dict(AXRole='AXStaticText',AXValue='LC-generated-8s')])],truncated=True)
            def command(argv,seconds):
                calls.append((argv,seconds))
                if argv[0]=='/own/ax-workload':
                    reads[0]+=1
                    if reads[0]==10 and outcome=='app-exited':alive[0]=False
                    return json.dumps(inventory).encode()
                if argv[0]=='/own/ax-observe':
                    if outcome=='observer-error':raise ValueError('bounded observer failed')
                    return json.dumps(view).encode()
                return b'{}'
            directory='/private/var/tmp/LightClickFCPFixture.Abc123'
            report=dict(workflow=dict(import_attempted=False))
            ns=dict(app=types.SimpleNamespace(pid=321,poll=lambda:None if alive[0]else 1),report=report,command=command,json=json,
                    os=types.SimpleNamespace(path=types.SimpleNamespace(lexists=lambda p:True,isdir=lambda p:True,islink=lambda p:False)),
                    time=types.SimpleNamespace(time=lambda:0,sleep=lambda sec:None),launched_at=0,workflow_directory=directory,
                    spec=dict(ax_helper='/own/ax-observe',workflow_helper='/own/ax-workload',workflow_action_helper='/own/ax-actions',workflow_action_mode='create-private-library',variant='10.1',app='/Applications/Final Cut Pro.app'),xml_path=directory+'/generated.fcpxml')
            exec(compile('if True:\n'+OBSERVE,'<production post-library full observation>','exec'),ns)
            full=[c for c in calls if c[0][0]=='/own/ax-observe']
            observed=report['workflow']['post_library_full_observer']
            self.assertEqual(reads[0],10) # Two initial reads plus all8 bounded readiness inventories.
            self.assertEqual(len([c for c in calls if c[0][0]=='/own/ax-actions']),1)
            self.assertEqual(len([c for c in calls if c[0][0]=='/usr/bin/open']),1)
            if outcome=='app-exited':
                self.assertEqual(full,[]);self.assertIn('exited',observed['reason'])
            else:
                self.assertEqual(full,[(['/own/ax-observe','10.1','321'],14)])
                self.assertEqual(calls[-1],full[0])
                if outcome=='available':self.assertEqual(observed,view) # Retain actual tree and its incomplete flag.
                else:self.assertFalse(observed['available']);self.assertIn('bounded observer failed',observed['reason'])
            self.assertNotIn('PASS',json.dumps(report))

    def test_generated_project_evidence_is_contextual_and_unambiguous(self):
        group=dict(AXRole='AXGroup',AXDescription='LC-generated-8s',children=[
            dict(AXRole='AXTextField',AXDescription='display name',AXValue='LC-generated-8s',AXEnabled=1),
            dict(AXRole='AXImage',AXTitle='LC-generated-8s',AXEnabled=True),
            dict(AXRole='AXLayoutItem',AXDescription='range selection',AXValue=8)])
        view=dict(result='OBSERVED_WINDOWS',version='10.1',pid=321,identityMatched=True,identityStillMatched=1,axTrusted=1,
                  windows=[dict(AXRole='AXWindow',AXSubrole='AXStandardWindow',children=[dict(AXRole='AXScrollArea',AXDescription='organizer',children=[dict(AXRole='AXGroup',AXDescription='events',children=[group])])])])
        self.assertTrue(generated_project_evidence(view,321,'10.1'))
        for field,value in [('pid',999),('version','10.4.4'),('axTrusted','1')]:
            bad=copy.deepcopy(view);bad[field]=value;self.assertFalse(generated_project_evidence(bad,321,'10.1'))
        bad=copy.deepcopy(view);bad['windows'][0]['children'][0]['AXDescription']='unrelated browser'
        self.assertFalse(generated_project_evidence(bad,321,'10.1'))
        for bad_value in (7.99,True,'8'):
            bad=copy.deepcopy(view);bad['windows'][0]['children'][0]['children'][0]['children'][0]['children'][2]['AXValue']=bad_value
            self.assertFalse(generated_project_evidence(bad,321,'10.1'))
        bad=copy.deepcopy(view);bad['windows'][0]['children'][0]['children'][0]['children'].append(copy.deepcopy(group))
        self.assertFalse(generated_project_evidence(bad,321,'10.1'))

    def test_create_and_open_routes_after_evidence_once_and_keeps_post_action_reads(self):
        group=dict(AXRole='AXGroup',AXDescription='LC-generated-8s',children=[
            dict(AXRole='AXTextField',AXDescription='display name',AXValue='LC-generated-8s',AXEnabled=1),
            dict(AXRole='AXImage',AXTitle='LC-generated-8s',AXEnabled=1),
            dict(AXRole='AXLayoutItem',AXDescription='range selection',AXValue=8)])
        view=dict(result='OBSERVED_WINDOWS',version='10.1',pid=321,identityMatched=1,identityStillMatched=1,axTrusted=1,
                  windows=[dict(AXRole='AXWindow',AXSubrole='AXStandardWindow',children=[dict(AXRole='AXScrollArea',AXDescription='organizer',children=[dict(AXRole='AXGroup',AXDescription='events',children=[group])])])])
        for outcome in ('open','missing-project','app-exited','open-error'):
            calls=[];alive=[True];full_reads=[0]
            inventory=dict(result='MENU_INVENTORY',identityMatched=1,identityStillMatched=1,axTrusted=1,pid=321,variant='10.1',mode='inventory')
            def command(argv,seconds):
                calls.append((argv,seconds))
                if argv[0]=='/own/ax-workload':return json.dumps(inventory).encode()
                if argv[0]=='/own/ax-observe':
                    full_reads[0]+=1;value=copy.deepcopy(view)
                    if outcome=='missing-project':value['windows'][0]['children']=[]
                    if outcome=='app-exited':alive[0]=False
                    return json.dumps(value).encode()
                if argv[0]=='/own/ax-actions':
                    if argv[3]=='create-private-library':return json.dumps(dict(result='PRIVATE_LIBRARY_CREATED_REQUIRES_IMPORT_REVIEW',privateLibraryVerified=1)).encode()
                    if outcome=='open-error':raise ValueError('ambiguous helper outcome after one attempt')
                    return json.dumps(dict(result='PROJECT_DOUBLE_CLICK_POSTED_REQUIRES_REVIEW')).encode()
                return b'{}'
            directory='/private/var/tmp/LightClickFCPFixture.Abc123';report=dict(workflow=dict(import_attempted=False))
            ns=dict(app=types.SimpleNamespace(pid=321,poll=lambda:None if alive[0]else 1),report=report,command=command,json=json,
                    os=types.SimpleNamespace(path=types.SimpleNamespace(lexists=lambda p:True,isdir=lambda p:True,islink=lambda p:False)),
                    time=types.SimpleNamespace(time=lambda:0,sleep=lambda sec:None),launched_at=0,workflow_directory=directory,
                    spec=dict(ax_helper='/own/ax-observe',workflow_helper='/own/ax-workload',workflow_action_helper='/own/ax-actions',workflow_action_mode='create-private-library',workflow_open_generated_project=True,variant='10.1',app='/Applications/Final Cut Pro.app'),xml_path=directory+'/generated.fcpxml')
            exec(compile('if True:\n'+OBSERVE,'<production create-and-open route>','exec'),ns)
            actions=[c for c in calls if c[0][0]=='/own/ax-actions']
            self.assertEqual(actions[0],(['/own/ax-actions','10.1','321','create-private-library',directory],60))
            self.assertEqual(len([c for c in calls if c[0][0]=='/usr/bin/open']),1)
            if outcome in ('open','open-error'):
                self.assertEqual(actions[1:], [(['/own/ax-actions','10.1','321','open-generated-project',directory],20)])
                self.assertEqual(full_reads[0],2)
                self.assertIn('post_project_open_inventory',report['workflow'])
                self.assertIn('post_project_open_full_observer',report['workflow'])
                if outcome=='open-error':self.assertIn('ambiguous helper outcome',report['workflow']['project_open_action']['reason'])
            else:
                self.assertEqual(len(actions),1);self.assertEqual(full_reads[0],1)
                self.assertNotIn('project_open_attempted',report['workflow'])
            self.assertNotIn('PASS',json.dumps(report))

    def test_invalid_creation_modes_fail_before_staging(self):
        source=Path(__file__).resolve().parents[1]
        path=source/'probes/fcp-workflow-driver.py'
        tree=ast.parse(path.read_text());tree.body.pop()
        for case,mode in (('mavericks-10.1','unknown'),('mojave-10.4.4','create-private-library'),('mojave-10.4.4','create-and-open-private-project')):
            with tempfile.TemporaryDirectory() as tmp:
                output=Path(tmp)/'result'
                ns=dict(source=source,arguments=[case,str(output),'observer','inventory','actions',mode],
                        stage=lambda *a:self.fail('invalid mode staged a helper'),request=lambda *a:self.fail('invalid mode issued a request'))
                exec(compile(tree,str(path),'exec'),ns)
                with self.assertRaisesRegex(ValueError,'grounded'):ns['run_workflow']()
                self.assertFalse(output.exists())

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
