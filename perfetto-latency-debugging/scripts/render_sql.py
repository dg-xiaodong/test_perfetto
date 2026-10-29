#!/usr/bin/env python3
"""Only validated literal parameters; no arbitrary SQL expressions."""
import argparse,re,sys
from pathlib import Path

def render(path, category='rdk.latency', slice_id=-1):
    if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_.-]{0,63}',category):raise ValueError('invalid category')
    if isinstance(slice_id,bool) or not isinstance(slice_id,int) or slice_id< -1:raise ValueError('invalid slice id')
    s=Path(path).read_text().replace('${CATEGORY}',category).replace('${SLICE_ID}',str(slice_id))
    if re.search(r'\$\{',s):raise ValueError('unknown template parameter')
    return s

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('sql',type=Path);p.add_argument('--category',default='rdk.latency');p.add_argument('--slice-id',type=int,default=-1);p.add_argument('--output',type=Path);a=p.parse_args()
    try:
        s=render(a.sql,a.category,a.slice_id)
        if a.output:
            with a.output.open('x') as f:f.write(s)
        else:sys.stdout.write(s)
    except (OSError,ValueError) as e:print('ERROR:',e,file=sys.stderr);return 2
    return 0
if __name__=='__main__':raise SystemExit(main())
