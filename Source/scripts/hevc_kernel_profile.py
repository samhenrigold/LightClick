"""Bounded guest-kernel sampling diagnostic. No EL1 visibility or timing qualification."""
import json
import re

LIMIT = 512 * 1024
PROFILE = r'''#pragma D option quiet
#pragma D option aggsize=8m
profile-997 /arg0/ { @kernel[func(arg0)] = count(); @stacks[stack(12)] = count(); @kind["kernel"] = count(); }
profile-997 /arg1 && substr(execname,0,9)=="VTDecoder"/ { @user[usym(arg1)] = count(); @kind["VT-user"] = count(); }
tick-60s { printf("PROFILE_DEADLINE\n"); exit(1); }
dtrace:::END {
 printa("PROFILE_KIND %s %@d\n", @kind);
 trunc(@kernel,100); printa("PROFILE_KERNEL %a %@d\n", @kernel);
 trunc(@user,100); printa("PROFILE_USER %A %@d\n", @user);
 printf("PROFILE_STACKS_BEGIN\n"); trunc(@stacks,64); printa(@stacks); printf("PROFILE_STACKS_END\n");
}
'''

# Python2.7-compatible guest supervisor. All signals target its own live Popen process group.
GUEST = r'''import os, sys, json, tempfile, subprocess, resource, signal, time, shutil, stat, errno
probe, space, profile = json.loads(sys.argv[1])
directory = tempfile.mkdtemp(prefix='lightclick-hevc-kernel-',dir='/private/var/tmp')
p = None
result = {'format_version':1,'timed_out':False,'files':{}}
def quote(s): return "'" + s.replace("'", "'\\''") + "'"
def owned_child():
    os.setsid()
    resource.setrlimit(resource.RLIMIT_FSIZE,(524288,524288))
def stop_owned():
    if p is not None and p.poll() is None:
        try: os.killpg(p.pid,signal.SIGTERM)
        except OSError as e:
            if e.errno != errno.ESRCH: raise
        end=time.time()+3
        while p.poll() is None and time.time()<end: time.sleep(.05)
        if p.poll() is None:
            try: os.killpg(p.pid,signal.SIGKILL)
            except OSError as e:
                if e.errno != errno.ESRCH: raise
        p.wait()
try:
    report=directory+'/probe.json'; err=directory+'/probe.stderr'
    args=[probe,'--full-resolution','/Library/Desktop Pictures/Mojave.heic','--index','0','--timeout','50','--max-output-bytes','268435456','--output-color-space',space,'--repeat-draw-seconds','30']
    # A private script avoids relying on DTrace -c to interpret redirection.
    wrapper=directory+'/run-probe.sh'
    command=' '.join(quote(a) for a in args)+' >'+quote(report)+' 2>'+quote(err)
    with open(wrapper,'wb') as f: f.write(('#!/bin/sh\n'+command+'\nstatus=$?\nprintf \'%s\\n\' \"$status\" >'+quote(directory+'/probe.exit')+'\nexit \"$status\"\n').encode('ascii'))
    os.chmod(wrapper,0o700)
    with open(directory+'/dtrace.stdout','wb') as out, open(directory+'/dtrace.stderr','wb') as errors:
        p=subprocess.Popen(['/usr/sbin/dtrace','-q','-n',profile,'-c',wrapper],stdin=open(os.devnull,'rb'),stdout=out,stderr=errors,preexec_fn=owned_child,close_fds=True)
        end=time.time()+65
        while p.poll() is None and time.time()<end: time.sleep(.1)
        result['timed_out']=p.poll() is None
        stop_owned()
        result['dtrace_exit_code']=p.returncode
except Exception as e: result['error']=repr(e)
finally:
    stop_owned()
    for name in ('dtrace.stdout','dtrace.stderr','probe.json','probe.stderr','probe.exit'):
        path=directory+'/'+name
        try:
            info=os.lstat(path)
            if not stat.S_ISREG(info.st_mode) or info.st_size>524288: raise ValueError('not bounded regular output')
            with open(path,'rb') as f: data=f.read(524289)
            result['files'][name]={'bytes':len(data),'at_limit':len(data)>=524288,'text':data.decode('utf-8','replace')}
        except Exception as e: result['files'][name]={'error':repr(e)}
    shutil.rmtree(directory)
print(json.dumps(result))
'''


def parse_result(value, reference):
    """Reject incomplete/truncated observations; retain raw inputs at the caller before validation."""
    if not isinstance(value, dict) or value.get('format_version') != 1 or value.get('timed_out') is not False or value.get('error') or value.get('dtrace_exit_code') != 0:
        raise ValueError('supervisor or DTrace did not complete normally')
    files = value.get('files', {})
    texts = {}
    for name in ('dtrace.stdout','dtrace.stderr','probe.json','probe.stderr','probe.exit'):
        row = files.get(name, {})
        text = row.get('text')
        if row.get('error') or row.get('at_limit') is not False or not isinstance(text,str) or type(row.get('bytes')) is not int or not 0 <= row['bytes'] < LIMIT or len(text.encode('utf-8')) > 3*LIMIT:
            raise ValueError('missing or bounded output limit reached: '+name)
        texts[name] = text
    if texts['probe.exit'].strip() != '0': raise ValueError('resident probe exit was not zero')
    raw = texts['dtrace.stdout']
    if 'PROFILE_DEADLINE' in raw or any(token in texts['dtrace.stderr'].lower() for token in ('drop','error','failed','abort')):
        raise ValueError('deadline or DTrace sampling error')
    kinds = dict((kind,int(count)) for kind,count in re.findall(r'^PROFILE_KIND (kernel|VT-user) ([0-9]+)$',raw,re.M))
    kernel = [dict(symbol=symbol,samples=int(count)) for symbol,count in re.findall(r'^PROFILE_KERNEL (.+?)\s+([0-9]+)$',raw,re.M)]
    user = [dict(symbol=symbol,samples=int(count)) for symbol,count in re.findall(r'^PROFILE_USER (.+?)\s+([0-9]+)$',raw,re.M)]
    if not all(kinds.get(key,0)>0 for key in ('kernel','VT-user')) or not kernel or not user or raw.count('PROFILE_STACKS_BEGIN') != 1 or raw.count('PROFILE_STACKS_END') != 1:
        raise ValueError('incomplete profile coverage')
    stacks = raw.split('PROFILE_STACKS_BEGIN',1)[1].split('PROFILE_STACKS_END',1)[0]
    if not stacks.strip(): raise ValueError('empty kernel stacks')
    report=json.loads(texts['probe.json'])
    keys=('format_version','mode','input_sha256','input_bytes','pixel_sha256','item_index','item_count','width','height','row_bytes','output_bytes','requested_output_color_space','output_color_space','source_color_space','source_icc_bytes','source_icc_sha256','output_icc_bytes','output_icc_sha256','pixel_format','row_order','orientation','orientation_applied','rendering_intent')
    if not isinstance(report,dict) or any(report.get(key)!=reference.get(key) for key in keys):
        raise ValueError('resident probe differs from prior guest reference')
    if report.get('format_version') != 1 or report.get('mode') != 'full-resolution' or not re.fullmatch('[0-9a-f]{64}',str(report.get('pixel_sha256'))) or any(type(report.get(key)) is not int or report[key]<=0 for key in ('width','height','row_bytes','output_bytes')) or report['row_bytes']!=report['width']*4 or report['output_bytes']!=report['row_bytes']*report['height'] or report['output_bytes']>256*1024*1024:
        raise ValueError('invalid resident RGBA8 report')
    repeat=report.get('repeat_draw',{})
    if repeat.get('requested_seconds') != 30 or repeat.get('termination') != 'duration' or type(repeat.get('iterations')) is not int or not 1 <= repeat['iterations'] <= 256 or not isinstance(repeat.get('elapsed_seconds'),(float,int)) or not 30 <= repeat['elapsed_seconds'] <= 60:
        raise ValueError('resident probe duration not qualified')
    return dict(kind_samples=kinds,kernel_functions=kernel,vt_user_functions=user,kernel_stacks_raw=stacks,probe_report=report,
                note='System-wide guest kernel and VTDecoder user sampling under DTrace observer load, including setup and edge hashes. No EL1 monitor visibility, exclusive CPU attribution, or performance timing qualification.')
