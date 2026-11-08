#!/usr/bin/env python3
"""Static whitelist/provider checks only; no compile, AVFoundation or guest execution."""
import argparse
from pathlib import Path
import re
import subprocess
parser=argparse.ArgumentParser();parser.add_argument('--mavericks-root',type=Path,required=True);args=parser.parse_args()
s=(Path(__file__).resolve().parents[1]/'probes/fcp-export-verify.m').read_text()
helper=s[s.index('static NSDictionary *colorScalar('):s.index('static BOOL validMediaFile(')]
keys=re.search(r'const CFStringRef keys\[\]=\{([^}]+)\}',helper).group(1).split(',')
assert keys==['kCVImageBufferColorPrimariesKey','kCVImageBufferTransferFunctionKey','kCVImageBufferYCbCrMatrixKey','kCMFormatDescriptionExtension_FullRangeVideo']
assert 'for(unsigned i=0;i<4;i++)' in helper
for forbidden in ('CFDictionaryApplyFunction','CFDictionaryGetKeysAndValues','description]','base64','writeToFile','CGColorSpaceCopyICCData','CGColorSpaceGetName('):assert forbidden not in helper
assert 'text.length>128' in helper and 'MIN(text.length,128)' in helper and 'isfinite(number)' in helper
assert 'unsupported_nonscalar' in helper and 'nonfinite' in helper
assert 'bytes>0 && bytes<=1024*1024' in helper and 'icc_sha256' in helper
assert 'CFRelease(profile)' in helper and 'if(name)CFRelease(name)' in helper
assert '@"color_extensions":formatColorDiagnostics(format)' in s
assert '@"decoded_image_color_space":imageColorDiagnostics(image)' in s
main=s[s.index('int main('):]
assert '@[@0,@30,@120,@239]' in main and 'AVAssetImageGeneratorApertureModeCleanAperture' in main
assert '@"fidelity_qualified":@NO' in main and '@"MEDIA_STRUCTURE_VALID_FIDELITY_REQUIRES_REVIEW"' in main
assert 'color_extensions' not in main and 'decoded_image_color_space' not in main
providers={
 'CoreMedia':['CMFormatDescriptionGetExtensions','kCMFormatDescriptionExtension_FullRangeVideo'],
 'CoreVideo':['kCVImageBufferColorPrimariesKey','kCVImageBufferTransferFunctionKey','kCVImageBufferYCbCrMatrixKey'],
 'CoreGraphics':['CGImageGetColorSpace','CGColorSpaceGetModel','CGColorSpaceCopyName','CGColorSpaceCopyICCProfile'],
 'CoreFoundation':['CFGetTypeID','CFStringGetTypeID','CFBooleanGetTypeID','CFNumberGetTypeID','CFDictionaryGetTypeID','CFDictionaryGetValue','CFDataGetLength','CFDataGetBytePtr','CFRelease'],
}
for framework,names in providers.items():
    path=args.mavericks_root/'System/Library/Frameworks'/f'{framework}.framework/Versions/A'/framework
    exported=set(subprocess.check_output(['nm','-arch','x86_64','-gUj',str(path)],text=True).split())
    missing=['_'+name for name in names if '_'+name not in exported];assert not missing,(str(path),missing)
print('PASS four-key scalar whitelist, bounds/no ICC payload, unchanged gates,18 actual Mavericks public provider exports; no compile/runtime')
