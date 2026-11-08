"""Guarded composition of frozen FCP preflight, generated XML open, and optional grounded library dialog action."""
import ast
import base64
import hashlib
import json
import re
import inspect
import textwrap
from pathlib import Path
import runpy

CLIP_SHA256='62dfa5b49d5f97d954c420d315c250015d8733f47c59752d002f8b841e650211'
CLIP_BYTES=58747744
PLACEHOLDER='/private/var/tmp/LightClickFCPFixture.PLACEHOLDER'

def complete_hid_open(opened,pid):
    if (not isinstance(opened,dict) or opened.get('mode')!='open-generated-project-hid'
            or opened.get('result')!='PROJECT_HID_DOUBLE_CLICK_POSTED_REQUIRES_REVIEW'
            or type(opened.get('pid')) is not int or opened['pid']!=pid):return False
    actions=opened.get('actionsPerformed',[])
    if not isinstance(actions,list) or len(actions)!=1 or not isinstance(actions[0],dict):return False
    action=actions[0];balanced=action.get('balancedRelease')
    return (action.get('action')=='doubleClick' and action.get('api')=='CGEventPost(kCGHIDEventTap)' and action.get('targetPID')==pid
            and type(action.get('eventsPosted')) is int and action['eventsPosted']==4
            and type(action.get('downsPosted')) is int and action['downsPosted']==2
            and type(action.get('upsPosted')) is int and action['upsPosted']==2
            and type(balanced) in (bool,int) and balanced in (0,1) and balanced==1)


RETENTION_HELPERS=r'''
def launch_for_workflow(binary,env,spec,report):
    with open(os.devnull,'rb') as null:
        if spec.get('workflow_retain_owned_app'):
            with open(os.devnull,'wb') as sink:
                child=subprocess.Popen([binary],stdin=null,stdout=sink,stderr=sink,env=env,preexec_fn=limits,close_fds=True)
            report['app_stdio']={'policy':'devnull','available':False,'reason':'explicit retention diagnostic; app output intentionally unavailable'}
            report['app_log_at_limit']=None
            return child,None
        child=subprocess.Popen([binary],stdin=null,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,preexec_fn=limits,close_fds=True)
    return child,(reader(child.stdout),reader(child.stderr))

def current_executable(pid):
    library=ctypes.CDLL('/usr/lib/libproc.dylib')
    buffer=ctypes.create_string_buffer(4096)
    if library.proc_pidpath(pid,buffer,ctypes.sizeof(buffer))<=0:return None
    return buffer.value.decode('utf-8','strict')

def readonly_observer_receipt(spec):
    path=spec.get('ax_helper');expected=spec.get('ax_helper_sha256')
    if path is None and expected is None:return None # Older synthetic/retained receipts remain valid.
    if (not isinstance(path,(str,type(u''))) or not re.match(r'\A/private/var/tmp/LightClickFCP\.[A-Za-z0-9_-]{6,16}/ax-observe\Z',path)
            or not isinstance(expected,(str,type(u''))) or not re.match(r'\A[0-9a-f]{64}\Z',expected)):raise ValueError('invalid readonly observer receipt')
    parent=os.path.dirname(path);home=parent+'/home'
    for directory in (parent,home):
        info=os.lstat(directory)
        if os.path.realpath(directory)!=directory or not stat.S_ISDIR(info.st_mode) or info.st_uid!=os.getuid() or stat.S_IMODE(info.st_mode)!=0o700:raise ValueError('readonly observer directory identity changed')
    if os.path.realpath(path)!=path:raise ValueError('readonly observer path noncanonical')
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    try:
        info=os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or info.st_nlink!=1 or not info.st_mode&0o111 or not 0<info.st_size<=2097152:raise ValueError('readonly observer file outside scope')
        with os.fdopen(os.dup(fd),'rb') as stream:data=stream.read(2097153)
        if len(data)!=info.st_size or hashlib.sha256(data).hexdigest()!=expected:raise ValueError('readonly observer hash/size changed')
    finally:os.close(fd)
    return {'path':path,'sha256':expected,'bytes':len(data),'uid':os.getuid(),'private_home':home,'scope':'existing fixed readonly FCP AX observer'}

def owned_retention_receipt(app,spec,report):
    if (not spec.get('workflow_retain_owned_app') or spec.get('variant')!='10.1'
            or report.get('result')!='OBSERVED_LAUNCH' or report.get('error')
            or report.get('app_stdio',{}).get('policy')!='devnull' or app is None or app.poll() is not None):return None
    workflow=report.get('workflow',{});created=workflow.get('library_action',{});opened=workflow.get('project_open_action',{})
    def true(value):return type(value) in (bool,int) and value in (0,1) and value==1
    if (workflow.get('project_open_evidence_gate') is not True or workflow.get('project_open_attempted') is not True
            or created.get('result')!='PRIVATE_LIBRARY_CREATED_REQUIRES_IMPORT_REVIEW' or not true(created.get('privateLibraryVerified'))
            or opened.get('mode')!=('open-generated-project-hid' if spec.get('workflow_open_project_hid') else 'open-generated-project') or opened.get('variant')!='10.1'
            or type(opened.get('pid')) is not int or opened['pid']!=app.pid
            or not all(true(opened.get(key)) for key in ('identityMatched','identityStillMatched','axTrusted'))):return None
    if spec.get('workflow_open_project_hid') and not complete_hid_open(opened,app.pid):return None
    directory=workflow.get('directory','')
    if not re.match(r'\A/private/var/tmp/LightClickFCPFixture\.[A-Za-z0-9_-]{6,16}\Z',directory):return None
    metadata=os.lstat(directory)
    if os.path.realpath(directory)!=directory or not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid!=os.getuid() or stat.S_IMODE(metadata.st_mode)!=0o700:return None
    for name,kind,cap in (('input-prores422.mov','file',58747744),('generated.fcpxml','xml',16384),('private.fcpbundle','directory',0)):
        path=directory+'/'+name;info=os.lstat(path)
        if os.path.realpath(path)!=path or info.st_uid!=os.getuid():return None
        if kind=='directory':
            if not stat.S_ISDIR(info.st_mode):return None
        elif not stat.S_ISREG(info.st_mode) or (info.st_size!=cap if kind=='file' else not 0<info.st_size<=cap):return None
    executable=spec['app']+'/Contents/MacOS/'+spec['identity']['CFBundleExecutable']
    if current_executable(app.pid)!=executable or os.path.realpath(executable)!=executable or os.getpgid(app.pid)!=app.pid or app.poll() is not None:return None
    receipt={'retained':True,'mode':'create-open-hid-and-retain-for-display' if spec.get('workflow_open_project_hid') else 'create-open-and-retain-for-display','pid':app.pid,'executable':executable,
             'console_uid':os.getuid(),'process_group':os.getpgid(app.pid),'fixture_directory':directory,
             'private_library':directory+'/private.fcpbundle','app_stdio_available':False,
             'identity_scope':'owned live Popen child verified at collector exit; revalidate before later input',
             'project_open_result':opened.get('result'),'max_host_observation_seconds':90}
    observer=readonly_observer_receipt(spec)
    if observer is not None:receipt['readonly_observer']=observer
    for action in opened.get('actionsPerformed',[]):
        if (action.get('targetPID')==app.pid and action.get('api',action.get('action')) in ('CGEventPostToPSN','CGEventPost(kCGHIDEventTap)')
                and type(action.get('psnHigh')) is int and type(action.get('psnLow')) is int
                and 0<=action['psnHigh']<=4294967295 and 0<=action['psnLow']<=4294967295 and (action['psnHigh'] or action['psnLow'])):
            receipt['helper_psn']={'high':action['psnHigh'],'low':action['psnLow']};break
    return receipt

def close_system_memory_notice(spec,report):
    if not spec.get('workflow_close_system_memory_notice'):return
    import errno
    record={'result':'INCONCLUSIVE','scope':'explicit Mavericks disposable-clone System utility only','queries':[],'signals':[]}
    report['system_memory_notice']=record
    try:
        if spec.get('variant')!='10.1' or os.uname()[0]!='Darwin' or os.uname()[2].split('.')[0]!='13':raise ValueError('System utility gate requires guest Darwin13')
        pids=set()
        for name in ('Memory Slot Utility','MemorySlotUtility','Memory Slot Util','MemorySlotUtilit'):
            text=command(['/usr/bin/pgrep','-x',name],3,(0,1))
            row=report['commands'][-1];record['queries'].append({'name':name,'exit_code':row['exit_code'],'stdout':row['stdout']})
            fields=text.split()
            if (row['exit_code']==1 and fields) or (row['exit_code']==0 and not fields) or any(not value.isdigit() or not 1<int(value)<2147483648 for value in fields):raise ValueError('unexpected exact utility process query response')
            pids.update(int(value)for value in fields)
        if not pids:record['result']='ABSENT';return
        if len(pids)!=1:raise ValueError('System utility PID ambiguous')
        pid=next(iter(pids));path=current_executable(pid);record.update(pid=pid,executable=path)
        allowed=('/System/Library/CoreServices/Memory Slot Utility.app/Contents/MacOS/Memory Slot Utility',
                 '/System/Library/CoreServices/MemorySlotUtility.app/Contents/MacOS/MemorySlotUtility')
        # Reject before touching any unexpected path, including all /Users locations.
        if path not in allowed:raise ValueError('System utility actual executable is not an exact allowed System path')
        info=os.lstat(path)
        if os.path.realpath(path)!=path or not stat.S_ISREG(info.st_mode) or info.st_uid!=0:raise ValueError('System utility executable must be canonical root-owned regular file')
        if current_executable(pid)!=path:raise ValueError('System utility identity changed before signal')
        os.kill(pid,signal.SIGTERM);record['signals'].append({'pid':pid,'signal':int(signal.SIGTERM)})
        until=time.time()+3
        while True:
            try:os.kill(pid,0) # Read-only existence probe; never another delivered signal.
            except OSError as error:
                if error.errno==errno.ESRCH:record['result']='TERMINATED';return
                raise
            now=current_executable(pid)
            if now is not None and now!=path:raise ValueError('System utility identity changed after signal')
            remaining=until-time.time()
            if remaining<=0:raise ValueError('System utility did not exit within3seconds; no resend or force')
            time.sleep(min(.1,remaining))
    except Exception as error:record['result']='FAILED';record['error']=repr(error);raise

def cleanup_for_workflow(owned,app,spec,report):
    errors=[];candidate=None
    # Defer only our one app. All helpers still finish/stop normally before retention is granted.
    for child in reversed(owned):
        if child is app and spec.get('workflow_retain_owned_app'):candidate=child;continue
        try:stop(child)
        except Exception as error:errors.append(repr(error))
    if candidate is not None:
        receipt=None
        if not errors:
            try:receipt=owned_retention_receipt(candidate,spec,report)
            except Exception as error:report['retention_validation_error']=repr(error)
        if receipt is not None:report['retained_owned_app']=receipt
        else:
            report['retained_owned_app']={'retained':False,'reason':'retention setup/identity/cleanup gate not satisfied'}
            try:stop(candidate)
            except Exception as error:errors.append(repr(error))
    return errors
'''


RETENTION_HELPERS=inspect.getsource(complete_hid_open)+'\n'+RETENTION_HELPERS


def hold_retained_display_window(evidence,save,clock=None,sleep=None):
    """No commands/input here. Entire VM cleanup follows this finite diagnostic window."""
    import time
    clock=clock or time.monotonic;sleep=sleep or time.sleep
    evidence['retained_display_observation']={'limit_seconds':90,'started_monotonic':clock(),'timing_qualified':False,
        'cleanup_owner':'guest-bench whole disposable VM; no further diagnostic requests from this driver'}
    deadline=evidence['retained_display_observation']['started_monotonic']+90
    save()
    print('RETAINED_DISPLAY_DIAGNOSTIC_READY (maximum90seconds; no presentation/export qualification)',flush=True)
    while clock()<deadline:sleep(min(.25,max(0,deadline-clock())))
    evidence['retained_display_observation']['finished_monotonic']=clock();save()


def valid_retention_receipt(guest,spec):
    receipt=guest.get('retained_owned_app',{});workflow=guest.get('workflow',{})
    if spec.get('workflow_open_project_hid') and not complete_hid_open(workflow.get('project_open_action',{}),guest.get('owned_app_pid')):return False
    observer=receipt.get('readonly_observer')
    if observer is not None:
        if (not isinstance(observer,dict) or not isinstance(observer.get('path'),str)
                or not re.fullmatch(r'/private/var/tmp/LightClickFCP\.[A-Za-z0-9_-]{6,16}/ax-observe',observer['path'])
                or observer.get('sha256')!=spec.get('ax_helper_sha256') or type(observer.get('bytes')) is not int or not 0<observer['bytes']<=2097152
                or observer.get('uid')!=receipt.get('console_uid') or observer.get('private_home')!=observer['path'].rsplit('/',1)[0]+'/home'):return False
    return (receipt.get('retained') is True and receipt.get('mode')==('create-open-hid-and-retain-for-display' if spec.get('workflow_open_project_hid') else 'create-open-and-retain-for-display')
            and type(receipt.get('pid')) is int and receipt['pid']==guest.get('owned_app_pid')
            and receipt.get('executable')==spec['app']+'/Contents/MacOS/'+spec['identity']['CFBundleExecutable']
            and receipt.get('fixture_directory')==workflow.get('directory')
            and receipt.get('private_library')==workflow.get('directory','')+'/private.fcpbundle'
            and receipt.get('process_group')==receipt['pid'] and receipt.get('max_host_observation_seconds')==90
            and receipt.get('app_stdio_available') is False and guest.get('cleanup_errors')==[])


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


def initial_menu_identity(view,pid,variant):
    def true(value):return type(value) in (bool,int) and value in (0,1) and value==1
    return (isinstance(view,dict) and type(view.get('pid')) is int and view['pid']==pid
            and view.get('variant')==variant and view.get('mode')=='inventory'
            and all(true(view.get(key)) for key in ('identityMatched','identityStillMatched')))


def initial_menu_ready(view,pid,variant):
    if not initial_menu_identity(view,pid,variant) or view.get('result')!='MENU_INVENTORY':return False
    trusted=view.get('axTrusted');menu=view.get('fileMenu',{})
    if not (type(trusted) in (bool,int) and trusted in (0,1) and trusted==1 and type(view.get('fileLabelMatches')) is int and view['fileLabelMatches']==1 and isinstance(menu,dict)
            and menu.get('AXRole')=='AXMenuBarItem' and menu.get('AXTitle')=='File'):return False
    children=menu.get('children',[])
    return (isinstance(children,list) and len(children)==1 and isinstance(children[0],dict) and children[0].get('AXRole')=='AXMenu'
            and isinstance(children[0].get('children'),list) and bool(children[0]['children']))


OBSERVE='\n'+textwrap.indent(inspect.getsource(generated_project_evidence)+inspect.getsource(initial_menu_identity)+inspect.getsource(initial_menu_ready),'    ')+r'''


    if app.poll() is None:
        report['workflow']['inventory_started_seconds']=time.time()-launched_at
        def native_true(value):return type(value) in (bool,int) and value in (0,1) and value==1
        menu_started=time.time();menu_deadline=menu_started+90
        readiness={'limit_seconds':90,'max_attempts':45,'polls':[],'result':'ATTEMPT_LIMIT'}
        report['workflow']['initial_menu_readiness']=readiness
        inventory={}
        for attempt in range(1,46):
            if app.poll() is not None:readiness['result']='OWNED_APP_EXITED';break
            remaining=menu_deadline-time.time()
            if remaining<=0:readiness['result']='DEADLINE';break
            if attempt>1:
                time.sleep(min(2,remaining))
                if app.poll() is not None:readiness['result']='OWNED_APP_EXITED';break
                remaining=menu_deadline-time.time()
                if remaining<=0:readiness['result']='DEADLINE';break
            row={'attempt':attempt,'elapsed_seconds':time.time()-menu_started,'timeout_seconds':min(14,remaining)}
            readiness['polls'].append(row)
            try:
                raw=command([spec['workflow_helper'],spec['variant'],str(app.pid),'inventory'],row['timeout_seconds'])
                inventory=json.loads(raw)
                if not isinstance(inventory,dict):raise ValueError('initial menu inventory is not a dictionary')
            except Exception as error:
                row['error']=repr(error);readiness['result']='COMMAND_FAILED';inventory={'available':False,'reason':repr(error)}
                report['workflow']['inventory']=inventory
                if attempt==1:report['workflow']['inventory_before']=inventory
                break
            if attempt==1:report['workflow']['inventory_before']=inventory
            report['workflow']['inventory']=inventory
            row.update(result=inventory.get('result'),pid=inventory.get('pid'),variant=inventory.get('variant'),
                       identityMatched=inventory.get('identityMatched'),identityStillMatched=inventory.get('identityStillMatched'),
                       axTrusted=inventory.get('axTrusted'),fileLabelMatches=inventory.get('fileLabelMatches'),attributeFailures=inventory.get('attributeFailures'),
                       nodes=inventory.get('nodes'),truncated=inventory.get('truncated'),deadlineExceeded=inventory.get('deadlineExceeded'))
            row['finished_elapsed_seconds']=time.time()-menu_started;row['app_alive']=app.poll() is None
            row['ready']=initial_menu_ready(inventory,app.pid,spec['variant'])
            if not row['app_alive']:readiness['result']='OWNED_APP_EXITED';break
            if time.time()>=menu_deadline:readiness['result']='DEADLINE';break
            if not initial_menu_identity(inventory,app.pid,spec['variant']):readiness['result']='IDENTITY_CHANGED_OR_UNAVAILABLE';break
            if not native_true(inventory.get('axTrusted')):readiness['result']='AX_NOT_TRUSTED';break
            if row['ready']:
                readiness['result']='READY';report['workflow']['inventory_ready']=inventory;break
        readiness['elapsed_seconds']=time.time()-menu_started
        if app.poll() is None and readiness['result']=='READY' and initial_menu_ready(inventory,app.pid,spec['variant']):
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
                                project_mode='open-generated-project-hid' if spec.get('workflow_open_project_hid') else 'open-generated-project'
                                raw=command([spec['workflow_action_helper'],spec['variant'],str(app.pid),project_mode,workflow_directory],20)
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
                            if spec.get('workflow_inspect_master_share'):
                                post_full=report['workflow'].get('post_project_open_full_observer',{})
                                post_menu=report['workflow'].get('post_project_open_inventory',{})
                                def same_owned_view(view,menu=False):
                                    return (isinstance(view,dict) and view.get('result')==('MENU_INVENTORY' if menu else 'OBSERVED_WINDOWS')
                                            and type(view.get('pid')) is int and view['pid']==app.pid
                                            and view.get('variant' if menu else 'version')==spec['variant']
                                            and (not menu or view.get('mode')=='inventory')
                                            and all(native_true(view.get(k)) for k in ('identityMatched','identityStillMatched','axTrusted')))
                                ready_share=(app.poll() is None and complete_hid_open(report['workflow'].get('project_open_action',{}),app.pid)
                                             and same_owned_view(post_full) and same_owned_view(post_menu,True)
                                             and not modal_present(post_full.get('windows',[])))
                                report['workflow']['master_share_evidence_gate']=ready_share
                                if ready_share:
                                    report['workflow']['master_share_inspection_attempted']=True
                                    try:
                                        raw=command([spec['workflow_action_helper'],spec['variant'],str(app.pid),'inspect-master-share',workflow_directory],28)
                                        report['workflow']['master_share_inspection']=json.loads(raw)
                                    except Exception as error:report['workflow']['master_share_inspection']={'available':False,'reason':repr(error)}
                                else:report['workflow']['master_share_inspection_skipped']='complete HID open and fresh owned nonmodal observations required'
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
    launch_old="""    with open(os.devnull,'rb') as null:
        app=subprocess.Popen([binary],stdin=null,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,preexec_fn=limits,close_fds=True)
    log=(reader(app.stdout),reader(app.stderr))"""
    text=replace_once(text,launch_old,"    close_system_memory_notice(spec,report)\n    app,log=launch_for_workflow(binary,env,spec,report)")
    cleanup_old="""    errors=[]
    for child in reversed(owned):
        try:stop(child)
        except Exception as error:errors.append(repr(error))"""
    text=replace_once(text,cleanup_old,"    errors=cleanup_for_workflow(owned,app,spec,report)")
    text=replace_once(text,"try:\n    def interrupted(n,frame):",RETENTION_HELPERS+"\ntry:\n    def interrupted(n,frame):")
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
