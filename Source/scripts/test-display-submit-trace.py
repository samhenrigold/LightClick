#!/usr/bin/env python3
"""Emit a host-only fixture comparing real submit queue logic with fixed pre-trace commit.

--emit-c FILE emits only. --check BINARY exercises the already compiled metadata/stub fixture.
No CGL, GPU, Mach message or guest execution: queue/port helpers below are stubs.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parents[1]
relative = 'Source/PassthroughOpenGL/direct-display-sender-host.c'
current = (root / 'PassthroughOpenGL/direct-display-sender-host.c').read_text()
baseline = subprocess.check_output(['git', 'show', '928b7fcb86ea2f0d2b77798a3a97afb63a791654:' + relative], cwd=root, text=True)


def function(source):
    match = re.search(r'(?m)^static GLenum DGDisplaySubmitSealed\([^;{]*\)\s*\{', source)
    assert match
    at, depth = match.end(), 1
    while depth:
        depth += (source[at] == '{') - (source[at] == '}')
        at += 1
    return source[match.start():at]


def emit(path):
    old, new = function(baseline), function(current)
    for lock in ('pthread_mutex_lock(', 'pthread_mutex_unlock('):
        assert old.count(lock) == new.count(lock)
    assert new.rindex('VIMDisplaySubmitTrace(error,') > new.rindex('pthread_mutex_unlock(')
    header = json.dumps(str(root / 'PassthroughOpenGL/display-submit-trace.h'))
    prefix = r'''
#include <assert.h>
#include <mach/mach.h>
#include HEADER
typedef unsigned GLenum;
#define GL_NO_ERROR 0u
#define GL_INVALID_VALUE 0x501u
#define GL_INVALID_OPERATION 0x502u
struct DGSurfaceSnapshot { void *completion,*completion_queue;unsigned width,height,refs;uint64_t epoch; };
struct DGDisplaySubmission {struct DGSurfaceSnapshot *version;mach_port_t reply;uint64_t ticket;};
struct DGDisplaySender {const void *owner;pthread_mutex_t lock;mach_port_t events;uint64_t next_ticket;int stopping;struct DGDisplaySubmission slots[3];};
static pthread_mutex_t dg_display_sender_lock=PTHREAD_MUTEX_INITIALIZER;
static struct DGDisplaySender *dg_display_sender,storage;
static struct DGSurfaceSnapshot version,occupied_version;
static int token,other,allocate_error,move_error,create_error;
static char calls[16];static unsigned count;
static void event(char c){assert(count<15);calls[count++]=c;calls[count]=0;}
static struct DGDisplaySender *DGDisplaySenderCreate(const void *owner){(void)owner;event('C');return create_error?NULL:&storage;}
static void DGDisplaySenderWake(struct DGDisplaySender *sender){assert(sender==&storage);event('W');}
static kern_return_t fake_allocate(task_t task,mach_port_right_t right,mach_port_name_t *name){(void)task;(void)right;event('A');if(!allocate_error)*name=123;return allocate_error;}
static kern_return_t fake_move(task_t task,mach_port_name_t name,mach_port_name_t set){(void)task;(void)name;(void)set;event('M');return move_error;}
static kern_return_t fake_destroy(task_t task,mach_port_name_t name){(void)task;assert(name==123);event('D');return 0;}
#undef mach_task_self
#define mach_task_self() 0
#define mach_port_allocate fake_allocate
#define mach_port_move_member fake_move
#define mach_port_destroy fake_destroy
'''.replace('HEADER', header)
    checks = r'''
static void reset(unsigned used,int stopping,int owner,int exhausted,int alloc,int move,int create){
    memset(&storage,0,sizeof(storage));pthread_mutex_init(&storage.lock,NULL);
    storage.owner=owner?&token:&other;storage.next_ticket=exhausted?UINT64_MAX:7;storage.stopping=stopping;
    for(unsigned i=0;i<used;i++)storage.slots[i].version=&occupied_version;
    dg_display_sender=&storage;version=(struct DGSurfaceSnapshot){(void *)1,(void *)1,800,600,1,31};
    allocate_error=alloc;move_error=move;create_error=create;memset(calls,0,sizeof(calls));count=0;
}
int main(int argc,char **argv){
    assert(argc==2);
    if(!strcmp(argv[1],"bounds")){
        assert(VIMDisplaySubmitTraceEnabled());
        for(unsigned i=0;i<400;i++)VIMDisplaySubmitTrace(0,0,0,100+i,1+i,mach_absolute_time());
        for(unsigned i=0;i<400;i++)VIMDisplaySubmitTrace(GL_INVALID_OPERATION,3,1,500+i,0,mach_absolute_time());
        for(unsigned i=0;i<3;i++)VIMDisplaySubmitTrace(GL_INVALID_VALUE,-1,0,0,0,mach_absolute_time());
        return 0;
    }
    for(unsigned used=0;used<=3;used++)for(int stop=0;stop<2;stop++)for(int owner=0;owner<2;owner++)for(int exhaust=0;exhaust<2;exhaust++){
        int expected=used==3&&owner&&!stop&&!exhaust;
        assert(VIMDisplaySubmitFullRefusal(GL_INVALID_OPERATION,used,owner,stop,exhaust)==expected);
        assert(!VIMDisplaySubmitFullRefusal(0,used,owner,stop,exhaust));
    }
    for(unsigned used=0;used<=3;used++)for(int stop=0;stop<2;stop++)for(int owner=0;owner<2;owner++)
    for(int exhausted=0;exhausted<2;exhausted++)for(int failure=0;failure<3;failure++){
        reset(used,stop,owner,exhausted,failure==1,failure==2,0);uint64_t a=0xdeadbeef;
        GLenum old=baseline_submit(&token,&version,&a);struct DGDisplaySubmission slots[3];memcpy(slots,storage.slots,sizeof(slots));
        uint64_t next=storage.next_ticket;unsigned refs=version.refs;char trace[16];memcpy(trace,calls,sizeof(trace));pthread_mutex_destroy(&storage.lock);
        reset(used,stop,owner,exhausted,failure==1,failure==2,0);uint64_t b=0xdeadbeef;
        GLenum now=DGDisplaySubmitSealed(&token,&version,&b);
        assert(now==old&&a==b&&next==storage.next_ticket&&refs==version.refs);
        assert(!memcmp(slots,storage.slots,sizeof(slots))&&!strcmp(trace,calls));pthread_mutex_destroy(&storage.lock);
    }
    reset(0,0,1,0,0,0,1);dg_display_sender=NULL;uint64_t ticket=999;
    assert(DGDisplaySubmitSealed(&token,&version,&ticket)==GL_INVALID_OPERATION&&ticket==999);pthread_mutex_destroy(&storage.lock);
    assert(DGDisplaySubmitSealed(NULL,NULL,NULL)==GL_INVALID_VALUE);
    if(!strcmp(argv[1],"off"))assert(!vim_submit_trace_enabled&&vim_submit_attempts==0);
    puts("PASS actual submit result/ticket/refs/slot/port/wake semantics unchanged, full/other classification");return 0;
}
'''
    path.write_text(prefix + old.replace('DGDisplaySubmitSealed(', 'baseline_submit(', 1) + new + checks)
    print('Wrote', path)


def check(binary):
    for value in (None, '0', 'true', '01'):
        env = dict(os.environ)
        env.pop('VIM_DISPLAY_SUBMIT_TRACE', None)
        if value is not None: env['VIM_DISPLAY_SUBMIT_TRACE'] = value
        row = subprocess.run([str(binary), 'off'], env=env, capture_output=True, text=True, timeout=10, check=True)
        assert row.stderr == '', (value, row.stderr)
    env = dict(os.environ, VIM_DISPLAY_SUBMIT_TRACE='1')
    row = subprocess.run([str(binary), 'mechanism'], env=env, capture_output=True, text=True, timeout=10, check=True)
    assert 'enabled=1' in row.stderr and 'summary=1' in row.stderr
    row = subprocess.run([str(binary), 'bounds'], env=env, capture_output=True, text=True, timeout=10, check=True)
    lines = row.stderr.splitlines()
    assert len(lines) == 260, len(lines)
    assert sum('attempt=' in line for line in lines) == 256
    assert sum('attempt_rows_truncated=1' in line for line in lines) == 1
    assert sum('full_refusal_rows_truncated=1' in line for line in lines) == 1
    assert 'attempt=401' in row.stderr, 'late refusal after first128 attempts lost'
    assert 'attempts=803 accepted=400 full_refusals=400 other_errors=3' in row.stderr
    print('PASS exact opt-in/default silent, queue behavior, reserved late-refusal budget, hard260-line bound and totals')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--emit-c', type=Path)
    group.add_argument('--check', type=Path)
    args = parser.parse_args()
    emit(args.emit_c) if args.emit_c else check(args.check)
