#!/usr/bin/env python3
"""Verify immutable package files and local markdown links. Ignores Python bytecode only."""
import argparse,hashlib,json,re,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

def valid_path(s):
    p=Path(s)
    return bool(s) and not p.is_absolute() and '..' not in p.parts

def verify(root):
    root=Path(root).resolve();meta=json.loads((root/'MANIFEST.json').read_text())
    if meta.get('name')!='perfetto-latency-debugging' or meta.get('version')!='0.1.1':raise ValueError('package identity mismatch')
    hs=meta.get('files_sha256',{})
    if not hs:raise ValueError('empty file manifest')
    for name,sha in hs.items():
        if not valid_path(name):raise ValueError('unsafe manifest path')
        f=root/name
        if f.is_symlink() or not f.is_file():raise ValueError('missing/unsafe resource: '+name)
        if hashlib.sha256(f.read_bytes()).hexdigest()!=sha:raise ValueError('hash mismatch: '+name)
    expected=set(hs)|{'MANIFEST.json','SHA256SUMS.txt'}
    actual={str(f.relative_to(root)) for f in root.rglob('*') if f.is_file() and '__pycache__' not in f.parts and f.suffix!='.pyc'}
    if actual!=expected:raise ValueError('unexpected/missing files: '+str(sorted(actual^expected)))
    # SHA256SUMS covers MANIFEST itself, but not its own bytes (no circular digest).
    lines=(root/'SHA256SUMS.txt').read_text().splitlines();seen=set()
    for line in lines:
        sha,name=line.split('  ',1)
        if name in seen or not valid_path(name):raise ValueError('duplicate/unsafe SHA list path')
        seen.add(name)
        if hashlib.sha256((root/name).read_bytes()).hexdigest()!=sha:raise ValueError('SHA list mismatch: '+name)
    if seen!=actual-{'SHA256SUMS.txt'}:raise ValueError('SHA list coverage mismatch')
    missing=[]
    for md in root.rglob('*.md'):
        for target in re.findall(r'\]\(([^)]+)\)',md.read_text()):
            if re.match(r'^[a-z]+://|^#',target):continue
            path=target.split('#',1)[0]
            if path and not (md.parent/path).exists():missing.append(str(md.relative_to(root))+': '+path)
    if missing:raise ValueError('broken Markdown links: '+str(missing))
    resources=json.loads((root/'RESOURCE_LIST.json').read_text())
    if any(not valid_path(x) or not (root/x).is_file() for x in resources):raise ValueError('resource list incomplete')
    return dict(name=meta['name'],version=meta['version'],status=meta['status'],files=len(actual),hashes=len(hs),resources=len(resources))

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,default=ROOT);a=p.parse_args()
    try:print('PACKAGE_PASS '+json.dumps(verify(a.root)));return 0
    except Exception as e:print('PACKAGE_FAIL:',e,file=sys.stderr);return 2
if __name__=='__main__':raise SystemExit(main())
