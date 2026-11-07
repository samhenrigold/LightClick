#!/usr/bin/env python3
"""Host-only tally preservation/parser and resident-driver contracts. No guest, process launch, build or UI."""
import ast
import contextlib
import copy
import io
import os
import plistlib
import runpy
import struct
import sys
import json
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import patch

from hevc_tally import TallyCollector, differences, interval, parse_tally


def tally(t=10, count=100):
    return f'''# hvdbt tally. One vCPU; test
seconds since hand-off: {t:.1f}
== stops and fallbacks, ranked by count. tcg_ms: time away ==
 {count} 12.5  unsupported form
== by site: reason | bytes ==
 {count}  unsupported form | 0f ff  @0x1234 0x0
== rates ==
page-table stores        {count}  10/s
cold blocks              {count}  10/s
blocks invalidated       {count}  10/s
shadow fills             {count}  10/s
interrupts delivered     {count}  10/s
arm steps to a boundary   {count}  10/s
deepest monitor stack, bytes   864  86/s
translation time         3.5 ms
monitor lock waited 1.25 s; held, s: other 0.10, view switch 0.20, before translating 0.30, after 0.40, fault 0.50, table store 0.60
page invalidations: {count}, 0.10 s waiting for the translator lock, 0.20 s in all
== sampled invalidation cost (global translator; do not sum vCPU files) ==
invalidation_profile_enabled 1
invalidation_profiled_kills {count}
invalidation_sampled_kills 1
invalidation_hash_view_visits 5
invalidation_map_unlink_ns 120
== where the time goes: ==
 {count} 0.25 1.25 7
monitor calls by SVC_ number in engine_abi.h, ranked:
 {count}, 10/s 64
== other counters ==
'''


class Checks(unittest.TestCase):
    def test_parser_scopes_and_actual_sections(self):
        p = parse_tally(tally())
        self.assertEqual(p['per_cpu']['shadow fills'], 100)
        self.assertNotIn('monitor_lock_wait_seconds',p['per_cpu'])
        self.assertEqual(p['per_cpu_gauges']['deepest monitor stack, bytes'],864)
        self.assertEqual(p['global_translator']['cold blocks'], 100)
        self.assertNotIn('cold blocks', p['per_cpu'])
        self.assertEqual(p['global_monitor']['monitor_lock_wait_seconds'], 1.25)
        self.assertEqual(p['global_monitor']['monitor_lock_hold_table_store_seconds'], .6)
        self.assertEqual(p['fallbacks']['unsupported form'], {'count':100, 'tcg_wall_away_milliseconds':12.5})
        self.assertEqual(p['fallback_sites'][0]['first_rip'], '0x1234')
        self.assertEqual(p['svc'], {'64':100})
        self.assertEqual(p['host_calls']['7'], {'count':100, 'total_seconds':.25})
        self.assertEqual(p['invalidation_profile']['invalidation_map_unlink_ns'], 120)
        with self.assertRaises(ValueError):
            parse_tally('not a tally')
        with self.assertRaises(ValueError):
            parse_tally('# hvdbt tally.\nseconds since hand-off: 1.0\n')

    def test_delta_rejects_reset_and_tracks_new_rows(self):
        self.assertEqual(differences({'a':1}, {'a':3,'new':2}), {'a':2,'new':2})
        with self.assertRaises(ValueError): differences({'a':3}, {'a':1})
        with self.assertRaises(ValueError): differences({'a':3}, {})
        a = dict(parsed=parse_tally(tally()), observed_monotonic_seconds=10, file='a')
        b = dict(parsed=parse_tally(tally(12,130)), observed_monotonic_seconds=12, file='b')
        d = interval(a,b)
        self.assertEqual(d['per_cpu']['shadow fills'],30)
        self.assertEqual(d['global_translator']['cold blocks'],30)
        self.assertEqual(d['invalidation_profile_enabled'],1)
        self.assertEqual(d['per_cpu_gauges']['end']['deepest monitor stack, bytes'],864)
        a['parsed']['svc']={'64':100,'10':5}
        b['parsed']['svc']={'64':130,'20':999}
        ranked=interval(a,b)
        self.assertEqual(ranked['svc_count_deltas_common_top20'],{'64':30})
        self.assertEqual(ranked['svc_newly_printed_end_counts'],{'20':999})
        self.assertEqual(ranked['svc_no_longer_printed'],['10'])
        self.assertEqual(d['fallback_site_count_deltas_common'], {'unsupported form | 0f ff':30})
        b['parsed']['fallback_sites'].append(dict(key='new top200 row',count=999,first_rip='0x5678',detail='0x0'))
        bounded=interval(a,b)
        self.assertNotIn('new top200 row',bounded['fallback_site_count_deltas_common'])
        self.assertEqual(bounded['fallback_sites_newly_printed_end_counts'],{'new top200 row':999})
        b['parsed']['invalidation_profile']['invalidation_profile_enabled'] = 0
        with self.assertRaises(ValueError): interval(a,b)

    def test_preserves_every_expected_cpu_and_never_sums_global_counters(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prefix = root/'tally'
            c = TallyCollector(prefix,2,root/'saved')
            with patch('hevc_tally.time.monotonic', return_value=3):
                prefix.write_text(tally(10,100))
                Path(str(prefix)+'.cpu1').write_text(tally(9,100))
                c.poll()
                c.poll() # Identical publication does not consume another snapshot.
            with patch('hevc_tally.time.monotonic', return_value=6):
                prefix.write_text(tally(13,130).replace('monitor lock waited 1.25','monitor lock waited 2.25'))
                Path(str(prefix)+'.cpu1').write_text(tally(12,130).replace('monitor lock waited 1.25','monitor lock waited 99.00'))
                c.poll()
            phase = c.phase(0,8)
            self.assertTrue(phase['all_expected_vcpus_present'])
            self.assertEqual(phase['global_translator']['cold blocks'],30) # Not60!
            self.assertEqual(set(phase['per_cpu']),{'0','1'})
            self.assertEqual(phase['global_monitor_source_cpu'],0)
            self.assertEqual(phase['global_monitor']['monitor_lock_wait_seconds'],1)
            self.assertNotIn('global_monitor',phase['per_cpu']['0'])
            self.assertNotIn('monitor_lock_wait_seconds',phase['per_cpu']['0']['per_cpu'])
            self.assertNotIn('global_translator',phase['per_cpu']['1'])
            self.assertEqual(phase['per_cpu']['0']['per_cpu']['shadow fills'],30)
            self.assertEqual(len(list((root/'saved').glob('cpu*.txt'))),4)
            self.assertEqual((root/'saved/cpu0-000000.txt').read_text(),tally(10,100))
            self.assertFalse(c.phase(5,8)['all_expected_vcpus_present'])
            self.assertEqual(c.errors,[])

    def test_resident_driver_uses_one_real_probe_and_preserves_phase_costs(self):
        path = Path(__file__).parents[1]/'probes/hevc-tally-driver.py'
        tree = ast.parse(path.read_text())
        tree.body = [node for node in tree.body if isinstance(node,(ast.Import,ast.ImportFrom,ast.FunctionDef,ast.Assign))]
        ns = {}
        exec(compile(tree,str(path),'exec'),ns)
        reference = dict(format_version=1,mode='full-resolution',input_sha256=ns['INPUT_SHA256'],input_bytes=ns['INPUT_BYTES'],
                         pixel_sha256='b'*64,item_index=0,item_count=16,width=5120,height=2880,row_bytes=20480,output_bytes=58982400,
                         requested_output_color_space='source',timings_ms={
                             'forced_draw':1,'input_hash':1,'pixel_hash':1,'total_before_report':4})
        report = copy.deepcopy(reference)
        report['timings_ms'] = dict(forced_draw=28000,input_hash=1000,pixel_hash=100,total_before_report=31200)
        report['repeat_draw'] = dict(requested_seconds=30,elapsed_seconds=30,iterations=1,iteration_limit=256,
            termination='duration',per_iteration=[dict(source_create_ms=1000,image_create_ms=1000,forced_draw_ms=28000)])
        ns['validate_repeat'](report,30)
        bad = copy.deepcopy(report);bad['repeat_draw']['iterations']=2
        with self.assertRaises(ValueError): ns['validate_repeat'](bad,30)
        bad = copy.deepcopy(report);bad['pixel_sha256']='c'*64
        with self.assertRaises(ValueError): ns['validate_report'](bad,reference)
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary); probe=root/'probe';probe.write_bytes(b'unchanged-existing-probe')
            prior=root/'reference.json';prior.write_text(json.dumps(reference))
            clock=[0.0];calls=[]
            class FakeCollector:
                def __init__(self,*args):
                    import threading
                    self.lock=threading.Lock();self.samples=[[{'parsed':{'elapsed_since_handoff_seconds':1}}]];self.errors=[]
                def start(self): pass
                def stop(self): calls.append('stop')
                def phase(self,start,end):
                    return dict(start=start,end=end,all_expected_vcpus_present=True,invalidation_profile_enabled=1)
            def request(command,timeout):
                calls.append(command)
                if command['Executable']=='/bin/test': return {'ExitCode':0}
                self.assertEqual(command['Executable'],'/staged/probe')
                self.assertEqual(command['Arguments'][-2:],['--repeat-draw-seconds','30'])
                self.assertNotIn('--raw',command['Arguments'])
                clock[0]+=32
                return dict(ExitCode=0,Stdout=json.dumps(report))
            ns.update(arguments=[str(root/'results'),str(probe),str(root/'tally'),'1','30','12',str(prior),'1'],
                      request=request,stage=lambda path:'/staged/probe',TallyCollector=FakeCollector,
                      time=types.SimpleNamespace(monotonic=lambda:clock[0],sleep=lambda seconds:clock.__setitem__(0,clock[0]+seconds)))
            with contextlib.redirect_stdout(io.StringIO()): ns['experiment']()
            saved=json.loads((root/'results/result.json').read_text())
            self.assertEqual(saved['result'],'COLLECTED')
            self.assertEqual(len(saved['trials']),1)
            self.assertEqual(saved['phase_timing_sums_ms']['input_hash'],1000)
            self.assertEqual(saved['phase_timing_sums_ms']['forced_draw'],28000)
            self.assertEqual(set(saved['phases']),{'idle_before','resident_probe','idle_after'})
            self.assertEqual(calls[-1],'stop')
            self.assertEqual(len([call for call in calls if isinstance(call,dict)]),2)
            # An ambiguous timed-out request must never be resent, nor followed by another guest command.
            calls.clear()
            ns['arguments'][0]=str(root/'failed')
            def timeout_request(command,timeout):
                calls.append(command)
                if command['Executable']=='/bin/test': return {'ExitCode':0}
                raise SystemExit('ambiguous probe timeout')
            ns['request']=timeout_request
            with self.assertRaisesRegex(SystemExit,'ambiguous'):
                ns['experiment']()
            self.assertEqual(len([call for call in calls if isinstance(call,dict)]),2)
            self.assertEqual(calls[-1],'stop')
            self.assertEqual(json.loads((root/'failed/result.json').read_text())['result'],'FAIL')

    def test_wrapper_forwards_explicit_running_vm_optin_and_boot_wait(self):
        path=Path(__file__).with_name('hevc-tally-try')
        ns=runpy.run_path(str(path),run_name='wrapper_for_test')
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            app=root/'App.app';(app/'Contents/MacOS').mkdir(parents=True)
            (app/'Contents/MacOS/Light Click').write_bytes(b'fixture')
            machine=root/'Test.vintelmac';machine.mkdir()
            (machine/'Machine.plist').write_bytes(plistlib.dumps(dict(Guest='mojave',CPUCount=2)))
            probe=root/'probe';probe.write_bytes(struct.pack('<II',0xfeedfacf,0x1000007))
            reference=root/'reference.json'
            reference.write_text(json.dumps(dict(input_sha256='a84ed4faa376b8b2cb0328b306d09d25ad9047a0f7d106ad46098d0d91381256',requested_output_color_space='source')))
            for allow,extra,wait in ((False,[],90),(True,['--allow-running-vms','--boot-wait','120'],120)):
                launched=[]
                def launch(command,**kwargs):
                    launched.append((command,kwargs))
                    return types.SimpleNamespace(pid=123,returncode=0,poll=lambda:0)
                argv=[str(path),str(app),str(machine),str(probe),str(reference),'--results',str(root/('allowed' if allow else 'default')),*extra,'--profile-invalidations']
                environment={'LC_SEAMLESS_TEST':'1','VIM_SEAMLESS_PVG_SERVICE':'old','LC_HVDBT_PROFILE_INVALIDATION':'old','KEEP_ME':'yes'}
                with patch.object(sys,'argv',argv), patch('subprocess.Popen',side_effect=launch), \
                        patch.dict(os.environ,environment), patch('signal.signal'), contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(ns['main'](),0)
                self.assertEqual(len(launched),1)
                command,kwargs=launched[0]
                self.assertEqual('--allow-running-vms' in command,allow)
                self.assertEqual(command[command.index('--boot-wait')+1],str(wait))
                self.assertIn('LC_HVDBT_PROFILE_INVALIDATION=1',command)
                self.assertIn('guest-bench',command[1]) # Exclusive CloneLease owner is retained.
                self.assertFalse(any(key.startswith(('LC_SEAMLESS_','VIM_SEAMLESS_')) for key in kwargs['env']))
                self.assertNotIn('LC_HVDBT_PROFILE_INVALIDATION',kwargs['env'])
                self.assertEqual(kwargs['env']['KEEP_ME'],'yes')


if __name__=='__main__': unittest.main()
