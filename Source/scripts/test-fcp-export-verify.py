#!/usr/bin/env python3
"""Execute only extracted pure file/count/rational-time predicates; no AVFoundation calls."""
from pathlib import Path
import subprocess
import tempfile
source=(Path(__file__).resolve().parents[1]/'probes/fcp-export-verify.m').read_text()
a=source.index('static BOOL validMediaFile(');b=source.index('static NSDictionary *timeJSON(',a)
fixture=r'''
#include <CoreMedia/CMTime.h>
#include <sys/stat.h>
#include <stdint.h>
#include <assert.h>
typedef int BOOL;
''' + source[a:b] + r'''
int main(void){
 assert(validMediaFile(S_IFREG|0600,501,501,1,58747744,1));
 assert(!validMediaFile(S_IFREG|0600,501,501,1,58747743,1));
 assert(!validMediaFile(S_IFLNK|0600,501,501,1,58747744,1));
 assert(!validMediaFile(S_IFDIR|0700,501,501,1,58747744,1));
 assert(!validMediaFile(S_IFREG|0600,502,501,1,58747744,1));
 assert(!validMediaFile(S_IFREG|0600,0,0,1,58747744,1));
 assert(!validMediaFile(S_IFREG|0600,501,501,2,58747744,1));
 assert(validMediaFile(S_IFREG|0600,501,501,1,512ULL*1024*1024,0));
 assert(!validMediaFile(S_IFREG|0600,501,501,1,512ULL*1024*1024+1,0));
 assert(!validMediaFile(S_IFREG|0600,501,501,1,0,0));
 assert(sampleBudget(0,240,4096));assert(sampleBudget(240,0,4096));
 assert(!sampleBudget(239,2,2));assert(!sampleBudget(241,0,2));assert(!sampleBudget(0,1,4097));assert(!sampleBudget(0,UINT64_MAX,1));
 for(int frame=0;frame<=240;frame++){
  CMTime exact={(int64_t)frame*512,15360,kCMTimeFlags_Valid,0};assert(frameTime(exact,frame));exact.value++;assert(!frameTime(exact,frame));
 }
 CMTime last={239,30,kCMTimeFlags_Valid,0},one={1,30,kCMTimeFlags_Valid,0};assert(endAtEight(last,one));
 one.value=2;assert(!endAtEight(last,one));one.value=1;last.value=238;assert(!endAtEight(last,one));
 last=(CMTime){239,30,kCMTimeFlags_Valid,1};assert(!frameTime(last,239) && !endAtEight(last,one));
 last=(CMTime){239,30,0,0};assert(!frameTime(last,239) && !endAtEight(last,one));
 last=(CMTime){239,0,kCMTimeFlags_Valid,0};assert(!frameTime(last,239) && !endAtEight(last,one));
 last=(CMTime){INT64_MAX,INT32_MAX,kCMTimeFlags_Valid,0};assert(!frameTime(last,239) && !endAtEight(last,one));
 last=(CMTime){33333333,1000000000,kCMTimeFlags_Valid,0};assert(!frameTime(last,1));
 return 0;
}
'''
main=source[source.index('int main('):]
assert main.index('strncmp(system.release,"13.",3)')<main.index('AVURLAsset *source=')
assert 'getuid()==0' in main and 'console.st_uid!=getuid()' in main
assert 'O_RDONLY|O_NOFOLLOW|O_NONBLOCK'in source and 'input-prores422.mov'in source and '@"export.mov"'in source
assert '62dfa5b49d5f97d954c420d315c250015d8733f47c59752d002f8b841e650211'in source
assert 'outputSettings:nil'in source and 'output.alwaysCopiesSampleData=NO'in source
assert 'CMSampleBufferGetSampleTimingInfo(buffer,i,&timing)'in source and 'CMSampleBufferGetNumSamples(buffer)'in source
assert 'qsort(times,(size_t)used' in source and 'for(unsigned i=0;i<used;i++)' in source
assert 'g.requestedTimeToleranceBefore=kCMTimeZero;g.requestedTimeToleranceAfter=kCMTimeZero'in source
assert '@[@0,@30,@120,@239]'in source and 'g.apertureMode=AVAssetImageGeneratorApertureModeCleanAperture'in source
assert 'CMVideoFormatDescriptionGetPresentationDimensions(format,true,true)'in source
assert '[info[@"presentation_width"]doubleValue]==1920'in source and '[info[@"presentation_height"]doubleValue]==1080'in source
assert 'AVAssetImageGeneratorApertureModeEncodedPixels'not in source
assert source.count('verifyStable(sourceFD,sourcePath,&sourceStat)')==2 and source.count('verifyStable(outputFD,outputPath,&outputStat)')==2
assert 'alarm(65)'in source and 'deadline=began+60'in source
assert 'json.length>jsonLimit'in source and '[report removeObjectForKey:@"inline_pngs"]'in source and '@"REPORT_BUDGET_FAILURE"'in source
for forbidden in ('/Users/','CGWindow','AXUIElement','CGEvent','writeToFile','AVAssetWriter'):
 assert forbidden not in source
with tempfile.TemporaryDirectory(prefix='lightclick-fcp-export-predicates-')as temporary:
 p=Path(temporary);c=p/'predicates.c';binary=p/'predicates';c.write_text(fixture)
 subprocess.run(['nice','-n','10','xcrun','clang','-std=c11','-Wall','-Wextra','-Werror',str(c),'-o',str(binary)],check=True,timeout=20)
 subprocess.run([str(binary)],check=True,timeout=5)
print('PASS actual file/count/rational-time boundary predicates + scope/budget/order guards; no verifier or AVFoundation execution')
