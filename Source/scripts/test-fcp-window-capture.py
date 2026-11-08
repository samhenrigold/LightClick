#!/usr/bin/env python3
"""Run only extracted identity selection/output-cap predicates, never the capture probe."""
from pathlib import Path
import subprocess
import tempfile
source=(Path(__file__).resolve().parents[1]/'probes/fcp-window-capture.m').read_text()
a=source.index('static int windowCandidate(');b=source.index('static NSDictionary *windowRecord(',a)
c=source.index('static size_t pngWrite(');d=source.index('int main(',c)
fixture=r'''
#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>
#include <errno.h>
typedef int BOOL;typedef unsigned CC_LONG;
#define YES 1
#define NO 0
typedef struct {double x,y,w,h;} CGRect;
static int CGRectEqualToRect(CGRect a,CGRect b){return a.x==b.x && a.y==b.y && a.w==b.w && a.h==b.h;}
''' + source[a:b] + r'''
static const size_t pngLimit=16;static int alive=1,writeCalls,eintrOnce;static size_t written,hashed;
static int room(void){return alive;}
static ssize_t write(int fd,const void *p,size_t n){(void)p;assert(fd==42);writeCalls++;if(eintrOnce){eintrOnce=0;errno=EINTR;return -1;}size_t amount=n>3?3:n;written+=amount;return amount;}
static void CC_SHA256_Update(int *ctx,const void *p,CC_LONG n){(void)ctx;(void)p;hashed+=n;}
typedef struct {int fd;size_t bytes;BOOL failed;int sha;} Output;
''' + source[c:d] + r'''
int main(void){
 CGRect saved={0,22,1280,705},other=saved;assert(windowCandidate(321,321,0,1,123,saved,saved));
 assert(!windowCandidate(1,1,0,1,123,saved,saved));assert(!windowCandidate(321,999,0,1,123,saved,saved));
 assert(!windowCandidate(321,321,1,1,123,saved,saved));assert(!windowCandidate(321,321,0,0,123,saved,saved));assert(!windowCandidate(321,321,0,1,0,saved,saved));
 other.x=.5;assert(!windowCandidate(321,321,0,1,123,other,saved));other=saved;other.h++;assert(!windowCandidate(321,321,0,1,123,other,saved));
 char bytes[20]={0};Output out={.fd=42};eintrOnce=1;
 assert(pngWrite(&out,bytes,10)==10 && written==10 && hashed==10 && out.bytes==10 && writeCalls==5);
 assert(pngWrite(&out,bytes,7)==0 && out.failed && written==10);
 out=(Output){.fd=42};alive=0;assert(pngWrite(&out,bytes,1)==0 && out.failed && written==10);
 out=(Output){.fd=42};alive=1;assert(pngWrite(&out,bytes,16)==16 && out.bytes==16);assert(pngWrite(&out,bytes,1)==0 && out.failed);
 return 0;
}
'''
assert source.count('CGWindowListCreateImage(')==1
assert source.index('identity(pid,expected,&before)')<source.index('CGWindowListCreateImage(')
assert source.index('windowRecord(pid,saved,rows)')<source.index('CGWindowListCreateImage(')
assert 'kCGWindowListOptionIncludingWindow' in source and 'kCGWindowImageBoundsIgnoreFraming|kCGWindowImageNominalResolution' in source
assert source.index('CGDataProviderCopyData(')<source.index('CGImageDestinationFinalize(')<source.index('windowAfter=windowRecord(')
assert 'mkstemps(outputPath,4)' in source and 'fchmod(fd,0600)' in source and '(info.st_mode&0777)!=0700' in source
assert 'strncmp(system.release,"13.",3)' in source
for forbidden in ('CGEvent','AXUIElement','activateWithOptions','/Users/','kCGWindowListOptionAll'):
 assert forbidden not in source
with tempfile.TemporaryDirectory(prefix='lightclick-fcp-window-predicate-')as temporary:
 p=Path(temporary);c=p/'predicate.c';binary=p/'predicate';c.write_text(fixture)
 subprocess.run(['nice','-n','10','xcrun','clang','-std=c11','-Wall','-Wextra','-Werror',str(c),'-o',str(binary)],check=True,timeout=20)
 subprocess.run([str(binary)],check=True,timeout=5)
print('PASS exact window selection, output cap/deadline/EINTR/partial writes, identity/order/private-path/no-input source guards; capture helper never executed')
