#!/usr/bin/env python3
"""Pure plist/fake-codesign checks. Never signs or runs any app/QEMU."""
import ast
from pathlib import Path
import plistlib
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from sampling_entitlements import MAX_ENTITLEMENT_BYTES, SAMPLING_KEYS, sampling_plist, prepare_sampling_entitlements

HV='com.apple.security.hypervisor'
class SamplingTests(unittest.TestCase):
    def test_preserves_capabilities_and_values(self):
        original={HV:True,'com.apple.security.device.audio-input':True,'arbitrary-existing':['one',2,False], 'data':b'bytes', 'disabled':False}
        for fmt in (plistlib.FMT_XML,plistlib.FMT_BINARY):
            actual=plistlib.loads(sampling_plist(plistlib.dumps(original,fmt=fmt)))
            self.assertEqual(actual,{**original,**dict.fromkeys(SAMPLING_KEYS,True)})
    def test_hypervisor_never_invented_or_enabled(self):
        self.assertNotIn(HV,plistlib.loads(sampling_plist(plistlib.dumps({}))))
        self.assertIs(plistlib.loads(sampling_plist(plistlib.dumps({HV:False})))[HV],False)
    def test_reject_bad_inputs(self):
        for value in (None,'text',b'',b'garbage',b'x'*(MAX_ENTITLEMENT_BYTES+1),plistlib.dumps([]),plistlib.dumps('str'),plistlib.dumps({'':True})):
            with self.subTest(kind=type(value),size=len(value) if value is not None else None):
                with self.assertRaises(ValueError):sampling_plist(value)
    def test_bounded_extract_and_private_exclusive_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            output=Path(temporary)/'sample.entitlements'
            completed=subprocess.CompletedProcess([],0,stdout=plistlib.dumps({HV:True}),stderr=b'ignored diagnostics')
            with patch('sampling_entitlements.subprocess.run',return_value=completed) as run:
                prepare_sampling_entitlements('/owned/clone/qemu.real',output)
                self.assertEqual(run.call_args.args[0],['codesign','-d','--entitlements',':-','/owned/clone/qemu.real'])
                self.assertEqual(run.call_args.kwargs['timeout'],10)
                self.assertTrue(run.call_args.kwargs['check'])
                self.assertEqual(stat.S_IMODE(output.stat().st_mode),0o600)
                self.assertTrue(plistlib.loads(output.read_bytes())[HV])
                with self.assertRaises(FileExistsError):prepare_sampling_entitlements('/owned/clone/qemu.real',output)
    def test_extraction_failure_no_output(self):
        for failure in (subprocess.TimeoutExpired('codesign',10),subprocess.CalledProcessError(1,'codesign')):
            with tempfile.TemporaryDirectory() as temporary:
                output=Path(temporary)/'sample.entitlements'
                with patch('sampling_entitlements.subprocess.run',side_effect=failure):
                    with self.assertRaises(type(failure)):prepare_sampling_entitlements('/clone/qemu.real',output)
                self.assertFalse(output.exists())
        with tempfile.TemporaryDirectory() as temporary:
            output=Path(temporary)/'sample.entitlements'
            with patch('sampling_entitlements.subprocess.run',return_value=subprocess.CompletedProcess([],0,stdout=b'invalid')):
                with self.assertRaises(ValueError):prepare_sampling_entitlements('/clone/qemu.real',output)
            self.assertFalse(output.exists())
    def test_clone_integration_order_and_no_literal_replacement(self):
        source=(Path(__file__).parent/'guest-bench').read_text();ast.parse(source)
        body=source[source.index('if args.sample:'):source.index("exports = ' '")]
        self.assertLess(body.index('prepare_sampling_entitlements(real, entitlements)'),body.index("subprocess.run(['codesign'"))
        self.assertNotIn('write_text',body)
        self.assertIn("str(real)",body)

if __name__=='__main__':unittest.main()
