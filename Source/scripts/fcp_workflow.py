"""Explicit guarded composition of the frozen FCP preflight for a first menu inventory."""
import ast
import base64
import hashlib
import json
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
'''

OBSERVE=r'''
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
