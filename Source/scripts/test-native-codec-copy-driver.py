"""Run the real driver with RAM request doubles; never execute a guest binary."""
import hashlib
import json
from pathlib import Path
import runpy
import tempfile
import unittest

DRIVER = Path(__file__).resolve().parents[1]/'probes/native-codec-copy-driver.py'


class CopyDriverTests(unittest.TestCase):
    def run_case(self, bad=None, fail_at=None, mode=None, overrides=None):
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
            if mode == 'throughput':
                report.update(result='COPY_TRANSPORT_THROUGHPUT_PASS', mode='throughput',
                              accepted=240, completed=240, delivered_to_guest=240,
                              guest_seconds=2.25, fullguest_seconds=2.25,
                              transfer_hash_seconds=2.0, frames_per_second=120.0,
                              cancelled=0, host_delivered=240, peak_slots=2, live_slots=0,
                              worker_stopped=1, clean_close=True)
            if bad == 'count':
                report['accepted'] = 2.0
            if bad == 'incomplete':
                report['delivered_to_guest'] = 1
            if overrides:
                report.update(overrides)
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
            arguments = [str(output), str(helper), hashlib.sha256(helper.read_bytes()).hexdigest()]
            if mode is not None:
                arguments.append(mode)
            try:
                runpy.run_path(str(DRIVER), init_globals=dict(
                    arguments=arguments,
                    channel=channel, request=request))
            except (SystemExit, ValueError) as error:
                stopped = str(error)
            result = json.loads((output/'result.json').read_text()) if (output/'result.json').exists() else None
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
        self.assertEqual(calls[3][0]['Arguments'], ['--mavericks-copy-test'])
        self.assertNotIn('mode', result['guest_report'])

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

    def test_throughput_positive(self):
        stopped, calls, result, staged = self.run_case(mode='throughput')
        self.assertIsNone(stopped)
        self.assertTrue(staged)
        self.assertEqual(len(calls), 4)
        self.assertEqual(calls[3][1], 70)
        self.assertEqual(calls[3][0]['Arguments'], ['--mavericks-copy-throughput'])
        self.assertEqual(result['result'], 'COPY_TRANSPORT_THROUGHPUT_PASS')
        self.assertIn('copy plus FNV', result['scope'])
        self.assertIs(result['speedup_measured'], False)
        self.assertIs(result['host_codec_API_invoked'], False)

    def test_invalid_modes_stop_before_requests(self):
        for mode in ('ownership', 'Throughput', '', 1):
            with self.subTest(mode=mode):
                stopped, calls, result, staged = self.run_case(mode=mode)
                self.assertIsNotNone(stopped)
                self.assertEqual(calls, [])
                self.assertIsNone(result)
                self.assertFalse(staged)

    def test_throughput_counts_and_lifetime_fail_closed(self):
        for change in ({'accepted': 240.0}, {'completed': True}, {'delivered_to_guest': 239},
                       {'frame_bytes': 4147201}, {'io_return': 1}, {'cancelled': 1},
                       {'host_delivered': 239}, {'peak_slots': 3}, {'live_slots': 1},
                       {'worker_stopped': False}, {'clean_close': 1}, {'mode': 'ownership'}):
            with self.subTest(change=change):
                stopped, calls, result, _ = self.run_case(mode='throughput', overrides=change)
                self.assertIsNotNone(stopped)
                self.assertEqual(len(calls), 4)
                self.assertEqual(result['result'], 'INCONCLUSIVE')

    def test_throughput_invalid_timing(self):
        changes = [{'transfer_hash_seconds': x} for x in (0, -1, True, '2', float('nan'), float('inf'), 71)]
        changes += [{'frames_per_second': x} for x in (0, True, float('inf'), float('nan'), 119.999)]
        changes += [{'fullguest_seconds': 71}, {'fullguest_seconds': 1}, {'guest_seconds': 2.5}]
        for change in changes:
            with self.subTest(change=change):
                stopped, calls, result, _ = self.run_case(mode='throughput', overrides=change)
                self.assertIsNotNone(stopped)
                self.assertEqual(len(calls), 4)
                self.assertEqual(result['result'], 'INCONCLUSIVE')

    def test_throughput_decimal_rounding_and_one_slot_are_valid(self):
        seconds = 2.345678901
        stopped, _, result, _ = self.run_case(mode='throughput', overrides={
            'guest_seconds': 3.0, 'fullguest_seconds': 3.0, 'transfer_hash_seconds': seconds,
            'frames_per_second': round(240/seconds, 9), 'peak_slots': 1})
        self.assertIsNone(stopped)
        self.assertEqual(result['result'], 'COPY_TRANSPORT_THROUGHPUT_PASS')

    def test_throughput_request_timeouts_never_resend(self):
        for n in range(1, 5):
            with self.subTest(request=n):
                stopped, calls, result, _ = self.run_case(mode='throughput', fail_at=n)
                self.assertIsNotNone(stopped)
                self.assertEqual(len(calls), n)
                self.assertEqual(result['result'], 'INCONCLUSIVE')


if __name__ == '__main__':
    unittest.main()
