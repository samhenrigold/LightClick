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
from fcp_workflow import OBSERVE, PLACEHOLDER, RETENTION_HELPERS, hold_retained_display_window, compose_guest, complete_hid_open, generated_project_evidence, replace_once, xml_template


def ready_inventory(**values):
    result=dict(result='MENU_INVENTORY',identityMatched=1,identityStillMatched=1,axTrusted=1,pid=321,variant='10.1',mode='inventory',fileLabelMatches=1,
                fileMenu=dict(AXRole='AXMenuBarItem',AXTitle='File',children=[dict(AXRole='AXMenu',children=[dict(AXRole='AXMenuItem',AXTitle='New')])]))
    result.update(values);return result


class Checks(unittest.TestCase):
    def test_composition_keeps_existing_cleanup_and_refuses_anchor_drift(self):
        composed=compose_guest(GUEST)
        ast.parse(composed)
        self.assertEqual(composed.count('def stop(child):'),1)
        self.assertEqual(composed.count('for child in reversed(owned):'),1)
        self.assertLess(composed.index('workflow_directory=tempfile.mkdtemp'),composed.index("report['console_uid']=join_console()"))
        self.assertLess(composed.index("report['workflow']['inventory_before']"),composed.index('errors=cleanup_for_workflow(owned,app,spec,report)'))
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
            inventory=ready_inventory(result='MENU_INVENTORY',identityMatched=1,identityStillMatched=1,axTrusted=1,pid=321,variant='10.1',mode='inventory')
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
        inventory=ready_inventory(result='MENU_INVENTORY',identityMatched=1,identityStillMatched=1,axTrusted=1,pid=321,variant='10.1',mode='inventory')
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
        inventory=ready_inventory(result='MENU_INVENTORY',identityMatched=1,identityStillMatched=1,axTrusted=1,pid=321,variant='10.1',mode='inventory')
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
            inventory=ready_inventory(result='MENU_INVENTORY',identityMatched=1,identityStillMatched=1,axTrusted=1,pid=321,variant='10.1',mode='inventory')
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
        for outcome in ('open','hid-open','missing-project','app-exited','open-error'):
            calls=[];alive=[True];full_reads=[0]
            inventory=ready_inventory(result='MENU_INVENTORY',identityMatched=1,identityStillMatched=1,axTrusted=1,pid=321,variant='10.1',mode='inventory')
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
                    return json.dumps(dict(result='PROJECT_HID_DOUBLE_CLICK_POSTED_REQUIRES_REVIEW'if argv[3]=='open-generated-project-hid'else'PROJECT_DOUBLE_CLICK_POSTED_REQUIRES_REVIEW')).encode()
                return b'{}'
            directory='/private/var/tmp/LightClickFCPFixture.Abc123';report=dict(workflow=dict(import_attempted=False))
            ns=dict(app=types.SimpleNamespace(pid=321,poll=lambda:None if alive[0]else 1),report=report,command=command,json=json,
                    os=types.SimpleNamespace(path=types.SimpleNamespace(lexists=lambda p:True,isdir=lambda p:True,islink=lambda p:False)),
                    time=types.SimpleNamespace(time=lambda:0,sleep=lambda sec:None),launched_at=0,workflow_directory=directory,
                    spec=dict(ax_helper='/own/ax-observe',workflow_helper='/own/ax-workload',workflow_action_helper='/own/ax-actions',workflow_action_mode='create-private-library',workflow_open_generated_project=True,workflow_open_project_hid=outcome=='hid-open',variant='10.1',app='/Applications/Final Cut Pro.app'),xml_path=directory+'/generated.fcpxml')
            exec(compile('if True:\n'+OBSERVE,'<production create-and-open route>','exec'),ns)
            actions=[c for c in calls if c[0][0]=='/own/ax-actions']
            self.assertEqual(actions[0],(['/own/ax-actions','10.1','321','create-private-library',directory],60))
            self.assertEqual(len([c for c in calls if c[0][0]=='/usr/bin/open']),1)
            if outcome in ('open','hid-open','open-error'):
                self.assertEqual(actions[1:], [(['/own/ax-actions','10.1','321','open-generated-project-hid'if outcome=='hid-open'else'open-generated-project',directory],20)])
                self.assertEqual(full_reads[0],2)
                self.assertIn('post_project_open_inventory',report['workflow'])
                self.assertIn('post_project_open_full_observer',report['workflow'])
                if outcome=='open-error':self.assertIn('ambiguous helper outcome',report['workflow']['project_open_action']['reason'])
            else:
                self.assertEqual(len(actions),1);self.assertEqual(full_reads[0],1)
                self.assertNotIn('project_open_attempted',report['workflow'])
            self.assertNotIn('PASS',json.dumps(report))

    def test_retention_stdio_has_no_inherited_pipes_and_defaults_keep_readers(self):
        import os
        calls=[];readers=[]
        child=types.SimpleNamespace(stdout='stdout pipe',stderr='stderr pipe')
        pipe=object()
        def popen(argv,**kwargs):
            self.assertEqual(argv,['/fixed/app'])
            self.assertTrue(kwargs['close_fds'])
            self.assertEqual(os.fstat(kwargs['stdin'].fileno()).st_rdev,os.stat(os.devnull).st_rdev)
            if kwargs['stdout'] is not pipe:
                self.assertEqual(os.fstat(kwargs['stdout'].fileno()).st_rdev,os.stat(os.devnull).st_rdev)
                self.assertIs(kwargs['stdout'],kwargs['stderr'])
            calls.append(kwargs);return child
        ns=dict(os=os,subprocess=types.SimpleNamespace(Popen=popen,PIPE=pipe),limits=lambda:None,
                reader=lambda stream:readers.append(stream)or('reader',stream))
        exec(RETENTION_HELPERS,ns)
        report={};app,log=ns['launch_for_workflow']('/fixed/app',{},dict(workflow_retain_owned_app=True),report)
        self.assertIs(app,child);self.assertIsNone(log);self.assertEqual(readers,[])
        self.assertFalse(report['app_stdio']['available']);self.assertIsNone(report['app_log_at_limit'])
        self.assertTrue(calls[0]['stdin'].closed);self.assertTrue(calls[0]['stdout'].closed)
        report={};app,log=ns['launch_for_workflow']('/fixed/app',{},dict(workflow_retain_owned_app=False),report)
        self.assertEqual(readers,['stdout pipe','stderr pipe']);self.assertIsNotNone(log);self.assertNotIn('app_stdio',report)

    def test_retention_identity_and_private_fixture_gate(self):
        import re,stat
        directory='/private/var/tmp/LightClickFCPFixture.ABC123';executable='/Applications/Final Cut Pro.app/Contents/MacOS/Final Cut Pro'
        metadata={directory:types.SimpleNamespace(st_mode=stat.S_IFDIR|0o700,st_uid=501),
                  directory+'/input-prores422.mov':types.SimpleNamespace(st_mode=stat.S_IFREG|0o600,st_uid=501,st_size=58747744),
                  directory+'/generated.fcpxml':types.SimpleNamespace(st_mode=stat.S_IFREG|0o600,st_uid=501,st_size=1000),
                  directory+'/private.fcpbundle':types.SimpleNamespace(st_mode=stat.S_IFDIR|0o700,st_uid=501)}
        report=dict(result='OBSERVED_LAUNCH',app_stdio=dict(policy='devnull'),workflow=dict(directory=directory,project_open_evidence_gate=True,project_open_attempted=True,
            library_action=dict(result='PRIVATE_LIBRARY_CREATED_REQUIRES_IMPORT_REVIEW',privateLibraryVerified=1),
            project_open_action=dict(result='PROJECT_DOUBLE_CLICK_POSTED_REQUIRES_REVIEW',mode='open-generated-project',variant='10.1',pid=321,identityMatched=1,identityStillMatched=1,axTrusted=1,
                                     actionsPerformed=[dict(api='CGEventPostToPSN',targetPID=321,psnHigh=0,psnLow=73746)])))
        spec=dict(workflow_retain_owned_app=True,variant='10.1',app='/Applications/Final Cut Pro.app',identity=dict(CFBundleExecutable='Final Cut Pro'))
        ns=dict(re=re,stat=stat,os=types.SimpleNamespace(lstat=lambda path:metadata[path],getuid=lambda:501,getpgid=lambda pid:pid,path=types.SimpleNamespace(realpath=lambda path:path)))
        exec(RETENTION_HELPERS,ns);ns['current_executable']=lambda pid:executable
        app=types.SimpleNamespace(pid=321,poll=lambda:None)
        receipt=ns['owned_retention_receipt'](app,spec,report)
        self.assertTrue(receipt['retained']);self.assertEqual(receipt['pid'],321);self.assertEqual(receipt['executable'],executable)
        self.assertEqual(receipt['helper_psn'],dict(high=0,low=73746));self.assertEqual(receipt['project_open_result'],'PROJECT_DOUBLE_CLICK_POSTED_REQUIRES_REVIEW')
        hid=copy.deepcopy(report);hid_spec=dict(spec,workflow_open_project_hid=True)
        opened=hid['workflow']['project_open_action'];opened.update(mode='open-generated-project-hid',result='PROJECT_HID_DOUBLE_CLICK_POSTED_REQUIRES_REVIEW',
            actionsPerformed=[dict(action='doubleClick',api='CGEventPost(kCGHIDEventTap)',targetPID=321,psnHigh=0,psnLow=73746,eventsPosted=4,downsPosted=2,upsPosted=2,balancedRelease=1)])
        self.assertEqual(ns['owned_retention_receipt'](app,hid_spec,hid)['mode'],'create-open-hid-and-retain-for-display')
        opened['actionsPerformed'][0]['upsPosted']=1;self.assertIsNone(ns['owned_retention_receipt'](app,hid_spec,hid))
        opened['actionsPerformed'][0]['upsPosted']=2;opened['result']='PROJECT_HID_DOUBLE_CLICK_PARTIAL_UNCONFIRMED'
        self.assertIsNone(ns['owned_retention_receipt'](app,hid_spec,hid))

        for field,value in [('error','setup failed'),('result','INCONCLUSIVE'),('app_stdio',dict(policy='pipes'))]:
            bad=copy.deepcopy(report);bad[field]=value;self.assertIsNone(ns['owned_retention_receipt'](app,spec,bad))
        bad=copy.deepcopy(report);bad['workflow']['project_open_evidence_gate']=False
        self.assertIsNone(ns['owned_retention_receipt'](app,spec,bad))
        bad=copy.deepcopy(report);bad['workflow']['project_open_action']['pid']=999
        self.assertIsNone(ns['owned_retention_receipt'](app,spec,bad))
        self.assertIsNone(ns['owned_retention_receipt'](types.SimpleNamespace(pid=321,poll=lambda:1),spec,report))
        ns['current_executable']=lambda pid:'/unexpected/app';self.assertIsNone(ns['owned_retention_receipt'](app,spec,report))
        ns['current_executable']=lambda pid:executable
        metadata[directory+'/private.fcpbundle'].st_mode=stat.S_IFLNK|0o777
        self.assertIsNone(ns['owned_retention_receipt'](app,spec,report))
        metadata[directory+'/private.fcpbundle'].st_mode=stat.S_IFDIR|0o700
        metadata[directory].st_uid=0;self.assertIsNone(ns['owned_retention_receipt'](app,spec,report))

    def test_retention_cleanup_skips_only_app_after_helpers_and_never_on_failure(self):
        for outcome in ('retain','normal','bad-setup','helper-failed','receipt-error'):
            app=object();before=object();after=object();stopped=[];checks=[]
            def stop(child):
                stopped.append(child)
                if outcome=='helper-failed' and child is after:raise ValueError('helper cleanup failed')
            def receipt(*args):
                checks.append(list(stopped))
                if outcome=='receipt-error':raise ValueError('identity read failed')
                return dict(retained=True,pid=321)if outcome=='retain'else None
            ns=dict(stop=stop);exec(RETENTION_HELPERS,ns);ns['owned_retention_receipt']=receipt
            report={};errors=ns['cleanup_for_workflow']([before,app,after],app,dict(workflow_retain_owned_app=outcome!='normal'),report)
            if outcome=='retain':
                self.assertEqual(stopped,[after,before]);self.assertEqual(checks,[[after,before]]);self.assertTrue(report['retained_owned_app']['retained'])
            else:self.assertEqual(set(stopped),{before,app,after});self.assertNotEqual(report.get('retained_owned_app',{}).get('retained'),True)
            self.assertEqual(bool(errors),outcome=='helper-failed')

    def test_retention_host_window_is_finite_and_issues_no_commands(self):
        clock=[100.];sleeps=[];saved=[];evidence={}
        def sleep(seconds):sleeps.append(seconds);clock[0]+=seconds
        hold_retained_display_window(evidence,lambda:saved.append(clock[0]),clock=lambda:clock[0],sleep=sleep)
        self.assertEqual(clock[0],190.);self.assertTrue(all(0<value<=.25 for value in sleeps));self.assertEqual(len(saved),2)
        self.assertEqual(evidence['retained_display_observation']['limit_seconds'],90)
        self.assertFalse(evidence['retained_display_observation']['timing_qualified'])

    def test_retain_outer_mode_routes_then_leaves_channel_quiet_for_vm_cleanup(self):
        for workflow_mode in ('create-open-and-retain-for-display','create-open-hid-and-retain-for-display'):
            from fcp_workflow import valid_retention_receipt
            path=Path(__file__).parents[1]/'probes/fcp-workflow-driver.py';tree=ast.parse(path.read_text());tree.body.pop()
            source=Path(__file__).parents[1];ns={'source':source};exec(compile(tree,str(path),'exec'),ns)
            with tempfile.TemporaryDirectory() as temporary:
                root=Path(temporary).resolve();fixture=root/'fixture.dmg';fixture.write_bytes(b'fixture')
                helper=root/'helper';helper.write_bytes(bytes.fromhex('cffaedfe07000001'))
                calls=[];disk_lists=[0];holds=[];opened_result=[]
                spec=dict(variant='10.1',app='/Applications/Final Cut Pro.app',identity=dict(CFBundleExecutable='Final Cut Pro'))
                base=dict(GUEST=GUEST,CASES={'mavericks-10.1':spec},checked_response=lambda r:r['Stdout'])
                def experiment():
                    configured=base['CASES']['mavericks-10.1']
                    self.assertTrue(configured['workflow_retain_owned_app']);self.assertTrue(configured['workflow_open_generated_project'])
                    self.assertEqual(configured['workflow_action_mode'],'create-private-library')
                    self.assertEqual(configured['workflow_open_project_hid'],workflow_mode.endswith('hid-and-retain-for-display'))
                    self.assertEqual(configured['workflow_close_system_memory_notice'],workflow_mode.endswith('hid-and-retain-for-display'))
                    output=Path(base['arguments'][1]);output.mkdir()
                    directory='/private/var/tmp/LightClickFCPFixture.ABC123'
                    opened=dict(mode='open-generated-project-hid'if workflow_mode.endswith('hid-and-retain-for-display')else'open-generated-project',pid=321,result='PROJECT_HID_DOUBLE_CLICK_POSTED_REQUIRES_REVIEW'if workflow_mode.endswith('hid-and-retain-for-display')else'PROJECT_DOUBLE_CLICK_POSTED_REQUIRES_REVIEW',actionsPerformed=[dict(action='doubleClick',api='CGEventPost(kCGHIDEventTap)',targetPID=321,eventsPosted=4,downsPosted=2,upsPosted=2,balancedRelease=True)])
                    guest=dict(owned_app_pid=321,cleanup_errors=[],workflow=dict(directory=directory,project_open_attempted=True,project_open_action=opened),
                        retained_owned_app=dict(retained=True,mode=workflow_mode,pid=321,executable='/Applications/Final Cut Pro.app/Contents/MacOS/Final Cut Pro',fixture_directory=directory,private_library=directory+'/private.fcpbundle',process_group=321,max_host_observation_seconds=90,app_stdio_available=False))
                    opened_result.append(opened['result'])
                    # stage() enriches only preflight's local spec, never the CASES table.
                    self.assertNotIn('ax_helper_sha256',configured)
                    completed_spec=dict(configured,ax_helper_sha256='a'*64,ax_helper='/private/var/tmp/VirtualIntelMac.Def456/Transfer.bin')
                    guest['retained_owned_app']['console_uid']=501
                    guest['retained_owned_app']['readonly_observer']=dict(path='/private/var/tmp/LightClickFCP.ABC123/ax-observe',sha256='a'*64,bytes=12345,uid=501,private_home='/private/var/tmp/LightClickFCP.ABC123/home')
                    self.assertFalse(valid_retention_receipt(guest,configured))
                    self.assertTrue(valid_retention_receipt(guest,completed_spec))
                    self.assertFalse(valid_retention_receipt(guest,dict(completed_spec,ax_helper_sha256='b'*64)))
                    (output/'result.json').write_text(json.dumps(dict(result='INCONCLUSIVE',spec=completed_spec,guest=guest)))
                base['experiment']=experiment
                def request(command,timeout):
                    calls.append(command)
                    if command.get('Action')=='insert-disc':return dict(Inserted=1)
                    args=command['Arguments']
                    if args==['list','-plist']:
                        disk_lists[0]+=1;value=dict(WholeDisks=['disk0']+(['disk7']if disk_lists[0]>1 else []))
                    elif args[0]=='info':value=dict(DeviceIdentifier='disk7',Internal=False,BusProtocol='USB')
                    elif args[0]=='mountDisk':return dict(ExitCode=0,Stdout='mounted')
                    else:value=dict(AllDisksAndPartitions=[dict(DeviceIdentifier='disk7',Partitions=[dict(VolumeName='LC_FCP_Fixture',MountPoint='/Volumes/LC_FCP_Fixture')])])
                    return dict(ExitCode=0,Stdout=plistlib.dumps(value).decode())
                def hold(evidence,save):holds.append(len(calls));save()
                ns.update(FIXTURE=fixture,arguments=['mavericks-10.1',str(root/'result'),'observer',str(helper),str(helper),workflow_mode],
                          stage=lambda p:'/private/var/tmp/VirtualIntelMac.Abc123/Transfer.bin',request=request,load_preflight=lambda *a:base,hold_retained_display_window=hold)
                ns['run_workflow']()
                self.assertEqual(holds,[len(calls)])
                self.assertEqual(len([c for c in calls if c.get('Action')=='insert-disc']),1)
                self.assertFalse(any(c.get('Arguments',[''])[0]=='eject'for c in calls))
                evidence=json.loads((root/'result/result.json').read_text());self.assertEqual(evidence['result'],'RETAINED_OWNED_APP_FOR_DISPLAY_DIAGNOSTIC')
                self.assertEqual(evidence['workflow']['project_open_action']['result'],opened_result[0])

    def test_system_utility_gate_only_signals_one_verified_system_pid(self):
        import errno,re,signal,stat
        allowed='/System/Library/CoreServices/Memory Slot Utility.app/Contents/MacOS/Memory Slot Utility'
        for case in ('disabled','wrong-darwin','absent','terminate','wrong-path','wrong-owner','ambiguous','bad-status','permission','timeout','pid-changed','truncated','duplicate-alias','wrong-path-alias'):
            clock=[0.];queries=[];signals=[];reads=[];report=dict(commands=[]);sent=[False]
            def command(argv,seconds,allowed_codes):
                self.assertEqual(argv[:2],['/usr/bin/pgrep','-x']);self.assertEqual(seconds,3);self.assertEqual(allowed_codes,(0,1));queries.append(argv)
                present=case!='absent'and argv[-1]=='Memory Slot Utility'
                if case in ('truncated','wrong-path-alias'):present=argv[-1]=='Memory Slot Util'
                if case=='duplicate-alias':present=argv[-1]in('Memory Slot Utility','Memory Slot Util')
                text='123\n'if present else ''
                if case=='ambiguous'and not present:text='124\n'
                if case=='bad-status'and present:text=''
                code=0 if present or text else 1
                report['commands'].append(dict(exit_code=code,stdout=text));return text.encode()
            def executable(pid):
                self.assertEqual(pid,123)
                if case in ('wrong-path','wrong-path-alias'):return '/Users/not-permitted/Memory Slot Utility'
                if case=='pid-changed'and sent[0]:return '/System/Library/CoreServices/Other.app/Contents/MacOS/Other'
                return allowed
            def metadata(path):
                reads.append(path);self.assertEqual(path,allowed)
                return types.SimpleNamespace(st_mode=stat.S_IFREG|0o755,st_uid=501 if case=='wrong-owner'else 0)
            def kill(pid,number):
                self.assertEqual(pid,123)
                if number==signal.SIGTERM:
                    signals.append((pid,number));sent[0]=True
                    if case=='permission':raise OSError(errno.EPERM,'not owner')
                elif number==0:
                    if case not in ('timeout','pid-changed'):raise OSError(errno.ESRCH,'gone')
                else:self.fail('unexpected delivered signal')
            ns=dict(re=re,stat=stat,signal=signal,command=command,time=types.SimpleNamespace(time=lambda:clock[0],sleep=lambda t:clock.__setitem__(0,clock[0]+t)),
                    os=types.SimpleNamespace(uname=lambda:('Darwin','','14.0'if case=='wrong-darwin'else'13.4'),lstat=metadata,kill=kill,path=types.SimpleNamespace(realpath=lambda p:p)))
            exec(RETENTION_HELPERS,ns);ns['current_executable']=executable
            try:ns['close_system_memory_notice'](dict(workflow_close_system_memory_notice=case!='disabled',variant='10.1'),report)
            except (ValueError,OSError):self.assertIn(case,('wrong-darwin','wrong-path','wrong-owner','ambiguous','bad-status','permission','timeout','pid-changed','wrong-path-alias'))
            else:self.assertIn(case,('disabled','absent','terminate','truncated','duplicate-alias'))
            if case=='disabled':self.assertFalse(queries);self.assertNotIn('system_memory_notice',report)
            elif case=='absent':self.assertEqual(report['system_memory_notice']['result'],'ABSENT')
            elif case in ('terminate','truncated','duplicate-alias'):self.assertEqual(report['system_memory_notice']['result'],'TERMINATED');self.assertEqual(signals,[(123,signal.SIGTERM)])
            else:self.assertEqual(report['system_memory_notice']['result'],'FAILED')
            self.assertLessEqual(len(signals),1)
            if case in ('disabled','wrong-darwin','absent','wrong-path','wrong-owner','ambiguous','bad-status','wrong-path-alias'):self.assertFalse(signals)
            if case in ('wrong-path','wrong-path-alias'):self.assertEqual(reads,[]) # Never stat/read an unexpected or /Users path.
            if case=='timeout':self.assertEqual(clock[0],3);self.assertEqual(signals,[(123,signal.SIGTERM)])
        composed=compose_guest(GUEST)
        self.assertLess(composed.index("report['console_uid']=join_console()"),composed.index('    close_system_memory_notice(spec,report)'))
        self.assertLess(composed.index('    close_system_memory_notice(spec,report)'),composed.index('    app,log=launch_for_workflow'))

    def test_hid_retention_requires_all_events_and_balanced_release(self):
        action=dict(action='doubleClick',api='CGEventPost(kCGHIDEventTap)',targetPID=321,eventsPosted=4,downsPosted=2,upsPosted=2,balancedRelease=1)
        report=dict(mode='open-generated-project-hid',result='PROJECT_HID_DOUBLE_CLICK_POSTED_REQUIRES_REVIEW',pid=321,actionsPerformed=[action])
        self.assertTrue(complete_hid_open(report,321))
        for field,value in [('eventsPosted',2),('downsPosted',1),('upsPosted',1),('balancedRelease',False),('balancedRelease','1'),('targetPID',999)]:
            bad=copy.deepcopy(report);bad['actionsPerformed'][0][field]=value;self.assertFalse(complete_hid_open(bad,321))
        for field,value in [('result','PROJECT_HID_DOUBLE_CLICK_PARTIAL_UNCONFIRMED'),('mode','open-generated-project'),('pid',999)]:
            bad=copy.deepcopy(report);bad[field]=value;self.assertFalse(complete_hid_open(bad,321))
        ns={};exec(RETENTION_HELPERS,ns);self.assertTrue(ns['complete_hid_open'](report,321))

    def test_readonly_observer_receipt_is_private_bounded_and_hash_checked(self):
        import hashlib,os,re,stat
        with tempfile.TemporaryDirectory(prefix='lightclick-observer-receipt-')as temporary:
            parent=Path(temporary).resolve();parent.chmod(0o700);home=parent/'home';home.mkdir(mode=0o700)
            observer=parent/'ax-observe';data=b'readonly observer receipt fixture; never executed';observer.write_bytes(data);observer.chmod(0o755)
            guest='/private/var/tmp/LightClickFCP.ABC123'
            def local(path):return str(parent)+path[len(guest):]if path.startswith(guest)else path
            def canonical(path):
                value=os.path.realpath(local(path))
                return guest+value[len(str(parent)):]if value==str(parent)or value.startswith(str(parent)+'/')else value
            # Virtual guest prefix maps to this test's permitted host temporary directory.
            guest_os=types.SimpleNamespace(path=types.SimpleNamespace(dirname=os.path.dirname,realpath=canonical),
                lstat=lambda path:os.lstat(local(path)),open=lambda path,flags:os.open(local(path),flags),
                fstat=os.fstat,fdopen=os.fdopen,dup=os.dup,close=os.close,getuid=os.getuid,
                O_RDONLY=os.O_RDONLY,O_NOFOLLOW=os.O_NOFOLLOW,O_NONBLOCK=os.O_NONBLOCK)
            spec=dict(ax_helper=guest+'/ax-observe',ax_helper_sha256=hashlib.sha256(data).hexdigest())
            ns=dict(os=guest_os,re=re,stat=stat,hashlib=hashlib);exec(RETENTION_HELPERS,ns)
            receipt=ns['readonly_observer_receipt'](spec)
            self.assertEqual(receipt['path'],guest+'/ax-observe');self.assertEqual(receipt['bytes'],len(data));self.assertEqual(receipt['private_home'],guest+'/home')
            self.assertIsNone(ns['readonly_observer_receipt']({}))
            for bad in (dict(spec,ax_helper='/Users/forbidden/ax-observe'),dict(spec,ax_helper=guest+'/arbitrary-helper'),dict(spec,ax_helper_sha256='0'*64)):
                with self.assertRaises(ValueError):ns['readonly_observer_receipt'](bad)
            observer.unlink();observer.symlink_to(home)
            with self.assertRaises(ValueError):ns['readonly_observer_receipt'](spec)
            observer.unlink();observer.write_bytes(data);observer.chmod(0o755);parent.chmod(0o755)
            with self.assertRaises(ValueError):ns['readonly_observer_receipt'](spec)

    def test_initial_menu_readiness_is_bounded_read_only_and_precedes_xml_open(self):
        for case in ('already-ready','slow-ready','exited','identity-changed','deadline','attempt-limit','command-failed'):
            clock=[0.];alive=[True];opened=[False];reads=[0];calls=[];sleeps=[];report=dict(workflow=dict(import_attempted=False))
            def command(argv,seconds):
                calls.append((argv,seconds))
                if argv[0]=='/usr/bin/open':
                    self.assertEqual(report['workflow']['initial_menu_readiness']['result'],'READY')
                    self.assertGreaterEqual(reads[0],4 if case=='slow-ready'else 1)
                    opened[0]=True;return b''
                self.assertEqual(argv,['/own/ax-workload','10.1','321','inventory'])
                if opened[0]:return json.dumps(ready_inventory()).encode()
                reads[0]+=1;self.assertLessEqual(seconds,14);self.assertLessEqual(seconds,90-clock[0])
                if case=='command-failed':raise ValueError('acknowledged observer command failed')
                if case=='deadline':clock[0]+=seconds
                elif case!='attempt-limit':clock[0]+=1
                value=ready_inventory()
                if case not in ('already-ready','slow-ready')or(case=='slow-ready'and reads[0]<4):
                    value.update(result='INCONCLUSIVE',fileLabelMatches=0);value.pop('fileMenu',None)
                if case=='identity-changed'and reads[0]==2:value['pid']=999
                return json.dumps(value).encode()
            def sleep(seconds):
                sleeps.append(seconds)
                if case!='attempt-limit':clock[0]+=seconds
                if case=='exited'and seconds==2:alive[0]=False
            directory='/private/var/tmp/LightClickFCPFixture.ABC123'
            ns=dict(app=types.SimpleNamespace(pid=321,poll=lambda:None if alive[0]else 1),report=report,command=command,json=json,
                    time=types.SimpleNamespace(time=lambda:clock[0],sleep=sleep),launched_at=0,
                    spec=dict(workflow_helper='/own/ax-workload',variant='10.1',app='/Applications/Final Cut Pro.app'),xml_path=directory+'/generated.fcpxml')
            exec(compile('if True:\n'+OBSERVE,'<production bounded initial menu readiness>','exec'),ns)
            readiness=report['workflow']['initial_menu_readiness'];opens=[c for c in calls if c[0][0]=='/usr/bin/open']
            self.assertLessEqual(len(readiness['polls']),45);self.assertLessEqual(readiness['elapsed_seconds'],90)
            if case in ('already-ready','slow-ready'):
                self.assertEqual(len(opens),1);self.assertEqual(readiness['result'],'READY')
                self.assertEqual(len(readiness['polls']),1 if case=='already-ready'else 4)
                if case=='already-ready':self.assertNotIn(2,sleeps) # No new wait in the established ready path.
                else:self.assertEqual(report['workflow']['inventory_before']['result'],'INCONCLUSIVE');self.assertEqual(readiness['elapsed_seconds'],10)
            else:
                self.assertEqual(opens,[]);self.assertFalse(report['workflow']['import_attempted'])
                expected={'exited':'OWNED_APP_EXITED','identity-changed':'IDENTITY_CHANGED_OR_UNAVAILABLE','deadline':'DEADLINE','attempt-limit':'ATTEMPT_LIMIT','command-failed':'COMMAND_FAILED'}[case]
                self.assertEqual(readiness['result'],expected)
            if case=='deadline':self.assertEqual(readiness['elapsed_seconds'],90);self.assertEqual(readiness['polls'][-1]['timeout_seconds'],10)
            if case=='attempt-limit':self.assertEqual(reads[0],45)
            if case=='command-failed':self.assertIn('acknowledged observer command failed',readiness['polls'][0]['error'])

    def test_master_share_inspection_is_one_guarded_call_after_fresh_project_views(self):
        group=dict(AXRole='AXGroup',AXDescription='LC-generated-8s',children=[dict(AXRole='AXTextField',AXDescription='display name',AXValue='LC-generated-8s',AXEnabled=1),dict(AXRole='AXImage',AXTitle='LC-generated-8s',AXEnabled=1),dict(AXRole='AXLayoutItem',AXDescription='range selection',AXValue=8)])
        view=dict(result='OBSERVED_WINDOWS',version='10.1',pid=321,identityMatched=1,identityStillMatched=1,axTrusted=1,windows=[dict(AXRole='AXWindow',AXSubrole='AXStandardWindow',children=[dict(AXRole='AXScrollArea',AXDescription='organizer',children=[dict(AXRole='AXGroup',AXDescription='events',children=[group])])])])
        for case in ('inspect','partial-hid','wrong-full-pid','wrong-menu-pid','exited','modal','helper-error'):
            calls=[];opened=[False];full_reads=[0];alive=[True]
            def command(argv,seconds):
                calls.append((argv,seconds))
                if argv[0]=='/own/ax-workload':
                    return json.dumps(ready_inventory(pid=999 if opened[0]and case=='wrong-menu-pid'else 321)).encode()
                if argv[0]=='/own/ax-observe':
                    full_reads[0]+=1;current=copy.deepcopy(view)
                    if opened[0]and case=='wrong-full-pid':current['pid']=999
                    if opened[0]and case=='exited':alive[0]=False
                    if opened[0]and case=='modal':current['windows'].append(dict(AXRole='AXWindow',AXSubrole='AXDialog'))
                    return json.dumps(current).encode()
                if argv[0]=='/own/ax-actions':
                    if argv[3]=='create-private-library':return json.dumps(dict(result='PRIVATE_LIBRARY_CREATED_REQUIRES_IMPORT_REVIEW',privateLibraryVerified=1)).encode()
                    if argv[3]=='open-generated-project-hid':
                        opened[0]=True
                        return json.dumps(dict(mode='open-generated-project-hid',result='PROJECT_HID_DOUBLE_CLICK_PARTIAL_UNCONFIRMED'if case=='partial-hid'else'PROJECT_HID_DOUBLE_CLICK_POSTED_REQUIRES_REVIEW',pid=321,actionsPerformed=[dict(action='doubleClick',api='CGEventPost(kCGHIDEventTap)',targetPID=321,eventsPosted=2 if case=='partial-hid'else 4,downsPosted=1 if case=='partial-hid'else 2,upsPosted=1 if case=='partial-hid'else 2,balancedRelease=True)])).encode()
                    self.assertEqual(argv[3],'inspect-master-share');self.assertEqual(seconds,28)
                    if case=='helper-error':raise ValueError('share action unconfirmed')
                    return json.dumps(dict(mode='inspect-master-share',result='MASTER_SHARE_PRESS_SENT_REQUIRES_PANE_REVIEW',exportAttempted=False,nextOrSavePressed=False,sharePanels=[dict(AXTitle='Master File')])).encode()
                return b'{}'
            directory='/private/var/tmp/LightClickFCPFixture.ABC123';report=dict(workflow=dict(import_attempted=False))
            ns=dict(complete_hid_open=complete_hid_open,app=types.SimpleNamespace(pid=321,poll=lambda:None if alive[0]else 1),report=report,command=command,json=json,
                    os=types.SimpleNamespace(path=types.SimpleNamespace(lexists=lambda p:True,isdir=lambda p:True,islink=lambda p:False)),
                    time=types.SimpleNamespace(time=lambda:0,sleep=lambda sec:None),launched_at=0,workflow_directory=directory,
                    spec=dict(ax_helper='/own/ax-observe',workflow_helper='/own/ax-workload',workflow_action_helper='/own/ax-actions',workflow_action_mode='create-private-library',workflow_open_generated_project=True,workflow_open_project_hid=True,workflow_inspect_master_share=True,workflow_retain_owned_app=False,variant='10.1',app='/Applications/Final Cut Pro.app'),xml_path=directory+'/generated.fcpxml')
            exec(compile('if True:\n'+OBSERVE,'<production one-shot master share>','exec'),ns)
            actions=[c for c in calls if c[0][0]=='/own/ax-actions']
            self.assertEqual([c[0][3]for c in actions[:2]],['create-private-library','open-generated-project-hid'])
            if case in ('inspect','helper-error'):
                self.assertEqual([c[0][3]for c in actions[2:]],['inspect-master-share'])
                if case=='inspect':self.assertFalse(report['workflow']['master_share_inspection']['exportAttempted'])
                else:self.assertIn('unconfirmed',report['workflow']['master_share_inspection']['reason'])
            else:self.assertEqual(len(actions),2)
            self.assertEqual(full_reads[0],2)
            self.assertNotIn('retained_owned_app',report)
            self.assertNotIn('PASS',json.dumps(report))

    def test_master_share_mode_routes_hid_without_retaining_app(self):
        source=(Path(__file__).resolve().parents[1]/'probes/fcp-workflow-driver.py').read_text()
        tree=ast.parse(source);function=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='run_workflow')
        stop=next(i for i,n in enumerate(function.body) if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='output' for t in n.targets))
        function.body=function.body[:stop]+[ast.Return(value=ast.Dict(keys=[ast.Constant(k)for k in ('inspect_share','hid_project','retain_app','open_project','action_mode')],values=[ast.Name(id=k,ctx=ast.Load())for k in ('inspect_share','hid_project','retain_app','open_project','action_mode')]))]
        extracted=ast.fix_missing_locations(ast.Module(body=[function],type_ignores=[]));namespace={}
        exec(compile(extracted,'<actual outer Share routing>','exec'),namespace)
        for mode,share,hid,retain in [('create-open-hid-inspect-master-share',True,True,False),('create-open-hid-and-retain-for-display',False,True,True),('create-and-open-private-project',False,False,False)]:
            namespace['arguments']=['mavericks-10.1','/own/results','observer','workload','actions',mode]
            self.assertEqual(namespace['run_workflow'](),dict(inspect_share=share,hid_project=hid,retain_app=retain,open_project=True,action_mode='create-private-library'))
        namespace['arguments']=['mojave-10.4.4','/own/results','observer','workload','actions','create-open-hid-inspect-master-share']
        with self.assertRaises(ValueError):namespace['run_workflow']()
        self.assertIn('workflow_close_system_memory_notice=hid_project',source)

    def test_invalid_creation_modes_fail_before_staging(self):
        source=Path(__file__).resolve().parents[1]
        path=source/'probes/fcp-workflow-driver.py'
        tree=ast.parse(path.read_text());tree.body.pop()
        for case,mode in (('mavericks-10.1','unknown'),('mojave-10.4.4','create-private-library'),('mojave-10.4.4','create-and-open-private-project'),('mojave-10.4.4','create-open-and-retain-for-display'),('mojave-10.4.4','create-open-hid-and-retain-for-display'),('mojave-10.4.4','create-open-hid-inspect-master-share')):
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
            inventory=ready_inventory(result='MENU_INVENTORY',identityMatched=1,identityStillMatched=1,axTrusted=trusted,pid=321,variant='10.1',mode='inventory')
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
