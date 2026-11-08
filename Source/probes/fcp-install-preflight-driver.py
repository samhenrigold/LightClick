"""Same-boot disposable guest install/launch diagnostic. CASE ABS_NEW_RESULTS EXISTING_X86_AX_HELPER.
Fixed user DMGs only. No host mounts/installers, Seamless, document/media operations or UI input.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import sys
sys.path.insert(0,str(source/'scripts'))
from fcp_preflight import GUEST, qualify_launch, wire_bool

CASES={
 'mavericks-10.1':dict(dmg='/Users/shg/Downloads/FinalCutPro-10.1.dmg',os_prefix='10.9.',variant='10.1',kind='app',payload='Final Cut Pro.app',app='/Applications/Final Cut Pro.app',identity=dict(CFBundleIdentifier='com.apple.FinalCut',CFBundleShortVersionString='10.1',CFBundleVersion='238755',CFBundleExecutable='Final Cut Pro')),
 'mojave-10.4.4':dict(dmg='/Users/shg/Downloads/FinalCutPro-10.4.4.dmg',os_prefix='10.14.',variant='10.4.4',kind='pkg',payload='FinalCutProXTrial.pkg',app='/Applications/Final Cut Pro Trial.app',identity=dict(CFBundleIdentifier='com.apple.FinalCutTrial',CFBundleShortVersionString='10.4.4',CFBundleVersion='330236',CFBundleExecutable='Final Cut Pro Trial')),
}


def checked_response(response):
    if not isinstance(response,dict) or response.get('ExitCode')!=0 or response.get('Error'):
        raise ValueError('guest command failed: '+repr(response))
    text=response.get('Stdout')
    if not isinstance(text,str) or len(text.encode('utf-8'))>2*1024*1024:raise ValueError('guest output missing/outside budget')
    return text


def experiment():
    if len(arguments)!=3 or arguments[0] not in CASES:raise ValueError('requires fixed case mavericks-10.1/mojave-10.4.4, new absolute results, existing x86 AX helper')
    spec=dict(CASES[arguments[0]])
    output=Path(arguments[1]);dmg=Path(spec['dmg'])
    if not output.is_absolute() or output.exists():raise ValueError('new absolute results required')
    info=dmg.lstat()
    if not stat.S_ISREG(info.st_mode) or str(dmg.resolve())!=spec['dmg']:raise ValueError('fixed user DMG must be canonical regular file')
    output.mkdir(parents=True)
    evidence=dict(result='INCONCLUSIVE',case=arguments[0],spec=spec,dmg_bytes=info.st_size,dmg_mtime_ns=info.st_mtime_ns,
                  note='Installation and observed launch in one disposable boot; not app/media/render correctness or performance qualification. No input or alert dismissal.')
    def save(): (output/'result.json').write_text(json.dumps(evidence,indent=2)+'\n')
    inserted=False;ambiguous=False
    save()
    try:
        if len(arguments)==3:
            helper=Path(arguments[2])
            if not helper.is_file() or helper.is_symlink() or not 0<helper.stat().st_size<=2097152:raise ValueError('existing AX helper required')
            with helper.open('rb') as file:header=file.read(8)
            if header!=bytes.fromhex('cffaedfe07000001'):raise ValueError('thin x86_64 AX helper required')
            evidence['ax_helper_sha256']=hashlib.sha256(helper.read_bytes()).hexdigest()
            spec['ax_helper_sha256']=evidence['ax_helper_sha256']
            spec['ax_helper']=stage(helper)
            if not isinstance(spec['ax_helper'],str) or not re.fullmatch(r'/private/var/tmp/VirtualIntelMac\.[A-Za-z0-9]{6}/Transfer\.bin',spec['ax_helper']):raise ValueError('invalid helper staging receipt')
        response=request({'Executable':'/usr/sbin/diskutil','Arguments':['list','-plist']},30)
        evidence['before_response']=response;save()
        before=plistlib.loads(checked_response(response).encode()).get('WholeDisks')
        if not isinstance(before,list) or not before or any(not isinstance(name,str) or not name.startswith('disk') or not name[4:].isdigit() for name in before):raise ValueError('invalid before whole-disk inventory')
        response=request({'Action':'insert-disc','Path':spec['dmg'],'Slot':0},120)
        evidence['insert_response']=response;save()
        if not isinstance(response,dict) or response.get('Error') or not wire_bool(response.get('Inserted'),True):raise ValueError('readonly image insertion not confirmed')
        inserted=True
        response=request({'Executable':'/usr/bin/python','Arguments':['-c',GUEST,json.dumps([spec,before])]},1100)
        evidence['collector_response']=response;save()
        guest=json.loads(checked_response(response))
        (output/'guest-report.json').write_text(json.dumps(guest,indent=2)+'\n')
        evidence['guest']=guest;evidence['result']=qualify_launch(guest);save()
        # Detach only this inserted slot after a completed collector response; root cleanup owns ambiguous runs.
        if guest.get('disk',{}).get('DeviceIdentifier'):
            device=guest['disk']['DeviceIdentifier']
            if not isinstance(device,str) or not device.startswith('disk') or not device[4:].isdigit():raise ValueError('invalid retained whole-disk identity')
            response=request({'Executable':'/usr/sbin/diskutil','Arguments':['eject','/dev/'+device]},30)
            evidence['eject_response']=response;checked_response(response);save()
    except SystemExit as error:
        ambiguous=True;evidence['error']=repr(error);save();raise
    except Exception as error:
        evidence['error']=repr(error);save();raise
    finally:
        if inserted and not ambiguous:
            try:
                response=request({'Action':'insert-disc','Path':'','Slot':0},120)
                evidence['detach_response']=response
                if not isinstance(response,dict) or response.get('Error') or not wire_bool(response.get('Inserted'),False):evidence['result']='INCONCLUSIVE';evidence['detach_error']='detach not confirmed'
            except BaseException as error:
                evidence['result']='INCONCLUSIVE';evidence['detach_error']=repr(error)
        save()
    print(evidence['result']+' FCP install/launch observations; review '+str(output/'result.json'),flush=True)


experiment()
