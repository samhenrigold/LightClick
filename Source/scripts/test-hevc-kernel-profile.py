#!/usr/bin/env python3
"""Host-only parser/bounds and guest-bench orchestration checks; no processes or guests."""
import ast
import contextlib
import copy
import io
import json
from pathlib import Path
import tempfile
import unittest
from hevc_kernel_profile import GUEST, LIMIT, PROFILE, parse_result


def fixture():
    report=dict(format_version=1,mode='full-resolution',input_sha256='a84ed4faa376b8b2cb0328b306d09d25ad9047a0f7d106ad46098d0d91381256',input_bytes=134758820,
        pixel_sha256='b'*64,item_index=0,item_count=16,requested_output_color_space='source',width=5120,height=2880,row_bytes=20480,output_bytes=58982400,
        repeat_draw=dict(requested_seconds=30,termination='duration',iterations=33,elapsed_seconds=30.9))
    raw='PROFILE_KIND kernel 100\nPROFILE_KIND VT-user 80\nPROFILE_KERNEL mach_kernel`vm_fault 50\nPROFILE_USER VCPHEVC`decoder 70\nPROFILE_STACKS_BEGIN\n mach_kernel`vm_fault\n 50\nPROFILE_STACKS_END\n'
    texts={'dtrace.stdout':raw,'dtrace.stderr':'','probe.json':json.dumps(report),'probe.stderr':'','probe.exit':'0\n'}
    return report,dict(format_version=1,timed_out=False,dtrace_exit_code=0,files={name:dict(text=text,bytes=len(text.encode()),at_limit=False) for name,text in texts.items()})


class Checks(unittest.TestCase):
    def test_observed_profile_and_raw_stack_parse(self):
        reference,value=fixture();r=parse_result(value,reference)
        self.assertEqual(r['kind_samples'],{'kernel':100,'VT-user':80})
        self.assertEqual(r['kernel_functions'],[dict(symbol='mach_kernel`vm_fault',samples=50)])
        self.assertIn('vm_fault',r['kernel_stacks_raw'])
        self.assertIn('No EL1',r['note'])
        ast.parse(GUEST) # Guest syntax remains Python2-compatible (no fstrings/type annotations/subprocess timeout).
        self.assertIn('os.killpg(p.pid',GUEST)
        self.assertNotIn('killall',GUEST)
        self.assertIn('stack(12)',PROFILE)

    def test_truncated_failed_empty_and_wrong_pixel_output_rejected(self):
        reference,value=fixture()
        for change in ('limit','timeout','exit','dropped','no-stacks','missing-user','wrong-pixels','short-phase','probe-exit'):
            bad=copy.deepcopy(value)
            if change=='limit': bad['files']['dtrace.stdout'].update(bytes=LIMIT,at_limit=True)
            elif change=='timeout': bad['timed_out']=True
            elif change=='exit': bad['dtrace_exit_code']=1
            elif change=='dropped': bad['files']['dtrace.stderr']['text']='1 dynamic variable drop'
            elif change=='no-stacks': bad['files']['dtrace.stdout']['text']=bad['files']['dtrace.stdout']['text'].replace('PROFILE_STACKS_END','')
            elif change=='missing-user': bad['files']['dtrace.stdout']['text']=bad['files']['dtrace.stdout']['text'].replace('PROFILE_KIND VT-user 80','')
            elif change=='probe-exit': bad['files']['probe.exit']['text']='9\n'
            else:
                report=json.loads(bad['files']['probe.json']['text'])
                if change=='wrong-pixels': report['pixel_sha256']='c'*64
                else: report['repeat_draw']['elapsed_seconds']=29
                bad['files']['probe.json']['text']=json.dumps(report)
            with self.subTest(change=change),self.assertRaises(ValueError): parse_result(bad,reference)

    def test_driver_preserves_raw_failure_and_never_retries_ambiguous_request(self):
        path=Path(__file__).parents[1]/'probes/hevc-kernel-profile-driver.py'
        tree=ast.parse(path.read_text());tree.body=tree.body[:-1]
        ns={'source':Path(__file__).parents[1]};exec(compile(tree,str(path),'exec'),ns)
        reference,value=fixture()
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);probe=root/'probe';probe.write_bytes(bytes.fromhex('cffaedfe07000001'))
            prior=root/'prior.json';prior.write_text(json.dumps(reference));calls=[]
            def request(command,timeout):
                calls.append(command)
                self.assertEqual(timeout,80)
                self.assertEqual(command['Executable'],'/usr/bin/python')
                return dict(ExitCode=0,Stdout=json.dumps(value),Stderr='supervisor stderr')
            ns.update(arguments=[str(root/'good'),str(probe),str(prior)],stage=lambda p:'/private/var/tmp/own/Transfer.bin',request=request)
            with contextlib.redirect_stdout(io.StringIO()): ns['experiment']()
            self.assertEqual(json.loads((root/'good/result.json').read_text())['result'],'COLLECTED')
            self.assertEqual((root/'good/dtrace.stdout').read_text(),value['files']['dtrace.stdout']['text'])
            value['dtrace_exit_code']=1;ns['arguments'][0]=str(root/'bad')
            with self.assertRaises(ValueError): ns['experiment']()
            self.assertTrue((root/'bad/dtrace.stdout').exists())
            self.assertTrue((root/'bad/response.json').exists())
            def ambiguous(command,timeout): calls.append(command);raise SystemExit('ambiguous timeout')
            ns['request']=ambiguous;ns['arguments'][0]=str(root/'timeout');before=len(calls)
            with self.assertRaises(SystemExit): ns['experiment']()
            self.assertEqual(len(calls)-before,1)
            self.assertEqual(json.loads((root/'timeout/result.json').read_text())['result'],'INCONCLUSIVE')


if __name__=='__main__': unittest.main()
