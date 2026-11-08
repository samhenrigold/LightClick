"""Read one vCPU's fixed shift census, or subtract two periodic snapshots. No execution."""
import argparse,json,pathlib,re,hashlib
ROW=re.compile(r'shift_helpers_bucket kind=([0-7]) bytes=(1|2|4|8) memory=([01]) cl=([01]) masked_zero=([01]) count=([0-9]+)')
NAMES=['rol','ror','rcl','rcr','shl','shr','sal','sar']
def parse(path):
    data=path.read_bytes()
    if len(data)>16*1024*1024:raise ValueError('tally too large')
    fields={};buckets={}
    for line in data.decode().splitlines():
        if line.startswith('shift_helpers_bucket '):
            m=ROW.fullmatch(line)
            if not m:raise ValueError('invalid bucket')
            *key,count=map(int,m.groups());key=tuple(key)
            if key in buckets or count>2**64-1:raise ValueError('duplicate/invalid counter')
            buckets[key]=count
        elif line.startswith('shift_helpers_'):
            parts=line.split()
            if len(parts)!=2 or parts[0] not in ['shift_helpers_enabled','shift_helpers_cpu_index','shift_helpers_svc64_entries','shift_helpers_unclassified']:raise ValueError('unknown census field')
            if parts[0] in fields or not parts[1].isdigit():raise ValueError('invalid census scalar')
            fields[parts[0]]=int(parts[1])
    if fields.get('shift_helpers_enabled')!=1 or len(buckets)!=256 or set(fields)!=set(['shift_helpers_enabled','shift_helpers_cpu_index','shift_helpers_svc64_entries','shift_helpers_unclassified']):raise ValueError('incomplete enabled census')
    if fields['shift_helpers_cpu_index']>7 or any(v>2**64-1 for v in fields.values()):raise ValueError('invalid scalar range')
    return {'path':str(path),'sha256':hashlib.sha256(data).hexdigest(),'fields':fields,'buckets':buckets}
def report(end,start=None):
    counts=dict(end['buckets']);svc=end['fields']['shift_helpers_svc64_entries'];unknown=end['fields']['shift_helpers_unclassified']
    if start:
        if start['fields']['shift_helpers_cpu_index']!=end['fields']['shift_helpers_cpu_index']:raise ValueError('different vCPUs')
        counts={k:v-start['buckets'][k] for k,v in counts.items()};svc-=start['fields']['shift_helpers_svc64_entries'];unknown-=start['fields']['shift_helpers_unclassified']
        if min([svc,unknown]+list(counts.values()))<0:raise ValueError('counter reset/nonmonotonic interval')
    total=sum(counts.values());rows=[]
    for (kind,width,memory,cl,zero),count in sorted(counts.items(),key=lambda x:(-x[1],x[0])):
        if count:rows.append({'kind':NAMES[kind],'kind_code':kind,'bytes':width,'operand':'memory' if memory else 'register','count_source':'CL' if cl else 'immediate','masked_zero':bool(zero),'entries':count,'fraction_of_classified':count/total if total else 0})
    return {'status':'CENSUS_READ','cpu_index':end['fields']['shift_helpers_cpu_index'],'start_snapshot':start['path'] if start else None,'end_snapshot':end['path'],'start_sha256':start['sha256'] if start else None,'end_sha256':end['sha256'],'classified_entries':total,'svc64_entries':svc,'unclassified_entries':unknown,'svc_minus_classified_and_unclassified':svc-total-unknown,'ranked_buckets':rows,'scope':'Per-vCPU helper entries only, not retired instructions/time/speedup. Memory-store retries can count again; inline and immediate-zero paths absent. Periodic snapshots are asynchronous and may not reconcile atomically. Interval endpoints delimit publications, not exact guest task boundaries.'}
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--end',type=pathlib.Path,required=True);p.add_argument('--start',type=pathlib.Path);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
    result=report(parse(a.end),parse(a.start) if a.start else None)
    with a.output.open('x') as f:json.dump(result,f,indent=2);f.write('\n')
