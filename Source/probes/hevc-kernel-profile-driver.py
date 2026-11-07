"""No-UI guest-bench driver: NEW_ABSOLUTE_RESULTS EXISTING_X86_PROBE PRIOR_GUEST_REPORT.
Run through guest-bench --driver; no Seamless hooks, retries, UI, raw images or guest app launches.
"""
import hashlib
import json
from pathlib import Path
import sys
sys.path.insert(0,str(source/'scripts'))
from hevc_kernel_profile import GUEST, PROFILE, parse_result


def experiment():
    if len(arguments)!=3: raise ValueError('requires new results, existing x86 probe, prior guest report')
    output,probe,prior=map(Path,arguments)
    if not output.is_absolute() or output.exists() or not probe.is_file() or probe.is_symlink() or not prior.is_file():
        raise ValueError('new absolute results and existing regular probe/reference required')
    with probe.open('rb') as file: header=file.read(8)
    if header != bytes.fromhex('cffaedfe07000001'): raise ValueError('existing thin x86_64 Mach-O required')
    reference=json.loads(prior.read_text())
    if reference.get('input_sha256')!='a84ed4faa376b8b2cb0328b306d09d25ad9047a0f7d106ad46098d0d91381256' or reference.get('input_bytes')!=134758820 or reference.get('requested_output_color_space') not in ('source','srgb') or reference.get('item_index')!=0 or reference.get('item_count')!=16:
        raise ValueError('verified fixed OS-image reference required')
    output.mkdir(parents=True)
    evidence=dict(result='INCOMPLETE',probe_sha256=hashlib.sha256(probe.read_bytes()).hexdigest(),reference=str(prior),dtrace_program=PROFILE,
                  note='Sampling diagnostic only; no performance timing claim. guest-bench owns clone/process cleanup after ambiguous transport failures.')
    try:
        guest=stage(probe)
        response=request({'Executable':'/usr/bin/python','Arguments':['-c',GUEST,json.dumps([guest,reference['requested_output_color_space'],PROFILE])]},80)
        (output/'response.json').write_text(json.dumps(response,indent=2)+'\n')
        if response.get('ExitCode')!=0 or response.get('Error'): raise ValueError('guest supervisor request failed')
        value=json.loads(response.get('Stdout') or '')
        (output/'supervisor.json').write_text(json.dumps(value,indent=2)+'\n')
        for name,row in value.get('files',{}).items():
            if name in ('dtrace.stdout','dtrace.stderr','probe.json','probe.stderr','probe.exit') and isinstance(row,dict) and isinstance(row.get('text'),str):
                (output/name).write_text(row['text'])
        evidence.update(parse_result(value,reference),result='COLLECTED')
    except BaseException as error:
        evidence.update(result='INCONCLUSIVE',error=repr(error))
        raise
    finally:
        (output/'result.json').write_text(json.dumps(evidence,indent=2)+'\n')
    print('COLLECTED guest kernel/VT sampling diagnostic: '+str(output),flush=True)


experiment()
