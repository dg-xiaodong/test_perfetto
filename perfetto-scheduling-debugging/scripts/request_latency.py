#!/usr/bin/env python3
"""Convert normalized business CSV into queue/processing/total latency.
Input: request_id,utid,enq_ns,start_ns,end_ns. All must share a VERIFIED clock.
No inference of thread state from elapsed time. Multi-worker critical paths need
application-specific modeling; these rows describe one processing interval.
"""
import argparse,csv,sys
from pathlib import Path

def measure(row):
    enq,st,en=(int(row[k]) for k in ('enq_ns','start_ns','end_ns'))
    utid=int(row['utid'])
    if utid<0 or not 0<=enq<=st<=en or en>=2**63:raise ValueError('invalid timestamp order or UTID')
    return dict(request_id=row['request_id'],utid=utid,enq_ns=enq,start_ns=st,end_ns=en,
                queue_ns=st-enq,processing_ns=en-st,total_ns=en-enq)

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('csv',type=Path)
    p.add_argument('--clock-verified',action='store_true',required=True)
    a=p.parse_args()
    try:
        with a.csv.open(newline='') as f:rows=[measure(r) for r in csv.DictReader(f)]
        keys=['request_id','utid','enq_ns','start_ns','end_ns','queue_ns','processing_ns','total_ns']
        out=csv.DictWriter(sys.stdout,fieldnames=keys);out.writeheader();out.writerows(rows)
    except (KeyError,ValueError,OSError) as e:print('ERROR: '+str(e),file=sys.stderr);return 2
    return 0
if __name__=='__main__':raise SystemExit(main())
