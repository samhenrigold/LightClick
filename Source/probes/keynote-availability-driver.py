"""guest-bench read-only inventory: fixed /Applications iWork paths and /System version only. No app launch.

One argument: existing fresh host results directory. SDEF source is retained verbatim before planning any export API.
"""
import base64
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET

INVENTORY = r'''import base64, binascii, hashlib, json, os, plistlib, signal, stat, struct, sys
signal.alarm(15)
APPS = ['/Applications/Keynote.app', "/Applications/iWork '09/Keynote.app",
        "/Applications/iWork '09/Numbers.app", "/Applications/iWork '09/Pages.app"]
SYSTEM = '/System/Library/CoreServices/SystemVersion.plist'
def regular(path, limit):
    if os.path.realpath(path) != path:
        raise ValueError('refusing noncanonical fixed app/system path')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= limit:
            raise ValueError('file is not regular/nonempty/within budget')
        return fd, info
    except:
        os.close(fd)
        raise
def contents(path, limit):
    fd, info = regular(path, limit)
    try:
        data = os.read(fd, limit+1)
        if len(data) != info.st_size:
            raise ValueError('file changed size or read was incomplete')
        return data
    finally:
        os.close(fd)
def header(fd, offset, size):
    os.lseek(fd, offset, os.SEEK_SET)
    data = os.read(fd, size)
    if len(data) != size:
        raise ValueError('short Mach-O header')
    return data
def architecture(data):
    magic = data[:4]
    formats = {b'\xce\xfa\xed\xfe': ('<',32), b'\xcf\xfa\xed\xfe': ('<',64),
               b'\xfe\xed\xfa\xce': ('>',32), b'\xfe\xed\xfa\xcf': ('>',64)}
    if magic not in formats:
        raise ValueError('unknown Mach-O magic')
    endian, width = formats[magic]
    cpu, subtype, kind = struct.unpack(endian+'III', data[4:16])
    names = {7:'i386',0x1000007:'x86_64',18:'ppc',0x1000012:'ppc64'}
    return {'architecture':names.get(cpu,'unknown'), 'bits':width, 'cpu_type':cpu,
            'cpu_subtype':subtype, 'file_type':kind, 'header_hex':binascii.hexlify(data[:28 if width==32 else 32]).decode('ascii')}
def macho(path):
    fd, info = regular(path, 512*1024*1024)
    try:
        first = header(fd,0,8)
        magic = first[:4]
        if magic in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
            count = struct.unpack('>I',first[4:])[0]
            if not 0 < count <= 16:
                raise ValueError('invalid fat slice count')
            size = 32 if magic==b'\xca\xfe\xba\xbf' else 20
            table = header(fd,8,count*size)
            slices = []
            for i in range(count):
                entry = struct.unpack('>IIQQII' if size==32 else '>IIIII',table[i*size:(i+1)*size])
                cpu, subtype, offset, length = entry[:4]
                if length < 32 or offset < 8+count*size or offset+length > info.st_size:
                    raise ValueError('invalid fat slice bounds')
                item = architecture(header(fd,offset,32))
                if item['cpu_type'] != cpu or item['cpu_subtype'] != subtype:
                    raise ValueError('fat/header architecture mismatch')
                item.update(offset=offset, bytes=length)
                slices.append(item)
        else:
            slices = [architecture(header(fd,0,32))]
        return {'path':path, 'bytes':info.st_size, 'owner_uid':info.st_uid, 'slices':slices}
    finally:
        os.close(fd)
def app(index):
    path = APPS[index]
    result = {'index':index, 'path':path, 'present':False, 'sdef':[]}
    try:
        info = os.lstat(path)
    except OSError:
        return result
    result['present'] = True
    try:
        if os.path.realpath(path) != path or not stat.S_ISDIR(info.st_mode):
            raise ValueError('app is not a canonical directory')
        metadata = plistlib.readPlistFromString(contents(path+'/Contents/Info.plist',512*1024))
        result['bundle'] = dict((key,metadata.get(key)) for key in
            ('CFBundleIdentifier','CFBundleVersion','CFBundleShortVersionString','CFBundleExecutable',
             'OSAScriptingDefinition','NSAppleScriptEnabled','LSMinimumSystemVersion'))
        executable = metadata.get('CFBundleExecutable')
        if not isinstance(executable,basestring) or executable in ('.','..') or '/' in executable or '\x00' in executable:
            raise ValueError('invalid executable basename')
        result['macho'] = macho(path+'/Contents/MacOS/'+executable)
        resources = path+'/Contents/Resources'
        declared = metadata.get('OSAScriptingDefinition')
        names = []
        if isinstance(declared,basestring):
            if declared.startswith('/') or '..' in declared.split('/') or '\x00' in declared:
                raise ValueError('invalid SDEF resource name')
            names.append(declared)
        else:
            listing = os.listdir(resources)
            if len(listing)>4096:
                raise ValueError('resource listing exceeds metadata budget')
            names = sorted(name for name in listing if name.endswith('.sdef'))[:4]
        for name in names:
            try:
                data = contents(resources+'/'+name,192*1024)
                result['sdef'].append({'resource':name,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()})
            except Exception as error:
                result.setdefault('sdef_errors',[]).append(str(error))
        if not result['sdef']:
            result['sdef_note'] = 'No readable direct SDEF resource; do not guess AppleScript API or launch app to obtain one.'
    except Exception as error:
        result['error'] = str(error)
    return result
operation = sys.argv[1]
if operation == 'inventory' and len(sys.argv)==2:
    system = plistlib.readPlistFromString(contents(SYSTEM,65536))
    result = {'system':dict((key,system.get(key)) for key in ('ProductName','ProductVersion','ProductBuildVersion')),
              'apps':[app(i) for i in range(len(APPS))], 'scope':'fixed Applications/System metadata only; no app launched'}
elif operation == 'sdef' and len(sys.argv)==4 and sys.argv[2].isdigit() and sys.argv[3].isdigit():
    index, item = int(sys.argv[2]), int(sys.argv[3])
    if not 0 <= index < len(APPS): raise ValueError('invalid fixed app selector')
    entry = app(index)
    if not 0 <= item < len(entry['sdef']): raise ValueError('invalid SDEF selector')
    descriptor = entry['sdef'][item]
    data = contents(APPS[index]+'/Contents/Resources/'+descriptor['resource'],192*1024)
    result = dict(descriptor, index=index, item=item, base64=base64.b64encode(data).decode('ascii'))
else:
    raise ValueError('invalid fixed metadata operation')
encoded = json.dumps(result)
if len(encoded)>300*1024:
    raise ValueError('metadata exceeds the control-response budget')
sys.stdout.write(encoded)
'''


def dictionary_metadata(data):
    if len(data)>192*1024 or b'<!ENTITY' in data.upper():
        raise ValueError('SDEF exceeds budget or declares entities')
    root = ET.fromstring(data)
    return {'commands':[dict(item.attrib, children=[dict(child.attrib, tag=child.tag) for child in item])
                        for item in root.findall('.//command')],
            'classes':[dict(item.attrib, properties=[dict(child.attrib) for child in item.findall('property')])
                       for item in root.findall('.//class')],
            'enumerations':[dict(item.attrib, values=[dict(child.attrib) for child in item])
                            for item in root.findall('.//enumeration')],
            'includes':[dict(item.attrib) for item in root.iter() if item.tag.endswith('include')]}


def availability():
    if len(arguments)!=1:
        raise RuntimeError('availability driver requires one existing fresh host results directory')
    results = Path(arguments[0])
    if not results.is_dir() or (results/'keynote-availability.json').exists():
        raise RuntimeError('availability results must be an existing fresh directory')
    evidence = {'result':'INCONCLUSIVE', 'scope':'read-only fixed Applications/System metadata; no app launched'}
    def save():
        (results/'keynote-availability.json').write_text(json.dumps(evidence,indent=2)+'\n')
    def call(operation, selectors, timeout=30):
        response = request({'Executable':'/usr/bin/python','Arguments':['-c',INVENTORY,operation,*selectors]},timeout)
        if not isinstance(response,dict) or 'Error' in response or type(response.get('ExitCode')) is not int or response['ExitCode']!=0:
            evidence['failed_response']=response
            raise RuntimeError(f'read-only metadata {operation} failed: {response!r}')
        text=response.get('Stdout')
        if not isinstance(text,str) or len(text)>300*1024:
            raise ValueError('metadata JSON exceeded envelope or is not text')
        return json.loads(text)
    try:
        save()
        inventory=call('inventory',[])
        evidence['inventory']=inventory
        save()
        dictionaries=[]
        for app in inventory['apps']:
            for item,descriptor in enumerate(app.get('sdef',[])):
                response=call('sdef',[str(app['index']),str(item)])
                encoded=response.get('base64')
                if not isinstance(encoded,str) or len(encoded)>262144:
                    raise ValueError('SDEF payload exceeds budget')
                data=base64.b64decode(encoded,validate=True)
                if (not 0<len(data)<=192*1024 or len(data)!=descriptor['bytes'] or
                        hashlib.sha256(data).hexdigest()!=descriptor['sha256'] or
                        any(response.get(key)!=descriptor[key] for key in ('resource','bytes','sha256')) or
                        response.get('index')!=app['index'] or response.get('item')!=item):
                    raise ValueError('SDEF changed between inventory and export')
                target=results/f'app-{app["index"]}-sdef-{item}.xml'
                with target.open('xb') as output: output.write(data)
                record=dict(app_index=app['index'],artifact=str(target),**descriptor)
                try:
                    record['dictionary']=dictionary_metadata(data)
                except (ValueError,ET.ParseError) as error:
                    record['parse_error']=str(error)
                dictionaries.append(record)
                evidence['dictionaries']=dictionaries
                save()
        candidates=[item for item in inventory['apps'] if item['index'] in (0,1) and item.get('present') and
                    not item.get('error') and any(entry['app_index']==item['index'] and 'dictionary' in entry for entry in dictionaries)]
        evidence.update(result='PASS_INVENTORY',dictionaries=dictionaries, keynote_candidates=candidates,
                        benchmark_preflight_status='SDEF_REVIEW_REQUIRED' if candidates else 'NO_USABLE_KEYNOTE_SDEF',
                        export_status='NOT_PREPARED: review actual version/SDEF before choosing document creation/export commands.')
        save()
        print(f'PASS read-only iWork availability inventory; no app launched; evidence {results}',flush=True)
    except (Exception,SystemExit) as error:
        evidence['error']=repr(error)
        save()
        raise


availability()
