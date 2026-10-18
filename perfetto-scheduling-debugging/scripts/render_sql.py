#!/usr/bin/env python3
"""Safely fill numeric SQL parameters. One output file -> one query result set.
Example: render_sql.py sql/01-state-window.sql --utid 17 --start-ns 100 --end-ns 200
"""
import argparse
import re
import sys
from pathlib import Path
DEFAULTS=dict(utid=-1,wait_id=-1,start_ns=-1,end_ns=-1,cpu=-1,
              switch_session=-1,waking_session=-1,clock_verified=0,
              streams_verified=0,tolerance_ns=0,callsite_id=-1)
PAT=re.compile(r'\{\{([a-z_]+)\}\}')

def render(path,params=None):
    p=DEFAULTS.copy(); supplied=params or {}
    for k,v in supplied.items():
        if k not in p:raise ValueError('unknown parameter '+k)
        if isinstance(v,bool) or not isinstance(v,int):raise ValueError('numeric integer parameters only')
        p[k]=v
    for k,v in p.items():
        if not -(2**63)<=v<2**63:raise ValueError('out of int64 range')
        if k not in ('clock_verified','streams_verified','tolerance_ns') and v< -1:raise ValueError('invalid negative value')
    if any(p[k] not in (0,1) for k in ('clock_verified','streams_verified')):raise ValueError('proof flags must be 0/1')
    if not 0<=p['tolerance_ns']<=1000000:raise ValueError('tolerance 0..1ms; must be explicitly justified, default exact')
    if p['start_ns']>=0 and p['end_ns']>=0 and p['end_ns']<=p['start_ns']:raise ValueError('window must be [start,end), end>start')
    text=Path(path).read_text()
    def replace(m):
        if m[1] not in p:raise ValueError('unknown template parameter '+m[1])
        return str(p[m[1]])
    return PAT.sub(replace,text)

def main():
    a=argparse.ArgumentParser(description=__doc__);a.add_argument('sql',type=Path)
    for name,default in DEFAULTS.items():a.add_argument('--'+name.replace('_','-'),type=int,default=default)
    a.add_argument('--output',type=Path)
    p=a.parse_args()
    try:
        text=render(p.sql,{k:getattr(p,k) for k in DEFAULTS})
        if p.output:
            with p.output.open('x') as f:f.write(text)
        else:sys.stdout.write(text)
    except (ValueError,OSError) as e:print('ERROR: '+str(e),file=sys.stderr);return 2
    return 0
if __name__=='__main__':raise SystemExit(main())
