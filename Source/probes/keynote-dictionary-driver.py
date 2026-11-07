"""guest-bench: bounded fixed Keynote 5.3 resources + sdef extraction in a disposable guest.

Arguments: existing fresh host results directory and optionally an already-built fixed-Keynote OSA helper.
sdef/OSA may launch Keynote inside the guest; no host input or Seamless. Native-helper mode does not repeat the resource walk.
Only fixed application resources and this collector's private files can be read. No scripting API is assumed.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import time
import xml.etree.ElementTree as ET

COLLECTOR = r'''import base64, hashlib, json, os, plistlib, re, resource, signal, stat, subprocess, sys, tempfile, time
APP = '/Applications/Keynote.app'
TARGETS = {'keynote':{'direct':'/Applications/Keynote.app','iwork09':"/Applications/iWork '09/Keynote.app"},
           'numbers':{'direct':'/Applications/Numbers.app','iwork09':"/Applications/iWork '09/Numbers.app"},
           'pages':{'direct':'/Applications/Pages.app','iwork09':"/Applications/iWork '09/Pages.app"}}
SUFFIXES = ('.sdef','.aete','.scriptsuite','.scriptterminology')
def identity(info):
    return [info.st_dev,info.st_ino,info.st_size,info.st_mtime,info.st_ctime]
def regular(path,cap,root):
    if not path.startswith(root+'/') or os.path.realpath(path)!=path:
        raise ValueError('refusing noncanonical/outside fixed root file')
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    try:
        info=os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or not 0<info.st_size<=cap:
            raise ValueError('file is not regular/nonempty/within budget')
        return fd,info
    except:
        os.close(fd)
        raise
def read(path,cap,root):
    fd,info=regular(path,cap,root)
    try:
        data=os.read(fd,cap+1)
        if len(data)!=info.st_size or identity(os.fstat(fd))!=identity(info):
            raise ValueError('file changed or was incompletely read')
        return data
    finally:
        os.close(fd)
def private(directory):
    if not re.match(r'\A/private/var/tmp/LightClickKeynote\.[A-Za-z0-9_-]{6,16}\Z',directory):
        raise ValueError('invalid collection directory')
    info=os.lstat(directory)
    if os.path.realpath(directory)!=directory or not stat.S_ISDIR(info.st_mode) or info.st_uid!=0 or info.st_mode&0o077:
        raise ValueError('collection directory must be canonical/private/root-owned')
def store(path,data):
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'wb') as output: output.write(data)
def describe(path,selector,cap,directory):
    data=read(path,cap,directory)
    info=os.lstat(path)
    return {'selector':selector,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest(),'identity':identity(info)}
def resources():
    queue=[(APP+'/Contents',0)]
    found,errors=[],[]
    seen,symlinks,visited=0,0,0
    truncated=False
    while queue:
        if visited>=256:
            truncated=True; break
        visited+=1
        directory,depth=queue.pop()
        if depth>16:
            truncated=True; continue
        if os.path.realpath(directory)!=directory or not directory.startswith(APP+'/Contents'):
            errors.append('noncanonical resource directory skipped'); continue
        listing=sorted(os.listdir(directory))
        if len(listing)+seen>8192:
            truncated=True; break
        for name in listing:
            seen+=1
            path=directory+'/'+name
            info=os.lstat(path)
            if stat.S_ISLNK(info.st_mode):
                symlinks+=1; continue
            if stat.S_ISDIR(info.st_mode):
                if len(queue)>=256:
                    truncated=True
                else:
                    queue.append((path,depth+1))
            elif stat.S_ISREG(info.st_mode) and name.lower().endswith(SUFFIXES):
                if len(found)>=64:
                    truncated=True; continue
                if len(path)-len(APP)>512 or not 0<info.st_size<=1024*1024:
                    errors.append('oversize/empty/long scripting resource skipped'); continue
                found.append(path)
    return found,{'entries_seen':seen,'directories_seen':visited,'symlinks_skipped':symlinks,'walk_truncated':truncated,'errors':errors[:64]}
def validated_helper(path,expected):
    if not re.match(r'\A/private/var/tmp/VirtualIntelMac\.[A-Za-z0-9]{6}/Transfer\.bin\Z',path):
        raise ValueError('invalid staged helper path')
    parent=path.rsplit('/',1)[0]
    info=os.lstat(parent)
    if os.path.realpath(parent)!=parent or not stat.S_ISDIR(info.st_mode) or info.st_uid!=0 or info.st_mode&0o077:
        raise ValueError('staged helper directory is not canonical/private/root-owned')
    data=read(path,4*1024*1024,parent)
    if os.lstat(path).st_uid!=0 or hashlib.sha256(data).hexdigest()!=expected:
        raise ValueError('staged helper ownership/hash mismatch')
    return path
def extract(directory,helper=None,target=None):
    def limits():
        resource.setrlimit(resource.RLIMIT_FSIZE,(2*1024*1024,2*1024*1024))
        resource.setrlimit(resource.RLIMIT_CPU,(10,10))
    paths=[directory+'/sdef.stdout',directory+'/sdef.stderr']
    files=[os.fdopen(os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600),'wb') for path in paths]
    process=None
    try:
        command=([helper,target[0],target[1],directory+'/sdef.native'] if target else
                 [helper,directory+'/sdef.native']) if helper else ['/usr/bin/sdef',APP]
        process=subprocess.Popen(command,stdin=open(os.devnull,'rb'),stdout=files[0],stderr=files[1],
                                 close_fds=True,preexec_fn=limits)
        deadline=time.time()+15
        while process.poll() is None and time.time()<deadline: time.sleep(0.05)
        expired=process.poll() is None
        if expired:
            process.kill()
            deadline=time.time()+2
            while process.poll() is None and time.time()<deadline: time.sleep(0.05)
        return {'command':command,'mode':'native-osa' if helper else 'sdef-tool','exit_code':process.poll(),'timed_out':expired,
                'deadline_seconds':15,'output_file_cap':2*1024*1024,'cpu_limit_seconds':10}
    finally:
        if process is not None and process.poll() is None: process.kill()
        for output in files: output.close()
def collect(helper=None,helper_hash=None,target=None,expected=None):
    global APP
    if target:
        if not helper or target[0] not in TARGETS or target[1] not in TARGETS[target[0]]:
            raise ValueError('invalid fixed iWork application selector')
        APP=TARGETS[target[0]][target[1]]
    if os.path.realpath(APP)!=APP or not stat.S_ISDIR(os.lstat(APP).st_mode):
        raise ValueError('fixed Keynote app is absent/noncanonical')
    info=plistlib.readPlistFromString(read(APP+'/Contents/Info.plist',512*1024,APP))
    if target:
        if (not isinstance(expected,dict) or expected.get('path')!=APP or
                any(not expected.get(key) for key in ('CFBundleIdentifier','CFBundleShortVersionString','CFBundleVersion')) or
                any(info.get(key)!=expected.get(key) for key in ('CFBundleIdentifier','CFBundleShortVersionString','CFBundleVersion'))):
            raise ValueError('fixed app changed from this clone inventory metadata')
    elif str(info.get('CFBundleShortVersionString'))!='5.3' or str(info.get('CFBundleVersion'))!='1170':
        raise ValueError('fixed app changed from inventoried Keynote5.3 build1170')
    scripting=dict((key,value) for key,value in info.items() if 'script' in key.lower() or key.startswith('OSA') or key in
        ('CFBundleIdentifier','CFBundleName','CFBundleExecutable','CFBundleVersion','CFBundleShortVersionString','NSPrincipalClass'))
    if helper: helper=validated_helper(helper,helper_hash)
    os.umask(0o077)
    directory=tempfile.mkdtemp(prefix='LightClickKeynote.',dir='/private/var/tmp')
    private(directory)
    manifest={'app':APP,'info':scripting,'resources':[],'files':[]}
    paths,walk=([],{'walk_not_repeated':True,'reason':'Native OSA extraction; prior resource-walk evidence retained separately.'}) if helper else resources()
    manifest['walk']=walk
    total=0
    for path in paths:
        data=read(path,1024*1024,APP)
        if total+len(data)>16*1024*1024:
            manifest['walk']['walk_truncated']=True; break
        total+=len(data)
        selector='resource-%03d'%len(manifest['resources'])
        target=directory+'/'+selector+'.bin'
        store(target,data)
        descriptor=describe(target,selector,1024*1024,directory)
        descriptor['relative_path']=path[len(APP)+1:]
        manifest['resources'].append(descriptor)
        manifest['files'].append(descriptor)
    try:
        manifest['extractor']=extract(directory,helper,target)
    except Exception as error:
        manifest['extractor']={'error':str(error)[:512]}
    for selector,name in (('sdef-stdout','sdef.stdout'),('sdef-stderr','sdef.stderr'),('sdef-native','sdef.native')):
        path=directory+'/'+name
        if os.path.lexists(path) and os.lstat(path).st_size:
            manifest['files'].append(describe(path,selector,2*1024*1024,directory))
    encoded=json.dumps(manifest)
    if len(encoded)>300*1024: raise ValueError('collection manifest exceeds response budget')
    store(directory+'/collection.json',encoded.encode('utf-8'))
    return {'directory':directory,'manifest':manifest}
def chunk(directory,selector,offset,length,expected):
    private(directory)
    manifest=json.loads(read(directory+'/collection.json',300*1024,directory))
    if re.match(r'\Aresource-[0-9]{3}\Z',selector): filename=selector+'.bin'
    elif selector=='sdef-stdout': filename='sdef.stdout'
    elif selector=='sdef-stderr': filename='sdef.stderr'
    elif selector=='sdef-native': filename='sdef.native'
    else: raise ValueError('invalid fixed output selector')
    descriptor=next((item for item in manifest['files'] if item['selector']==selector),None)
    if descriptor is None or descriptor['identity']!=expected or not 0<length<=192*1024 or offset<0 or offset+length>descriptor['bytes']:
        raise ValueError('invalid output range/identity')
    fd,info=regular(directory+'/'+filename,2*1024*1024,directory)
    try:
        if info.st_uid!=0 or info.st_nlink!=1 or identity(info)!=expected:
            raise ValueError('output ownership/identity changed')
        os.lseek(fd,offset,os.SEEK_SET)
        data=os.read(fd,length)
        if len(data)!=length or identity(os.fstat(fd))!=expected: raise ValueError('output changed/short read')
        return {'selector':selector,'offset':offset,'bytes':length,'identity':expected,
                'sha256':hashlib.sha256(data).hexdigest(),'base64':base64.b64encode(data).decode('ascii')}
    finally: os.close(fd)
operation=sys.argv[1]
if operation=='collect' and len(sys.argv)==2: result=collect()
elif operation=='collect-native' and len(sys.argv)==4: result=collect(sys.argv[2],sys.argv[3])
elif operation=='collect-native-target' and len(sys.argv)==7:
    result=collect(sys.argv[2],sys.argv[3],(sys.argv[4],sys.argv[5]),json.loads(sys.argv[6]))
elif operation=='chunk' and len(sys.argv)==7 and sys.argv[4].isdigit() and sys.argv[5].isdigit():
    result=chunk(sys.argv[2],sys.argv[3],int(sys.argv[4]),int(sys.argv[5]),json.loads(sys.argv[6]))
else: raise ValueError('invalid fixed collector operation')
encoded=json.dumps(result)
if len(encoded)>300*1024: raise ValueError('collector response exceeds budget')
sys.stdout.write(encoded)
'''


def dictionary_summary(data):
    if b'<!ENTITY' in data.upper():
        raise ValueError('dictionary declares entities')
    root=ET.fromstring(data)
    return {'root':root.tag,'commands':[dict(item.attrib,children=[dict(child.attrib,tag=child.tag) for child in item])
                                      for item in root.findall('.//command')],
            'classes':[dict(item.attrib,properties=[dict(child.attrib) for child in item.findall('property')])
                       for item in root.findall('.//class')],
            'enumerations':[dict(item.attrib,values=[dict(child.attrib) for child in item])
                            for item in root.findall('.//enumeration')],
            'includes':[dict(item.attrib) for item in root.iter() if item.tag.endswith('include')]}


def collect_dictionary():
    if len(arguments) not in (1,2):
        raise RuntimeError('dictionary driver requires fresh results directory and optional compiled fixed-Keynote OSA helper')
    results=Path(arguments[0])
    if globals().get('dictionary_target') is not None and len(arguments)!=2:
        raise RuntimeError('fixed dictionary target requires an explicitly supplied native helper')
    artifact=results/'keynote-dictionary.json'
    if not results.is_dir() or artifact.exists(): raise RuntimeError('results directory is absent or already used')
    evidence={'result':'INCONCLUSIVE','files':[], 'note':'Fixed guest Keynote resources/sdef only; application launch is allowed setup, no API assumed.'}
    deadline=time.monotonic()+240
    def save(): artifact.write_text(json.dumps(evidence,indent=2)+'\n')
    def call(options,limit):
        remaining=deadline-time.monotonic()
        if remaining<=0: raise RuntimeError('dictionary collection deadline exhausted')
        response=request({'Executable':'/usr/bin/python','Arguments':['-c',COLLECTOR,*options]},min(limit,remaining))
        if not isinstance(response,dict) or 'Error' in response or type(response.get('ExitCode')) is not int or response['ExitCode']!=0:
            evidence['failed_response']=response
            raise RuntimeError(f'fixed dictionary command failed: {response!r}')
        text=response.get('Stdout')
        if not isinstance(text,str) or len(text)>300*1024: raise ValueError('oversize/invalid dictionary response')
        return json.loads(text)
    try:
        save()
        operation=['collect']
        if len(arguments)==2:
            helper=Path(arguments[1])
            if not helper.is_file() or not 0<helper.stat().st_size<=4*1024*1024:
                raise ValueError('host OSA helper is absent or exceeds4MiB')
            helper_hash=hashlib.sha256(helper.read_bytes()).hexdigest()
            evidence['native_helper']={'path':str(helper),'sha256':helper_hash}
            save()
            reusable=globals().get('staged_dictionary_helper')
            if reusable is not None:
                if not isinstance(reusable,dict) or reusable.get('sha256')!=helper_hash:
                    raise ValueError('reused staged helper differs from host helper bytes')
                guest_helper=reusable.get('path')
            else:
                guest_helper=stage(helper)
            if not isinstance(guest_helper,str) or not re.fullmatch(r'/private/var/tmp/VirtualIntelMac\.[A-Za-z0-9]{6}/Transfer\.bin',guest_helper):
                raise ValueError('unexpected OSA helper staging receipt')
            operation=['collect-native',guest_helper,helper_hash]
            target=globals().get('dictionary_target')
            if target is not None:
                if (not isinstance(target,dict) or target.get('selector') not in ('keynote','numbers','pages') or
                        target.get('location') not in ('direct','iwork09') or not isinstance(target.get('expected'),dict)):
                    raise ValueError('invalid fixed dictionary target metadata')
                operation=['collect-native-target',guest_helper,helper_hash,target['selector'],target['location'],json.dumps(target['expected'])]
        receipt=call(operation,40)
        evidence['receipt']=receipt
        save()
        directory=receipt.get('directory')
        if not isinstance(directory,str) or not re.fullmatch(r'/private/var/tmp/LightClickKeynote\.[A-Za-z0-9_-]{6,16}',directory):
            raise ValueError('unexpected collection directory')
        descriptors=receipt['manifest']['files']
        if not isinstance(descriptors,list) or len(descriptors)>67: raise ValueError('invalid file manifest')
        total=0
        seen=set()
        for descriptor in descriptors:
            selector,count,identity,expected=(descriptor.get(key) for key in ('selector','bytes','identity','sha256'))
            if (not isinstance(selector,str) or not re.fullmatch(r'resource-[0-9]{3}|sdef-stdout|sdef-stderr|sdef-native',selector)
                    or selector in seen or type(count) is not int or not 0<count<=2*1024*1024 or
                    not isinstance(expected,str) or not re.fullmatch('[0-9a-f]{64}',expected) or not isinstance(identity,list)):
                raise ValueError('invalid bounded output descriptor')
            seen.add(selector); total+=count
            if total>22*1024*1024: raise ValueError('total collector output budget exceeded')
            target=results/(selector+'.bin')
            partial=results/(selector+'.partial')
            digest=hashlib.sha256()
            with partial.open('xb') as output:
                for offset in range(0,count,192*1024):
                    length=min(192*1024,count-offset)
                    item=call(['chunk',directory,selector,str(offset),str(length),json.dumps(identity)],20)
                    payload=item.get('base64')
                    if not isinstance(payload,str) or len(payload)>262144: raise ValueError('oversize chunk payload')
                    data=base64.b64decode(payload,validate=True)
                    if (item.get('selector')!=selector or type(item.get('offset')) is not int or item['offset']!=offset or
                            type(item.get('bytes')) is not int or item['bytes']!=length or len(data)!=length or
                            item.get('identity')!=identity or hashlib.sha256(data).hexdigest()!=item.get('sha256')):
                        raise ValueError('chunk identity/range/hash mismatch')
                    output.write(data); digest.update(data)
            data=partial.read_bytes()
            if len(data)!=count or digest.hexdigest()!=expected or hashlib.sha256(data).hexdigest()!=expected:
                raise ValueError('final output bytes/hash mismatch')
            os.link(partial,target); partial.unlink()
            record=dict(descriptor,artifact=str(target))
            if (selector=='sdef-native' or selector=='sdef-stdout' and
                    receipt['manifest'].get('extractor',{}).get('mode')!='native-osa' or
                    str(descriptor.get('relative_path','')).lower().endswith('.sdef')):
                try: record['dictionary']=dictionary_summary(data)
                except (ValueError,ET.ParseError) as error: record['parse_error']=str(error)
            evidence['files'].append(record); save()
        evidence.update(result='PASS_COLLECTION',export_api_status='REVIEW_INSTALLED_DICTIONARY_NO_API_ASSUMED')
        save()
        print(f'PASS fixed Keynote dictionary/resource collection; evidence {artifact}',flush=True)
    except (Exception,SystemExit) as error:
        evidence['error']=repr(error); save(); raise


collect_dictionary()
