#!/usr/bin/env python3
"""Run ONE rendered SQL with an existing local TP executable; preserve stdout,
stderr, version, return code, and hashes. Never auto-download or hide errors.
Legacy command contract: trace_processor_shell query -f QUERY TRACE.
"""
import argparse,hashlib,json,subprocess,sys
from pathlib import Path
from render_sql import render,DEFAULTS

def digest(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        for b in iter(lambda:f.read(1048576),b''):h.update(b)
    return h.hexdigest()

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--tp',required=True,type=Path);p.add_argument('--trace',required=True,type=Path)
    p.add_argument('--sql',required=True,type=Path);p.add_argument('--out',required=True,type=Path)
    p.add_argument('--timeout',type=int,default=60)
    for k,d in DEFAULTS.items():p.add_argument('--'+k.replace('_','-'),type=int,default=d)
    a=p.parse_args()
    try:
        if a.timeout<=0:raise ValueError('positive timeout required')
        for f in (a.tp,a.trace,a.sql):
            if not f.is_file():raise ValueError('missing file: '+str(f))
        a.out.mkdir(parents=False,exist_ok=False)
        q=a.out/'query.sql';q.write_text(render(a.sql,{k:getattr(a,k) for k in DEFAULTS}))
        cmd=[str(a.tp.resolve()),'query','-f',str(q.resolve()),str(a.trace.resolve())]
        v=subprocess.run([str(a.tp.resolve()),'--version'],capture_output=True,text=True,timeout=10)
        (a.out/'version.txt').write_text(v.stdout+v.stderr)
        with (a.out/'stdout.csv').open('w') as out,(a.out/'stderr.txt').open('w') as err:
            try:r=subprocess.run(cmd,stdout=out,stderr=err,timeout=a.timeout);rc=r.returncode
            except subprocess.TimeoutExpired:rc=124;err.write('\nQUERY_TIMEOUT\n')
        info={'command':cmd,'returncode':rc,'trace_sha256':digest(a.trace),'sql_sha256':digest(q),'tp_sha256':digest(a.tp),
              'note':'rc=0 means query ran, not diagnostic PASS; verify target, coverage, clocks, and evidence'}
        (a.out/'run.json').write_text(json.dumps(info,indent=2)+'\n')
        print(json.dumps(info,ensure_ascii=False))
        return 0 if rc==0 else 1
    except (OSError,ValueError,subprocess.SubprocessError) as e:
        print('ERROR: '+str(e),file=sys.stderr);return 2
if __name__=='__main__':raise SystemExit(main())
