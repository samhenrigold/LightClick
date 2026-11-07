"""Performance-only guest-bench driver. No Seamless, application UI, exports, dtrace, or new guest helper.
Arguments: NEW_RESULTS EXISTING_X86_PROBE TALLY_PREFIX CPU_COUNT DRAW_SECONDS IDLE_SECONDS PRIOR_GUEST_REPORT PROFILE_INVALIDATIONS_0_OR_1 MEMBERSHIP_0_OR_1
The opt-in resident probe hashes input once before the repeat loop and final pixels afterward. Periodic tallies remain coarse.
"""
import hashlib
import json
import math
import re
from pathlib import Path
import sys
import time

sys.path.insert(0, str(source/'scripts'))
from hevc_tally import TallyCollector, membership_qualification

OS_IMAGE = '/Library/Desktop Pictures/Mojave.heic'
INPUT_SHA256 = 'a84ed4faa376b8b2cb0328b306d09d25ad9047a0f7d106ad46098d0d91381256'
INPUT_BYTES = 134758820
COMPARE = ('input_sha256', 'input_bytes', 'pixel_sha256', 'item_index', 'item_count', 'width', 'height', 'row_bytes', 'output_bytes',
           'output_color_space', 'requested_output_color_space', 'source_color_space',
           'source_icc_bytes', 'source_icc_sha256', 'output_icc_bytes', 'output_icc_sha256',
           'orientation', 'orientation_applied', 'pixel_format', 'row_order', 'rendering_intent')


def validate_report(report, reference):
    if not isinstance(report, dict) or report.get('format_version') != 1 or report.get('mode') != 'full-resolution':
        raise ValueError('invalid existing image probe report')
    if report.get('input_sha256') != INPUT_SHA256 or report.get('input_bytes') != INPUT_BYTES:
        raise ValueError('probe did not read the fixed verified OS image')
    sizes = [report.get(key) for key in ('width', 'height', 'row_bytes', 'output_bytes')]
    if any(type(value) is not int or value <= 0 for value in sizes) or sizes[2] != sizes[0]*4 or sizes[3] != sizes[2]*sizes[1] or sizes[3] > 256*1024*1024:
        raise ValueError('invalid RGBA8 shape')
    if report.get('item_index') != 0 or report.get('item_count') != 16 or report.get('requested_output_color_space') not in ('source', 'srgb'):
        raise ValueError('wrong image item or output space')
    if not isinstance(report.get('pixel_sha256'), str) or not re.fullmatch('[0-9a-f]{64}', report['pixel_sha256']):
        raise ValueError('invalid actual pixel SHA')
    if any(report.get(key) != reference.get(key) for key in COMPARE):
        raise ValueError('probe bytes or metadata differ from prior guest reference')
    phases = report.get('timings_ms')
    required = ('forced_draw', 'input_hash', 'pixel_hash', 'total_before_report')
    if not isinstance(phases, dict) or any(type(phases.get(key)) not in (int, float)
            or not math.isfinite(phases[key]) or phases[key] < 0 for key in required):
        raise ValueError('invalid real probe phase timings')
    if phases['total_before_report'] < phases['forced_draw']:
        raise ValueError('draw exceeds total probe time')
    return report


def validate_repeat(report, requested):
    repeat = report.get('repeat_draw')
    if not isinstance(repeat, dict) or repeat.get('requested_seconds') != requested or repeat.get('iteration_limit') != 256:
        raise ValueError('missing resident repeat-draw contract')
    rows = repeat.get('per_iteration')
    if not isinstance(rows, list) or type(repeat.get('iterations')) is not int or not 1 <= len(rows) <= 256 or repeat['iterations'] != len(rows):
        raise ValueError('invalid repeat iteration count')
    elapsed = repeat.get('elapsed_seconds')
    if type(elapsed) not in (float, int) or not math.isfinite(elapsed) or elapsed < requested or repeat.get('termination') != 'duration':
        raise ValueError('resident loop did not reach requested duration')
    for row in rows:
        if not isinstance(row, dict) or any(type(row.get(key)) not in (int, float) or not math.isfinite(row[key]) or row[key] < 0
                for key in ('source_create_ms', 'image_create_ms', 'forced_draw_ms')):
            raise ValueError('invalid repeat iteration timings')
    draw_sum = sum(row['forced_draw_ms'] for row in rows)
    if not math.isclose(draw_sum, report['timings_ms']['forced_draw'], rel_tol=1e-9, abs_tol=1e-6) or draw_sum > elapsed*1000+.001:
        raise ValueError('repeat draw timing sums inconsistent')


def experiment():
    if len(arguments) != 9:
        raise ValueError('requires results, existing probe, tally prefix, cpu count, trials, idle seconds, prior guest report, expected invalidation profiling0/1, expected membership0/1')
    output, probe, prefix = map(Path, arguments[:3])
    cpus, draw_seconds, idle = map(int, arguments[3:6])
    reference_path = Path(arguments[6])
    if arguments[7] not in ('0', '1'):
        raise ValueError('expected invalidation profiling must be0/1')
    profile_expected = int(arguments[7])
    if arguments[8] not in ('0','1'):
        raise ValueError('expected membership must be0/1')
    membership_expected=int(arguments[8])
    if not output.is_absolute() or output.exists() or not prefix.is_absolute() or not 1 <= cpus <= 8 or not 10 <= draw_seconds <= 30 or not 8 <= idle <= 30:
        raise ValueError('new absolute results, absolute tally prefix, cpus1..8, draw_seconds10..30, idle8..30 required')
    if not probe.is_file() or probe.is_symlink() or not reference_path.is_file():
        raise ValueError('existing regular x86 probe and prior guest reference required')
    reference = json.loads(reference_path.read_text())
    validate_report(reference, reference)
    if reference.get('requested_output_color_space') not in ('source', 'srgb'):
        raise ValueError('reference must specify source or srgb')
    output.mkdir(parents=True)
    collector = TallyCollector(prefix, cpus, output/'snapshots')
    evidence = dict(result='INCOMPLETE', expected_vcpus=cpus, trials=[], phases={},
                    probe_sha256=hashlib.sha256(probe.read_bytes()).hexdigest(),
                    reference_report_sha256=hashlib.sha256(reference_path.read_bytes()).hexdigest(),
                    reference_report=str(reference_path), tally_prefix=str(prefix),
                    note='Resident warm-decode diagnostic, not an application-speed claim. Initial/final SHA are outside the guest repeat loop; coarse host request intervals also include setup, IPC and those edge hashes. No summed global translator/monitor counters. Fallback wall-away and hostcall timings are not CPU; overlapping invalidation timings are not additive.')

    def save():
        (output/'result.json').write_text(json.dumps(evidence, indent=2, sort_keys=True)+'\n')

    def idle_phase(name):
        start = time.monotonic()
        time.sleep(idle)
        evidence['phases'][name] = collector.phase(start, time.monotonic())
        save()

    collector.start()
    try:
        # No guest payload read/export. Startup readiness and staging occur outside the observed workload phases.
        ready = request({'Executable': '/bin/test', 'Arguments': ['-f', OS_IMAGE]}, 30)
        if ready.get('ExitCode') != 0:
            raise RuntimeError('required OS image is not ready: ' + repr(ready))
        guest = stage(probe)
        deadline = time.monotonic() + 90
        while True:
            with collector.lock:
                complete = all(rows and rows[-1]['parsed']['elapsed_since_handoff_seconds'] > 0 for rows in collector.samples)
            if complete:
                break
            if time.monotonic() >= deadline:
                raise RuntimeError('all expected vCPU tallies did not appear')
            time.sleep(.25)
        idle_phase('idle_before')
        begin = time.monotonic()
        response = request({'Executable': guest, 'Arguments': ['--full-resolution', OS_IMAGE, '--index', '0',
                            '--timeout', str(draw_seconds+20), '--max-output-bytes', str(256*1024*1024),
                            '--output-color-space', reference['requested_output_color_space'],
                            '--repeat-draw-seconds', str(draw_seconds)]}, draw_seconds+30)
        finished = time.monotonic()
        (output/'resident-probe-response.json').write_text(json.dumps(response, indent=2)+'\n')
        if not isinstance(response, dict) or response.get('ExitCode') != 0 or response.get('Error'):
            raise RuntimeError('resident probe failed: ' + repr(response))
        report = validate_report(json.loads(response.get('Stdout') or ''), reference)
        validate_repeat(report, draw_seconds)
        evidence['trials'].append(dict(start_monotonic_seconds=begin, end_monotonic_seconds=finished,
                                       host_request_seconds=finished-begin, report=report))
        evidence['phases']['resident_probe'] = collector.phase(begin, finished)
        idle_phase('idle_after')
        evidence['phase_timing_sums_ms'] = {key: sum(row['report']['timings_ms'][key] for row in evidence['trials'])
                                          for key in ('forced_draw', 'input_hash', 'pixel_hash', 'total_before_report')}
        complete = all(row['all_expected_vcpus_present'] for row in evidence['phases'].values())
        profile_matches = all((row.get('invalidation_profile_enabled') or 0) == profile_expected for row in evidence['phases'].values())
        evidence['invalidation_profile_expected'] = profile_expected
        evidence['membership_expected']=membership_expected
        evidence['membership_qualification']={name:membership_qualification(row,membership_expected) for name,row in evidence['phases'].items()}
        membership_matches=all(row['qualified'] for row in evidence['membership_qualification'].values())
        evidence['result'] = 'COLLECTED' if complete and profile_matches and membership_matches else 'INCONCLUSIVE'
    except BaseException as error:
        evidence.update(result='FAIL', error=repr(error))
        raise
    finally:
        try:
            collector.stop()
        except BaseException as error:
            evidence.update(result='FAIL', collector_stop_error=repr(error))
            raise
        finally:
            evidence['collector_errors'] = collector.errors
            if collector.errors and evidence['result'] == 'COLLECTED':
                evidence['result'] = 'INCONCLUSIVE'
            save()
    if evidence['result'] != 'COLLECTED':
        raise RuntimeError('incomplete periodic tally coverage; evidence ' + str(output))
    print('COLLECTED resident warm HEVC decode and coarse periodic tally/idle intervals; evidence ' + str(output), flush=True)


experiment()
