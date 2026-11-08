"""guest-bench NEW_RESULTS EXISTING_GUEST_PROBE EXPECTED_SHA256.

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

if len(arguments) != 3:
    raise ValueError('new results, guest probe and exact SHA256 required')
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
            'scope': 'Two copied inputs/hold/backpressure/asynchronous completion and drain only',
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
response = checked({'Executable': staged, 'Arguments': ['--mavericks-copy-test']}, 20)
if type(response.get('ExitCode')) is not int or response['ExitCode'] != 0:
    raise SystemExit('Copy probe failed; whole-clone cleanup required')
text = response.get('Stdout')
if not isinstance(text, str) or len(text.encode()) > 16384:
    raise SystemExit('Copy probe report missing/outside bound')
report = json.loads(text)
evidence['guest_report'] = report
if (not isinstance(report, dict) or report.get('result') != 'COPY_TRANSPORT_OWNERSHIP_PASS' or
        any(type(report.get(k)) is not int or report[k] != v for k, v in
            [('accepted', 2), ('completed', 2), ('delivered_to_guest', 2), ('frame_bytes', 4147200), ('io_return', 0)]) or
        report.get('step') != 'complete' or report.get('receiver_intent_before_submit') is not True or type(report.get('guest_seconds')) not in (float, int) or
        not math.isfinite(report['guest_seconds']) or not 0 <= report['guest_seconds'] <= 20 or
        report.get('speedup_measured') is not False or report.get('host_codec_API_invoked') is not False):
    save()
    raise SystemExit('Copy ownership report did not qualify')
evidence['result'] = 'COPY_TRANSPORT_OWNERSHIP_PASS'
save()
print('Copy ownership result retained: '+str(output), flush=True)
