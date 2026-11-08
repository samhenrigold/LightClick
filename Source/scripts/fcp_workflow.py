"""Guarded composition of frozen FCP preflight, generated XML open, and optional grounded library dialog action."""
import ast
import base64
import hashlib
import json
import inspect
import textwrap
from pathlib import Path
import runpy

CLIP_SHA256='62dfa5b49d5f97d954c420d315c250015d8733f47c59752d002f8b841e650211'
CLIP_BYTES=58747744
PLACEHOLDER='/private/var/tmp/LightClickFCPFixture.PLACEHOLDER'

PREPARE=r'''
    # Workflow extension: only generated fixture media and verified observation helper.
    workflow_paths=[]
    workflow_directory=tempfile.mkdtemp(prefix='LightClickFCPFixture.',dir='/private/var/tmp')
    os.chmod(workflow_directory,0o700)
    source_clip='/Volumes/LC_FCP_Fixture/input-prores422.mov'
    source_manifest='/Volumes/LC_FCP_Fixture/manifest.json'
    def bounded_file(path,cap):
        if os.path.realpath(path)!=path:raise ValueError('workflow source noncanonical')
        fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
        try:
            info=os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or not 0<info.st_size<=cap:raise ValueError('workflow file outside budget')
            with os.fdopen(os.dup(fd),'rb') as stream:data=stream.read(cap+1)
            if len(data)!=info.st_size:raise ValueError('workflow file changed')
            return data
        finally:os.close(fd)
    manifest=bounded_file(source_manifest,131072)
    report['workflow']={'scope':'verified generated fixture prepared; surgical inventory and OS-open attempt only; no import/render/export qualification',
                        'directory':workflow_directory,'source_manifest':json.loads(manifest)}
    clip=bounded_file(source_clip,58747744)
    if len(clip)!=58747744 or hashlib.sha256(clip).hexdigest()!='62dfa5b49d5f97d954c420d315c250015d8733f47c59752d002f8b841e650211':raise ValueError('generated media identity mismatch')
    clip_path=workflow_directory+'/input-prores422.mov'
    with open(clip_path,'wb') as stream:stream.write(clip)
    del clip
    template=__import__('base64').b64decode(spec['workflow_xml_template'])
    if hashlib.sha256(template).hexdigest()!=spec['workflow_xml_template_sha256'] or template.count('/private/var/tmp/LightClickFCPFixture.PLACEHOLDER')!=1:raise ValueError('generated XML template changed')
    xml=template.replace('/private/var/tmp/LightClickFCPFixture.PLACEHOLDER',workflow_directory)
    xml_path=workflow_directory+'/generated.fcpxml'
    with open(xml_path,'wb') as stream:stream.write(xml)
    report['workflow'].update(clip_path=clip_path,clip_bytes=58747744,clip_sha256='62dfa5b49d5f97d954c420d315c250015d8733f47c59752d002f8b841e650211',xml_path=xml_path,xml_bytes=len(xml),xml_sha256=hashlib.sha256(xml).hexdigest(),import_attempted=False)
    helper=spec['workflow_helper']
    if not re.match(r'\A/private/var/tmp/VirtualIntelMac\.[A-Za-z0-9]{6}/Transfer\.bin\Z',helper):raise ValueError('invalid workflow helper receipt')
    parent=os.path.dirname(helper);parent_info=os.lstat(parent)
    if os.path.realpath(parent)!=parent or not stat.S_ISDIR(parent_info.st_mode) or parent_info.st_uid!=0 or stat.S_IMODE(parent_info.st_mode)!=0o700:raise ValueError('workflow staging parent changed')
    data=bounded_file(helper,2097152)
    if hashlib.sha256(data).hexdigest()!=spec['workflow_helper_sha256']:raise ValueError('workflow helper bytes changed')
    helper_path=directory+'/ax-workload'
    with open(helper_path,'wb') as stream:stream.write(data)
    os.chmod(helper_path,0o755)
    spec['workflow_helper']=helper_path
    workflow_paths=[workflow_directory,clip_path,xml_path,helper_path]
    if spec.get('workflow_action_helper'):
        action_helper=spec['workflow_action_helper']
        if not re.match(r'\A/private/var/tmp/VirtualIntelMac\.[A-Za-z0-9]{6}/Transfer\.bin\Z',action_helper):raise ValueError('invalid action helper receipt')
        parent=os.path.dirname(action_helper);parent_info=os.lstat(parent)
        if os.path.realpath(parent)!=parent or not stat.S_ISDIR(parent_info.st_mode) or parent_info.st_uid!=0 or stat.S_IMODE(parent_info.st_mode)!=0o700:raise ValueError('action staging parent changed')
        data=bounded_file(action_helper,2097152)
        if hashlib.sha256(data).hexdigest()!=spec['workflow_action_helper_sha256']:raise ValueError('action helper bytes changed')
        action_path=directory+'/ax-actions'
        with open(action_path,'wb') as stream:stream.write(data)
        os.chmod(action_path,0o755)
        spec['workflow_action_helper']=action_path
        workflow_paths.append(action_path)

'''

def generated_project_evidence(view,pid,variant):
    """Recorded evidence gate only; live action helper independently rejects ambiguity."""
    def native_true(value):return type(value) in (bool,int) and value in (0,1) and value==1
    if (not isinstance(view,dict) or view.get('result')!='OBSERVED_WINDOWS'
            or type(view.get('pid')) is not int or view['pid']!=pid or view.get('version')!=variant
            or not all(native_true(view.get(key)) for key in ('identityMatched','identityStillMatched','axTrusted'))):return False
    windows=view.get('windows',[])
    if not isinstance(windows,list) or len(windows)!=1 or not isinstance(windows[0],dict) or windows[0].get('AXSubrole')!='AXStandardWindow':return False
    labels=[0];valid=[0];count=[0]
    def visit(node,organizer=False,events=False):
        if not isinstance(node,dict):return
        count[0]+=1
        if count[0]>1024:return
        organizer=organizer or (node.get('AXRole')=='AXScrollArea' and node.get('AXDescription')=='organizer')
        events=events or (organizer and node.get('AXRole')=='AXGroup' and node.get('AXDescription')=='events')
        children=node.get('children',[])
        if not isinstance(children,list):return
        if events and node.get('AXRole')=='AXGroup' and node.get('AXDescription')=='LC-generated-8s':
            labels[0]+=1
            names=[c for c in children if isinstance(c,dict) and c.get('AXRole')=='AXTextField' and c.get('AXDescription')=='display name' and c.get('AXValue')=='LC-generated-8s' and native_true(c.get('AXEnabled'))]
            images=[c for c in children if isinstance(c,dict) and c.get('AXRole')=='AXImage' and c.get('AXTitle')=='LC-generated-8s' and native_true(c.get('AXEnabled'))]
            ranges=[c for c in children if isinstance(c,dict) and c.get('AXRole')=='AXLayoutItem' and c.get('AXDescription')=='range selection' and type(c.get('AXValue')) in (int,float) and c['AXValue']==8]
            if len(children)==3 and len(names)==len(images)==len(ranges)==1:valid[0]+=1
        for child in children:visit(child,organizer,events)
    visit(windows[0])
    return count[0]<=1024 and labels[0]==valid[0]==1


OBSERVE='\n'+textwrap.indent(inspect.getsource(generated_project_evidence),'    ')+r'''

    if app.poll() is None:
        report['workflow']['inventory_started_seconds']=time.time()-launched_at
        raw=command([spec['workflow_helper'],spec['variant'],str(app.pid),'inventory'],20)
        inventory=json.loads(raw)
        report['workflow']['inventory_before']=inventory
        report['workflow']['inventory']=inventory
        def native_true(value):return type(value) in (bool,int) and value in (0,1) and value==1
        if inventory.get('result')=='MENU_INVENTORY' and inventory.get('variant')==spec['variant'] and type(inventory.get('pid')) is int and inventory['pid']==app.pid and inventory.get('mode')=='inventory' and all(native_true(inventory.get(k)) for k in ('identityMatched','identityStillMatched','axTrusted')):
            # Standard LaunchServices open of ONLY our generated XML; no guessed AX actions or library paths.
            report['workflow']['import_attempted']=True
            command(['/usr/bin/open','-a',spec['app'],xml_path],10)
            report['workflow']['open_command_completed']=True
            time.sleep(3)
            if app.poll() is None:
                raw=command([spec['workflow_helper'],spec['variant'],str(app.pid),'inventory'],14)
                report['workflow']['inventory_after_open']=json.loads(raw)
                after_open=report['workflow']['inventory_after_open']
                if spec.get('workflow_action_helper') and app.poll() is None and after_open.get('result')=='MENU_INVENTORY' and after_open.get('variant')==spec['variant'] and type(after_open.get('pid')) is int and after_open['pid']==app.pid and after_open.get('mode')=='inventory' and all(native_true(after_open.get(k)) for k in ('identityMatched','identityStillMatched','axTrusted')):
                    report['workflow']['library_action_attempted']=True
                    action_mode=spec.get('workflow_action_mode','new-private-library')
                    if action_mode not in ('new-private-library','create-private-library'):raise ValueError('unknown library action mode')
                    report['workflow']['library_action_mode']=action_mode
                    raw=command([spec['workflow_action_helper'],spec['variant'],str(app.pid),action_mode,workflow_directory],60 if action_mode=='create-private-library' else 20)
                    report['workflow']['library_action']=json.loads(raw)
                    report['workflow']['post_library_observations']=[]
                    def export_menu_available(node):
                        if isinstance(node,dict):
                            if node.get('AXRole')=='AXMenuItem' and node.get('AXTitle') in (u'Export XML\u2026',u'Master File (default)\u2026',u'Apple Devices 1080p\u2026') and native_true(node.get('AXEnabled')):return True
                            return any(export_menu_available(value) for value in node.values())
                        if isinstance(node,list):return any(export_menu_available(value) for value in node)
                        return False
                    def modal_present(node):
                        if isinstance(node,dict):
                            if node.get('AXRole') in ('AXSheet','AXAlert') or node.get('AXSubrole') in ('AXDialog','AXSystemDialog'):return True
                            return any(modal_present(value) for value in node.values())
                        if isinstance(node,list):return any(modal_present(value) for value in node)
                        return False
                    # Library creation starts asynchronous import. Poll only read-only inventories;
                    # never resend New, Save, or the XML-open command while waiting for the editor.
                    for attempt in range(8 if action_mode=='create-private-library' else 1):
                        if app.poll() is not None:break
                        if action_mode=='create-private-library':time.sleep(2)
                        raw=command([spec['workflow_helper'],spec['variant'],str(app.pid),'inventory'],14)
                        current=json.loads(raw)
                        report['workflow']['inventory_after_library_action']=current
                        ready=current.get('result')=='MENU_INVENTORY' and not modal_present(current.get('windows',[])) and export_menu_available(current.get('fileMenu',{}))
                        report['workflow']['post_library_observations'].append({'elapsed_seconds':time.time()-launched_at,'result':current.get('result'),'export_menu_available':ready,'alive':app.poll() is None})
                        if ready:break
                    report['workflow']['owned_app_alive_after_library']=app.poll() is None
                    # One read-only full-window capture using the already verified/staged observer.
                    # This reveals browser/timeline names after the surgical menu readiness polls;
                    # it does not select a project or establish import/render/timing correctness.
                    if app.poll() is None:
                        report['workflow']['post_library_full_observer_started_seconds']=time.time()-launched_at
                        try:
                            raw=command([spec['ax_helper'],spec['variant'],str(app.pid)],14)
                            report['workflow']['post_library_full_observer']=json.loads(raw)
                        except Exception as error:
                            report['workflow']['post_library_full_observer']={'available':False,'reason':repr(error)}
                        report['workflow']['post_library_full_observer_finished_seconds']=time.time()-launched_at
                    else:report['workflow']['post_library_full_observer']={'available':False,'reason':'owned app exited before read-only capture'}
                    if spec.get('workflow_open_generated_project'):
                        full=report['workflow'].get('post_library_full_observer',{})
                        created=report['workflow'].get('library_action',{})
                        can_open=(app.poll() is None and created.get('result')=='PRIVATE_LIBRARY_CREATED_REQUIRES_IMPORT_REVIEW'
                                  and native_true(created.get('privateLibraryVerified')) and generated_project_evidence(full,app.pid,spec['variant']))
                        report['workflow']['project_open_evidence_gate']=can_open
                        if can_open:
                            report['workflow']['project_open_attempted']=True
                            try:
                                raw=command([spec['workflow_action_helper'],spec['variant'],str(app.pid),'open-generated-project',workflow_directory],20)
                                report['workflow']['project_open_action']=json.loads(raw)
                            except Exception as error:report['workflow']['project_open_action']={'available':False,'reason':repr(error)}
                            # Input delivery is not proof of opening. Always collect fresh read-only evidence;
                            # never repeat XML-open, library actions or the project-open attempt.
                            for key,argv in [('post_project_open_full_observer',[spec['ax_helper'],spec['variant'],str(app.pid)]),
                                             ('post_project_open_inventory',[spec['workflow_helper'],spec['variant'],str(app.pid),'inventory'])]:
                                if app.poll() is None:
                                    try:report['workflow'][key]=json.loads(command(argv,14))
                                    except Exception as error:report['workflow'][key]={'available':False,'reason':repr(error)}
                                else:report['workflow'][key]={'available':False,'reason':'owned app exited before post-open observation'}
                        else:report['workflow']['project_open_skipped']='owned app, verified creation or exact generated-project evidence missing'
                    library=workflow_directory+'/private.fcpbundle'
                    report['workflow']['library_artifact']={'path':library,'exists':os.path.lexists(library),'is_directory':os.path.isdir(library),'is_symlink':os.path.islink(library)}

            else:report['workflow']['open_error']='owned app exited after OS open'
        report['workflow']['inventory_finished_seconds']=time.time()-launched_at
    else:report['workflow']['inventory_error']='owned app exited'
'''


def replace_once(text,old,new):
    if text.count(old)!=1:raise ValueError('frozen preflight composition anchor changed: '+repr(old))
    return text.replace(old,new,1)


def compose_guest(base):
    text=replace_once(base,"    report['console_uid']=join_console()",PREPARE+"\n    report['console_uid']=join_console()")
    text=replace_once(text,'    os.initgroups(user.pw_name,user.pw_gid);os.setgid(user.pw_gid);os.setuid(uid)',
                      '    for path in workflow_paths:os.chown(path,uid,user.pw_gid)\n    os.initgroups(user.pw_name,user.pw_gid);os.setgid(user.pw_gid);os.setuid(uid)')
    text=replace_once(text,"    report['result']='OBSERVED_LAUNCH'",OBSERVE+"\n    report['result']='OBSERVED_LAUNCH'")
    ast.parse(text)
    return text


def load_preflight(path,globals):
    tree=ast.parse(path.read_text(),filename=str(path))
    last=tree.body[-1]
    if not isinstance(last,ast.Expr) or not isinstance(last.value,ast.Call) or not isinstance(last.value.func,ast.Name) or last.value.func.id!='experiment' or last.value.args or last.value.keywords:
        raise ValueError('base driver invocation changed')
    tree.body.pop()
    namespace=dict(globals)
    exec(compile(tree,str(path),'exec'),namespace)
    return namespace


def xml_template(source):
    builder=runpy.run_path(str(source/'probes/fcp-fixture-xml.py'),run_name='fixture_builder')
    data,manifest=builder['build_fixture'](PLACEHOLDER+'/input-prores422.mov',PLACEHOLDER)
    if manifest['expected_input']['sha256']!=CLIP_SHA256 or manifest['expected_input']['bytes']!=CLIP_BYTES:raise ValueError('fixture contract changed')
    return data,manifest
