#!/usr/bin/env python3
"""Execute one PerfettoSQL result query with explicit raw output, exit code and hashes.
Uses the existing v57.1/v58.2 CLI contract: TP query -f SQL TRACE.
Never downloads a TP, alters input data or interprets rc=0 as diagnostic success.
"""
import argparse,hashlib,json,subprocess,sys
from pathlib import Path
from render_sql import render

def digest(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for chunk in iter(lambda:f.read(1048576),b''):h.update(chunk)
    return h.hexdigest()

def run(tp,trace,sql,out,category='rdk.latency',slice_id=-1,timeout=60):
    tp,trace,sql,out=map(Path,(tp,trace,sql,out))
    if timeout<=0:raise ValueError('positive timeout required')
    for p in (tp,trace,sql):
        if not p.is_file():raise ValueError('missing file: '+str(p))
    out.mkdir(exist_ok=False)
    q=out/'query.sql';q.write_text(render(sql,category,slice_id))
    cmd=[str(tp.resolve()),'query','-f',str(q.resolve()),str(trace.resolve())]
    v=subprocess.run([str(tp.resolve()),'--version'],capture_output=True,text=True,timeout=10)
    (out/'version.txt').write_text(v.stdout+v.stderr)
    with (out/'stdout.csv').open('w') as stdout,(out/'stderr.txt').open('w') as stderr:
        try:rc=subprocess.run(cmd,stdout=stdout,stderr=stderr,timeout=timeout).returncode
        except subprocess.TimeoutExpired:rc=124;stderr.write('\nQUERY_TIMEOUT\n')
    meta=dict(command=cmd,returncode=rc,trace_sha256=digest(trace),tp_sha256=digest(tp),sql_sha256=digest(q),
              note='Exit 0 confirms execution only. Verify identity, quality, contract and coverage.')
    (out/'run.json').write_text(json.dumps(meta,indent=2)+'\n')
    if rc!=0:raise RuntimeError('query failed: rc=%d; see %s'%(rc,out))
    return meta

def main():
    p=argparse.ArgumentParser(description=__doc__)
    for n in ('tp','trace','sql','out'):p.add_argument('--'+n,required=True,type=Path)
    p.add_argument('--category',default='rdk.latency');p.add_argument('--slice-id',type=int,default=-1);p.add_argument('--timeout',type=int,default=60);a=p.parse_args()
    try:print(json.dumps(run(**vars(a)),ensure_ascii=False));return 0
    except (OSError,ValueError,RuntimeError,subprocess.SubprocessError) as e:print('ERROR:',e,file=sys.stderr);return 2
if __name__=='__main__':raise SystemExit(main())
