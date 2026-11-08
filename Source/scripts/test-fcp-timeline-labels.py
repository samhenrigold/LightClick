#!/usr/bin/env python3
"""Run the actual exact-string matcher only; no AX helper or guest execution."""
import json
from pathlib import Path
import re
import subprocess
import tempfile

root=Path(__file__).resolve().parents[1]
source=(root/'probes/fcp-ax-actions.m').read_text()
start=source.index('static unsigned timelineFormatLabel(')
end=source.index('typedef struct { NSUInteger scanned,runtime',start)
matcher=source[start:end]
old='08:00 total - 1920\u2009×\u20091080 | 30 fps Stereo'
named='08:00 total - 1080p HD 30p Stereo'
tests=[(old,1),(named,2),('',0),(old.replace('\u2009',' '),0),
       (named+' ',0),(named.replace('08:00','09:00'),0),
       (named.replace('30p','25p'),0),(named.replace('1080p','720p'),0),
       (named.replace('Stereo','Mono'),0),(named+'\0suffix',0),(old+'\0suffix',0),('\0'+named,0)]
body=['#include <assert.h>','#include <string.h>',matcher,'int main(void){','assert(timelineFormatLabel(NULL,0)==0);']
for text,expected in tests:
    literal=json.dumps(text,ensure_ascii=False).replace('\\u0000','\\000')
    body.append('assert(timelineFormatLabel(%s,sizeof(%s)-1)==%d);'%(literal,literal,expected))
body.append('assert(timelineFormatLabel("08:00 total - 1080p HD 30p Stereo",0)==0);')
body+=['return 0;}']
verified=source[source.index('static BOOL verifiedTimeline('):source.index('static void inspectMasterShare(')]
assert 'return !evidence.incomplete && evidence.runtime==1 && evidence.project==1 && evidence.clip==1;' in verified
assert 'allowedRuntimeLabels' in verified and 'recognizedRuntimeLabels' in verified
counting=source[source.index('static void timelineEvidence('):source.index('static BOOL verifiedTimeline(')]
assert 'CFGetTypeID(value)==CFStringGetTypeID()' in counting and 'if(label){e->runtime++;' in counting
assert 'lengthOfBytesUsingEncoding:NSUTF8StringEncoding' in counting
assert 'CFRelease(value)' in counting
fixture=root/'Build/performance/perf59-fcp101-named-format/preflight/guest-report.json'
if fixture.exists():
    report=json.loads(fixture.read_text());view=report['workflow']['post_project_open_full_observer']
    observed=[]
    def visit(value):
        if isinstance(value,dict):
            if value.get('AXRole')=='AXStaticText' and value.get('AXDescription')=='runtime':observed.append(value.get('AXValue'))
            for child in value.values():visit(child)
        elif isinstance(value,list):
            for child in value:visit(child)
    visit(view)
    assert observed==[named],observed
with tempfile.TemporaryDirectory(prefix='lightclick-timeline-label-test-')as temporary:
    path=Path(temporary);c=path/'labels.c';binary=path/'labels';c.write_text('\n'.join(body))
    subprocess.run(['xcrun','clang','-std=c11','-Wall','-Wextra','-Werror',str(c),'-o',str(binary)],check=True,timeout=20)
    subprocess.run([str(binary)],check=True,timeout=5)
print('PASS actual matcher: both grounded labels, exact negative cases, unchanged uniqueness/clip guards; no AX execution')
