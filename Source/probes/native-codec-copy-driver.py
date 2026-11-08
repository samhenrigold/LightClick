"""guest-bench NEW_RESULTS EXISTING_GUEST_PROBE EXPECTED_SHA256 [throughput].

One headless Mavericks copy/ownership probe. The caller configures a frozen mux
and unchanged GL delegate before launch. No encoder API, UI or file workload.
"""
import hashlib
import json
import math
from pathlib import Path
import re
import stat
import time

if len(arguments) not in (3, 4) or (len(arguments) == 4 and arguments[3] != 'throughput'):
    raise ValueError('new results, guest probe and exact SHA256, optionally exact throughput mode required')
throughput = len(arguments) == 4
expected_count = 240 if throughput else 2
expected_result = 'COPY_TRANSPORT_THROUGHPUT_PASS' if throughput else 'COPY_TRANSPORT_OWNERSHIP_PASS'
probe_argument = '--mavericks-copy-throughput' if throughput else '--mavericks-copy-test'
probe_timeout = 70 if throughput else 20
output, helper, expected = Path(arguments[0]), Path(arguments[1]), arguments[2]
if not output.is_absolute() or output.exists() or not re.fullmatch(r'[0-9a-f]{64}', expected):
    raise ValueError('new absolute results and exact lowercase hash required')
info = helper.lstat()
if helper.resolve() != helper or not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= 2*1024*1024:
    raise ValueError('canonical bounded existing guest probe required')
data = helper.read_bytes()
if len(data) != info.st_size or data[:8] != bytes.fromhex('cffaedfe07000001') or hashlib.sha256(data).hexdigest() != expected:
    raise ValueError('guest probe architecture/bytes changed')
output.mkdir(parents=True)
evidence = {'result': 'INCONCLUSIVE', 'probe_sha256': expected, 'requests': [],
            'scope': ('240 synthetic inputs: copy plus FNV-1a throughput only; guest clock, not host CPU, FCP or UI frame rate'
                      if throughput else 'Two copied inputs/hold/backpressure/asynchronous completion and drain only'),
            'host_codec_API_invoked': False, 'speedup_measured': False}
def save():
    (output/'result.json').write_text(json.dumps(evidence, indent=2)+'\n')
stopped = False
def checked(command, timeout):
    global stopped
    if stopped:
        raise SystemExit('Copy requests stopped; no resend')
    try:
        response = request(command, timeout)
    except BaseException:
        stopped = True
        raise
    evidence['requests'].append({'command': command, 'response': response})
    save()
    if (not isinstance(response, dict) or 'Error' in response or
            ('ExitCode' in response and type(response['ExitCode']) is not int) or response.get('ExitCode') == 77):
        stopped = True
        raise SystemExit('Ambiguous copy request; no further requests or resends')
    return response
save()
# Read-only QOM check before any guest staging or potentially blocking RX.
bql = checked({'Action': 'passthrough-opengl-release-bql'}, 10)
if type(bql.get('Enabled')) not in (bool, int) or bql['Enabled'] != 1:
    raise SystemExit('BQL release is not attested; refusing the copy experiment')
deadline = time.monotonic()+60
(channel/'Transfer.bin').write_bytes(data)
def stage_request(command, maximum):
    remaining = deadline-time.monotonic()
    if remaining <= 0:
        raise SystemExit('Copy staging deadline; no resend')
    response = checked(command, min(maximum, remaining))
    if time.monotonic() > deadline:
        raise SystemExit('Copy staging deadline after request; no resend')
    return response
receipt = stage_request({'Action': 'stage-probe'}, 60)
transfer_receipt = receipt.get('Transfer')
directory = transfer_receipt.get('Directory') if isinstance(transfer_receipt, dict) else None
if not isinstance(directory, str) or not re.fullmatch(r'/private/var/tmp/VirtualIntelMac\.[A-Za-z0-9]{6}', directory):
    raise SystemExit('Copy staging path mismatch; no resend')
staged = directory+'/Transfer.bin'
permissions = stage_request({'Executable': '/bin/chmod', 'Arguments': ['0755', staged]}, 10)
if type(permissions.get('ExitCode')) is not int or permissions['ExitCode'] != 0:
    raise SystemExit('Copy staging chmod failed; no further requests')
response = checked({'Executable': staged, 'Arguments': [probe_argument]}, probe_timeout)
if type(response.get('ExitCode')) is not int or response['ExitCode'] != 0:
    raise SystemExit('Copy probe failed; whole-clone cleanup required')
text = response.get('Stdout')
if not isinstance(text, str) or len(text.encode()) > 16384:
    raise SystemExit('Copy probe report missing/outside bound')
report = json.loads(text)
evidence['guest_report'] = report
if (not isinstance(report, dict) or report.get('result') != expected_result or
        any(type(report.get(k)) is not int or report[k] != v for k, v in
            [('accepted', expected_count), ('completed', expected_count), ('delivered_to_guest', expected_count), ('frame_bytes', 4147200), ('io_return', 0)]) or
        report.get('step') != 'complete' or report.get('receiver_intent_before_submit') is not True or type(report.get('guest_seconds')) not in (float, int) or
        not math.isfinite(report['guest_seconds']) or not 0 <= report['guest_seconds'] <= probe_timeout or
        report.get('speedup_measured') is not False or report.get('host_codec_API_invoked') is not False):
    save()
    raise SystemExit('Copy report did not qualify')


def fps_matches_printed_interval(seconds, fps):
    # The probe prints both values with %.9f. Account for both decimal rounding
    # intervals, plus only floating arithmetic roundoff in this comparison.
    half = 0.0000000005
    lower = 240.0/(seconds+half)
    upper = 240.0/(seconds-half) if seconds > half else math.inf
    roundoff = 4*max(math.ulp(fps), math.ulp(lower), math.ulp(upper) if math.isfinite(upper) else 0)
    return fps+half+roundoff >= lower and fps-half-roundoff <= upper


if throughput:
    if (report.get('mode') != 'throughput' or
            any(type(report.get(k)) not in (int, float) or not math.isfinite(report[k]) or report[k] <= 0
                for k in ('fullguest_seconds', 'transfer_hash_seconds', 'frames_per_second')) or
            not report['transfer_hash_seconds'] <= report['fullguest_seconds'] <= 70 or
            report['fullguest_seconds'] != report['guest_seconds'] or
            any(type(report.get(k)) is not int or report[k] != v for k, v in
                [('cancelled', 0), ('host_delivered', 240), ('live_slots', 0), ('worker_stopped', 1)]) or
            type(report.get('peak_slots')) is not int or report['peak_slots'] not in (1, 2) or
            report.get('clean_close') is not True or
            not fps_matches_printed_interval(report['transfer_hash_seconds'], report['frames_per_second'])):
        save()
        raise SystemExit('Copy plus FNV throughput report did not qualify')
evidence['result'] = expected_result
save()
print(('Copy plus FNV throughput' if throughput else 'Copy ownership')+' result retained: '+str(output), flush=True)
