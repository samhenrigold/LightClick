"""Run the real driver with RAM request doubles; never execute a guest binary."""
import hashlib
import json
from pathlib import Path
import runpy
import tempfile
import unittest

DRIVER = Path(__file__).resolve().parents[1]/'probes/native-codec-copy-driver.py'


class CopyDriverTests(unittest.TestCase):
    def run_case(self, bad=None, fail_at=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            helper = root/'probe'
            helper.write_bytes(bytes.fromhex('cffaedfe07000001')+b'RAM-only fixture, never executed')
            channel = root/'channel'
            channel.mkdir()
            output = root/'result'
            calls = []
            report = dict(result='COPY_TRANSPORT_OWNERSHIP_PASS', step='complete', io_return=0,
                          accepted=2, completed=2, delivered_to_guest=2, frame_bytes=4147200,
                          guest_seconds=0.25, receiver_intent_before_submit=True, speedup_measured=False, host_codec_API_invoked=False)
            if bad == 'count':
                report['accepted'] = 2.0
            if bad == 'incomplete':
                report['delivered_to_guest'] = 1
            def request(command, timeout):
                calls.append((command, timeout))
                if len(calls) == fail_at:
                    raise SystemExit('simulated request timeout')
                if len(calls) == 1:
                    return {'Enabled': False if bad == 'bql' else True}
                if len(calls) == 2:
                    return {'Transfer': {'Directory': '/wrong/path' if bad == 'path' else '/private/var/tmp/VirtualIntelMac.ABC123'}}
                if len(calls) == 3:
                    return {'ExitCode': 1 if bad == 'chmod' else 0}
                if len(calls) == 4:
                    return {'ExitCode': 77 if bad == 'ambiguous' else 0, 'Stdout': json.dumps(report)}
                raise AssertionError('unexpected further request')
            stopped = None
            try:
                runpy.run_path(str(DRIVER), init_globals=dict(
                    arguments=[str(output), str(helper), hashlib.sha256(helper.read_bytes()).hexdigest()],
                    channel=channel, request=request))
            except SystemExit as error:
                stopped = str(error)
            result = json.loads((output/'result.json').read_text())
            return stopped, calls, result, (channel/'Transfer.bin').exists()

    def test_positive(self):
        stopped, calls, result, staged = self.run_case()
        self.assertIsNone(stopped)
        self.assertEqual(len(calls), 4)
        self.assertTrue(staged)
        self.assertEqual(result['result'], 'COPY_TRANSPORT_OWNERSHIP_PASS')
        self.assertLessEqual(calls[1][1], 60)
        self.assertLessEqual(calls[2][1], 10)
        self.assertEqual(calls[3][1], 20)

    def test_unsupported_bql_stops_before_staging(self):
        stopped, calls, result, staged = self.run_case('bql')
        self.assertIsNotNone(stopped)
        self.assertEqual(len(calls), 1)
        self.assertFalse(staged)

    def test_stage_and_report_failures_never_send_more_requests(self):
        for bad, count in [('path', 2), ('chmod', 3), ('ambiguous', 4), ('count', 4), ('incomplete', 4)]:
            with self.subTest(bad=bad):
                stopped, calls, result, staged = self.run_case(bad)
                self.assertIsNotNone(stopped)
                self.assertEqual(len(calls), count)
                self.assertEqual(result['result'], 'INCONCLUSIVE')

    def test_each_request_timeout_stops_without_resend(self):
        for n in range(1, 5):
            with self.subTest(request=n):
                stopped, calls, result, staged = self.run_case(fail_at=n)
                self.assertIsNotNone(stopped)
                self.assertEqual(len(calls), n)
                self.assertEqual(result['result'], 'INCONCLUSIVE')


if __name__ == '__main__':
    unittest.main()
