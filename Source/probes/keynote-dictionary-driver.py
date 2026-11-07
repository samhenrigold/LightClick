"""guest-bench: bounded fixed Keynote 5.3 resources + sdef extraction in a disposable guest.

One argument: existing fresh host results directory. sdef may launch Keynote inside the guest; no host input or Seamless.
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
def extract(directory):
    def limits():
        resource.setrlimit(resource.RLIMIT_FSIZE,(2*1024*1024,2*1024*1024))
        resource.setrlimit(resource.RLIMIT_CPU,(10,10))
    paths=[directory+'/sdef.stdout',directory+'/sdef.stderr']
    files=[os.fdopen(os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600),'wb') for path in paths]
    process=None
    try:
        process=subprocess.Popen(['/usr/bin/sdef',APP],stdin=open(os.devnull,'rb'),stdout=files[0],stderr=files[1],
                                 close_fds=True,preexec_fn=limits)
        deadline=time.time()+15
        while process.poll() is None and time.time()<deadline: time.sleep(0.05)
        expired=process.poll() is None
        if expired:
            process.kill()
            deadline=time.time()+2
            while process.poll() is None and time.time()<deadline: time.sleep(0.05)
        return {'command':['/usr/bin/sdef',APP],'exit_code':process.poll(),'timed_out':expired,
                'deadline_seconds':15,'output_file_cap':2*1024*1024,'cpu_limit_seconds':10}
    finally:
        if process is not None and process.poll() is None: process.kill()
        for output in files: output.close()
def collect():
    if os.path.realpath(APP)!=APP or not stat.S_ISDIR(os.lstat(APP).st_mode):
        raise ValueError('fixed Keynote app is absent/noncanonical')
    info=plistlib.readPlistFromString(read(APP+'/Contents/Info.plist',512*1024,APP))
    if str(info.get('CFBundleShortVersionString'))!='5.3' or str(info.get('CFBundleVersion'))!='1170':
        raise ValueError('fixed app changed from inventoried Keynote5.3 build1170')
    scripting=dict((key,value) for key,value in info.items() if 'script' in key.lower() or key.startswith('OSA') or key in
        ('CFBundleIdentifier','CFBundleName','CFBundleExecutable','CFBundleVersion','CFBundleShortVersionString','NSPrincipalClass'))
    os.umask(0o077)
    directory=tempfile.mkdtemp(prefix='LightClickKeynote.',dir='/private/var/tmp')
    private(directory)
    manifest={'app':APP,'info':scripting,'resources':[],'files':[]}
    paths,walk=resources()
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
        manifest['extractor']=extract(directory)
    except Exception as error:
        manifest['extractor']={'error':str(error)[:512]}
    for selector,name in (('sdef-stdout','sdef.stdout'),('sdef-stderr','sdef.stderr')):
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
    if len(arguments)!=1:
        raise RuntimeError('dictionary driver requires one fresh existing host results directory')
    results=Path(arguments[0])
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
        receipt=call(['collect'],40)
        evidence['receipt']=receipt
        save()
        directory=receipt.get('directory')
        if not isinstance(directory,str) or not re.fullmatch(r'/private/var/tmp/LightClickKeynote\.[A-Za-z0-9_-]{6,16}',directory):
            raise ValueError('unexpected collection directory')
        descriptors=receipt['manifest']['files']
        if not isinstance(descriptors,list) or len(descriptors)>66: raise ValueError('invalid file manifest')
        total=0
        seen=set()
        for descriptor in descriptors:
            selector,count,identity,expected=(descriptor.get(key) for key in ('selector','bytes','identity','sha256'))
            if (not isinstance(selector,str) or not re.fullmatch(r'resource-[0-9]{3}|sdef-stdout|sdef-stderr',selector)
                    or selector in seen or type(count) is not int or not 0<count<=2*1024*1024 or
                    not isinstance(expected,str) or not re.fullmatch('[0-9a-f]{64}',expected) or not isinstance(identity,list)):
                raise ValueError('invalid bounded output descriptor')
            seen.add(selector); total+=count
            if total>20*1024*1024: raise ValueError('total collector output budget exceeded')
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
            if selector=='sdef-stdout' or str(descriptor.get('relative_path','')).lower().endswith('.sdef'):
                try: record['dictionary']=dictionary_summary(data)
                except (ValueError,ET.ParseError) as error: record['parse_error']=str(error)
            evidence['files'].append(record); save()
        evidence.update(result='PASS_COLLECTION',export_api_status='REVIEW_INSTALLED_DICTIONARY_NO_API_ASSUMED')
        save()
        print(f'PASS fixed Keynote dictionary/resource collection; evidence {artifact}',flush=True)
    except (Exception,SystemExit) as error:
        evidence['error']=repr(error); save(); raise


collect_dictionary()
