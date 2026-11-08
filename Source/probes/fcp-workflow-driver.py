"""guest-bench CASE NEW_RESULTS EXISTING_AX_OBSERVER EXISTING_SURGICAL_HELPER [EXISTING_LIBRARY_ACTION_HELPER [new-private-library|create-private-library|create-and-open-private-project|create-open-and-retain-for-display|create-open-hid-and-retain-for-display|create-open-hid-inspect-master-share|create-open-hid-inspect-master-settings|create-open-hid-inspect-master-transcode-save-panel|create-open-hid-export-h264] [PRIVATE_EXPORT_VERIFIER]].
Prepares verified generated media/XML, then inventories the live editor's actual menus.
One standard OS-open attempt of generated XML; optional grounded New-library dialog helper.
No guessed Save controls or import/playback/export qualification.
"""
import base64
import hashlib
import json
from pathlib import Path
import plistlib
import re
import stat
import sys
import time
sys.path.insert(0,str(source/'scripts'))
from fcp_workflow import compose_guest, hold_retained_display_window, load_preflight, valid_retention_receipt, workflow_checked_response, xml_template
from fcp_preflight import wire_bool
from fcp_export import fetch_private_export_report

FIXTURE=Path('/private/tmp/lightclick-fcp-fixture-v1.dmg')


def run_workflow():
    if len(arguments) not in (4,5,6,7):raise ValueError('requires fixed FCP case, new absolute results, existing observer, existing surgical helper')
    case,out,observer,helper=arguments[:4]
    requested_mode=arguments[5] if len(arguments)>=6 else 'new-private-library'
    export_private=requested_mode=='create-open-hid-export-h264'
    if export_private != (len(arguments)==7):raise ValueError('private export requires its explicit grounded verifier argument')
    inspect_share=requested_mode in ('create-open-hid-inspect-master-share','create-open-hid-inspect-master-settings','create-open-hid-inspect-master-transcode-save-panel','create-open-hid-export-h264')
    share_action={'create-open-hid-inspect-master-settings':'inspect-master-settings','create-open-hid-inspect-master-transcode-save-panel':'inspect-master-transcode-save-panel','create-open-hid-export-h264':'export-h264-private-fixture'}.get(requested_mode,'inspect-master-share')
    hid_project=requested_mode in ('create-open-hid-and-retain-for-display','create-open-hid-inspect-master-share','create-open-hid-inspect-master-settings','create-open-hid-inspect-master-transcode-save-panel','create-open-hid-export-h264')
    retain_app=requested_mode in ('create-open-and-retain-for-display','create-open-hid-and-retain-for-display')
    open_project=requested_mode in ('create-and-open-private-project','create-open-and-retain-for-display','create-open-hid-and-retain-for-display','create-open-hid-inspect-master-share','create-open-hid-inspect-master-settings','create-open-hid-inspect-master-transcode-save-panel','create-open-hid-export-h264')
    action_mode='create-private-library' if open_project else requested_mode
    if requested_mode not in ('new-private-library','create-private-library','create-and-open-private-project','create-open-and-retain-for-display','create-open-hid-and-retain-for-display','create-open-hid-inspect-master-share','create-open-hid-inspect-master-settings','create-open-hid-inspect-master-transcode-save-panel','create-open-hid-export-h264') or (len(arguments)>=5 and case!='mavericks-10.1'):raise ValueError('library mode must be explicit and grounded for FCP10.1 before staging')
    output=Path(out)
    if case not in ('mavericks-10.1','mojave-10.4.4') or not output.is_absolute() or output.exists():raise ValueError('fixed case and new absolute results required')
    if not stat.S_ISREG(FIXTURE.lstat().st_mode) or FIXTURE.resolve()!=FIXTURE:raise ValueError('fixed readonly fixture image unavailable')
    helper=Path(helper)
    if not helper.is_file() or helper.is_symlink() or not 0<helper.stat().st_size<=2097152:raise ValueError('existing bounded surgical helper required')
    with helper.open('rb') as stream:header=stream.read(8)
    if header!=bytes.fromhex('cffaedfe07000001'):raise ValueError('surgical helper must be thin x86_64')
    ns=load_preflight(source/'probes/fcp-install-preflight-driver.py',globals())
    ns['checked_response']=workflow_checked_response(ns['checked_response'])
    template,manifest=xml_template(source)
    ns['GUEST']=compose_guest(ns['GUEST'])
    output.mkdir(parents=True)
    evidence=dict(result='INCONCLUSIVE',case=case,fixture_image=str(FIXTURE),xml_template_manifest=manifest,setup_commands=[],
                  scope='Generated media/XML open and observations, with an optional grounded New-library dialog action; no import/library/playback/export qualification or performance claim.')
    if export_private:evidence['scope']='One private generated H264 export and bounded media verification; no app performance or full fidelity qualification'
    attached=False;ambiguous=False;retained_for_observation=False
    def save(): (output/'result.json').write_text(json.dumps(evidence,indent=2)+'\n')
    def tracked(command,timeout):
        nonlocal ambiguous
        try:return request(command,timeout)
        except SystemExit:
            ambiguous=True
            raise
    def tracked_stage(program):
        nonlocal ambiguous
        try:return stage(program)
        except SystemExit:
            ambiguous=True
            raise
    def setup(command,timeout=30):
        response=tracked(command,timeout)
        evidence['setup_commands'].append(dict(command=command,response=response));save()
        return response
    def disks():
        response=setup({'Executable':'/usr/sbin/diskutil','Arguments':['list','-plist']})
        names=plistlib.loads(ns['checked_response'](response).encode()).get('WholeDisks')
        if not isinstance(names,list) or not names or any(not isinstance(x,str) or not re.fullmatch(r'disk[0-9]+',x) for x in names):raise ValueError('invalid fixture disk baseline')
        return set(names)
    save()
    try:
        receipt=tracked_stage(helper)
        if not isinstance(receipt,str) or not re.fullmatch(r'/private/var/tmp/VirtualIntelMac\.[A-Za-z0-9]{6}/Transfer\.bin',receipt):raise ValueError('invalid surgical helper staging receipt')
        extra=dict(workflow_helper=receipt,workflow_helper_sha256=hashlib.sha256(helper.read_bytes()).hexdigest(),
                   workflow_xml_template=base64.b64encode(template).decode(),workflow_xml_template_sha256=hashlib.sha256(template).hexdigest())
        if len(arguments)>=5:
            if case!='mavericks-10.1':raise ValueError('library action helper currently grounded only for FCP10.1')
            action_helper=Path(arguments[4])
            if not action_helper.is_file() or action_helper.is_symlink() or not 0<action_helper.stat().st_size<=2097152:raise ValueError('bounded existing action helper required')
            with action_helper.open('rb') as stream:header=stream.read(8)
            if header!=bytes.fromhex('cffaedfe07000001'):raise ValueError('action helper must be thin x86_64')
            action_receipt=tracked_stage(action_helper)
            if not isinstance(action_receipt,str) or not re.fullmatch(r'/private/var/tmp/VirtualIntelMac\.[A-Za-z0-9]{6}/Transfer\.bin',action_receipt):raise ValueError('invalid action helper staging receipt')
            extra.update(workflow_master_share_action=share_action,workflow_inspect_master_share=inspect_share,workflow_open_project_hid=hid_project,workflow_close_system_memory_notice=hid_project,workflow_retain_owned_app=retain_app,workflow_open_generated_project=open_project,workflow_action_mode=action_mode,workflow_action_helper=action_receipt,workflow_action_helper_sha256=hashlib.sha256(action_helper.read_bytes()).hexdigest())
            evidence['library_actions_requested']=True;evidence['requested_workflow_mode']=requested_mode;save()
        if export_private:
            verifier=Path(arguments[6])
            if not verifier.is_file() or verifier.is_symlink() or not 0<verifier.stat().st_size<=2097152:raise ValueError('bounded existing export verifier required')
            verifier_data=verifier.read_bytes()
            verifier_sha=hashlib.sha256(verifier_data).hexdigest()
            if verifier_data[:8]!=bytes.fromhex('cffaedfe07000001') or verifier_sha!='798516cf2ae54e80bceb0dc9e6fa1f7121fd698df248b7a1d977504d4db27739':raise ValueError('pinned x86_64 export verifier changed')
            verifier_receipt=tracked_stage(verifier)
            if not isinstance(verifier_receipt,str) or not re.fullmatch(r'/private/var/tmp/VirtualIntelMac\.[A-Za-z0-9]{6}/Transfer\.bin',verifier_receipt):raise ValueError('invalid export verifier staging receipt')
            extra.update(workflow_export_verifier=verifier_receipt,workflow_export_verifier_sha256=verifier_sha)
            evidence['export_verifier_sha256']=verifier_sha;save()

        baseline=disks()
        inserted=setup({'Action':'insert-disc','Path':str(FIXTURE),'Slot':1},120)
        if inserted.get('Error') or not wire_bool(inserted.get('Inserted'),True):raise ValueError('fixture insertion unconfirmed')
        attached=True
        deadline=time.monotonic()+60
        while True:
            new=disks()-baseline
            if len(new)>1:raise ValueError('multiple new fixture disks')
            if len(new)==1:
                device=next(iter(new))
                info=plistlib.loads(ns['checked_response'](setup({'Executable':'/usr/sbin/diskutil','Arguments':['info','-plist','/dev/'+device]})).encode())
                if info.get('DeviceIdentifier')!=device or info.get('Internal') is not False or info.get('BusProtocol')!='USB':raise ValueError('fixture is not unique new externalUSB disk')
                setup({'Executable':'/usr/sbin/diskutil','Arguments':['mountDisk','/dev/'+device]})
                listing=plistlib.loads(ns['checked_response'](setup({'Executable':'/usr/sbin/diskutil','Arguments':['list','-plist','/dev/'+device]})).encode())
                def has_volume(value):
                    if isinstance(value,dict):return (value.get('VolumeName')=='LC_FCP_Fixture' and value.get('MountPoint')=='/Volumes/LC_FCP_Fixture') or any(has_volume(v) for v in value.values())
                    if isinstance(value,list):return any(has_volume(v) for v in value)
                    return False
                if not has_volume(listing):raise ValueError('fixture exact volume/mount not observed')
                evidence['fixture_disk']=info;save();break
            if time.monotonic()>=deadline:raise ValueError('fixture disk did not enumerate')
            time.sleep(1)
        ns['CASES']={case:dict(ns['CASES'][case],**extra)}
        ns.update(arguments=[case,str(output/'preflight'),observer],request=tracked,stage=tracked_stage)
        ns['experiment']()
        preflight=json.loads((output/'preflight/result.json').read_text())
        evidence['preflight_result']=preflight['result']
        workflow=preflight.get('guest',{}).get('workflow',{})
        evidence['workflow']=workflow
        inventory=workflow.get('inventory',{})
        def valid_inventory(value):
            return (value.get('result')=='MENU_INVENTORY' and value.get('variant')==ns['CASES'][case]['variant']
                    and type(value.get('pid')) is int and value['pid']==preflight.get('guest',{}).get('owned_app_pid') and value.get('mode')=='inventory'
                    and all(wire_bool(value.get(k),True) for k in ('identityMatched','identityStillMatched','axTrusted','readOnly'))
                    and wire_bool(value.get('trustRequested'),False) and value.get('actionsPerformed')==[])
        if valid_inventory(inventory):
            if workflow.get('import_attempted') is True:
                evidence['result']='OS_OPEN_COMPLETED_REQUIRES_REVIEW' if workflow.get('open_command_completed') is True and valid_inventory(workflow.get('inventory_after_open',{})) else 'OS_OPEN_ATTEMPT_INCONCLUSIVE'
            else:evidence['result']='PREPARED_MENU_INVENTORY'
        if workflow.get('library_action_attempted') is True:
            action=workflow.get('library_action',{})
            evidence['result']='LIBRARY_ACTION_INCONCLUSIVE'
            if (action.get('result')=='NEW_LIBRARY_PANEL_OBSERVED_REQUIRES_REVIEW' and action.get('variant')==ns['CASES'][case]['variant']
                    and type(action.get('pid')) is int and action['pid']==preflight.get('guest',{}).get('owned_app_pid')
                    and all(wire_bool(action.get(key),True) for key in ('identityMatched','identityStillMatched','axTrusted'))
                    and valid_inventory(workflow.get('inventory_after_library_action',{}))):evidence['result']='LIBRARY_PANEL_OBSERVED_REQUIRES_REVIEW'
            artifact=workflow.get('library_artifact',{})
            if (action_mode=='create-private-library' and action.get('result')=='PRIVATE_LIBRARY_CREATED_REQUIRES_IMPORT_REVIEW'
                    and action.get('variant')==ns['CASES'][case]['variant'] and type(action.get('pid')) is int and action['pid']==preflight.get('guest',{}).get('owned_app_pid')
                    and all(wire_bool(action.get(key),True) for key in ('identityMatched','identityStillMatched','axTrusted','privateLibraryVerified'))
                    and artifact.get('path')==workflow.get('directory','')+'/private.fcpbundle' and artifact.get('exists') is True and artifact.get('is_directory') is True and artifact.get('is_symlink') is False
                    and valid_inventory(workflow.get('inventory_after_library_action',{}))):evidence['result']='PRIVATE_LIBRARY_CREATED_REQUIRES_IMPORT_REVIEW'


        if open_project and workflow.get('project_open_attempted') is True:
            evidence['result']='PROJECT_OPEN_ATTEMPT_REQUIRES_REVIEW'
        elif open_project:evidence['project_open_skipped']=workflow.get('project_open_skipped','project evidence missing')
        if inspect_share:
            evidence['result']='MASTER_SHARE_INSPECTION_REQUIRES_REVIEW' if workflow.get('master_share_inspection_attempted') is True else 'MASTER_SHARE_EVIDENCE_GATE_NOT_SATISFIED'

        if export_private:
            verification=workflow.get('export_verification',{})
            evidence['export_verification']=verification
            evidence['result']='PRIVATE_EXPORT_VERIFICATION_INCONCLUSIVE'
            export_receipt=verification.get('stdout_receipt')
            receipt_bytes=export_receipt.get('bytes') if isinstance(export_receipt,dict) else None
            if type(receipt_bytes) is int and 1<=receipt_bytes<=524289:
                evidence['export_verification_artifacts']=fetch_private_export_report(tracked,export_receipt,workflow['directory'],preflight['guest']['console_uid'],output/'export-verification')
                artifact=evidence['export_verification_artifacts']
                if verification.get('structure_qualified') is True and verification.get('app_alive_after') is True and artifact.get('closed_media_revalidated') is True:
                    evidence['result']='PRIVATE_EXPORT_STRUCTURE_QUALIFIED_FIDELITY_REQUIRES_REVIEW'
            else:
                evidence['verifier_report_unavailable']={'reason':'empty verifier stdout' if type(receipt_bytes) is int and receipt_bytes==0 else 'missing or outside bounded verifier stdout receipt',
                                                       'receipt_bytes':receipt_bytes,'stdout_protocol_limit':524289}
            save()

        if retain_app:
            guest=preflight.get('guest',{})
            evidence['retained_owned_app']=guest.get('retained_owned_app',{})
            if valid_retention_receipt(guest,preflight['spec']):
                retained_for_observation=True
                evidence['result']='RETAINED_OWNED_APP_FOR_DISPLAY_DIAGNOSTIC'
                # No further diagnostic commands: the host may use the now-free channel serially.
                # At deadline/interrupt, guest-bench's finally tears down the entire disposable VM.
                hold_retained_display_window(evidence,save)
            else:evidence['result']='RETENTION_GATE_NOT_SATISFIED'


    except BaseException as error:
        evidence['error']=repr(error);save();raise
    finally:
        if attached and not ambiguous and not retained_for_observation:
            try:
                fixture_device=evidence.get('fixture_disk',{}).get('DeviceIdentifier')
                if not isinstance(fixture_device,str) or not re.fullmatch(r'disk[0-9]+',fixture_device):raise ValueError('fixture whole-disk identity missing; no blind detach')
                ns['checked_response'](setup({'Executable':'/usr/sbin/diskutil','Arguments':['eject','/dev/'+fixture_device]},30))
                response=setup({'Action':'insert-disc','Path':'','Slot':1},120)
                if response.get('Error') or not wire_bool(response.get('Inserted'),False):evidence['result']='INCONCLUSIVE';evidence['detach_error']='fixture detach unconfirmed'
            except BaseException as error:evidence['result']='INCONCLUSIVE';evidence['detach_error']=repr(error)
        save()
    print(evidence['result']+' fixture/menu observations: '+str(output),flush=True)


run_workflow()
